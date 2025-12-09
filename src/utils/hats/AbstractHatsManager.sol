// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.19;

import { IHats } from "hats-protocol/Interfaces/IHats.sol";
import { IHatsEligibility } from "src/utils/hats/interfaces/IHatsEligibility.sol";
import { IHatsToggle } from "src/utils/hats/interfaces/IHatsToggle.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Hats__InvalidAddressFor, Hats__InvalidHat, Hats__DoesNotHaveThisHat, Hats__HatAlreadyExists, Hats__HatDoesNotExist, Hats__TooManyInitialHolders, Hats__NotAdminOfHat } from "./HatsErrors.sol";

/**
 * @title AbstractHatsManager
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Abstract pattern for managing hierarchical roles through Hats Protocol
 * @dev Implements base logic for creating and managing role-based hats under a branch
 */
abstract contract AbstractHatsManager is ReentrancyGuard, IHatsEligibility, IHatsToggle {
    /// @notice Hats Protocol contract instance
    IHats public immutable HATS;

    /// @notice Parent admin hat ID with admin privileges
    uint256 public immutable adminHat;

    /// @notice Branch admin hat ID
    uint256 public immutable branchHat;

    /// @notice Maps role identifiers to hat IDs
    mapping(bytes32 => uint256) public roleHats;

    /// @notice Reverse mapping of hats to role identifiers
    mapping(uint256 => bytes32) public hatRoles;

    /// @notice Whether the branch is currently active
    bool public isActive = true;

    /// @notice Emitted when a new role hat is created
    /// @param roleId Unique role identifier
    /// @param hatId Hats Protocol hat ID assigned to the role
    event RoleHatCreated(bytes32 roleId, uint256 hatId);

    /// @notice Emitted when a role is granted to an account
    /// @param roleId Role identifier
    /// @param account Address receiving the role
    /// @param hatId Hat ID representing the role
    event RoleGranted(bytes32 roleId, address account, uint256 hatId);

    /// @notice Emitted when a role is revoked from an account
    /// @param roleId Role identifier
    /// @param account Address losing the role
    /// @param hatId Hat ID representing the role
    event RoleRevoked(bytes32 roleId, address account, uint256 hatId);

    /**
     * @notice Initializes the hat hierarchy
     * @param hats Address of Hats protocol contract
     * @param _adminHat Admin hat ID with admin privileges
     * @param _branchHat Branch hat ID
     */
    constructor(address hats, uint256 _adminHat, uint256 _branchHat) {
        require(hats != address(0), Hats__InvalidAddressFor("Hats", hats));
        HATS = IHats(hats);

        require(HATS.isWearerOfHat(msg.sender, _adminHat), Hats__DoesNotHaveThisHat(msg.sender, _adminHat));
        adminHat = _adminHat;
        branchHat = _branchHat;
    }

    /**
     * @notice Allows admin to toggle role availability
     */
    function toggleBranch() external virtual {
        require(HATS.isWearerOfHat(msg.sender, adminHat), Hats__DoesNotHaveThisHat(msg.sender, adminHat));
        isActive = !isActive;
    }

    /**
     * @notice Virtual function to check if an address is eligible for a role
     * @dev Must be implemented by inheriting contracts
     */
    function getWearerStatus(
        address wearer,
        uint256 hatId
    ) external view virtual override returns (bool eligible, bool standing);

    /**
     * @notice Checks if roles are currently enabled
     * @param hatId Hat ID to check
     * @return bool Whether the hat is active
     */
    function getHatStatus(uint256 hatId) external view override returns (bool) {
        require(hatId == branchHat || hatRoles[hatId] != 0, Hats__InvalidHat(hatId));
        return isActive;
    }

    /**
     * @notice Grants a role to an address by minting the corresponding hat
     * @dev This function may only be called by the admin hat of this contract
     * @param roleId Role to grant
     * @param account Address to receive role
     */
    function grantRole(bytes32 roleId, address account) public virtual {
        require(HATS.isWearerOfHat(msg.sender, adminHat), Hats__DoesNotHaveThisHat(msg.sender, adminHat));
        require(account != address(0), Hats__InvalidAddressFor("account", account));

        uint256 hatId = roleHats[roleId];
        require(hatId != 0, Hats__HatDoesNotExist(roleId));

        // Mint role hat
        HATS.mintHat(hatId, account);
        emit RoleGranted(roleId, account, hatId);
    }

    /**
     * @notice Revokes a role from an address by burning the corresponding hat
     * @param roleId Role to revoke
     * @param account Address to revoke role from
     */
    function revokeRole(bytes32 roleId, address account) public virtual {
        require(HATS.isWearerOfHat(msg.sender, adminHat), Hats__DoesNotHaveThisHat(msg.sender, adminHat));

        uint256 hatId = roleHats[roleId];
        require(hatId != 0, Hats__HatDoesNotExist(roleId));
        require(HATS.isWearerOfHat(account, hatId), Hats__DoesNotHaveThisHat(account, hatId));

        // Burn role hat
        HATS.setHatWearerStatus(hatId, account, false, false);
        emit RoleRevoked(roleId, account, hatId);
    }

    /**
     * @notice Creates a new role hat under the branch
     * @param roleId Unique identifier for the role
     * @param details Human-readable description of the role
     * @param maxSupply Maximum number of addresses that can hold this role
     * @param initialHolders Optional array of addresses to grant the role to immediately
     * @return hatId ID of newly created role hat
     */
    function _createRole(
        bytes32 roleId,
        string memory details,
        uint256 maxSupply,
        address[] memory initialHolders
    ) internal virtual nonReentrant returns (uint256 hatId) {
        require(HATS.isAdminOfHat(msg.sender, adminHat), Hats__NotAdminOfHat(msg.sender, adminHat));
        require(roleHats[roleId] == 0, Hats__HatAlreadyExists(roleId));
        require(initialHolders.length <= maxSupply, Hats__TooManyInitialHolders(initialHolders.length, maxSupply));

        // Create role hat under branch
        // False positive: marked nonReentrant
        //slither-disable-next-line reentrancy-no-eth
        hatId = HATS.createHat(
            branchHat,
            details,
            uint32(maxSupply),
            address(this), // this contract determines eligibility
            address(this), // this contract controls activation
            true, // can be modified by admin
            "" // no custom image
        );

        roleHats[roleId] = hatId;
        hatRoles[hatId] = roleId;

        // Mint hats to initial holders
        for (uint256 i = 0; i < initialHolders.length; i++) {
            address holder = initialHolders[i];
            require(holder != address(0), Hats__InvalidAddressFor("initial holder", holder));

            // mintHat(
            //    uint256 hatId,    // Hat ID to mint
            //    address wearer    // Address to receive hat
            // )
            HATS.mintHat(hatId, holder);
            emit RoleGranted(roleId, holder, hatId);
        }

        emit RoleHatCreated(roleId, hatId);
    }
}
