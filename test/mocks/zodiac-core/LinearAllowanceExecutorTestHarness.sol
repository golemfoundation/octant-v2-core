// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { IAddressSet } from "src/utils/IAddressSet.sol";
import { LinearAllowanceExecutor } from "src/zodiac-core/LinearAllowanceExecutor.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { NATIVE_TOKEN, AccessMode } from "src/constants.sol";

/// @title LinearAllowanceExecutorTestHarness
/// @notice Test implementation of LinearAllowanceExecutor with owner-only withdrawal functionality
/// @dev This contract provides a concrete implementation of the abstract LinearAllowanceExecutor
/// for testing purposes. It implements owner-only withdrawal controls using OpenZeppelin's Ownable
/// pattern, ensuring that only the contract owner can withdraw accumulated funds from allowance transfers.
/// The deployer automatically becomes the owner and has exclusive withdrawal privileges.
contract LinearAllowanceExecutorTestHarness is LinearAllowanceExecutor, Ownable {
    /// @notice Contract constructor that sets the deployer as the owner
    /// @dev Inherits from Ownable which automatically sets msg.sender as the initial owner
    /// during contract deployment. This ensures immediate access control setup.
    constructor() Ownable(msg.sender) {}

    /// @notice Set the module address set contract (owner only)
    /// @dev Only the owner can set the address set contract
    /// @param addressSet The address set contract address (can be address(0) to disable)
    function assignModuleAddressSet(IAddressSet addressSet) external override onlyOwner {
        _assignModuleAddressSet(addressSet);
    }

    /// @notice Set the module access mode (owner only)
    /// @dev Only the owner can set the access mode
    /// @param mode The access mode (NONE, ALLOWSET, or BLOCKSET)
    function setModuleAccessMode(AccessMode mode) external override onlyOwner {
        _setModuleAccessMode(mode);
    }

    /// @notice Enables the contract to receive ETH transfers from allowance executions
    /// @dev Required for ETH allowance transfers to succeed when this contract is the recipient
    receive() external payable override {}

    /// @notice Withdraw accumulated funds from this contract (owner only)
    /// @dev Implements the abstract withdraw function with owner-only access control.
    /// Supports both ETH and ERC20 token withdrawals with proper balance validation.
    /// Reverts if insufficient balance or transfer fails.
    /// @param token The address of the token to withdraw (use NATIVE_TOKEN for ETH)
    /// @param amount The amount to withdraw from this contract's balance
    /// @param to The destination address to send the withdrawn funds
    function withdraw(address token, uint256 amount, address payable to) external override onlyOwner {
        // Validate destination address to prevent accidental burns
        require(to != address(0), "LinearAllowanceExecutorTestHarness: cannot withdraw to zero address");

        // Handle ETH withdrawal
        if (token == NATIVE_TOKEN) {
            // Check contract has sufficient ETH balance
            require(address(this).balance >= amount, "LinearAllowanceExecutorTestHarness: insufficient ETH balance");

            // Transfer ETH to destination
            (bool success, ) = to.call{ value: amount }("");
            require(success, "LinearAllowanceExecutorTestHarness: ETH transfer failed");
        } else {
            // Handle ERC20 token withdrawal
            IERC20 tokenContract = IERC20(token);

            // Check contract has sufficient token balance
            uint256 contractBalance = tokenContract.balanceOf(address(this));
            require(contractBalance >= amount, "LinearAllowanceExecutorTestHarness: insufficient token balance");

            // Transfer tokens to destination
            bool success = tokenContract.transfer(to, amount);
            require(success, "LinearAllowanceExecutorTestHarness: token transfer failed");
        }
    }

    /// @notice Get the contract's balance for a specific token
    /// @dev Utility function for testing and monitoring contract balances
    /// @param token The address of the token to check (use NATIVE_TOKEN for ETH)
    /// @return balance The contract's current balance of the specified token
    function getBalance(address token) external view returns (uint256 balance) {
        if (token == NATIVE_TOKEN) {
            // Return ETH balance
            return address(this).balance;
        } else {
            // Return ERC20 token balance
            return IERC20(token).balanceOf(address(this));
        }
    }
}
