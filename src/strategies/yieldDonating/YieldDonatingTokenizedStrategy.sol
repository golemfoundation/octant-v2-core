// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.25;

import { TokenizedStrategy, Math } from "src/core/TokenizedStrategy.sol";
import { IBaseStrategy } from "src/core/interfaces/IBaseStrategy.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
/**
 * @title YieldDonatingTokenizedStrategy
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Specialized TokenizedStrategy for productive assets with discrete harvesting; profits are donated by minting shares to the dragon router.
 * @dev Behavior overview:
 *      - On report(), harvests the underlying position via BaseStrategy.harvestAndReport()
 *      - If newTotalAssets > oldTotalAssets, mints shares equal to the profit (asset value) to the dragon router
 *      - If losses occur and burning is enabled, burns dragon router shares (up to its balance) using rounding-down shares-to-burn
 *      - No tracked-loss bucket exists; any loss not covered by dragon router burning reduces totalAssets and affects PPS for all holders
 *
 * Economic notes:
 *      - Profit donations are realized via share mints at the time of report
 *      - Losses first attempt dragon share burning when enabled; residual losses decrease PPS
 *      - Dragon router change follows TokenizedStrategy cooldown and two-step finalization
 *
 * Terminal-state recovery (operator-managed):
 *      - After a catastrophic loss that reduces `totalAssets` to 0 while `totalSupply`
 *        remains positive (all dragon shares burned and residual loss socialized), the
 *        strategy enters a terminal state: `_convertToShares` returns 0 at the new PPS,
 *        so deposit() and mint() revert until accounting is restored by a future report
 *        and conversions no longer round to zero.
 *      - External donations of the underlying asset are not a dedicated recovery
 *        mechanism. A donated balance can raise `totalAssets` when report() records it,
 *        but the value flows proportionally to existing shareholders. At the terminal
 *        ratio the dragon-mint floors to 0, so no new profit shares accrue to the dragon
 *        router or donation receiver.
 *      - This contract does not implement an automatic recovery flow for that state.
 *        Recovery is operator-managed: call `shutdownStrategy` to stop new deposits while
 *        operators assess the position and migrate users to a fresh deployment if needed.
 *        Avoiding a donation-based rescue path prevents reintroducing first-depositor
 *        dust-extraction style issues.
 */

contract YieldDonatingTokenizedStrategy is TokenizedStrategy {
    using Math for uint256;
    using SafeERC20 for ERC20;

    /// @notice Strategy-owned seed that keeps supply non-zero after user exits.
    uint256 public constant MINIMUM_PROTOCOL_POSITION = 1_000_000_000;

    /// @notice Emitted when profit shares are minted to dragon router
    /// @param dragonRouter Address receiving minted donation shares
    /// @param amount Amount of shares minted in share base units
    event DonationMinted(address indexed dragonRouter, uint256 amount);

    /// @notice Emitted when dragon shares are burned to cover losses
    /// @param dragonRouter Address whose shares are burned
    /// @param amount Amount of shares burned in share base units
    event DonationBurned(address indexed dragonRouter, uint256 amount);

    /// @notice Emitted when the strategy-owned minimum position is funded and locked.
    /// @param funder Address that supplied the underlying asset seed
    /// @param amount Amount of underlying assets locked as the minimum position
    event MinimumProtocolPositionSeeded(address indexed funder, uint256 amount);

    /**
     * @notice Funds and locks the protocol minimum position.
     * @dev This must be called once by the operator before public deposits are enabled.
     *      The minted shares are held by the strategy itself, so users cannot redeem or
     *      transfer them away. This keeps `totalSupply` non-zero even if all external
     *      holders exit after a loss-report sequence.
     * @return shares Amount of locked shares minted to the strategy
     */
    function seedMinimumPosition() external virtual nonReentrant onlyManagement returns (uint256 shares) {
        StrategyData storage S = super._strategyStorage();

        require(_totalSupply(S) == 0 && _totalAssets(S) == 0, "MINIMUM_POSITION_LATE");
        require(_balanceOf(S, address(this)) == 0, "MINIMUM_POSITION_SEEDED");

        shares = MINIMUM_PROTOCOL_POSITION;
        S.asset.safeTransferFrom(msg.sender, address(this), shares);

        IBaseStrategy(address(this)).deployFunds(shares);

        S.totalAssets = shares;
        _mint(S, address(this), shares);

        emit MinimumProtocolPositionSeeded(msg.sender, shares);
    }

    /**
     * @notice Reports strategy performance and distributes profits as donations
     * @dev Mints profit-derived shares to dragon router when newTotalAssets > oldTotalAssets; on loss, attempts
     *      dragon share burning if enabled. Residual loss reduces PPS (no tracked-loss bucket).
     *
     *      Keeper trust assumption: report() timing is at the keeper's discretion and directly controls
     *      when dragon shares mint (on profit) and burn (on loss). A compromised keeper can time calls
     *      adversarially — for example, call report() during a temporary dip to burn dragon shares at
     *      the depressed PPS and then call again on recovery so the rebound is captured as fresh
     *      dragon-mint profit rather than offsetting the earlier dip; or delay report() through a real
     *      loss to let users exit at a stale, inflated PPS and socialise the loss across remaining
     *      holders. These paths are bounded by the dragon router's share balance and degrade yield
     *      quality rather than drain funds, but they are genuine keeper-side risks.
     *
     *      The keeper is a SEMI-TRUSTED role. Mitigation is operational: keeper key custody under
     *      multisig / MPC, off-chain alerting on report() calls during volatility spikes, and the
     *      no-cooldown `setKeeper()` rotation path if the key is compromised. `shutdownStrategy`
     *      can be used as containment to halt new deposits/mints while rotation and assessment
     *      happen, but it does not block tend() or report(). No on-chain cap on reporting cadence
     *      is enforced — that would constrain legitimate operation for a threat the trust model
     *      already accepts.
     */
    function report()
        public
        virtual
        override(TokenizedStrategy)
        nonReentrant
        onlyKeepers
        returns (uint256 profit, uint256 loss)
    {
        // Cache storage pointer since its used repeatedly.
        StrategyData storage S = super._strategyStorage();

        uint256 newTotalAssets = IBaseStrategy(address(this)).harvestAndReport();
        uint256 oldTotalAssets = _totalAssets(S);
        address _dragonRouter = S.dragonRouter;

        if (newTotalAssets > oldTotalAssets) {
            unchecked {
                profit = newTotalAssets - oldTotalAssets;
            }
            uint256 sharesToMint = _convertToShares(S, profit, Math.Rounding.Floor);

            // Floor rounding can map dust profit to zero shares; skip the no-op mint and
            // DonationMinted emission so off-chain indexers do not see a donation event
            // without a corresponding supply change.
            if (sharesToMint != 0) {
                // mint the shares to the dragon router
                _mint(S, _dragonRouter, sharesToMint);
                emit DonationMinted(_dragonRouter, sharesToMint);
            }
        } else {
            unchecked {
                loss = oldTotalAssets - newTotalAssets;
            }

            if (loss != 0) {
                // Handle loss protection
                _handleDragonLossProtection(S, loss);
            }
        }

        // Update the new total assets value
        S.totalAssets = newTotalAssets;
        S.lastReport = uint96(block.timestamp);

        emit Reported(profit, loss);
    }

    /// @inheritdoc TokenizedStrategy
    function maxDeposit(address receiver) public view virtual override returns (uint256) {
        StrategyData storage S = super._strategyStorage();
        if (!_minimumPositionSeeded(S)) return 0;
        return super.maxDeposit(receiver);
    }

    /// @inheritdoc TokenizedStrategy
    function maxMint(address receiver) public view virtual override returns (uint256) {
        StrategyData storage S = super._strategyStorage();
        if (!_minimumPositionSeeded(S)) return 0;
        return super.maxMint(receiver);
    }

    /**
     * @dev Internal function to handle loss protection for dragon principal
     * @param S Storage struct pointer to access strategy's storage variables
     * @param loss Amount of loss to protect against in asset base units
     *
     * If burning is enabled, this function will try to burn shares from the dragon router
     * equivalent to the loss amount.
     */
    function _handleDragonLossProtection(StrategyData storage S, uint256 loss) internal {
        if (S.enableBurning) {
            // Convert loss to shares that should be burned.
            // Floor rounding: any sub-wei remainder is socialized via PPS reduction
            // rather than over-burning dragon shares. This avoids systematically
            // extracting value from dragon in favor of depositors.
            uint256 sharesToBurn = _convertToShares(S, loss, Math.Rounding.Floor);

            // Can only burn up to available shares from dragon router
            uint256 sharesBurned = Math.min(sharesToBurn, S.balances[S.dragonRouter]);

            if (sharesBurned > 0) {
                // Burn shares from dragon router
                _burn(S, S.dragonRouter, sharesBurned);
                emit DonationBurned(S.dragonRouter, sharesBurned);
            }
        }
    }

    function _deposit(
        StrategyData storage S,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal virtual override {
        require(_minimumPositionSeeded(S), "MINIMUM_POSITION_UNSEEDED");
        super._deposit(S, receiver, assets, shares);
    }

    function _minimumPositionSeeded(StrategyData storage S) internal view returns (bool) {
        return _balanceOf(S, address(this)) >= MINIMUM_PROTOCOL_POSITION;
    }
}
