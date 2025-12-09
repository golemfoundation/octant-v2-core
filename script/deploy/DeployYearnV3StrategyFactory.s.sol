// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";
import { YearnV3StrategyFactory } from "src/factories/yieldDonating/YearnV3StrategyFactory.sol";

/**
 * @title DeployYearnV3StrategyFactory
 * @author [Golem Foundation](https://golem.foundation)
 * @notice Deployment script for YearnV3StrategyFactory
 * @dev This deploys the factory that can create YearnV3Strategy instances
 */
contract DeployYearnV3StrategyFactory is Script {
    // Salt for deterministic deployment
    bytes32 public constant DEPLOYMENT_SALT = keccak256("OCT_YEARN_V3_COMPOUNDER_STRATEGY_FACTORY_V1");

    function run() external returns (address) {
        // Load private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Begin deployment with the private key context
        vm.startBroadcast(deployerPrivateKey);

        console.log("Deployer address:", vm.addr(deployerPrivateKey));

        // Deploy the factory deterministically using create2
        YearnV3StrategyFactory factory = new YearnV3StrategyFactory{ salt: DEPLOYMENT_SALT }();
        address factoryAddress = address(factory);

        // Log deployment information
        console.log("YearnV3StrategyFactory deployed at:", factoryAddress);

        vm.stopBroadcast();

        return factoryAddress;
    }
}
