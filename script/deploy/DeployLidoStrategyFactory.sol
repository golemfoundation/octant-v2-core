// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { LidoStrategyFactory } from "src/factories/LidoStrategyFactory.sol";

contract DeployLidoStrategyFactory is Script {
    // Salt for deterministic deployment
    bytes32 public constant DEPLOYMENT_SALT = keccak256("OCTANT_LIDO_FACTORY_V2");

    LidoStrategyFactory public lidoStrategyFactory;

    function deploy() public virtual returns (address) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        console.log("Deploying LidoStrategyFactory with CREATE2...");
        console.log("Deployer:", vm.addr(deployerPrivateKey));

        // Deploy using CREATE2 with salt
        lidoStrategyFactory = new LidoStrategyFactory{ salt: DEPLOYMENT_SALT }();
        address factoryAddress = address(lidoStrategyFactory);

        console.log("LidoStrategyFactory deployed at:", factoryAddress);

        vm.stopBroadcast();
        return factoryAddress;
    }
}
