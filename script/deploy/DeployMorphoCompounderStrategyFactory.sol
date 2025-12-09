// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { MorphoCompounderStrategyFactory } from "src/factories/MorphoCompounderStrategyFactory.sol";

contract DeployMorphoCompounderStrategyFactory is Script {
    // Salt for deterministic deployment
    bytes32 public constant DEPLOYMENT_SALT = keccak256("OCTANT_MORPHO_COMPOUNDER_FACTORY_V2");

    MorphoCompounderStrategyFactory public morphoCompounderStrategyFactory;

    function deploy() public virtual returns (address) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        console.log("Deploying MorphoCompounderStrategyFactory with CREATE2...");
        console.log("Deployer:", vm.addr(deployerPrivateKey));

        // Deploy using CREATE2 with salt
        morphoCompounderStrategyFactory = new MorphoCompounderStrategyFactory{ salt: DEPLOYMENT_SALT }();
        address factoryAddress = address(morphoCompounderStrategyFactory);

        console.log("MorphoCompounderStrategyFactory deployed at:", factoryAddress);

        vm.stopBroadcast();
        return factoryAddress;
    }
}
