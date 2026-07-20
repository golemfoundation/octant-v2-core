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
import { SparkStrategyFactory } from "src/factories/SparkStrategyFactory.sol";
import { AaveV3StrategyFactory } from "src/factories/AaveV3StrategyFactory.sol";
import { RocketPoolStrategyFactory } from "src/factories/yieldSkimming/RocketPoolStrategyFactory.sol";

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
 * @dev Due to the EIP-7825 per-transaction gas limit of 16,777,216 gas (2^24), all 13 contracts
 *      cannot be deployed in a single transaction. The deployment is split
 *      into four Safe MultiSend batches:
 *
 *      Batch 1 (~12.9M gas of contract creation, measured): Implementations + PaymentSplitter
 *      + YieldSkimming factories (5 contracts)
 *        - YieldSkimmingTokenizedStrategy
 *        - YieldDonatingTokenizedStrategy
 *        - PaymentSplitterFactory
 *        - LidoStrategyFactory
 *        - MorphoCompounderStrategyFactory
 *
 *      Batch 2: Remaining YieldDonating factories (2 contracts)
 *        - SkyCompounderStrategyFactory
 *        - YearnV3StrategyFactory
 *
 *      Batch 3 (~3M gas): RegenStaker infrastructure (3 contracts)
 *        - AddressSetFactory
 *        - RegenEarningPowerCalculatorFactory
 *        - RegenStakerFactory
 *
 *      Batch 4 (~6.8M gas of contract creation, measured): Spark, Aave V3, and Rocket Pool
 *      factories (3 contracts)
 *        - SparkStrategyFactory
 *        - AaveV3StrategyFactory
 *        - RocketPoolStrategyFactory
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
 * # Simulation is the default. Every address assertion runs, but nothing is proposed
 * # to the Safe transaction service unless SEND=true is set:
 * export SEND=true
 *
 * # Deploy ALL (four batches, four Safe proposals in sequence: nonce N, N+1, N+2, N+3)
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
 *
 * forge script script/deploy/DeployNewStrategiesAndFactories.s.sol \
 *   --sig "runBatch4()" --rpc-url $ETH_RPC_URL --ffi --sender $SENDER
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

    // RegenStaker ecosystem salts
    bytes32 public constant ADDRESS_SET_FACTORY_SALT = keccak256("ADDRESS_SET_FACTORY_11022026");
    bytes32 public constant EARNING_POWER_CALCULATOR_FACTORY_SALT =
        keccak256("REGEN_EARNING_POWER_CALCULATOR_FACTORY_11022026");
    bytes32 public constant REGEN_STAKER_FACTORY_SALT = keccak256("REGEN_STAKER_FACTORY_11022026");

    // Spark, Aave V3, and Rocket Pool factory salts.
    // Dated 07072026, not 11022026: these were added after batches 1-3 were proposed.
    bytes32 public constant SPARK_FACTORY_SALT = keccak256("SPARK_STRATEGY_FACTORY_07072026");
    bytes32 public constant AAVE_V3_FACTORY_SALT = keccak256("AAVE_V3_STRATEGY_FACTORY_07072026");
    bytes32 public constant ROCKET_POOL_FACTORY_SALT = keccak256("ROCKET_POOL_STRATEGY_FACTORY_07072026");

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

    // Batch 3
    address public addressSetFactory;
    address public earningPowerCalculatorFactory;
    address public regenStakerFactory;

    // Batch 4
    address public sparkFactory;
    address public aaveV3Factory;
    address public rocketPoolFactory;

    address public safe;

    function setUp() public {
        safe = _loadSafeAddress();
        console.log("Using Safe:", safe);
    }

    /// @dev SEND=true submits to the Safe API. Default is simulate-only.
    function _shouldSend() internal view returns (bool) {
        return vm.envOr("SEND", false);
    }

    /// @dev Never print "sent" after a simulation run.
    function _logSendStatus() internal view {
        if (_shouldSend()) {
            console.log("Transaction sent to Safe for signing.\n");
        } else {
            console.log("SIMULATION ONLY -- nothing sent. Re-run with SEND=true to submit.\n");
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // RUN ALL: Proposes all batches as four Safe transactions (nonce N .. N+3)
    // ═══════════════════════════════════════════════════════════════════════

    function run() public isBatch(safe) {
        // --- Batch 1 ---
        _calculateBatch1Addresses();
        _addBatch1Deployments();
        executeBatch(_shouldSend());
        _logBatch1Summary();

        // Clear the transaction queue for batch 2
        delete encodedTxns;

        // --- Batch 2 ---
        _calculateBatch2Addresses();
        _addBatch2Deployments();
        executeBatch(_shouldSend());
        _logBatch2Summary();

        // Clear the transaction queue for batch 3
        delete encodedTxns;

        // --- Batch 3 ---
        _calculateBatch3Addresses();
        _addBatch3Deployments();
        executeBatch(_shouldSend());
        _logBatch3Summary();

        // Clear the transaction queue for batch 4
        delete encodedTxns;

        // --- Batch 4 ---
        _calculateBatch4Addresses();
        _addBatch4Deployments();
        executeBatch(_shouldSend());
        _logBatch4Summary();

        _logFullSummary();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BATCH 1: Implementations + PaymentSplitter + YieldSkimming factories
    // ~12.9M creation gas measured -- tightest batch. Safe overhead sits on top of it.
    // ═══════════════════════════════════════════════════════════════════════

    function runBatch1() external isBatch(safe) {
        _calculateBatch1Addresses();
        _addBatch1Deployments();
        executeBatch(_shouldSend());
        _logBatch1Summary();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BATCH 2: Remaining YieldDonating factories
    // ═══════════════════════════════════════════════════════════════════════

    function runBatch2() external isBatch(safe) {
        _calculateBatch2Addresses();
        _addBatch2Deployments();
        executeBatch(_shouldSend());
        _logBatch2Summary();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BATCH 3: RegenStaker infrastructure
    // Estimated gas: ~3M (under 16.78M EIP-7825 limit)
    // ═══════════════════════════════════════════════════════════════════════

    function runBatch3() external isBatch(safe) {
        _calculateBatch3Addresses();
        _addBatch3Deployments();
        executeBatch(_shouldSend());
        _logBatch3Summary();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BATCH 4: Spark, Aave V3, and Rocket Pool factories
    // ═══════════════════════════════════════════════════════════════════════

    function runBatch4() external isBatch(safe) {
        _calculateBatch4Addresses();
        _addBatch4Deployments();
        executeBatch(_shouldSend());
        _logBatch4Summary();
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

    function _calculateBatch4Addresses() internal {
        sparkFactory = _computeCreate2AddressViaFactory(
            SPARK_FACTORY_SALT,
            keccak256(type(SparkStrategyFactory).creationCode)
        );
        aaveV3Factory = _computeCreate2AddressViaFactory(
            AAVE_V3_FACTORY_SALT,
            keccak256(type(AaveV3StrategyFactory).creationCode)
        );
        rocketPoolFactory = _computeCreate2AddressViaFactory(
            ROCKET_POOL_FACTORY_SALT,
            keccak256(type(RocketPoolStrategyFactory).creationCode)
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // BATCH DEPLOYMENT LOGIC
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Fails if the queued deployment lands anywhere other than the address
    ///      _calculateBatchNAddresses() precomputed and the summary logs show.
    function _addAndAssert(bytes32 salt, bytes memory creationCode, address expected, string memory label) internal {
        address deployed = _addCreate2Deployment(salt, creationCode);
        require(deployed == expected, string.concat(label, ": address mismatch"));
        console.log(string.concat("- ", label, ":"), deployed);
    }

    function _addBatch1Deployments() internal {
        console.log("\n=== BATCH 1: Implementations + YieldSkimming Factories ===\n");

        _addAndAssert(
            YIELD_SKIMMING_SALT,
            type(YieldSkimmingTokenizedStrategy).creationCode,
            yieldSkimmingStrategy,
            "YieldSkimmingTokenizedStrategy"
        );
        _addAndAssert(
            YIELD_DONATING_SALT,
            type(YieldDonatingTokenizedStrategy).creationCode,
            yieldDonatingStrategy,
            "YieldDonatingTokenizedStrategy"
        );
        _addAndAssert(
            PAYMENT_SPLITTER_FACTORY_SALT,
            type(PaymentSplitterFactory).creationCode,
            paymentSplitterFactory,
            "PaymentSplitterFactory"
        );
        _addAndAssert(LIDO_FACTORY_SALT, type(LidoStrategyFactory).creationCode, lidoFactory, "LidoStrategyFactory");
        _addAndAssert(
            MORPHO_FACTORY_SALT,
            type(MorphoCompounderStrategyFactory).creationCode,
            morphoFactory,
            "MorphoCompounderStrategyFactory"
        );
    }

    function _addBatch2Deployments() internal {
        console.log("\n=== BATCH 2: YieldDonating Factories ===\n");

        _addAndAssert(
            SKY_FACTORY_SALT,
            type(SkyCompounderStrategyFactory).creationCode,
            skyFactory,
            "SkyCompounderStrategyFactory"
        );
        _addAndAssert(
            YEARN_V3_FACTORY_SALT,
            type(YearnV3StrategyFactory).creationCode,
            yearnV3Factory,
            "YearnV3StrategyFactory"
        );
    }

    function _addBatch3Deployments() internal {
        console.log("\n=== BATCH 3: RegenStaker Infrastructure ===\n");

        _addAndAssert(
            ADDRESS_SET_FACTORY_SALT,
            type(AddressSetFactory).creationCode,
            addressSetFactory,
            "AddressSetFactory"
        );
        _addAndAssert(
            EARNING_POWER_CALCULATOR_FACTORY_SALT,
            type(RegenEarningPowerCalculatorFactory).creationCode,
            earningPowerCalculatorFactory,
            "RegenEarningPowerCalculatorFactory"
        );
        _addAndAssert(
            REGEN_STAKER_FACTORY_SALT,
            abi.encodePacked(
                type(RegenStakerFactory).creationCode,
                abi.encode(
                    keccak256(type(RegenStaker).creationCode),
                    keccak256(type(RegenStakerWithoutDelegateSurrogateVotes).creationCode)
                )
            ),
            regenStakerFactory,
            "RegenStakerFactory"
        );
    }

    function _addBatch4Deployments() internal {
        console.log("\n=== BATCH 4: Spark, Aave V3, and Rocket Pool Factories ===\n");

        _addAndAssert(
            SPARK_FACTORY_SALT,
            type(SparkStrategyFactory).creationCode,
            sparkFactory,
            "SparkStrategyFactory"
        );
        _addAndAssert(
            AAVE_V3_FACTORY_SALT,
            type(AaveV3StrategyFactory).creationCode,
            aaveV3Factory,
            "AaveV3StrategyFactory"
        );
        _addAndAssert(
            ROCKET_POOL_FACTORY_SALT,
            type(RocketPoolStrategyFactory).creationCode,
            rocketPoolFactory,
            "RocketPoolStrategyFactory"
        );
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
        _logSendStatus();
    }

    function _logBatch2Summary() internal view {
        console.log("\n=== BATCH 2 SUMMARY ===");
        console.log("Safe Address:", safe);
        console.log("Contracts: 2 (nonce N+1)");
        console.log("  SkyCompounderStrategyFactory:", skyFactory);
        console.log("  YearnV3StrategyFactory:", yearnV3Factory);
        _logSendStatus();
    }

    function _logBatch3Summary() internal view {
        console.log("\n=== BATCH 3 SUMMARY ===");
        console.log("Safe Address:", safe);
        console.log("Contracts: 3 (nonce N+2)");
        console.log("  AddressSetFactory:", addressSetFactory);
        console.log("  RegenEarningPowerCalculatorFactory:", earningPowerCalculatorFactory);
        console.log("  RegenStakerFactory:", regenStakerFactory);
        _logSendStatus();
    }

    function _logBatch4Summary() internal view {
        console.log("\n=== BATCH 4 SUMMARY ===");
        console.log("Safe Address:", safe);
        console.log("Contracts: 3 (nonce N+3)");
        console.log("  SparkStrategyFactory:", sparkFactory);
        console.log("  AaveV3StrategyFactory:", aaveV3Factory);
        console.log("  RocketPoolStrategyFactory:", rocketPoolFactory);
        _logSendStatus();
    }

    function _logFullSummary() internal view {
        console.log("=== FULL DEPLOYMENT SUMMARY ===");
        console.log("Total contracts: 13 across 4 Safe transactions");
        console.log(
            _shouldSend()
                ? "All transactions proposed to Safe for signing."
                : "SIMULATION ONLY -- nothing proposed. Re-run with SEND=true to submit."
        );
        console.log("Execute batch 1, then batch 2, then batch 3, then batch 4.");
        console.log("================================\n");
    }
}
