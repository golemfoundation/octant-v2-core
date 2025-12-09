// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { SkyCompounderStrategyFactory } from "src/factories/SkyCompounderStrategyFactory.sol";

contract DeploySkyCompounderStrategyFactory is Script {
    // Salt for deterministic deployment
    bytes32 public constant DEPLOYMENT_SALT = keccak256("OCTANT_SKY_COMPOUNDER_FACTORY_V2");

    SkyCompounderStrategyFactory public skyCompounderStrategyFactory;

    function deploy() public virtual returns (address) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        console.log("Deploying SkyCompounderStrategyFactory with CREATE2...");
        console.log("Deployer:", vm.addr(deployerPrivateKey));

        // Deploy using CREATE2 with salt
        skyCompounderStrategyFactory = new SkyCompounderStrategyFactory{ salt: DEPLOYMENT_SALT }();
        address factoryAddress = address(skyCompounderStrategyFactory);

        console.log("SkyCompounderStrategyFactory deployed at:", factoryAddress);

        vm.stopBroadcast();
        return factoryAddress;
    }
}
