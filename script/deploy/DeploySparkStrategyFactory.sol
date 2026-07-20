// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { SparkStrategyFactory } from "src/factories/SparkStrategyFactory.sol";

contract DeploySparkStrategyFactory is Script {
    // Salt for deterministic deployment
    bytes32 public constant DEPLOYMENT_SALT = keccak256("OCTANT_SPARK_FACTORY_V1");

    SparkStrategyFactory public sparkStrategyFactory;

    function deploy() public virtual returns (address) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        console.log("Deploying SparkStrategyFactory with CREATE2...");
        console.log("Deployer:", vm.addr(deployerPrivateKey));

        // Deploy using CREATE2 with salt
        sparkStrategyFactory = new SparkStrategyFactory{ salt: DEPLOYMENT_SALT }();
        address factoryAddress = address(sparkStrategyFactory);

        console.log("SparkStrategyFactory deployed at:", factoryAddress);

        vm.stopBroadcast();
        return factoryAddress;
    }
}
