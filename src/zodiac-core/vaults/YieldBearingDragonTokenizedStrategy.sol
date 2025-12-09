// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { DragonTokenizedStrategy } from "src/zodiac-core/vaults/DragonTokenizedStrategy.sol";
import { ITokenizedStrategy } from "src/zodiac-core/interfaces/ITokenizedStrategy.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IBaseStrategy } from "src/zodiac-core/interfaces/IBaseStrategy.sol";

/**
 * @title YieldBearingDragonTokenizedStrategy
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice A specialized version of DragonTokenizedStrategy designed for yield-bearing tokens
 * like mETH whose value in ETH terms appreciates over time.
 */
contract YieldBearingDragonTokenizedStrategy is DragonTokenizedStrategy {
    using Math for uint256;

    /**
     * @notice Reports profit for yield-bearing token strategies where token value appreciates
     * @dev Overrides report to handle appreciation-based yield (e.g., mETH). Mints shares based on profit
     * @return profit Profit generated in asset base units
     * @return loss Loss incurred (always 0 for appreciation-only tokens)
     */
    function report() public override(DragonTokenizedStrategy) returns (uint256 profit, uint256 loss) {
        StrategyData storage S = super._strategyStorage();

        // Get the profit in mETH terms
        profit = IBaseStrategy(address(this)).harvestAndReport();
        address _dragonRouter = S.dragonRouter;

        if (profit > 0) {
            // Mint shares based on the adjusted profit amount
            uint256 shares = _convertToSharesFromReport(S, profit, Math.Rounding.Floor);
            // mint the mETH value
            _mint(S, _dragonRouter, shares);
        }

        // Update the new total assets value
        S.lastReport = uint96(block.timestamp);

        emit Reported(
            profit,
            loss,
            0, // Protocol fees
            0 // Performance Fees
        );

        return (profit, loss);
    }

    /**
     * @dev Override _depositWithLockup to track the ETH value
     */
    function _depositWithLockup(
        uint256 assets,
        address receiver,
        uint256 lockupDuration
    ) internal override returns (uint256 shares) {
        // report to update the exchange rate
        ITokenizedStrategy(address(this)).report();

        shares = super._depositWithLockup(assets, receiver, lockupDuration);

        return shares;
    }

    /**
     * @dev Helper function to convert assets to shares from report
     * Modified from ERC4626 to handle the totalAssets_ - assets calculation so that the shares are not undervalued
     */
    function _convertToSharesFromReport(
        StrategyData storage S,
        uint256 assets,
        Math.Rounding _rounding
    ) internal view virtual returns (uint256) {
        // Saves an extra SLOAD if values are non-zero.
        uint256 totalSupply_ = _totalSupply(S);
        // If supply is 0, PPS = 1.
        if (totalSupply_ == 0) return assets;

        uint256 totalAssets_ = _totalAssets(S);
        // If assets are 0 but supply is not PPS = 0.
        if (totalAssets_ == 0) return 0;

        return assets.mulDiv(totalSupply_, totalAssets_ - assets, _rounding);
    }
}
