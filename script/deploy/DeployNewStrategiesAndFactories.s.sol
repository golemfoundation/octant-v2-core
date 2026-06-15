// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import { BatchScript } from "../helpers/BatchScript.sol";

// Strategy implementations
import { YieldSkimmingTokenizedStrategy } from "src/strategies/yieldSkimming/YieldSkimmingTokenizedStrategy.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

// Factory contracts
import { PaymentSplitterFactory } from "src/factories/PaymentSplitterFactory.sol";
import { LidoStrategyFactory } from "src/factories/LidoStrategyFactory.sol";
import { MorphoCompounderStrategyFactory } from "src/factories/MorphoCompounderStrategyFactory.sol";
import { SkyCompounderStrategyFactory } from "src/factories/SkyCompounderStrategyFactory.sol";
import { YearnV3StrategyFactory } from "src/factories/yieldDonating/YearnV3StrategyFactory.sol";
import { AaveV3StrategyFactory } from "src/factories/AaveV3StrategyFactory.sol";

// RegenStaker ecosystem
import { AddressSetFactory } from "src/factories/AddressSetFactory.sol";
import { RegenEarningPowerCalculatorFactory } from "src/factories/RegenEarningPowerCalculatorFactory.sol";
import { RegenStakerFactory } from "src/factories/RegenStakerFactory.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerWithoutDelegateSurrogateVotes } from "src/regen/RegenStakerWithoutDelegateSurrogateVotes.sol";

/**
 * @title DeployNewStrategiesAndFactories
 * @author Golem Foundation
 * @notice Deploys new tokenized strategies, factories, and RegenStaker infrastructure via Safe multisig
 * @dev Due to the EIP-7825 per-transaction gas limit of 16,777,216 gas (2^24), all 11 contracts
 *      cannot be deployed in a single transaction. The deployment is split
 *      into three Safe MultiSend batches:
 *
 *      Batch 1 (~12.4M gas): Implementations + PaymentSplitter + YieldSkimming factories (5 contracts)
 *        - YieldSkimmingTokenizedStrategy
 *        - YieldDonatingTokenizedStrategy
 *        - PaymentSplitterFactory
 *        - LidoStrategyFactory
 *        - MorphoCompounderStrategyFactory
 *
 *      Batch 2: Remaining YieldDonating factories (3 contracts)
 *        - SkyCompounderStrategyFactory
 *        - YearnV3StrategyFactory
 *        - AaveV3StrategyFactory
 *
 *      Batch 3 (~3M gas): RegenStaker infrastructure (3 contracts)
 *        - AddressSetFactory
 *        - RegenEarningPowerCalculatorFactory
 *        - RegenStakerFactory
 *
 * Usage:
 * ```bash
 * export SAFE_ADDRESS=0x...
 * export CHAIN=mainnet
 * export WALLET_TYPE=local  # or ledger
 * export PRIVATE_KEY=0x...  # required for WALLET_TYPE=local
 * export SENDER=0x...       # must be a Safe owner or delegate
 * export ETH_RPC_URL=https://...
 *
 * # Deploy ALL (three batches, three Safe proposals in sequence: nonce N, N+1, N+2)
 * forge script script/deploy/DeployNewStrategiesAndFactories.s.sol \
 *   --rpc-url $ETH_RPC_URL --ffi --sender $SENDER
 *
 * # Or deploy each batch individually:
 * forge script script/deploy/DeployNewStrategiesAndFactories.s.sol \
 *   --sig "runBatch1()" --rpc-url $ETH_RPC_URL --ffi --sender $SENDER
 *
 * forge script script/deploy/DeployNewStrategiesAndFactories.s.sol \
 *   --sig "runBatch2()" --rpc-url $ETH_RPC_URL --ffi --sender $SENDER
 *
 * forge script script/deploy/DeployNewStrategiesAndFactories.s.sol \
 *   --sig "runBatch3()" --rpc-url $ETH_RPC_URL --ffi --sender $SENDER
 * ```
 */
contract DeployNewStrategiesAndFactories is Script, BatchScript {
    // ═══════════════════════════════════════════════════════════════════════
    // DEPLOYMENT SALTS (date-based: DDMMYYYY format)
    // ═══════════════════════════════════════════════════════════════════════

    // Strategy implementation salts
    bytes32 public constant YIELD_SKIMMING_SALT = keccak256("OCTANT_YIELD_SKIMMING_STRATEGY_11022026");
    bytes32 public constant YIELD_DONATING_SALT = keccak256("OCTANT_YIELD_DONATING_STRATEGY_11022026");

    // Factory deployment salts
    bytes32 public constant PAYMENT_SPLITTER_FACTORY_SALT = keccak256("PAYMENT_SPLITTER_FACTORY_11022026");
    bytes32 public constant LIDO_FACTORY_SALT = keccak256("LIDO_STRATEGY_FACTORY_11022026");
    bytes32 public constant MORPHO_FACTORY_SALT = keccak256("MORPHO_COMPOUNDER_FACTORY_11022026");
    bytes32 public constant SKY_FACTORY_SALT = keccak256("SKY_COMPOUNDER_FACTORY_11022026");
    bytes32 public constant YEARN_V3_FACTORY_SALT = keccak256("YEARN_V3_STRATEGY_FACTORY_11022026");
    bytes32 public constant AAVE_V3_FACTORY_SALT = keccak256("AAVE_V3_STRATEGY_FACTORY_11022026");

    // RegenStaker ecosystem salts
    bytes32 public constant ADDRESS_SET_FACTORY_SALT = keccak256("ADDRESS_SET_FACTORY_11022026");
    bytes32 public constant EARNING_POWER_CALCULATOR_FACTORY_SALT =
        keccak256("REGEN_EARNING_POWER_CALCULATOR_FACTORY_11022026");
    bytes32 public constant REGEN_STAKER_FACTORY_SALT = keccak256("REGEN_STAKER_FACTORY_11022026");

    // ═══════════════════════════════════════════════════════════════════════
    // DEPLOYED ADDRESSES (computed, logged after deployment)
    // ═══════════════════════════════════════════════════════════════════════

    // Batch 1
    address public yieldSkimmingStrategy;
    address public yieldDonatingStrategy;
    address public paymentSplitterFactory;
    address public lidoFactory;
    address public morphoFactory;

    // Batch 2
    address public skyFactory;
    address public yearnV3Factory;
    address public aaveV3Factory;

    // Batch 3
    address public addressSetFactory;
    address public earningPowerCalculatorFactory;
    address public regenStakerFactory;

    address public safe;

    function setUp() public {
        safe = _loadSafeAddress();
        console.log("Using Safe:", safe);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // RUN ALL: Proposes all batches as three Safe transactions (nonce N, N+1, N+2)
    // ═══════════════════════════════════════════════════════════════════════

    function run() public isBatch(safe) {
        // --- Batch 1 ---
        _calculateBatch1Addresses();
        _addBatch1Deployments();
        executeBatch(true);
        _logBatch1Summary();

        // Clear the transaction queue for batch 2
        delete encodedTxns;

        // --- Batch 2 ---
        _calculateBatch2Addresses();
        _addBatch2Deployments();
        executeBatch(true);
        _logBatch2Summary();

        // Clear the transaction queue for batch 3
        delete encodedTxns;

        // --- Batch 3 ---
        _calculateBatch3Addresses();
        _addBatch3Deployments();
        executeBatch(true);
        _logBatch3Summary();

        _logFullSummary();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BATCH 1: Implementations + PaymentSplitter + YieldSkimming factories
    // Estimated gas: ~12.4M (under 16.78M EIP-7825 limit)
    // ═══════════════════════════════════════════════════════════════════════

    function runBatch1() external isBatch(safe) {
        _calculateBatch1Addresses();
        _addBatch1Deployments();
        executeBatch(true);
        _logBatch1Summary();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BATCH 2: Remaining YieldDonating factories
    // ═══════════════════════════════════════════════════════════════════════

    function runBatch2() external isBatch(safe) {
        _calculateBatch2Addresses();
        _addBatch2Deployments();
        executeBatch(true);
        _logBatch2Summary();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BATCH 3: RegenStaker infrastructure
    // Estimated gas: ~3M (under 16.78M EIP-7825 limit)
    // ═══════════════════════════════════════════════════════════════════════

    function runBatch3() external isBatch(safe) {
        _calculateBatch3Addresses();
        _addBatch3Deployments();
        executeBatch(true);
        _logBatch3Summary();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ADDRESS PRECOMPUTATION
    // ═══════════════════════════════════════════════════════════════════════

    function _calculateBatch1Addresses() internal {
        yieldSkimmingStrategy = _computeCreate2AddressViaFactory(
            YIELD_SKIMMING_SALT,
            keccak256(type(YieldSkimmingTokenizedStrategy).creationCode)
        );
        yieldDonatingStrategy = _computeCreate2AddressViaFactory(
            YIELD_DONATING_SALT,
            keccak256(type(YieldDonatingTokenizedStrategy).creationCode)
        );
        paymentSplitterFactory = _computeCreate2AddressViaFactory(
            PAYMENT_SPLITTER_FACTORY_SALT,
            keccak256(type(PaymentSplitterFactory).creationCode)
        );
        lidoFactory = _computeCreate2AddressViaFactory(
            LIDO_FACTORY_SALT,
            keccak256(type(LidoStrategyFactory).creationCode)
        );
        morphoFactory = _computeCreate2AddressViaFactory(
            MORPHO_FACTORY_SALT,
            keccak256(type(MorphoCompounderStrategyFactory).creationCode)
        );
    }

    function _calculateBatch2Addresses() internal {
        skyFactory = _computeCreate2AddressViaFactory(
            SKY_FACTORY_SALT,
            keccak256(type(SkyCompounderStrategyFactory).creationCode)
        );
        yearnV3Factory = _computeCreate2AddressViaFactory(
            YEARN_V3_FACTORY_SALT,
            keccak256(type(YearnV3StrategyFactory).creationCode)
        );
        aaveV3Factory = _computeCreate2AddressViaFactory(
            AAVE_V3_FACTORY_SALT,
            keccak256(type(AaveV3StrategyFactory).creationCode)
        );
    }

    function _calculateBatch3Addresses() internal {
        addressSetFactory = _computeCreate2AddressViaFactory(
            ADDRESS_SET_FACTORY_SALT,
            keccak256(type(AddressSetFactory).creationCode)
        );
        earningPowerCalculatorFactory = _computeCreate2AddressViaFactory(
            EARNING_POWER_CALCULATOR_FACTORY_SALT,
            keccak256(type(RegenEarningPowerCalculatorFactory).creationCode)
        );
        regenStakerFactory = _computeCreate2AddressViaFactory(
            REGEN_STAKER_FACTORY_SALT,
            keccak256(
                abi.encodePacked(
                    type(RegenStakerFactory).creationCode,
                    abi.encode(
                        keccak256(type(RegenStaker).creationCode),
                        keccak256(type(RegenStakerWithoutDelegateSurrogateVotes).creationCode)
                    )
                )
            )
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BATCH DEPLOYMENT LOGIC
    // ═══════════════════════════════════════════════════════════════════════

    function _addBatch1Deployments() internal {
        console.log("\n=== BATCH 1: Implementations + YieldSkimming Factories ===\n");

        _addCreate2Deployment(YIELD_SKIMMING_SALT, type(YieldSkimmingTokenizedStrategy).creationCode);
        console.log("- YieldSkimmingTokenizedStrategy:", yieldSkimmingStrategy);

        _addCreate2Deployment(YIELD_DONATING_SALT, type(YieldDonatingTokenizedStrategy).creationCode);
        console.log("- YieldDonatingTokenizedStrategy:", yieldDonatingStrategy);

        _addCreate2Deployment(PAYMENT_SPLITTER_FACTORY_SALT, type(PaymentSplitterFactory).creationCode);
        console.log("- PaymentSplitterFactory:", paymentSplitterFactory);

        _addCreate2Deployment(LIDO_FACTORY_SALT, type(LidoStrategyFactory).creationCode);
        console.log("- LidoStrategyFactory:", lidoFactory);

        _addCreate2Deployment(MORPHO_FACTORY_SALT, type(MorphoCompounderStrategyFactory).creationCode);
        console.log("- MorphoCompounderStrategyFactory:", morphoFactory);
    }

    function _addBatch2Deployments() internal {
        console.log("\n=== BATCH 2: YieldDonating Factories ===\n");

        _addCreate2Deployment(SKY_FACTORY_SALT, type(SkyCompounderStrategyFactory).creationCode);
        console.log("- SkyCompounderStrategyFactory:", skyFactory);

        _addCreate2Deployment(YEARN_V3_FACTORY_SALT, type(YearnV3StrategyFactory).creationCode);
        console.log("- YearnV3StrategyFactory:", yearnV3Factory);

        _addCreate2Deployment(AAVE_V3_FACTORY_SALT, type(AaveV3StrategyFactory).creationCode);
        console.log("- AaveV3StrategyFactory:", aaveV3Factory);
    }

    function _addBatch3Deployments() internal {
        console.log("\n=== BATCH 3: RegenStaker Infrastructure ===\n");

        _addCreate2Deployment(ADDRESS_SET_FACTORY_SALT, type(AddressSetFactory).creationCode);
        console.log("- AddressSetFactory:", addressSetFactory);

        _addCreate2Deployment(
            EARNING_POWER_CALCULATOR_FACTORY_SALT,
            type(RegenEarningPowerCalculatorFactory).creationCode
        );
        console.log("- RegenEarningPowerCalculatorFactory:", earningPowerCalculatorFactory);

        _addCreate2Deployment(
            REGEN_STAKER_FACTORY_SALT,
            abi.encodePacked(
                type(RegenStakerFactory).creationCode,
                abi.encode(
                    keccak256(type(RegenStaker).creationCode),
                    keccak256(type(RegenStakerWithoutDelegateSurrogateVotes).creationCode)
                )
            )
        );
        console.log("- RegenStakerFactory:", regenStakerFactory);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // LOGGING
    // ═══════════════════════════════════════════════════════════════════════

    function _logBatch1Summary() internal view {
        console.log("\n=== BATCH 1 SUMMARY ===");
        console.log("Safe Address:", safe);
        console.log("Contracts: 5 (nonce N)");
        console.log("  YieldSkimmingTokenizedStrategy:", yieldSkimmingStrategy);
        console.log("  YieldDonatingTokenizedStrategy:", yieldDonatingStrategy);
        console.log("  PaymentSplitterFactory:", paymentSplitterFactory);
        console.log("  LidoStrategyFactory:", lidoFactory);
        console.log("  MorphoCompounderStrategyFactory:", morphoFactory);
        console.log("Transaction sent to Safe for signing.\n");
    }

    function _logBatch2Summary() internal view {
        console.log("\n=== BATCH 2 SUMMARY ===");
        console.log("Safe Address:", safe);
        console.log("Contracts: 3 (nonce N+1)");
        console.log("  SkyCompounderStrategyFactory:", skyFactory);
        console.log("  YearnV3StrategyFactory:", yearnV3Factory);
        console.log("  AaveV3StrategyFactory:", aaveV3Factory);
        console.log("Transaction sent to Safe for signing.\n");
    }

    function _logBatch3Summary() internal view {
        console.log("\n=== BATCH 3 SUMMARY ===");
        console.log("Safe Address:", safe);
        console.log("Contracts: 3 (nonce N+2)");
        console.log("  AddressSetFactory:", addressSetFactory);
        console.log("  RegenEarningPowerCalculatorFactory:", earningPowerCalculatorFactory);
        console.log("  RegenStakerFactory:", regenStakerFactory);
        console.log("Transaction sent to Safe for signing.\n");
    }

    function _logFullSummary() internal pure {
        console.log("=== FULL DEPLOYMENT SUMMARY ===");
        console.log("Total contracts: 11 across 3 Safe transactions");
        console.log("All transactions proposed to Safe for signing.");
        console.log("Execute batch 1, then batch 2, then batch 3.");
        console.log("================================\n");
    }
}
