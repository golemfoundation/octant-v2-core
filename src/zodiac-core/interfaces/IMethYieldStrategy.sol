// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity >=0.8.18;

/**
 * @title IMethYieldStrategy
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Interface for mETH yield tracking strategy
 * @dev Exposes last reported exchange rate for mETH/ETH accounting
 */
interface IMethYieldStrategy {
    /**
     * @notice Get the last reported exchange rate of mETH to ETH
     * @return Last reported exchange rate (mETH to ETH ratio, scaled by 1e18)
     */
    function getLastReportedExchangeRate() external view returns (uint256);
}
