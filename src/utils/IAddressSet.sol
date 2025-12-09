// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

/// @title IAddressSet
/// @author [Golem Foundation](https://golem.foundation)
/// @custom:security-contact security@golem.foundation
/// @notice Interface for a managed set of addresses with access control
/// @dev Provides add/remove operations and membership checking
interface IAddressSet {
    /// @notice Check if an address is in the set
    /// @param account Address to check
    /// @return True if the address is in the set, false otherwise
    function contains(address account) external view returns (bool);

    /// @notice Add an address to the set
    /// @param account Address to add
    /// @dev Reverts if address is already in the set or is address(0)
    function add(address account) external;

    /// @notice Add multiple addresses to the set
    /// @param accounts Addresses to add
    /// @dev Reverts on first invalid address (already in set or address(0))
    function add(address[] memory accounts) external;

    /// @notice Remove an address from the set
    /// @param account Address to remove
    /// @dev Reverts if address is not in the set
    function remove(address account) external;

    /// @notice Remove multiple addresses from the set
    /// @param accounts Addresses to remove
    /// @dev Reverts on first address not in the set
    function remove(address[] memory accounts) external;
}
