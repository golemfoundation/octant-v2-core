// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { AddressSetFactory } from "src/factories/AddressSetFactory.sol";
import { AddressSet } from "src/utils/AddressSet.sol";

/**
 * @title DeployAddressSet
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Deployment script for AddressSet contracts via AddressSetFactory
 * @dev Deploys AddressSet instances through the factory for correct ownership and deterministic addresses.
 *
 *      PREREQUISITES:
 *      - AddressSetFactory must be deployed first (use DeployAddressSetFactory.s.sol)
 *      - Set ADDRESS_SET_FACTORY env var to the factory address
 *
 * Usage:
 * ```bash
 * # Deploy a staker allowset
 * ADDRESS_SET_FACTORY=0x... ADDRESS_SET_SALT=STAKER_ALLOWSET_V1 \
 * forge script script/deploy/DeployAddressSet.s.sol:DeployAddressSet \
 *   --rpc-url $ETH_RPC_URL \
 *   --private-key $PRIVATE_KEY \
 *   --broadcast \
 *   --verify \
 *   --etherscan-api-key $ETHERSCAN_API_KEY
 * ```
 *
 * Environment Variables:
 * - PRIVATE_KEY: Deployer private key (will become owner)
 * - ADDRESS_SET_FACTORY: Address of deployed AddressSetFactory
 * - ADDRESS_SET_SALT: Salt string for deterministic address (e.g., "STAKER_ALLOWSET_V1")
 */
contract DeployAddressSet is Script {
    error AddressMismatch(address expected, address actual);
    error OwnerMismatch(address expected, address actual);

    /// @notice Default salts for common AddressSet deployments
    bytes32 public constant STAKER_ALLOWSET_SALT = keccak256("OCTANT_STAKER_ALLOWSET_V1");
    bytes32 public constant STAKER_BLOCKSET_SALT = keccak256("OCTANT_STAKER_BLOCKSET_V1");
    bytes32 public constant ALLOCATION_MECHANISM_ALLOWSET_SALT = keccak256("OCTANT_ALLOCATION_MECHANISM_ALLOWSET_V1");

    /// @notice Deployed AddressSet contract
    AddressSet public addressSet;

    function run() external returns (address) {
        return deploy();
    }

    function deploy() public returns (address) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address factoryAddress = vm.envAddress("ADDRESS_SET_FACTORY");
        string memory saltString = vm.envOr("ADDRESS_SET_SALT", string("OCTANT_ADDRESS_SET_V1"));
        bytes32 salt = keccak256(bytes(saltString));

        AddressSetFactory factory = AddressSetFactory(factoryAddress);

        console.log("=== ADDRESSSET DEPLOYMENT VIA FACTORY ===");
        console.log("Deployer (will be owner):", deployer);
        console.log("Factory:", factoryAddress);
        console.log("Salt string:", saltString);
        console.logBytes32(salt);

        address expectedAddress = factory.predictAddress(salt, deployer);
        console.log("Expected AddressSet address:", expectedAddress);

        vm.startBroadcast(deployerPrivateKey);

        address deployedAddress = factory.deploy(salt, deployer);
        addressSet = AddressSet(deployedAddress);

        vm.stopBroadcast();

        console.log("Deployed AddressSet address:", deployedAddress);

        if (expectedAddress != deployedAddress) {
            revert AddressMismatch(expectedAddress, deployedAddress);
        }
        console.log("[OK] Deployment is deterministic");

        address owner = addressSet.owner();
        console.log("Owner:", owner);

        if (owner != deployer) {
            revert OwnerMismatch(deployer, owner);
        }
        console.log("[OK] Ownership correctly set to deployer");

        console.log("=== DEPLOYMENT COMPLETE ===");

        return deployedAddress;
    }

    /// @notice Deploy all three AddressSets needed for RegenStaker
    /// @return stakerAllowset Address of staker allowset
    /// @return stakerBlockset Address of staker blockset
    /// @return allocationMechanismAllowset Address of allocation mechanism allowset
    function deployAll()
        external
        returns (address stakerAllowset, address stakerBlockset, address allocationMechanismAllowset)
    {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address factoryAddress = vm.envAddress("ADDRESS_SET_FACTORY");
        AddressSetFactory factory = AddressSetFactory(factoryAddress);

        console.log("=== DEPLOYING ALL ADDRESSSETS FOR REGENSTAKER ===");
        console.log("Deployer (will be owner):", deployer);
        console.log("Factory:", factoryAddress);

        vm.startBroadcast(deployerPrivateKey);

        stakerAllowset = factory.deploy(STAKER_ALLOWSET_SALT, deployer);
        console.log("Staker Allowset:", stakerAllowset);

        stakerBlockset = factory.deploy(STAKER_BLOCKSET_SALT, deployer);
        console.log("Staker Blockset:", stakerBlockset);

        allocationMechanismAllowset = factory.deploy(ALLOCATION_MECHANISM_ALLOWSET_SALT, deployer);
        console.log("Allocation Mechanism Allowset:", allocationMechanismAllowset);

        vm.stopBroadcast();

        console.log("=== ALL ADDRESSSETS DEPLOYED ===");
    }
}
