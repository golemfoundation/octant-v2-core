// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ISwapper } from "./interfaces/ISwapper.sol";
import { ITokenizedStrategy } from "./interfaces/ITokenizedStrategy.sol";
import { YieldForwarder, IRedeemable, IReportable } from "./YieldForwarder.sol";

/// @notice Minimal ERC4626 interface to read a strategy's underlying asset
interface IERC4626Asset {
    /// @notice Returns the address of the underlying asset
    /// @return The address of the strategy's underlying ERC4626 asset
    function asset() external view returns (address);
}

/// @notice Minimal interface for ERC-4626 maxRedeem
/// @dev Defined inline here (rather than imported from YieldForwarder) so this
///      contract compiles standalone on develop while the matching base-class
///      interface declarations ship in the sibling forwarder PR. Once both PRs merge,
///      both copies are byte-for-byte identical.
interface IMaxRedeem {
    /// @notice Maximum shares redeemable by `owner` right now (ERC-4626)
    /// @param owner Address whose redeem headroom is queried
    /// @return maxShares Upper bound on shares redeemable by `owner`
    function maxRedeem(address owner) external view returns (uint256 maxShares);
}

/// @notice Minimal interface for ERC-4626 convertToAssets (floor rounding)
interface IConvertible {
    /// @notice Preview the assets returned for `shares`, rounded down (ERC-4626)
    /// @param shares Amount of shares to preview
    /// @return assets Assets that would be returned by redeem(), before fees/loss
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
}

/**
 * @title SwappingYieldForwarder
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Extends YieldForwarder with an additional swap step before forwarding to the receiver.
 * @dev Inherits reportAndForward() from YieldForwarder (no-swap fallback) and adds
 *      reportSwapAndForward() which swaps via a pluggable ISwapper before forwarding.
 *
 *      This dual-mode design acts as a built-in circuit breaker: if the swap protocol
 *      is unavailable, the keeper simply calls the inherited non-swapping path instead.
 *
 *      CALL CHAIN (with swap):
 *      Keeper EOA -> reportSwapAndForward() -> strategy.report() -> profit shares
 *      minted to this contract -> redeem shares to self -> swap via ISwapper ->
 *      target asset forwarded to receiver
 *
 *      CALL CHAIN (without swap / fallback):
 *      Keeper EOA -> reportAndForward() [inherited] -> strategy.report() -> profit shares
 *      minted to this contract -> redeem shares directly to receiver
 *
 *      DESIGN:
 *      - Keeper-gated: only the designated keeper can trigger yield forwarding
 *      - Single-purpose: assets can only flow to the hardcoded receiver
 *      - Pluggable swap: ISwapper adapter handles DEX-specific logic; the adapter
 *        itself is settable by the vault's management() role so deeper pools or
 *        newer adapter versions can be adopted without redeploying the forwarder
 *      - Dual-mode: keeper picks swap vs no-swap path at call-time
 *      - Strategy is passed as a call-time parameter to avoid circular dependencies
 */
contract SwappingYieldForwarder is YieldForwarder {
    using SafeERC20 for IERC20;

    // ============================================
    // ERRORS
    // ============================================

    /// @notice Thrown when the swapper address is zero
    error InvalidSwapper();

    /// @notice Thrown when the target asset address is zero
    error InvalidTargetAsset();

    /// @notice Thrown when the vault address is zero
    error InvalidVault();

    /// @notice Thrown when a swapper-management function is called by a non-management address
    error OnlyVaultManagement();

    /// @notice Thrown when a swapper reports an output below the enforced minimum
    /// @param expected Minimum amount expected
    /// @param actual Amount actually reported
    error InsufficientSwapOutput(uint256 expected, uint256 actual);

    /// @notice Thrown when setMinSlippageBps is called with a value above MAX_BPS
    error InvalidSlippageBps();

    /// @notice Thrown when the caller's minAmountOut falls below the admin-set floor
    /// @param floor Required minimum (assetsIn * minSlippageBps / MAX_BPS)
    /// @param supplied The minAmountOut the keeper passed in
    error SlippageFloorTooLoose(uint256 floor, uint256 supplied);

    /// @notice Thrown when `reportSwapAndForward` is called past the caller-supplied deadline
    /// @param deadline The keeper-chosen expiry timestamp (seconds since epoch)
    /// @param blockTimestamp The block time at which the call landed
    error ExpiredDeadline(uint256 deadline, uint256 blockTimestamp);

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when shares are redeemed, swapped to target asset, and forwarded
    /// @param strategy Address of the strategy whose shares were redeemed
    /// @param receiver Address that received the target assets
    /// @param shares Amount of shares redeemed
    /// @param assetsIn Amount of underlying assets redeemed (swap input)
    /// @param assetsOut Amount of target assets forwarded (swap output)
    event YieldSwappedAndForwarded(
        address indexed strategy,
        address indexed receiver,
        uint256 shares,
        uint256 assetsIn,
        uint256 assetsOut
    );

    /// @notice Emitted when the swap adapter is replaced by vault management
    /// @param oldSwapper The previous ISwapper implementation
    /// @param newSwapper The newly installed ISwapper implementation
    event SwapperUpdated(address indexed oldSwapper, address indexed newSwapper);

    /// @notice Emitted when the admin-set slippage floor is updated
    /// @param oldBps Previous floor (basis points of assetsIn)
    /// @param newBps New floor
    event MinSlippageBpsUpdated(uint16 oldBps, uint16 newBps);

    // ============================================
    // STATE
    // ============================================

    /// @notice The desired output token after swapping
    /// @dev Set once at construction, cannot be changed
    address public immutable targetAsset;

    /// @notice The governance source for this forwarder
    /// @dev Calls to vault.management() at swapper-management time authorize the caller.
    ///      In a 1:1 forwarder-to-vault deployment this is the tokenized strategy
    ///      whose profit shares flow through this forwarder; vault management is
    ///      the same multisig that already controls keeper/dragon-router rotation.
    address public immutable vault;

    /// @notice The swap adapter used to convert underlying -> target asset
    /// @dev Settable by vault.management() to pivot to a different adapter
    ///      (e.g. a new pool tier, a new DEX version) without redeploying.
    ISwapper public swapper;

    /// @notice Denominator for basis-point calculations (10_000 = 100%)
    uint16 public constant MAX_BPS = 10_000;

    /// @notice Floor on minAmountOut, denominated as basis points of assetsIn.
    /// @dev Set at construction so the deployment config explicitly chooses whether
    ///      the floor is active from the first report. A value of 0 is an intentional
    ///      opt-out for routes where management relies on the keeper's oracle-informed
    ///      minAmountOut instead of a near-parity floor.
    uint16 public minSlippageBps;

    // ============================================
    // MODIFIERS
    // ============================================

    /// @dev Restricts a call to the vault's management() address. Reading this at call
    ///      time (instead of caching a local admin) means rotation via the vault's
    ///      own two-step transfer (setPendingManagement / acceptManagement) is
    ///      picked up automatically.
    modifier onlyVaultManagement() {
        if (msg.sender != ITokenizedStrategy(vault).management()) revert OnlyVaultManagement();
        _;
    }

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /// @notice Creates a new SwappingYieldForwarder
    /// @param _receiver Address that will receive all forwarded assets
    /// @param _keeper Address authorized to call reportAndForward / reportSwapAndForward
    /// @param _targetAsset Address of the desired output token after swapping
    /// @param _swapper Initial ISwapper implementation for DEX routing
    /// @param _vault Vault contract whose management() controls swapper rotation
    /// @param _minSlippageBps Initial floor in basis points of assetsIn (0 disables)
    constructor(
        address _receiver,
        address _keeper,
        address _targetAsset,
        address _swapper,
        address _vault,
        uint16 _minSlippageBps
    ) YieldForwarder(_receiver, _keeper) {
        if (_targetAsset == address(0)) revert InvalidTargetAsset();
        if (_swapper == address(0)) revert InvalidSwapper();
        if (_vault == address(0)) revert InvalidVault();
        if (_minSlippageBps > MAX_BPS) revert InvalidSlippageBps();
        targetAsset = _targetAsset;
        swapper = ISwapper(_swapper);
        vault = _vault;
        minSlippageBps = _minSlippageBps;
    }

    // ============================================
    // EXTERNAL FUNCTIONS
    // ============================================

    /// @notice Replace the active swap adapter
    /// @dev Authorized by vault.management(). The new adapter must expose the
    ///      ISwapper pull-pattern semantic; the forwarder enforces its own
    ///      minAmountOut re-check inside reportSwapAndForward as a
    ///      defence-in-depth guard against a buggy adapter.
    /// @param _newSwapper New ISwapper implementation
    function setSwapper(address _newSwapper) external onlyVaultManagement {
        if (_newSwapper == address(0)) revert InvalidSwapper();
        emit SwapperUpdated(address(swapper), _newSwapper);
        swapper = ISwapper(_newSwapper);
    }

    /// @notice Update the slippage floor applied to the keeper's minAmountOut
    /// @dev Authorized by vault.management(). Passing 0 disables the floor.
    /// @param _bps New floor in basis points of assetsIn (max 10_000)
    function setMinSlippageBps(uint16 _bps) external onlyVaultManagement {
        if (_bps > MAX_BPS) revert InvalidSlippageBps();
        emit MinSlippageBpsUpdated(minSlippageBps, _bps);
        minSlippageBps = _bps;
    }

    /**
     * @notice Calls report() on the strategy, redeems profit shares, swaps the underlying
     *         asset to the target asset via the configured ISwapper, and forwards to the receiver
     * @dev The swap path: redeem to self -> approve swapper -> swapper.swap() -> receiver.
     *      The swapper enforces minAmountOut internally; the forwarder additionally
     *      re-checks the reported output against minAmountOut as defence-in-depth
     *      in case a future/buggy adapter forgets its own check.
     *
     *      If report() produces no profit shares, the function returns 0 without reverting.
     *      If redemption returns 0 assets, the function returns 0 without attempting a swap.
     *
     *      The caller MUST supply a fresh `deadline` (seconds since epoch).
     *      The underlying Uniswap V3 adapter uses `block.timestamp` as the router deadline,
     *      which always passes at inclusion and therefore adds no real time bound between
     *      the keeper's quote and settlement. Enforcing an explicit expiry at the forwarder
     *      prevents stale-slippage execution when a queued transaction lands in a later
     *      block against a moved market. There is no `0 = disabled` sentinel: keepers
     *      always pass `block.timestamp + buffer` at transaction assembly time.
     *
     * @param strategy Address of the strategy contract (must implement IReportable, IRedeemable, IERC20, IERC4626Asset)
     * @param maxLoss Maximum acceptable loss in basis points for the redemption
     * @param minAmountOut Minimum acceptable amount of target asset after swap (slippage protection)
     * @param deadline Unix timestamp (seconds) past which the call reverts with ExpiredDeadline
     * @return assetsOut Amount of target asset forwarded to receiver (0 if no profit shares)
     */
    function reportSwapAndForward(
        address strategy,
        uint256 maxLoss,
        uint256 minAmountOut,
        uint256 deadline
    ) external nonReentrant returns (uint256 assetsOut) {
        // Freshness check runs before any state-touching work so an expired
        // call fails cheaply and the keeper can retry with a fresh deadline.
        if (block.timestamp > deadline) revert ExpiredDeadline(deadline, block.timestamp);
        if (msg.sender != keeper) revert OnlyKeeper();

        IReportable(strategy).report();

        uint256 balance = IERC20(strategy).balanceOf(address(this));
        if (balance == 0) return 0;

        // Mirror reportAndForward's maxRedeem cap so the inner redeem cannot
        // revert when external vault liquidity tightens below the forwarder's
        // share balance. Residual shares stay at the forwarder until headroom recovers.
        uint256 shares = Math.min(balance, IMaxRedeem(strategy).maxRedeem(address(this)));
        if (shares == 0) return 0;

        // Mirror reportAndForward's zero-asset skip so a dust share balance on
        // a loss-impaired strategy (totalAssets < totalSupply) does not
        // roll back the report() above. The dust stays at the forwarder for a later
        // report once the imbalance resolves.
        if (IConvertible(strategy).convertToAssets(shares) == 0) return 0;

        // Redeem to this contract (not receiver) so we can swap first
        uint256 assetsIn = IRedeemable(strategy).redeem(shares, address(this), address(this), maxLoss);
        if (assetsIn == 0) {
            emit YieldSwappedAndForwarded(strategy, receiver, shares, 0, 0);
            return 0;
        }

        address assetIn = IERC4626Asset(strategy).asset();

        // Configured slippage floor: keeper's minAmountOut must be at least
        // `assetsIn * minSlippageBps / MAX_BPS`, normalized from `assetIn` decimals
        // into `targetAsset` decimals so mixed-decimal pairs (USDC 6 <-> USDS 18, etc.)
        // aren't silently bypassed or DoS'd. A constructor value of 0 disables the floor.
        // The 1:1 value assumption matches the documented use case (near-parity pairs:
        // stablecoin<>stablecoin, LST<>LST); admins must keep the floor at 0 for
        // non-parity pairs.
        uint16 floorBps = minSlippageBps;
        if (floorBps != 0) {
            uint8 inDecimals = IERC20Metadata(assetIn).decimals();
            uint8 outDecimals = IERC20Metadata(targetAsset).decimals();
            uint256 assetsInScaled = inDecimals >= outDecimals
                ? assetsIn / (10 ** (inDecimals - outDecimals))
                : assetsIn * (10 ** (outDecimals - inDecimals));
            uint256 floor = (assetsInScaled * floorBps) / MAX_BPS;
            if (minAmountOut < floor) revert SlippageFloorTooLoose(floor, minAmountOut);
        }

        // Approve swapper and execute swap to receiver. The swapper pulls
        // via transferFrom and returns any unused tokenIn before returning.
        ISwapper currentSwapper = swapper;
        IERC20(assetIn).forceApprove(address(currentSwapper), assetsIn);
        assetsOut = currentSwapper.swap(assetIn, targetAsset, assetsIn, minAmountOut, receiver);
        IERC20(assetIn).forceApprove(address(currentSwapper), 0);

        // Forwarder-side minAmountOut re-check, independent of the swapper's own
        // check. Catches an honest-but-buggy adapter whose swap() returns an
        // amountOut below the threshold without reverting.
        if (assetsOut < minAmountOut) revert InsufficientSwapOutput(minAmountOut, assetsOut);

        emit YieldSwappedAndForwarded(strategy, receiver, shares, assetsIn, assetsOut);
    }

    /// @inheritdoc YieldForwarder
    function _authorizeForwardToken() internal view override {
        if (msg.sender != keeper && msg.sender != ITokenizedStrategy(vault).management()) {
            revert OnlyVaultManagement();
        }
    }
}
