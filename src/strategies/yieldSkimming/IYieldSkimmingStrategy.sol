// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

interface IYieldSkimmingStrategy {
    function getCurrentExchangeRate() external view returns (uint256);

    function getLastRateRay() external view returns (uint256);

    function decimalsOfExchangeRate() external view returns (uint256);

    function getCurrentRateRay() external view returns (uint256);

    function isVaultInsolvent() external view returns (bool);
}
