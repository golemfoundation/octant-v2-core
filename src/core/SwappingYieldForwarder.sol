// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ISwapper } from "./interfaces/ISwapper.sol";
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
 *      - Fully immutable: no admin, no upgrades, no sweep
 *      - Keeper-gated: only the designated keeper can trigger
 *      - Single-purpose: assets can only flow to the hardcoded receiver
 *      - Pluggable swap: ISwapper adapter handles DEX-specific logic
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

    // ============================================
    // STATE
    // ============================================

    /// @notice The desired output token after swapping
    /// @dev Set once at construction, cannot be changed
    address public immutable targetAsset;

    /// @notice The swap adapter used to convert underlying -> target asset
    /// @dev Set once at construction, cannot be changed
    ISwapper public immutable swapper;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /// @notice Creates a new SwappingYieldForwarder with fixed receiver, keeper, target asset, and swapper
    /// @param _receiver Address that will receive all forwarded assets
    /// @param _keeper Address authorized to call reportAndForward / reportSwapAndForward
    /// @param _targetAsset Address of the desired output token after swapping
    /// @param _swapper Address of the ISwapper implementation for DEX routing
    constructor(
        address _receiver,
        address _keeper,
        address _targetAsset,
        address _swapper
    ) YieldForwarder(_receiver, _keeper) {
        if (_targetAsset == address(0)) revert InvalidTargetAsset();
        if (_swapper == address(0)) revert InvalidSwapper();
        targetAsset = _targetAsset;
        swapper = ISwapper(_swapper);
    }

    // ============================================
    // EXTERNAL FUNCTIONS
    // ============================================

    /**
     * @notice Calls report() on the strategy, redeems profit shares, swaps the underlying
     *         asset to the target asset via the configured ISwapper, and forwards to the receiver
     * @dev The swap path: redeem to self -> transfer to swapper -> swapper.swap() -> receiver.
     *      The swapper enforces minAmountOut internally and reverts if not met.
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
        IERC20(assetIn).forceApprove(address(swapper), assetsIn);
        assetsOut = swapper.swap(assetIn, targetAsset, assetsIn, minAmountOut, receiver);

        emit YieldSwappedAndForwarded(strategy, receiver, shares, assetsIn, assetsOut);
    }
}
