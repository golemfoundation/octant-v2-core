// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { AaveV3StrategyFactory } from "src/factories/AaveV3StrategyFactory.sol";

contract DeployAaveV3StrategyFactory is Script {
    // Salt for deterministic deployment
    bytes32 public constant DEPLOYMENT_SALT = keccak256("OCTANT_AAVE_V3_STRATEGY_FACTORY_V2");

    AaveV3StrategyFactory public aaveV3StrategyFactory;

    function deploy() public virtual returns (address) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        console.log("Deploying AaveV3StrategyFactory with CREATE2...");
        console.log("Deployer:", vm.addr(deployerPrivateKey));

        // Deploy using CREATE2 with salt
        aaveV3StrategyFactory = new AaveV3StrategyFactory{ salt: DEPLOYMENT_SALT }();
        address factoryAddress = address(aaveV3StrategyFactory);

        console.log("AaveV3StrategyFactory deployed at:", factoryAddress);

        vm.stopBroadcast();
        return factoryAddress;
    }
}
