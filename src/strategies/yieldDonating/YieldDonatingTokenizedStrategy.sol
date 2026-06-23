// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.25;

import { TokenizedStrategy, Math } from "src/core/TokenizedStrategy.sol";
import { IBaseStrategy } from "src/core/interfaces/IBaseStrategy.sol";
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
 *        strategy enters a terminal state: `_convertToShares` returns 0 while tracked
 *        assets are 0, so deposit() and mint() revert until accounting is restored.
 *      - A direct donation followed by report() can heal that state. When report()
 *        observes recovered assets from a zero-asset state, surplus recovery shares
 *        are minted to the dragon router as donation yield. This restores a usable
 *        PPS without assigning the recovered surplus to stale dust holders.
 */

contract YieldDonatingTokenizedStrategy is TokenizedStrategy {
    using Math for uint256;

    /// @notice Permanently locked first shares, following the Uniswap V2 minimum-liquidity pattern
    uint256 internal constant MINIMUM_LIQUIDITY = 1_000;

    /// @notice Receiver for permanently locked minimum-liquidity shares
    address internal constant MINIMUM_LIQUIDITY_RECEIVER = address(0xdead);

    /// @notice Emitted when profit or recovery shares are minted
    /// @param dragonRouter Address receiving minted donation or recovery shares
    /// @param amount Amount of shares minted in share base units
    event DonationMinted(address indexed dragonRouter, uint256 amount);

    /// @notice Emitted when dragon shares are burned to cover losses
    /// @param dragonRouter Address whose shares are burned
    /// @param amount Amount of shares burned in share base units
    event DonationBurned(address indexed dragonRouter, uint256 amount);

    /// @inheritdoc TokenizedStrategy
    function deposit(uint256 assets, address receiver) public virtual override nonReentrant returns (uint256 shares) {
        StrategyData storage S = _strategyStorage();

        if (assets == type(uint256).max) {
            assets = S.asset.balanceOf(msg.sender);
        }

        require(assets <= _maxDepositWithMinimumLiquidity(S, receiver), "ERC4626: deposit more than max");
        require((shares = _convertToShares(S, assets, Math.Rounding.Floor)) != 0, "ZERO_SHARES");

        _deposit(S, receiver, assets, shares);
    }

    /// @dev Yield-donating first deposits fund permanently locked shares.
    function _convertToShares(
        StrategyData storage S,
        uint256 assets,
        Math.Rounding _rounding
    ) internal view virtual override returns (uint256) {
        if (_totalSupply(S) == 0) {
            if (_totalAssets(S) != 0) return 0;
            return assets > MINIMUM_LIQUIDITY ? assets - MINIMUM_LIQUIDITY : 0;
        }

        return super._convertToShares(S, assets, _rounding);
    }

    /// @inheritdoc TokenizedStrategy
    function previewMint(uint256 shares) public view virtual override returns (uint256 assets) {
        StrategyData storage S = _strategyStorage();
        if (_totalSupply(S) == 0 && _totalAssets(S) == 0) return _addMinimumLiquidity(shares);

        return super.previewMint(shares);
    }

    /// @inheritdoc TokenizedStrategy
    function mint(uint256 shares, address receiver) public virtual override nonReentrant returns (uint256 assets) {
        StrategyData storage S = _strategyStorage();

        require(shares <= _maxMint(S, receiver), "ERC4626: mint more than max");

        if (_totalSupply(S) == 0 && _totalAssets(S) == 0) {
            assets = _addMinimumLiquidity(shares);
        } else {
            assets = _convertToAssets(S, shares, Math.Rounding.Ceil);
        }

        require(assets != 0, "ZERO_ASSETS");

        _deposit(S, receiver, assets, shares);
    }

    /// @inheritdoc TokenizedStrategy
    function maxDeposit(address receiver) public view virtual override returns (uint256) {
        StrategyData storage S = _strategyStorage();

        return _maxDepositWithMinimumLiquidity(S, receiver);
    }

    /// @inheritdoc TokenizedStrategy
    function maxMint(address receiver) public view virtual override returns (uint256) {
        StrategyData storage S = _strategyStorage();
        if (_isZeroAssetTerminalState(S)) return 0;

        return super.maxMint(receiver);
    }

    /// @inheritdoc TokenizedStrategy
    function maxRedeem(address owner) public view virtual override returns (uint256) {
        StrategyData storage S = _strategyStorage();
        if (_isZeroAssetTerminalState(S)) return 0;

        return super.maxRedeem(owner);
    }

    /// @dev Seeds permanently locked shares on the first successful yield-donating deposit/mint.
    function _deposit(
        StrategyData storage S,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal virtual override {
        bool seedMinimumLiquidity = _totalSupply(S) == 0;

        super._deposit(S, receiver, assets, shares);

        if (seedMinimumLiquidity) {
            _mint(S, MINIMUM_LIQUIDITY_RECEIVER, MINIMUM_LIQUIDITY);
        }
    }

    function _addMinimumLiquidity(uint256 shares) internal pure returns (uint256) {
        if (shares == 0) return 0;
        if (shares > type(uint256).max - MINIMUM_LIQUIDITY) return type(uint256).max;
        return shares + MINIMUM_LIQUIDITY;
    }

    function _maxDepositWithMinimumLiquidity(
        StrategyData storage S,
        address receiver
    ) internal view returns (uint256 maxAssets) {
        maxAssets = _maxDeposit(S, receiver);
        // Empty yield-donating vaults need enough headroom to fund the dead-share lock.
        if (_totalSupply(S) == 0 && _totalAssets(S) == 0 && maxAssets <= MINIMUM_LIQUIDITY) return 0;
    }

    function _isZeroAssetTerminalState(StrategyData storage S) internal view returns (bool) {
        return _totalSupply(S) != 0 && _totalAssets(S) == 0;
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
     *
     * @return profit Notional amount of gain since last report, in terms of `asset`
     * @return loss Notional loss in terms of `asset`, subject to override-specific semantics
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
            uint256 totalSupply_ = _totalSupply(S);
            address sharesReceiver = _dragonRouter;
            uint256 sharesToMint = 0;

            if (totalSupply_ == 0) {
                // Ghost collateral has assets but no share owner. Lock matching
                // shares to the strategy so later deposits do not get first-
                // depositor pricing against pre-existing assets.
                sharesReceiver = address(this);
                sharesToMint = newTotalAssets;
            } else if (oldTotalAssets == 0) {
                // Recovery from a zero-asset state should not let stale dust
                // capture the surplus; normal conversion cannot price from zero.
                // Existing supply receives up to 1 asset/share, surplus goes to dragon.
                if (newTotalAssets > totalSupply_) {
                    unchecked {
                        sharesToMint = newTotalAssets - totalSupply_;
                    }
                }
            } else {
                sharesToMint = _convertToShares(S, profit, Math.Rounding.Floor);
            }

            // Floor rounding can map dust profit to zero shares; skip the no-op mint and
            // DonationMinted emission so off-chain indexers do not see a donation event
            // without a corresponding supply change.
            if (sharesToMint != 0) {
                _mint(S, sharesReceiver, sharesToMint);
                emit DonationMinted(sharesReceiver, sharesToMint);
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

        if (_totalSupply(S) == 0 && newTotalAssets != 0) {
            _mint(S, address(this), newTotalAssets);
            emit DonationMinted(address(this), newTotalAssets);
        }

        // Update the new total assets value
        S.totalAssets = newTotalAssets;
        S.lastReport = uint96(block.timestamp);

        emit Reported(profit, loss);
    }

    /**
     * @notice Sets whether dragon-share burning is enabled for loss protection.
     * @dev Yield-donating strategies learn their authoritative current asset value
     *      through `report()`. When dragon shares exist, disabling burning without
     *      reporting first could retroactively preserve dragon shares through an
     *      unreported loss. Use `reportAndDisableBurning()` in that case.
     * @param _enableBurning Whether to enable the burning mechanism
     */
    function setEnableBurning(bool _enableBurning) external override onlyManagement {
        StrategyData storage S = _strategyStorage();

        if (S.enableBurning && !_enableBurning) {
            require(S.balances[S.dragonRouter] == 0, "report before disabling burning");
        }

        S.enableBurning = _enableBurning;
        emit UpdateBurningMechanism(_enableBurning);
    }

    /**
     * @notice Reports current accounting, then disables dragon burn loss protection.
     * @dev This explicit helper gives operators an atomic path for disabling burning
     *      without leaving a between-transaction window for unreported losses.
     * @return profit Profit reported by the accounting sync
     * @return loss Loss reported by the accounting sync
     */
    function reportAndDisableBurning() external onlyManagement returns (uint256 profit, uint256 loss) {
        (profit, loss) = report();

        _strategyStorage().enableBurning = false;
        emit UpdateBurningMechanism(false);
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
}
