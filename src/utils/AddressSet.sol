// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import { IAddressSet } from "./IAddressSet.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title AddressSet
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Managed set of addresses for allowlists and blocklists
 * @dev Wrapper around OpenZeppelin's EnumerableSet with owner controls
 *
 *      USE CASES:
 *      - Allowlists: Control who can interact with a contract
 *      - Blocklists: Prevent specific addresses from interacting
 *      - Registry: Track set of authorized addresses
 *
 *      FEATURES:
 *      - O(1) add, remove, contains operations
 *      - Enumerable (can iterate through all addresses)
 *      - Owner-only modifications
 *      - Batch operations supported
 *      - Duplicate prevention
 *
 *      GAS CONSIDERATIONS:
 *      - Add: ~40k gas first time, ~20k subsequent
 *      - Remove: ~20k gas
 *      - Contains: ~200 gas (view)
 *      - Batch operations save gas vs multiple transactions
 */
contract AddressSet is IAddressSet, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;

    // ============================================
    // ERRORS
    // ============================================

    error IllegalAddressSetOperation(address account, string reason);
    error EmptyArray();

    // ============================================
    // EVENTS
    // ============================================

    /// @notice Emitted when an address is added to or removed from the set
    /// @param account Address that was modified
    /// @param operation Type of operation (Add or Remove)
    event AddressSetAltered(address indexed account, AddressSetOperation indexed operation);

    // ============================================
    // ENUMS
    // ============================================

    /// @notice Operation types for address set modifications
    enum AddressSetOperation {
        Add,
        Remove
    }

    // ============================================
    // STATE VARIABLES
    // ============================================

    /// @notice Internal EnumerableSet storage
    /// @dev Uses OpenZeppelin's gas-optimized implementation
    EnumerableSet.AddressSet private _addresses;

    constructor() Ownable(msg.sender) {}

    function contains(address account) external view override returns (bool) {
        return _addresses.contains(account);
    }

    /// @notice Get all addresses in the set
    /// @return Array of all addresses
    function values() external view returns (address[] memory) {
        return _addresses.values();
    }

    /// @notice Get number of addresses in the set
    /// @return Number of addresses
    function length() external view returns (uint256) {
        return _addresses.length();
    }

    function add(address[] memory accounts) external override onlyOwner {
        require(accounts.length > 0, EmptyArray());

        for (uint256 i = 0; i < accounts.length; i++) {
            if (accounts[i] == address(0)) {
                revert IllegalAddressSetOperation(accounts[i], "Address zero not allowed.");
            }
            if (!_addresses.add(accounts[i])) {
                revert IllegalAddressSetOperation(accounts[i], "Address already in set.");
            }
            emit AddressSetAltered(accounts[i], AddressSetOperation.Add);
        }
    }

    function add(address account) external override onlyOwner {
        if (account == address(0)) {
            revert IllegalAddressSetOperation(account, "Address zero not allowed.");
        }
        if (!_addresses.add(account)) {
            revert IllegalAddressSetOperation(account, "Address already in set.");
        }

        emit AddressSetAltered(account, AddressSetOperation.Add);
    }

    /// @inheritdoc IAddressSet
    function remove(address[] memory accounts) external override onlyOwner {
        require(accounts.length > 0, EmptyArray());

        for (uint256 i = 0; i < accounts.length; i++) {
            if (accounts[i] == address(0)) {
                revert IllegalAddressSetOperation(accounts[i], "Address zero not allowed.");
            }
            if (!_addresses.remove(accounts[i])) {
                revert IllegalAddressSetOperation(accounts[i], "Address not in set.");
            }
            emit AddressSetAltered(accounts[i], AddressSetOperation.Remove);
        }
    }

    /// @inheritdoc IAddressSet
    function remove(address account) external override onlyOwner {
        if (account == address(0)) {
            revert IllegalAddressSetOperation(account, "Address zero not allowed.");
        }
        if (!_addresses.remove(account)) {
            revert IllegalAddressSetOperation(account, "Address not in set.");
        }
        emit AddressSetAltered(account, AddressSetOperation.Remove);
    }
}
