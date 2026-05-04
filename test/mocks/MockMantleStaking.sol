// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Mock Mantle Staking Contract
/// @notice A mock implementation of the Mantle staking contract for testing
/// @dev Deprecated compatibility mock retained for published package import path stability.
contract MockMantleStaking {
    IERC20 public mETHToken;
    uint256 public exchangeRate = 1e18; // 1:1 ETH:mETH ratio by default

    constructor(address _mETHToken) {
        mETHToken = IERC20(_mETHToken);
    }

    /// @notice Set a new exchange rate for testing
    function setExchangeRate(uint256 _exchangeRate) external {
        exchangeRate = _exchangeRate;
    }

    /// @notice Set the mETH token reference for testing
    function setMETHToken(address _mETHToken) external {
        mETHToken = IERC20(_mETHToken);
    }

    /// @notice Convert ETH to mETH based on current exchange rate
    function ethToMETH(uint256 ethAmount) public view returns (uint256) {
        return (ethAmount * 1e18) / exchangeRate;
    }

    /// @notice Convert mETH to ETH based on current exchange rate
    function mETHToETH(uint256 mETHAmount) public view returns (uint256) {
        return (mETHAmount * exchangeRate) / 1e18;
    }

    /// @notice Get total ETH controlled by the system
    function totalControlled() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Allow the contract to receive ETH
    receive() external payable {}
}
