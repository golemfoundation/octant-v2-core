// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { RocketPoolStrategyFactory } from "src/factories/yieldSkimming/RocketPoolStrategyFactory.sol";

contract DeployRocketPoolStrategyFactory is Script {
    // Salt for deterministic deployment
    bytes32 public constant DEPLOYMENT_SALT = keccak256("OCTANT_ROCKET_POOL_FACTORY_V2");

    RocketPoolStrategyFactory public rocketPoolStrategyFactory;

    function deploy() public virtual returns (address) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        console.log("Deploying RocketPoolStrategyFactory with CREATE2...");
        console.log("Deployer:", vm.addr(deployerPrivateKey));

        // Deploy using CREATE2 with salt
        rocketPoolStrategyFactory = new RocketPoolStrategyFactory{ salt: DEPLOYMENT_SALT }();
        address factoryAddress = address(rocketPoolStrategyFactory);

        console.log("RocketPoolStrategyFactory deployed at:", factoryAddress);

        vm.stopBroadcast();
        return factoryAddress;
    }
}
