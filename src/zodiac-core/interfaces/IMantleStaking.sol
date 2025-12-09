// SPDX-License-Identifier: MIT
pragma solidity >=0.8.18;

/**
 * @title IMantleStaking
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Interface for the Mantle staking contract
 */
interface IMantleStaking {
    /**
     * @notice Convert mETH to ETH based on the current exchange rate
     * @param mETHAmount Amount of mETH to convert
     * @return Equivalent amount of ETH
     */
    function mETHToETH(uint256 mETHAmount) external view returns (uint256);

    /**
     * @notice Convert ETH to mETH based on the current exchange rate
     * @param ethAmount Amount of ETH to convert
     * @return Equivalent amount of mETH
     */
    function ethToMETH(uint256 ethAmount) external view returns (uint256);

    /**
     * @notice Get the total amount of ETH controlled by the system
     * @return Total ETH controlled
     */
    function totalControlled() external view returns (uint256);
}
