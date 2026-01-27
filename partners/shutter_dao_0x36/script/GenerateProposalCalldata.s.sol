// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import { Script, console } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { IMorphoCompounderStrategyFactoryV1 } from "src/interfaces/IMorphoCompounderStrategyFactoryV1.sol";
import { MorphoCompounderStrategy } from "src/strategies/yieldDonating/MorphoCompounderStrategy.sol";

import {
    USDC_MAINNET,
    MORPHO_STRATEGY_FACTORY_MAINNET,
    YIELD_DONATING_TOKENIZED_STRATEGY_MAINNET
} from "src/constants.sol";

/**
 * @title GenerateProposalCalldata
 * @notice Verifies CREATE2 prediction for Shutter DAO governance proposal.
 * @dev Run on mainnet fork: forge script partners/shutter_dao_0x36/script/GenerateProposalCalldata.s.sol --fork-url $ETH_RPC_URL -vvvv
 *
 *      This script:
 *      1. Predicts strategy address using CREATE2
 *      2. Verifies prediction by simulating deployment on the fork
 *      3. Fails if bytecode mismatch detected (prediction != actual)
 *      4. Logs transaction details for reference
 *
 *      The verification step ensures local bytecode matches the deployed factory.
 */
contract GenerateProposalCalldata is Script {
    // ══════════════════════════════════════════════════════════════════════════════
    // SHUTTER DAO CONFIGURATION - Update these values before generating
    // ══════════════════════════════════════════════════════════════════════════════

    address constant SHUTTER_TREASURY = 0x36bD3044ab68f600f6d3e081056F34f2a58432c4;
    address constant DRAGON_FUNDING_POOL = 0x4B4505dEdE6408642511Fc0586b62676111e4904;
    address constant KEEPER_BOT = 0x06c2c4dB3776D500636DE63e4F109386dCBa6Ae2;

    string constant STRATEGY_NAME = "SHUGrantPool";
    uint256 constant DEPOSIT_AMOUNT = 1_200_000e6; // 1.2M USDC

    // ══════════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES (imported from src/constants.sol)
    // ══════════════════════════════════════════════════════════════════════════════

    address constant USDC = USDC_MAINNET;
    address constant MORPHO_STRATEGY_FACTORY = MORPHO_STRATEGY_FACTORY_MAINNET;
    address constant TOKENIZED_STRATEGY = YIELD_DONATING_TOKENIZED_STRATEGY_MAINNET;

    function run() public {
        console.log(unicode"══════════════════════════════════════════════════════════════════════════════");
        console.log("SHUTTER DAO PROPOSAL CALLDATA GENERATOR");
        console.log(unicode"══════════════════════════════════════════════════════════════════════════════");
        console.log("");

        _logConfiguration(DRAGON_FUNDING_POOL, KEEPER_BOT);

        // ══════════════════════════════════════════════════════════════════════════════
        // PRECOMPUTE ADDRESSES
        // ══════════════════════════════════════════════════════════════════════════════

        console.log("--- PRECOMPUTED ADDRESSES ---");

        // Build strategy parameters for CREATE2 prediction
        address ysUsdc = IMorphoCompounderStrategyFactoryV1(MORPHO_STRATEGY_FACTORY).YS_USDC();
        address usdc = IMorphoCompounderStrategyFactoryV1(MORPHO_STRATEGY_FACTORY).USDC();

        bytes32 parameterHash = keccak256(
            abi.encode(
                ysUsdc,
                usdc,
                STRATEGY_NAME,
                SHUTTER_TREASURY,
                KEEPER_BOT,
                SHUTTER_TREASURY,
                DRAGON_FUNDING_POOL,
                false,
                TOKENIZED_STRATEGY
            )
        );

        bytes memory strategyBytecode = abi.encodePacked(
            type(MorphoCompounderStrategy).creationCode,
            abi.encode(
                ysUsdc,
                usdc,
                STRATEGY_NAME,
                SHUTTER_TREASURY,
                KEEPER_BOT,
                SHUTTER_TREASURY,
                DRAGON_FUNDING_POOL,
                false,
                TOKENIZED_STRATEGY
            )
        );

        // Calculate bytecode hash for cross-run verification
        bytes32 bytecodeHash = keccak256(strategyBytecode);
        console.log("Strategy Bytecode Hash:", vm.toString(bytecodeHash));

        address predictedAddress = IMorphoCompounderStrategyFactoryV1(MORPHO_STRATEGY_FACTORY).predictStrategyAddress(
            parameterHash,
            SHUTTER_TREASURY,
            strategyBytecode
        );
        console.log("Predicted Strategy:", predictedAddress);

        // ══════════════════════════════════════════════════════════════════════════════
        // SIMULATE DEPLOYMENT TO GET ACTUAL ADDRESS
        // ══════════════════════════════════════════════════════════════════════════════

        console.log("");
        console.log("--- SIMULATING DEPLOYMENT ---");

        // Snapshot state before simulation
        uint256 snapshot = vm.snapshot();

        // Simulate deployment as Treasury
        vm.prank(SHUTTER_TREASURY);
        address strategyAddress = IMorphoCompounderStrategyFactoryV1(MORPHO_STRATEGY_FACTORY).createStrategy(
            STRATEGY_NAME,
            SHUTTER_TREASURY,
            KEEPER_BOT,
            SHUTTER_TREASURY,
            DRAGON_FUNDING_POOL,
            false,
            TOKENIZED_STRATEGY
        );

        // Revert to pre-deployment state
        vm.revertTo(snapshot);

        // Check prediction vs actual
        if (predictedAddress != strategyAddress) {
            console.log("[FAIL] CREATE2 prediction mismatch!");
            console.log("       Predicted:", predictedAddress);
            console.log("       Actual:   ", strategyAddress);
            revert("CREATE2 address mismatch - local bytecode differs from deployed factory");
        }
        console.log("[PASS] Prediction matches factory deployment");

        console.log("Strategy Address:", strategyAddress);
        console.log("");

        // ══════════════════════════════════════════════════════════════════════════════
        // GENERATE CALLDATA
        // ══════════════════════════════════════════════════════════════════════════════

        // Generate individual transaction calldata
        bytes memory tx0Calldata = abi.encodeCall(
            IMorphoCompounderStrategyFactoryV1.createStrategy,
            (
                STRATEGY_NAME,
                SHUTTER_TREASURY,
                KEEPER_BOT,
                SHUTTER_TREASURY,
                DRAGON_FUNDING_POOL,
                false,
                TOKENIZED_STRATEGY
            )
        );

        bytes memory tx1Calldata = abi.encodeCall(IERC20.approve, (strategyAddress, DEPOSIT_AMOUNT));
        bytes memory tx2Calldata = abi.encodeCall(IERC4626.deposit, (DEPOSIT_AMOUNT, SHUTTER_TREASURY));

        // Log individual transactions
        _logTx0(tx0Calldata);
        _logTx1(strategyAddress, tx1Calldata);
        _logTx2(strategyAddress, tx2Calldata);

        // ══════════════════════════════════════════════════════════════════════════════
        // COPY-PASTE SUMMARY
        // ══════════════════════════════════════════════════════════════════════════════

        _logCopyPasteSummary(strategyAddress, tx0Calldata, tx1Calldata, tx2Calldata);
    }

    function _logConfiguration(address dragonPool, address keeper) internal pure {
        console.log("--- CONFIGURATION ---");
        console.log("Treasury:           ", SHUTTER_TREASURY);
        console.log("Strategy Factory:   ", MORPHO_STRATEGY_FACTORY);
        console.log("Dragon Funding Pool:", dragonPool);
        console.log("Keeper Bot:         ", keeper);
        console.log("Deposit Amount:      %s USDC", DEPOSIT_AMOUNT / 1e6);
        console.log("");
    }

    function _logTx0(bytes memory callData) internal pure {
        console.log("--- TX 0: Deploy Strategy ---");
        console.log("Target:", MORPHO_STRATEGY_FACTORY);
        console.log("Function: createStrategy(string,address,address,address,address,bool,address)");
        console.log("Calldata:");
        console.logBytes(callData);
        console.log("");
    }

    function _logTx1(address strategy, bytes memory callData) internal pure {
        console.log("--- TX 1: Approve USDC ---");
        console.log("Target:", USDC);
        console.log("Spender:", strategy);
        console.log("Function: approve(address,uint256)");
        console.log("Selector: 0x095ea7b3");
        console.log("Calldata:");
        console.logBytes(callData);
        console.log("");
    }

    function _logTx2(address strategy, bytes memory callData) internal pure {
        console.log("--- TX 2: Deposit USDC ---");
        console.log("Target:", strategy);
        console.log("Function: deposit(uint256,address)");
        console.log("Selector: 0x6e553f65");
        console.log("Calldata:");
        console.logBytes(callData);
        console.log("");
    }

    function _logCopyPasteSummary(
        address strategyAddress,
        bytes memory tx0Calldata,
        bytes memory tx1Calldata,
        bytes memory tx2Calldata
    ) internal pure {
        console.log("");
        console.log(unicode"════════════════════════════════════════════════════════════════════════════════");
        console.log("COPY-PASTE VALUES FOR DECENT UI (3 Separate Transactions)");
        console.log(unicode"════════════════════════════════════════════════════════════════════════════════");
        console.log("");
        console.log("--- Transaction 1: Deploy Strategy ---");
        console.log("Target:    ", MORPHO_STRATEGY_FACTORY);
        console.log("Value:      0");
        console.log("Operation:  CALL (0)");
        console.log("Calldata:");
        console.logBytes(tx0Calldata);
        console.log("");
        console.log("--- Transaction 2: Approve USDC ---");
        console.log("Target:    ", USDC);
        console.log("Value:      0");
        console.log("Operation:  CALL (0)");
        console.log("Calldata:");
        console.logBytes(tx1Calldata);
        console.log("");
        console.log("--- Transaction 3: Deposit USDC ---");
        console.log("Target:    ", strategyAddress);
        console.log("Value:      0");
        console.log("Operation:  CALL (0)");
        console.log("Calldata:");
        console.logBytes(tx2Calldata);
        console.log("");
        console.log(unicode"════════════════════════════════════════════════════════════════════════════════");
    }
}
