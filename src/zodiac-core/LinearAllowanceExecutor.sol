// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import { LinearAllowanceSingletonForGnosisSafe } from "src/zodiac-core/modules/LinearAllowanceSingletonForGnosisSafe.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { NotInAllowset, InBlockset } from "src/errors.sol";
import { AccessMode } from "src/constants.sol";

/// @title LinearAllowanceExecutor
/// @author [Golem Foundation](https://golem.foundation)
/// @custom:security-contact security@golem.foundation
/// @notice Abstract base contract for executing linear allowance transfers from Gnosis Safe modules
/// @dev This contract provides the core functionality for interacting with LinearAllowanceSingletonForGnosisSafe
/// while leaving withdrawal mechanisms to be implemented by derived contracts. The contract can receive
/// both ETH and ERC20 tokens from allowance transfers, but the specific withdrawal logic must be defined
/// by inheriting contracts to ensure proper access control and business logic implementation.
///
/// Assumptions and security model:
/// - This executor contract instance is configured as the delegate in the LinearAllowance module.
/// - A module address set may be set via `assignModuleAddressSet`; `_validateModule` enforces it on calls.
/// - The moduleAccessMode determines how the moduleAddressSet is used:
///   - NONE: any module is allowed (no validation)
///   - ALLOWSET: only modules in moduleAddressSet are allowed
///   - BLOCKSET: any module EXCEPT those in moduleAddressSet are allowed
abstract contract LinearAllowanceExecutor {
    /// @notice Access control mode for module validation
    AccessMode public moduleAccessMode;

    /// @notice Address set contract for allowance modules to prevent arbitrary external calls
    IAddressSet public moduleAddressSet;

    /// @notice Emitted when the module access mode is set
    /// @param mode Access mode (NONE, ALLOWSET, or BLOCKSET)
    event ModuleAccessModeSet(AccessMode indexed mode);

    /// @notice Emitted when the module address set is assigned
    /// @param addressSet Address set contract address
    event ModuleAddressSetAssigned(IAddressSet indexed addressSet);

    /// @notice External function to configure the module address set used by this executor
    /// @dev Implementing contracts MUST restrict access (e.g., onlyOwner or governance).
    ///      The address set is only used when moduleAccessMode is ALLOWSET or BLOCKSET.
    ///      Can be address(0) when moduleAccessMode is NONE
    /// @param addressSet Address set contract address
    function assignModuleAddressSet(IAddressSet addressSet) external virtual;

    /// @notice Internal helper that updates the address set reference and emits an event
    /// @dev Does not perform access control; call from a restricted external setter
    /// @param addressSet Address set contract address
    function _assignModuleAddressSet(IAddressSet addressSet) internal {
        moduleAddressSet = addressSet;
        emit ModuleAddressSetAssigned(addressSet);
    }

    /// @notice External function to configure the module access mode
    /// @dev Implementing contracts MUST restrict access (e.g., onlyOwner or governance)
    /// @param mode Access mode (NONE, ALLOWSET, or BLOCKSET)
    function setModuleAccessMode(AccessMode mode) external virtual;

    /// @notice Internal helper that updates the access mode and emits an event
    /// @dev Does not perform access control; call from a restricted external setter
    /// @param mode Access mode to set (NONE, ALLOWSET, or BLOCKSET)
    function _setModuleAccessMode(AccessMode mode) internal {
        moduleAccessMode = mode;
        emit ModuleAccessModeSet(mode);
    }

    /// @notice Validate that a module is permitted to interact with this executor
    /// @dev Respects moduleAccessMode:
    ///      NONE: any module is allowed
    ///      ALLOWSET: only modules in moduleAddressSet are allowed
    ///      BLOCKSET: any module EXCEPT those in moduleAddressSet are allowed
    /// @param module Allowance module address to validate
    function _validateModule(address module) internal view {
        if (moduleAccessMode == AccessMode.ALLOWSET) {
            require(moduleAddressSet.contains(module), NotInAllowset(module));
        } else if (moduleAccessMode == AccessMode.BLOCKSET) {
            require(!moduleAddressSet.contains(module), InBlockset(module));
        }
        // AccessMode.NONE: no validation
    }

    /// @notice Accept ETH sent by allowance executions
    /// @dev Required so ETH transfers from a Safe succeed when this contract is the recipient
    receive() external payable virtual;

    /// @notice Pull available allowance from a Safe into this contract
    /// @dev Validates the module via `_validateModule`. The module uses msg.sender as the delegate,
    /// which means THIS contract instance must be configured as the delegate for the given Safe.
    /// Funds are always sent to address(this) and remain here until `withdraw` is called.
    /// Reverts if the underlying module call fails or no allowance is available
    /// @param allowanceModule Allowance module to interact with
    /// @param safe Safe that is the source of the allowance
    /// @param token Token to transfer (use NATIVE_TOKEN for ETH)
    /// @return Amount actually transferred to this contract in token base units
    function executeAllowanceTransfer(
        LinearAllowanceSingletonForGnosisSafe allowanceModule,
        address safe,
        address token
    ) external returns (uint256) {
        _validateModule(address(allowanceModule));
        // Execute the allowance transfer, sending funds to this contract
        return allowanceModule.executeAllowanceTransfer(safe, token, payable(address(this)));
    }

    /// @notice Pull allowance from multiple Safes into this contract
    /// @dev For each transfer, the module treats msg.sender as the delegate (this contract).
    /// Destinations are forced to address(this) to prevent parameter-injection attacks.
    /// Reverts if any underlying module call fails
    /// @param allowanceModule Allowance module to interact with
    /// @param safes Safe addresses that are the sources of allowances
    /// @param tokens Token addresses to transfer (use NATIVE_TOKEN for ETH)
    /// @return transferAmounts Amounts transferred for each operation in token base units
    function executeAllowanceTransfers(
        LinearAllowanceSingletonForGnosisSafe allowanceModule,
        address[] calldata safes,
        address[] calldata tokens
    ) external returns (uint256[] memory transferAmounts) {
        _validateModule(address(allowanceModule));
        address[] memory tos = new address[](safes.length);
        for (uint256 i = 0; i < safes.length; i++) {
            tos[i] = address(this);
        }
        return allowanceModule.executeAllowanceTransfers(safes, tokens, tos);
    }

    /// @notice Get the total unspent allowance for this executor as delegate
    /// @dev Pure view into module bookkeeping for this delegate; does not read this contract's balance
    /// @param allowanceModule Allowance module to query
    /// @param safe Safe that is the source of the allowance
    /// @param token Token address (use NATIVE_TOKEN for ETH)
    /// @return Unspent allowance at the time of the call in token base units
    function getTotalUnspent(
        LinearAllowanceSingletonForGnosisSafe allowanceModule,
        address safe,
        address token
    ) external view returns (uint256) {
        // Query the allowance module for this contract's unspent allowance
        return allowanceModule.getTotalUnspent(safe, address(this), token);
    }

    /**
     * @notice Withdraw funds that have been pulled into this contract
     * @dev Must be implemented by derived contracts with appropriate access control and safeguards.
     * Implementations should validate `to`, consider pausing/emergency paths, and apply business rules.
     * This function transfers funds already resident in this contract, not from the Safe directly
     * @param token Token to withdraw (use NATIVE_TOKEN for ETH)
     * @param amount Amount to withdraw from this contract's balance in token base units
     * @param to Recipient address for the withdrawn funds
     */
    function withdraw(address token, uint256 amount, address payable to) external virtual;

    /// @notice Get the maximum amount currently withdrawable for this delegate
    /// @dev Delegates to the module; computed as the minimum of unspent allowance and the Safe's
    /// current token balance at call time
    /// @param allowanceModule Allowance module to query
    /// @param safe Safe that is the source of the allowance
    /// @param token Token address (use NATIVE_TOKEN for ETH)
    /// @return Maximum withdrawable amount right now in token base units
    function getMaxWithdrawableAmount(
        LinearAllowanceSingletonForGnosisSafe allowanceModule,
        address safe,
        address token
    ) external view returns (uint256) {
        return allowanceModule.getMaxWithdrawableAmount(safe, address(this), token);
    }
}
