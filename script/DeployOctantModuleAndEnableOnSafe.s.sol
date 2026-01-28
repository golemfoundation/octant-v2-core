// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import { ModuleProxyFactory } from "../src/zodiac-core/ModuleProxyFactory.sol";
import { BatchScript } from "./helpers/BatchScript.sol";

contract DeployModuleAndEnableOnSafe is Script, BatchScript {
    address public safe_;
    address public token;
    ModuleProxyFactory public moduleFactory;
    address public safeModuleImplementation;
    address public octantVaultModule;

    address keeper;
    address treasury;
    address dragonRouter;
    uint256 totalValidators;
    uint256 maxYield = 1 ether;

    function setUp() public {
        safe_ = vm.envAddress("SAFE_ADDRESS");
        moduleFactory = ModuleProxyFactory(vm.envAddress("MODULE_FACTORY"));
        safeModuleImplementation = vm.envAddress("MODULE");
        keeper = vm.envAddress("KEEPER");
        treasury = vm.envAddress("TREASURY");
        dragonRouter = vm.envAddress("DRAGON_ROUTER");
        totalValidators = vm.envUint("TOTAL_VALIDATORS");

        vm.startBroadcast();

        octantVaultModule = moduleFactory.deployModule(
            safeModuleImplementation,
            abi.encodeWithSignature(
                "setUp(bytes)",
                abi.encode(safe_, abi.encode(keeper, treasury, dragonRouter, totalValidators, maxYield))
            ),
            block.timestamp
        );

        console.log("Linked Octant Vault Module: ", octantVaultModule);

        vm.stopBroadcast();
    }

    function run() public isBatch(safe_) {
        bytes memory txn1 = abi.encodeWithSignature("enableModule(address)", octantVaultModule);

        addToBatch(safe_, 0, txn1);

        executeBatch(true);
    }
}
