// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Minimal interface for strategy share redemption
interface IRedeemable {
    /// @notice Redeem shares for underlying assets
    /// @param shares Amount of shares to redeem
    /// @param receiver Address to receive the redeemed assets
    /// @param owner Address whose shares are being redeemed
    /// @param maxLoss Maximum acceptable loss in basis points
    /// @return assets Amount of assets returned
    function redeem(uint256 shares, address receiver, address owner, uint256 maxLoss) external returns (uint256 assets);
}

/// @notice Minimal interface for ERC-4626 maxRedeem
interface IMaxRedeem {
    /// @notice Maximum shares redeemable by `owner` right now (ERC-4626)
    /// @param owner Address whose redeem headroom is queried
    /// @return maxShares Upper bound on shares redeemable by `owner`
    function maxRedeem(address owner) external view returns (uint256 maxShares);
}

/// @notice Minimal interface for triggering a strategy report
interface IReportable {
    /// @notice Trigger a strategy report (realize gains/losses, mint profit shares)
    /// @return profit Amount of profit realized
    /// @return loss Amount of loss realized
    function report() external returns (uint256 profit, uint256 loss);
}

/**
 * @title YieldForwarder
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Immutable, single-purpose contract that calls report() on a strategy,
 *         redeems any resulting profit shares, and forwards the underlying assets
 *         to a hardcoded receiver
 * @dev Designed for trust-minimized yield flows where this contract serves as both
 *      the strategy's keeper (authorized to call report()) and the donation address
 *      (receives profit shares). Only an authorized keeper EOA can trigger it.
 *
 *      CALL CHAIN:
 *      Keeper EOA → reportAndForward() → strategy.report() → profit shares minted
 *      to this contract → redeem shares → assets forwarded to receiver
 *
 *      DESIGN:
 *      - Fully immutable: no admin, no upgrades, no sweep
 *      - Keeper-gated: only the designated keeper can trigger
 *      - Single-purpose: assets can only flow to the hardcoded receiver
 *      - Strategy is passed as a call-time parameter to avoid circular dependencies
 *
 *      COMPATIBILITY NOTE (Bailsec #64):
 *      When this contract is set as a strategy's `dragonRouter`, the
 *      `enableBurning` loss-protection feature is effectively disabled --
 *      `reportAndForward` redeems the forwarder's full share balance after every
 *      report, so the dragon's balance at loss time is always zero and no shares
 *      can be burned to absorb the loss. Operators who want `enableBurning = true`
 *      must use a non-forwarder dragon (EOA, multisig, or a splitter that retains
 *      balance between reports).
 *
 *      OPERATIONAL NOTE -- AIRDROP / KEEPER-ONLY STRATEGY APIS (Bailsec #65):
 *      When this contract is wired in as a strategy's `keeper`, any strategy
 *      function gated by `onlyKeepers` (for example SparkStrategy.sweepAirdrop)
 *      cannot be invoked by this contract -- this forwarder only exposes
 *      `reportAndForward` (and, for the swapping variant, `reportSwapAndForward`).
 *      Management must retain an operational channel (multisig, automation key,
 *      etc.) to call those keeper-gated strategy functions directly. For airdrops
 *      routed through `sweepAirdrop`, management should immediately follow up
 *      with `YieldForwarder.forwardToken(airdropToken)` to move the swept balance
 *      onward to the hardcoded receiver.
 *
 *      MIGRATION NOTE -- 14-DAY DRAGON ROUTER COOLDOWN (Bailsec #66):
 *      Because this contract is intended to act as both `keeper` and
 *      `dragonRouter`, migrating a strategy to or away from a forwarder is
 *      coupled to the TokenizedStrategy dragon-router cooldown: `setKeeper`
 *      takes effect immediately, but `initiateDragonRouterChange` enforces a
 *      14-day delay before `finalizeDragonRouterChange` can activate the new
 *      router. In practice every forwarder swap is a >=14-day operation. That
 *      delay is an intentional security invariant of the yield-skim design and
 *      is not bypassable by design.
 *      For compromised-keeper incident response, the correct posture is:
 *        1. Immediately call `setEmergencyShutdown` on the strategy -- this
 *           halts `report()`/profit minting, neutralizing the compromised
 *           keeper with no 14-day wait.
 *        2. Concurrently call `initiateDragonRouterChange` for the new
 *           forwarder (14-day timer begins).
 *        3. After 14 days, call `finalizeDragonRouterChange` and call
 *           `setKeeper` for the new forwarder.
 */
contract YieldForwarder is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================
    // ERRORS
    // ============================================

    /// @notice Thrown when the receiver address is zero
    error InvalidReceiver();

    /// @notice Thrown when the keeper address is zero
    error InvalidKeeper();

    /// @notice Thrown when caller is not the authorized keeper
    error OnlyKeeper();

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when shares are redeemed and assets forwarded to the receiver
    /// @param strategy Address of the strategy whose shares were redeemed
    /// @param receiver Address that received the underlying assets
    /// @param shares Amount of shares redeemed
    /// @param assets Amount of underlying assets forwarded
    event YieldForwarded(address indexed strategy, address indexed receiver, uint256 shares, uint256 assets);

    /// @notice Emitted when an arbitrary token balance is forwarded to the receiver
    /// @param token Address of the token whose balance was flushed
    /// @param receiver Address that received the token balance
    /// @param amount Amount of the token transferred
    event TokenForwarded(address indexed token, address indexed receiver, uint256 amount);

    // ============================================
    // STATE
    // ============================================

    /// @notice The address that receives all redeemed assets
    /// @dev Set once at construction, cannot be changed
    address public immutable receiver;

    /// @notice The address authorized to trigger report and forward
    /// @dev Set once at construction, cannot be changed
    address public immutable keeper;

    // ============================================
    // CONSTRUCTOR
    // ============================================

    /// @notice Creates a new YieldForwarder with a fixed receiver and keeper
    /// @param _receiver Address that will receive all forwarded assets
    /// @param _keeper Address authorized to call reportAndForward
    constructor(address _receiver, address _keeper) {
        if (_receiver == address(0)) revert InvalidReceiver();
        if (_keeper == address(0)) revert InvalidKeeper();
        receiver = _receiver;
        keeper = _keeper;
    }

    // ============================================
    // EXTERNAL FUNCTIONS
    // ============================================

    /**
     * @notice Calls report() on the strategy, redeems any profit shares, and forwards assets
     * @dev Only callable by the authorized keeper. This contract must be set as the
     *      strategy's keeper (so it can call report()) and as its donation address
     *      (so profit shares are minted here).
     *
     *      If report() produces no profit shares, the function returns 0 without reverting
     *      (the report itself may still be useful for loss accounting).
     *
     * @param strategy Address of the strategy contract (must implement IReportable, IRedeemable, IERC20)
     * @param maxLoss Maximum acceptable loss in basis points for the redemption
     * @return assets Amount of underlying assets forwarded to receiver (0 if no profit shares)
     */
    function reportAndForward(address strategy, uint256 maxLoss) external nonReentrant returns (uint256 assets) {
        if (msg.sender != keeper) revert OnlyKeeper();

        IReportable(strategy).report();

        uint256 balance = IERC20(strategy).balanceOf(address(this));
        if (balance == 0) return 0;

        // Bailsec #62: cap at strategy.maxRedeem so the inner redeem does not revert when
        // external vault liquidity (idle + vaultMax) shrinks below the forwarder's share
        // balance. Residual shares stay at the forwarder and are picked up on a later
        // report once headroom recovers; the report() side effects above still commit.
        uint256 shares = Math.min(balance, IMaxRedeem(strategy).maxRedeem(address(this)));
        if (shares == 0) return 0;

        assets = IRedeemable(strategy).redeem(shares, receiver, address(this), maxLoss);

        emit YieldForwarded(strategy, receiver, shares, assets);
    }

    /**
     * @notice Forwards the full balance of an arbitrary ERC-20 token to the immutable receiver
     * @dev Bailsec #63. Permissionless by design: the caller picks WHICH token to flush,
     *      but cannot pick WHERE it goes -- the destination is the construction-time
     *      `receiver`, so no new trust surface is introduced relative to the ordinary
     *      report path. Intended for airdrops and other non-pipeline tokens that arrive
     *      at this contract (for example when this forwarder is the `dragonRouter` of
     *      a strategy whose `sweepAirdrop` delivers non-asset tokens here).
     *
     *      Strategy share tokens SHOULD NOT be flushed through this path for normal
     *      yield accounting -- use {reportAndForward} so shares are redeemed to the
     *      underlying asset first. Calling `forwardToken(strategy)` is still safe
     *      (receiver ends up holding redeemable shares, no loss of funds), and is in
     *      fact the operational workaround when `reportAndForward` is temporarily
     *      blocked by tight `maxRedeem` liquidity on the strategy.
     *
     *      Returns silently (without reverting) if the balance is zero so keepers and
     *      bots can call it speculatively without having to pre-check every token.
     * @param token ERC-20 token whose balance should be flushed to the receiver
     */
    function forwardToken(address token) external nonReentrant {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) return;
        IERC20(token).safeTransfer(receiver, balance);
        emit TokenForwarded(token, receiver, balance);
    }
}
