// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

// Global constants and enums used across Octant contracts

// Sentinel value representing native ETH (address(0) for ETH instead of ERC20)
address constant NATIVE_TOKEN = address(0);

/**
 * @notice Access control modes for address set validation
 * @dev Used by LinearAllowanceExecutor and RegenStaker
 */
enum AccessMode {
    NONE, // No access control (permissionless)
    ALLOWSET, // Only addresses in allowset are permitted
    BLOCKSET // All addresses except those in blockset are permitted
}
