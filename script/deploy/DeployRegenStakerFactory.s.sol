// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { RegenStakerFactory } from "src/factories/RegenStakerFactory.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerWithoutDelegateSurrogateVotes } from "src/regen/RegenStakerWithoutDelegateSurrogateVotes.sol";

/**
 * @title DeployRegenStakerFactory
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Deployment script for RegenStakerFactory
 * @dev Deploys RegenStakerFactory deterministically using CREATE2 with a salt for consistent addresses.
 *      Supports integrated verification via Foundry's --verify flag.
 *
 * Usage:
 * ```bash
 * forge script script/deploy/DeployRegenStakerFactory.s.sol:DeployRegenStakerFactory \
 *   --rpc-url $ETH_RPC_URL \
 *   --private-key $PRIVATE_KEY \
 *   --broadcast \
 *   --verify \
 *   --etherscan-api-key $ETHERSCAN_API_KEY
 * ```
 */
contract DeployRegenStakerFactory is Script {
    error DeploymentFailed();

    /// @notice Salt for deterministic deployment
    bytes32 public constant DEPLOYMENT_SALT = keccak256("OCTANT_REGEN_STAKER_FACTORY_V1");

    /// @notice Deployed factory contract
    RegenStakerFactory public regenStakerFactory;

    function run() public virtual returns (address) {
        return deploy();
    }

    function deploy() public virtual returns (address) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== REGEN STAKER FACTORY DEPLOYMENT ===");
        console.log("Deployer:", deployer);

        bytes32 regenStakerBytecodeHash = keccak256(type(RegenStaker).creationCode);
        bytes32 noDelegationBytecodeHash = keccak256(type(RegenStakerWithoutDelegateSurrogateVotes).creationCode);

        console.log("RegenStaker bytecode hash:");
        console.logBytes32(regenStakerBytecodeHash);
        console.log("RegenStakerWithoutDelegation bytecode hash:");
        console.logBytes32(noDelegationBytecodeHash);

        bytes memory creationCode = abi.encodePacked(
            type(RegenStakerFactory).creationCode,
            abi.encode(regenStakerBytecodeHash, noDelegationBytecodeHash)
        );
        address expectedAddress = _computeCreate2Address(CREATE2_FACTORY, DEPLOYMENT_SALT, keccak256(creationCode));
        console.log("Expected address:", expectedAddress);

        vm.startBroadcast(deployerPrivateKey);

        // Explicitly call CREATE2_FACTORY with salt + bytecode
        bytes memory deployData = abi.encodePacked(DEPLOYMENT_SALT, creationCode);
        (bool success, ) = CREATE2_FACTORY.call(deployData);
        if (!success) {
            revert DeploymentFailed();
        }

        vm.stopBroadcast();

        // Verify deployment succeeded
        regenStakerFactory = RegenStakerFactory(expectedAddress);
        if (expectedAddress.code.length == 0) {
            revert DeploymentFailed();
        }

        console.log("Deployed address:", expectedAddress);
        console.log("[OK] Deployment successful");

        console.log("=== DEPLOYMENT COMPLETE ===");

        return expectedAddress;
    }

    /**
     * @notice Compute expected CREATE2 address
     * @param factory CREATE2 factory address
     * @param salt Deployment salt
     * @param initCodeHash Hash of the contract's creation code (including constructor args)
     * @return Expected deployment address
     */
    function _computeCreate2Address(
        address factory,
        bytes32 salt,
        bytes32 initCodeHash
    ) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", factory, salt, initCodeHash)))));
    }
}
