// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import { ModuleProxyFactory } from "src/zodiac-core/ModuleProxyFactory.sol";
import { SplitChecker } from "src/zodiac-core/SplitChecker.sol";

/**
 * @title DeployModuleProxyFactory
 * @notice Script to deploy the ModuleProxyFactory contract
 * @dev This factory is used to deploy minimal proxy clones of Safe modules
 *      following the EIP-1167 standard for minimal proxy contracts
 */
contract DeployModuleProxyFactory is Script {
    address public governance;
    address public regenGovernance;
    address public metapool;
    address public splitCheckerImplementation = address(new SplitChecker());
    address public dragonRouterImplementation;
    /// @notice The deployed ModuleProxyFactory instance
    ModuleProxyFactory public moduleProxyFactory;

    constructor(address _governance, address _regenGovernance, address _metapool) {
        governance = _governance;
        regenGovernance = _regenGovernance;
        metapool = _metapool;
    }

    function deploy() public virtual {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        dragonRouterImplementation = vm.envAddress("DRAGON_ROUTER_IMPLEMENTATION");

        // Deploy the factory
        moduleProxyFactory = new ModuleProxyFactory(
            governance,
            regenGovernance,
            metapool,
            splitCheckerImplementation,
            dragonRouterImplementation
        );

        vm.stopBroadcast();
    }
}
