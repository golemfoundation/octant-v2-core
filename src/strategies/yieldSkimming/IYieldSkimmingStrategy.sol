// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

/**
 * @title IYieldSkimmingStrategy
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Interface for yield skimming strategies with value debt tracking
 * @dev Exposes exchange rate and debt accounting for appreciating assets
 */
interface IYieldSkimmingStrategy {
    /**
     * @notice Get the current exchange rate of the yield-bearing asset vs underlying
     * @dev Returns the raw exchange rate as provided by the asset (native decimals)
     * @return exchangeRate Current exchange rate
     */
    function getCurrentExchangeRate() external view returns (uint256 exchangeRate);

    /**
     * @notice Get the last reported exchange rate in RAY precision
     * @dev Value is stored in the strategy and updated on report(); 27 decimals
     * @return lastRateRay Last rate in RAY
     */
    function getLastRateRay() external view returns (uint256 lastRateRay);

    /**
     * @notice Get the decimals used by the asset’s exchange rate
     * @dev Used to scale to RAY (1e27) internally
     * @return decimals Number of decimals in the external exchange rate
     */
    function decimalsOfExchangeRate() external view returns (uint256 decimals);

    /**
     * @notice Get the current exchange rate scaled to RAY (1e27)
     * @dev Convenience view for integrations that expect RAY precision
     * @return currentRateRay Current rate in RAY
     */
    function getCurrentRateRay() external view returns (uint256 currentRateRay);


    /**
     * @notice Combined ETH-value debt owed to users and dragon router
     * @return totalDebtInAssetValue Users + dragon value debt
     */
    function getTotalValueDebtInAssetValue() external view returns (uint256 totalDebtInAssetValue);

    /**
     * @notice Check whether the vault is insolvent
     * @dev Insolvent when total vault value (assets * rate) < total value debt (users + dragon)
     * @return isInsolvent True if vault cannot cover total value debt
     */
    function isVaultInsolvent() external view returns (bool isInsolvent);
}
