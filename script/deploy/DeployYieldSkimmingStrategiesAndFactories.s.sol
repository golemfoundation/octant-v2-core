// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import { BatchScript } from "../helpers/BatchScript.sol";

// Strategy implementations
import { YieldSkimmingTokenizedStrategy } from "src/strategies/yieldSkimming/YieldSkimmingTokenizedStrategy.sol";

// Factory contracts
import { LidoStrategyFactory } from "src/factories/LidoStrategyFactory.sol";
import { RocketPoolStrategyFactory } from "src/factories/yieldSkimming/RocketPoolStrategyFactory.sol";

/**
 * @title DeployYieldSkimmingStrategiesAndFactories
 * @author Golem Foundation
 * @notice Deployment script that deploys yield skimming tokenized strategy and factory contracts via Safe multisig
 * @dev Safe calls MultiSendCallOnly which makes multiple calls to CREATE2 factory for deployment
 */
contract DeployYieldSkimmingStrategiesAndFactories is Script, BatchScript {
    // Deployment salts for deterministic addresses (date-based: DDMMYYYY format)
    bytes32 public constant YIELD_SKIMMING_SALT = keccak256("OCTANT_YIELD_SKIMMING_STRATEGY_09012026");

    // Factory deployment salts
    bytes32 public constant LIDO_FACTORY_SALT = keccak256("LIDO_STRATEGY_FACTORY_09012026");
    bytes32 public constant ROCKET_POOL_FACTORY_SALT = keccak256("ROCKET_POOL_STRATEGY_FACTORY_09012026");

    // Deployed addresses (to be logged)
    address public yieldSkimmingStrategy;
    address public lidoFactory;
    address public rocketPoolFactory;

    // Safe address
    address public safe;

    function setUp() public {
        // Get Safe address from environment or prompt
        safe = vm.envOr("SAFE_ADDRESS", address(0));
        if (safe == address(0)) {
            try vm.prompt("Enter Safe Address") returns (string memory res) {
                safe = vm.parseAddress(res);
            } catch {
                revert("Invalid Safe Address");
            }
        }

        console.log("Using Safe:", safe);
    }

    function run() public isBatch(safe) {
        // Calculate expected addresses
        _calculateExpectedAddresses();

        // Add all deployment transactions to the batch
        _addStrategyDeployments();
        _addFactoryDeployments();

        // Execute the batch (sends to Safe backend)
        executeBatch(true);

        // Log deployment summary
        _logDeploymentSummary();
    }

    function _calculateExpectedAddresses() internal {
        // YieldSkimmingTokenizedStrategy
        bytes memory ysCreationCode = type(YieldSkimmingTokenizedStrategy).creationCode;
        yieldSkimmingStrategy = _computeCreate2Address(CREATE2_FACTORY, YIELD_SKIMMING_SALT, keccak256(ysCreationCode));

        // LidoStrategyFactory
        bytes memory lidoCreationCode = type(LidoStrategyFactory).creationCode;
        lidoFactory = _computeCreate2Address(CREATE2_FACTORY, LIDO_FACTORY_SALT, keccak256(lidoCreationCode));

        // RocketPoolStrategyFactory
        bytes memory rocketPoolCreationCode = type(RocketPoolStrategyFactory).creationCode;
        rocketPoolFactory = _computeCreate2Address(
            CREATE2_FACTORY,
            ROCKET_POOL_FACTORY_SALT,
            keccak256(rocketPoolCreationCode)
        );
    }

    function _addStrategyDeployments() internal {
        console.log("Adding strategy deployments to batch...");

        // Deploy YieldSkimmingTokenizedStrategy
        bytes memory ysDeployData = abi.encodePacked(
            YIELD_SKIMMING_SALT,
            type(YieldSkimmingTokenizedStrategy).creationCode
        );
        addToBatch(CREATE2_FACTORY, 0, ysDeployData);
        console.log("- YieldSkimmingTokenizedStrategy at:", yieldSkimmingStrategy);
    }

    function _addFactoryDeployments() internal {
        console.log("Adding factory deployments to batch...");

        // Deploy LidoStrategyFactory
        // CREATE2 factory expects: salt (32 bytes) + bytecode
        bytes memory lidoDeployData = abi.encodePacked(LIDO_FACTORY_SALT, type(LidoStrategyFactory).creationCode);
        addToBatch(CREATE2_FACTORY, 0, lidoDeployData);
        console.log("- LidoStrategyFactory at:", lidoFactory);

        // Deploy RocketPoolStrategyFactory
        bytes memory rocketPoolDeployData = abi.encodePacked(
            ROCKET_POOL_FACTORY_SALT,
            type(RocketPoolStrategyFactory).creationCode
        );
        addToBatch(CREATE2_FACTORY, 0, rocketPoolDeployData);
        console.log("- RocketPoolStrategyFactory at:", rocketPoolFactory);
    }

    function _logDeploymentSummary() internal view {
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Safe Address:", safe);
        console.log("\nTokenized Strategies:");
        console.log("- YieldSkimmingTokenizedStrategy:", yieldSkimmingStrategy);
        console.log("\nFactory Contracts:");
        console.log("- LidoStrategyFactory:", lidoFactory);
        console.log("- RocketPoolStrategyFactory:", rocketPoolFactory);
        console.log("\nBatch transaction created:");
        console.log("- Safe will call execTransaction once");
        console.log("- execTransaction calls MultiSendCallOnly");
        console.log("- MultiSendCallOnly makes 3 calls to CREATE2 factory");
        console.log("- CREATE2 factory deploys each contract deterministically");
        console.log("\nTransaction sent to Safe for signing.");
        console.log("========================\n");
    }

    /**
     * @notice Helper function to compute CREATE2 address
     * @param _deployer Address that will deploy the contract
     * @param _salt Salt used for deployment
     * @param _initCodeHash Hash of the contract's creation code
     * @return Expected deployment address
     */
    function _computeCreate2Address(
        address _deployer,
        bytes32 _salt,
        bytes32 _initCodeHash
    ) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", _deployer, _salt, _initCodeHash)))));
    }
}
