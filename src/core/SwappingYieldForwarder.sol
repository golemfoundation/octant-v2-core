// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ISwapper } from "./interfaces/ISwapper.sol";
import { ITokenizedStrategy } from "./interfaces/ITokenizedStrategy.sol";
import { YieldForwarder, IRedeemable, IReportable } from "./YieldForwarder.sol";

/// @notice Minimal ERC4626 interface to read a strategy's underlying asset
interface IERC4626Asset {
    /// @notice Returns the address of the underlying asset
    function asset() external view returns (address);
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
    constructor(
        address _receiver,
        address _keeper,
        address _targetAsset,
        address _swapper,
        address _vault
    ) YieldForwarder(_receiver, _keeper) {
        if (_targetAsset == address(0)) revert InvalidTargetAsset();
        if (_swapper == address(0)) revert InvalidSwapper();
        if (_vault == address(0)) revert InvalidVault();
        targetAsset = _targetAsset;
        swapper = ISwapper(_swapper);
        vault = _vault;
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
     * @param strategy Address of the strategy contract (must implement IReportable, IRedeemable, IERC20, IERC4626Asset)
     * @param maxLoss Maximum acceptable loss in basis points for the redemption
     * @param minAmountOut Minimum acceptable amount of target asset after swap (slippage protection)
     * @return assetsOut Amount of target asset forwarded to receiver (0 if no profit shares)
     */
    function reportSwapAndForward(
        address strategy,
        uint256 maxLoss,
        uint256 minAmountOut
    ) external nonReentrant returns (uint256 assetsOut) {
        if (msg.sender != keeper) revert OnlyKeeper();

        IReportable(strategy).report();

        uint256 shares = IERC20(strategy).balanceOf(address(this));
        if (shares == 0) return 0;

        // Redeem to this contract (not receiver) so we can swap first
        uint256 assetsIn = IRedeemable(strategy).redeem(shares, address(this), address(this), maxLoss);
        if (assetsIn == 0) {
            emit YieldSwappedAndForwarded(strategy, receiver, shares, 0, 0);
            return 0;
        }

        address assetIn = IERC4626Asset(strategy).asset();

        // Approve swapper and execute swap to receiver. The swapper pulls
        // via transferFrom and returns any unused tokenIn before returning.
        ISwapper currentSwapper = swapper;
        IERC20(assetIn).forceApprove(address(currentSwapper), assetsIn);
        assetsOut = currentSwapper.swap(assetIn, targetAsset, assetsIn, minAmountOut, receiver);

        // Forwarder-side minAmountOut re-check, independent of the swapper's own
        // check. Catches an honest-but-buggy adapter whose swap() returns an
        // amountOut below the threshold without reverting.
        if (assetsOut < minAmountOut) revert InsufficientSwapOutput(minAmountOut, assetsOut);

        emit YieldSwappedAndForwarded(strategy, receiver, shares, assetsIn, assetsOut);
    }
}
