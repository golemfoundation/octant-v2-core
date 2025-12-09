// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.19;

import { AbstractHatsManager } from "./AbstractHatsManager.sol";
import { Hats__InvalidHat, Hats__DoesNotHaveThisHat, Hats__NotAdminOfHat } from "./HatsErrors.sol";

/**
 * @title DragonHatter
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Branch hat wearer for Dragon Protocol Vault Management
 * @dev This contract wears the Branch Hat (1.1.1.1) and manages role hats beneath it:
 * 1 (Top Hat)
 * └── 1.1 (Autonomous Admin Hat - Protocol)
 *     └── 1.1.1 (Admin Hat - Dragon)
 *         └── 1.1.1.1 (Branch Hat - Vault Management) <-- This contract
 *             ├── 1.1.1.1.1 (Role Hat - Keeper)
 *             ├── 1.1.1.1.2 (Role Hat - Management)
 *             └── 1.1.1.1.3 (Role Hat - EmergencyResponder)
 */
contract DragonHatter is AbstractHatsManager {
    // Role identifiers
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant MANAGEMENT_ROLE = keccak256("MANAGEMENT_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant REGEN_GOVERNANCE_ROLE = keccak256("REGEN_GOVERNANCE_ROLE");

    bool public initialized;

    /// @notice Emitted when branch initialization is complete
    event BranchInitialized();

    error AlreadyInitialized();

    constructor(address hats, uint256 _adminHat, uint256 _branchHat) AbstractHatsManager(hats, _adminHat, _branchHat) {}

    /**
     * @notice Initializes the role hats under this branch
     * @dev Must be called after contract has been granted its branch hat
     */
    function initialize() external {
        // Check initialization
        if (initialized) revert AlreadyInitialized();

        // Verify contract has its branch hat
        require(HATS.isWearerOfHat(address(this), branchHat), Hats__DoesNotHaveThisHat(address(this), branchHat));

        // Create keeper role hat (1.1.1.1.1)
        _createRole(
            KEEPER_ROLE,
            string("Dragon Protocol Keeper"),
            10, // Max 10 keepers
            new address[](0) // No initial keepers
        );

        // Create management role hat (1.1.1.1.2)
        _createRole(
            MANAGEMENT_ROLE,
            string("Dragon Protocol Management"),
            5, // Max 5 managers
            new address[](0) // No initial managers
        );

        // Create emergency role hat (1.1.1.1.3)
        _createRole(
            EMERGENCY_ROLE,
            string("Dragon Protocol Emergency Responder"),
            3, // Max 3 emergency responders
            new address[](0) // No initial responders
        );

        // Create regen governance role hat (1.1.1.1.4)
        _createRole(
            REGEN_GOVERNANCE_ROLE,
            string("Dragon Protocol Regen Governance"),
            5, // Max 5 governance members
            new address[](0) // No initial members
        );

        initialized = true;
        emit BranchInitialized();
    }

    /**
     * @notice Checks if an address is eligible to wear a specific role hat
     * @param wearer Address to check
     * @param hatId Hat ID being checked
     * @return eligible Whether the address can wear the hat
     * @return standing Whether the address is in good standing
     */
    function getWearerStatus(
        address wearer,
        uint256 hatId
    ) external view override returns (bool eligible, bool standing) {
        bytes32 roleId = hatRoles[hatId];
        require(roleId != bytes32(0), Hats__InvalidHat(hatId));

        // Check if hat is under our branch
        require(HATS.isAdminOfHat(address(this), hatId), Hats__NotAdminOfHat(address(this), hatId));

        // Default to true standing - can be extended with role-specific checks
        standing = true;

        // Check eligibility based on role
        if (roleId == KEEPER_ROLE) {
            eligible = _isEligibleKeeper(wearer);
        } else if (roleId == MANAGEMENT_ROLE) {
            eligible = _isEligibleManager(wearer);
        } else if (roleId == EMERGENCY_ROLE) {
            eligible = _isEligibleEmergencyResponder(wearer);
        } else if (roleId == REGEN_GOVERNANCE_ROLE) {
            eligible = _isEligibleRegenGovernance(wearer);
        } else {
            eligible = false;
        }
    }

    /**
     * @notice Get the hat ID for a specific role
     * @param roleId Role identifier
     * @return hatId Corresponding hat ID
     */
    function getRoleHat(bytes32 roleId) external view returns (uint256) {
        return roleHats[roleId];
    }

    /**
     * @notice Check if an address has a specific role
     * @param account Address to check
     * @param roleId Role identifier (KEEPER_ROLE, MANAGEMENT_ROLE, etc.)
     * @return Whether the address has the role
     */
    function hasRole(address account, bytes32 roleId) external view returns (bool) {
        uint256 hatId = roleHats[roleId];
        return hatId != 0 && HATS.isWearerOfHat(account, hatId);
    }

    /**
     * @notice Custom eligibility checks for each role
     * @dev These can be extended with additional logic as needed
     */
    function _isEligibleKeeper(address) internal pure returns (bool) {
        return true; // Base implementation - extend as needed
    }

    function _isEligibleManager(address) internal pure returns (bool) {
        return true; // Base implementation - extend as needed
    }

    function _isEligibleEmergencyResponder(address) internal pure returns (bool) {
        return true; // Base implementation - extend as needed
    }

    function _isEligibleRegenGovernance(address) internal pure returns (bool) {
        return true; // Base implementation - extend as needed
    }
}
