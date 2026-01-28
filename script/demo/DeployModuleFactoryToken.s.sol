// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { ModuleProxyFactory } from "src/zodiac-core/ModuleProxyFactory.sol";
import { MockVaultModule } from "test/mocks/MockVaultModule.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { SplitChecker } from "src/zodiac-core/SplitChecker.sol";
import "forge-std/Script.sol";

contract DeployModuleFactoryTestToken is Script {
    address public splitCheckerImplementation = address(new SplitChecker());
    address public dragonRouterImplementation;

    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        dragonRouterImplementation = vm.envAddress("DRAGON_ROUTER_IMPLEMENTATION");

        ModuleProxyFactory factory = new ModuleProxyFactory(
            msg.sender,
            msg.sender,
            msg.sender,
            splitCheckerImplementation,
            dragonRouterImplementation
        );

        MockVaultModule dragonVaultModule = new MockVaultModule();

        MockERC20 testERC20 = new MockERC20(18);

        vm.stopBroadcast();

        // Log the address of the newly deployed Safe
        console.log("Factory deployed at:", address(factory));
        console.log("Dragon Vault Module deployed at:", address(dragonVaultModule));
        console.log("Test ERC20 Token", address(testERC20));
    }
}
