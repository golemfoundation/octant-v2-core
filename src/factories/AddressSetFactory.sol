// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import { AddressSet } from "src/utils/AddressSet.sol";

/**
 * @title AddressSetFactory
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Factory for deterministic AddressSet deployment via CREATE2
 * @dev Final salt = keccak256(salt, owner). Ownership transfers to specified owner after deployment.
 */
contract AddressSetFactory {
    /// @notice Information about a deployed AddressSet
    struct AddressSetInfo {
        address deployerAddress;
        uint256 timestamp;
        address owner;
        address addressSet;
        bytes32 salt;
    }

    /// @dev Tracks deployed AddressSets per deployer
    mapping(address => AddressSetInfo[]) public addressSets;

    /// @notice Emitted when a new AddressSet is deployed
    /// @param deployer Address that called deploy
    /// @param addressSet Deployed AddressSet address
    /// @param owner Address that owns the AddressSet
    /// @param salt Salt used for CREATE2 derivation
    event AddressSetDeployed(address indexed deployer, address indexed addressSet, address indexed owner, bytes32 salt);

    /// @notice Deploy a new AddressSet with deterministic address
    /// @param salt Salt for CREATE2 address derivation
    /// @param owner Address that will own the AddressSet
    /// @return addressSet Deployed AddressSet address
    function deploy(bytes32 salt, address owner) external returns (address addressSet) {
        bytes32 finalSalt = keccak256(abi.encode(salt, owner));
        AddressSet set = new AddressSet{ salt: finalSalt }();
        set.transferOwnership(owner);
        addressSet = address(set);
        _recordAddressSet(owner, addressSet, salt);
        emit AddressSetDeployed(msg.sender, addressSet, owner, salt);
    }

    /// @notice Predict deployment address before calling deploy
    /// @param salt Salt for CREATE2 address derivation
    /// @param owner Address that will own the AddressSet
    /// @return predicted Predicted deployment address
    function predictAddress(bytes32 salt, address owner) external view returns (address predicted) {
        bytes32 finalSalt = keccak256(abi.encode(salt, owner));
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), finalSalt, keccak256(type(AddressSet).creationCode))
        );
        predicted = address(uint160(uint256(hash)));
    }

    /// @notice Returns all AddressSets deployed by a specific address
    /// @param deployer Deployer address
    /// @return Array of AddressSetInfo entries for every AddressSet deployed by the given deployer
    function getAddressSetsByDeployer(address deployer) external view returns (AddressSetInfo[] memory) {
        return addressSets[deployer];
    }

    function _recordAddressSet(address owner, address deployedAddressSet, bytes32 salt) internal {
        addressSets[msg.sender].push(
            AddressSetInfo({
                deployerAddress: msg.sender,
                timestamp: block.timestamp,
                owner: owner,
                addressSet: deployedAddressSet,
                salt: salt
            })
        );
    }
}
