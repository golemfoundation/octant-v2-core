// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import { Script, console } from "forge-std/Script.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { MorphoCompounderStrategyFactory } from "src/factories/MorphoCompounderStrategyFactory.sol";

/**
 * @title DeployV2Contracts
 * @notice Deploys V2 contracts with symbol parameter support for Shutter DAO proposal
 * @dev Run with: forge script script/DeployV2Contracts.s.sol --rpc-url $ETH_RPC_URL --broadcast
 */
contract DeployV2Contracts is Script {
    function run() public {
        console.log("Deploying V2 contracts...");
        console.log("");

        vm.startBroadcast();

        // Deploy YieldDonatingTokenizedStrategy V2
        YieldDonatingTokenizedStrategy tokenizedStrategy = new YieldDonatingTokenizedStrategy();
        console.log("YieldDonatingTokenizedStrategy V2 deployed at:", address(tokenizedStrategy));

        // Deploy MorphoCompounderStrategyFactory V2
        MorphoCompounderStrategyFactory factory = new MorphoCompounderStrategyFactory();
        console.log("MorphoCompounderStrategyFactory V2 deployed at:", address(factory));

        vm.stopBroadcast();

        console.log("");
        console.log("Update src/constants.sol with:");
        console.log("  YIELD_DONATING_TOKENIZED_STRATEGY_V2_MAINNET =", address(tokenizedStrategy));
        console.log("  MORPHO_STRATEGY_FACTORY_V2_MAINNET =", address(factory));
    }
}
