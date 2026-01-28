// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { DragonTokenizedStrategy } from "src/zodiac-core/vaults/DragonTokenizedStrategy.sol";

/**
 * @title DeployDragonTokenizedStrategy
 * @notice Script to deploy the base implementation of DragonTokenizedStrategy
 * @dev This deploys the implementation contract that will be used as the base for all dragon strategies
 */
contract DeployDragonTokenizedStrategy is Test {
    DragonTokenizedStrategy public dragonTokenizedStrategySingleton;

    function deploy() public virtual {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        dragonTokenizedStrategySingleton = new DragonTokenizedStrategy();
        vm.stopBroadcast();
    }
}
