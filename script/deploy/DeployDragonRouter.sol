// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import { DeploySplitChecker } from "./DeploySplitChecker.sol";
/**
 * @title DeployDragonRouter
 * @notice Script to deploy the DragonRouter with transparent proxy pattern
 * @dev Uses OpenZeppelin Upgrades plugin to handle proxy deployment
 */

contract DeployDragonRouter is DeploySplitChecker {
    /// @notice The deployed DragonRouter implementation
    address public dragonRouterSingleton;
    /// @notice The deployed DragonRouter proxy
    address public dragonRouterProxy;

    function deploy() public virtual override {
        // First deploy SplitChecker
        DeploySplitChecker.deploy();
        dragonRouterSingleton = vm.envAddress("DRAGON_ROUTER_IMPLEMENTATION");
        dragonRouterProxy = vm.envAddress("DRAGON_ROUTER_ADDRESS");

        // Log deployment info
        // console2.log("DragonRouter Singleton deployed at:", address(dragonRouterSingleton));
        // console2.log("DragonRouter Proxy deployed at:", address(dragonRouterProxy));
        // console2.log("\nConfiguration:");
        // console2.log("- Governance:", _getConfiguredAddress("GOVERNANCE"));
        // console2.log("- Split Checker:", address(splitCheckerProxy));
        // console2.log("- Opex Vault:", _getConfiguredAddress("OPEX_VAULT"));
        // console2.log("- Metapool:", _getConfiguredAddress("METAPOOL"));
    }
}
