// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import { BatchScript } from "../helpers/BatchScript.sol";

// Factory contracts
import { AaveV3StrategyFactory } from "src/factories/AaveV3StrategyFactory.sol";
import { SparkStrategyFactory } from "src/factories/SparkStrategyFactory.sol";
import { LidoStrategyFactory } from "src/factories/LidoStrategyFactory.sol";

/**
 * @title DeployAaveSparkLidoFactories
 * @author Golem Foundation
 * @notice Deploys the AaveV3, Spark, and Lido strategy factories in ONE Safe transaction
 * @dev Safe calls MultiSendCallOnly which makes three calls to the CREATE2 factory.
 *
 *      Gas budget (EIP-7825 per-transaction cap: 16,777,216):
 *        - AaveV3StrategyFactory: ~15.3KB runtime -> ~3.4M gas
 *        - SparkStrategyFactory:  ~10.5KB runtime -> ~2.4M gas
 *        - LidoStrategyFactory:    ~7.9KB runtime -> ~1.8M gas
 *      Total ~8M gas including Safe/MultiSend overhead - fits in a single transaction.
 *
 *      The factories embed their strategy creation code and hardcode Ethereum mainnet
 *      protocol addresses (Aave AddressesProvider, wstETH, USDC), so this script targets
 *      Ethereum mainnet (or a mainnet fork such as Tenderly staging).
 *
 *      TokenizedStrategy implementations (YieldDonating / YieldSkimming) are NOT deployed
 *      here - factories receive the implementation address as a parameter at
 *      createStrategy() time. Use the addresses from the 11022026 deployment.
 *
 * Usage:
 * ```bash
 * export SAFE_ADDRESS=0x...
 * export WALLET_TYPE=local  # or ledger
 * export PRIVATE_KEY=0x...  # required for WALLET_TYPE=local
 * export SENDER=0x...       # must be a Safe owner or delegate
 * export ETH_RPC_URL=https://...
 *
 * forge script script/deploy/DeployAaveSparkLidoFactories.s.sol \
 *   --rpc-url $ETH_RPC_URL --ffi --sender $SENDER
 * ```
 */
contract DeployAaveSparkLidoFactories is Script, BatchScript {
    // Deployment salts for deterministic addresses (date-based: DDMMYYYY format)
    bytes32 public constant AAVE_V3_FACTORY_SALT = keccak256("AAVE_V3_STRATEGY_FACTORY_21072026");
    bytes32 public constant SPARK_FACTORY_SALT = keccak256("SPARK_STRATEGY_FACTORY_21072026");
    bytes32 public constant LIDO_FACTORY_SALT = keccak256("LIDO_STRATEGY_FACTORY_21072026");

    // Deployed addresses (computed, logged after proposal)
    address public aaveV3Factory;
    address public sparkFactory;
    address public lidoFactory;

    address public safe;

    function setUp() public {
        safe = _loadSafeAddress();
        console.log("Using Safe:", safe);
    }

    function run() public isBatch(safe) {
        _calculateExpectedAddresses();
        _addFactoryDeployments();

        // Propose the single batch transaction to the Safe backend
        executeBatch(true);

        _logDeploymentSummary();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ADDRESS PRECOMPUTATION
    // ═══════════════════════════════════════════════════════════════════════

    function _calculateExpectedAddresses() internal {
        aaveV3Factory = _computeCreate2AddressViaFactory(
            AAVE_V3_FACTORY_SALT,
            keccak256(type(AaveV3StrategyFactory).creationCode)
        );
        sparkFactory = _computeCreate2AddressViaFactory(
            SPARK_FACTORY_SALT,
            keccak256(type(SparkStrategyFactory).creationCode)
        );
        lidoFactory = _computeCreate2AddressViaFactory(
            LIDO_FACTORY_SALT,
            keccak256(type(LidoStrategyFactory).creationCode)
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BATCH DEPLOYMENT LOGIC
    // ═══════════════════════════════════════════════════════════════════════

    function _addFactoryDeployments() internal {
        console.log("\n=== SINGLE BATCH: AaveV3 + Spark + Lido Factories ===\n");

        _addCreate2Deployment(AAVE_V3_FACTORY_SALT, type(AaveV3StrategyFactory).creationCode);
        console.log("- AaveV3StrategyFactory:", aaveV3Factory);

        _addCreate2Deployment(SPARK_FACTORY_SALT, type(SparkStrategyFactory).creationCode);
        console.log("- SparkStrategyFactory:", sparkFactory);

        _addCreate2Deployment(LIDO_FACTORY_SALT, type(LidoStrategyFactory).creationCode);
        console.log("- LidoStrategyFactory:", lidoFactory);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // LOGGING
    // ═══════════════════════════════════════════════════════════════════════

    function _logDeploymentSummary() internal view {
        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Safe Address:", safe);
        console.log("Contracts: 3 (one Safe transaction)");
        console.log("  AaveV3StrategyFactory:", aaveV3Factory);
        console.log("  SparkStrategyFactory:", sparkFactory);
        console.log("  LidoStrategyFactory:", lidoFactory);
        console.log("\nBatch transaction created:");
        console.log("- Safe will call execTransaction once");
        console.log("- execTransaction calls MultiSendCallOnly");
        console.log("- MultiSendCallOnly makes 3 calls to the CREATE2 factory");
        console.log("- CREATE2 factory deploys each contract deterministically");
        console.log("\nTransaction sent to Safe for signing.");
        console.log("==========================\n");
    }
}
