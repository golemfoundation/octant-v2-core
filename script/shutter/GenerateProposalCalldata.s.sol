// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import { Script, console } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { PaymentSplitterFactory } from "src/factories/PaymentSplitterFactory.sol";
import { MorphoCompounderStrategyFactory } from "src/factories/MorphoCompounderStrategyFactory.sol";
import { MorphoCompounderStrategy } from "src/strategies/yieldDonating/MorphoCompounderStrategy.sol";
import { BaseStrategyFactory } from "src/factories/BaseStrategyFactory.sol";
import { MultiSendCallOnly } from "src/utils/libs/Safe/MultiSendCallOnly.sol";

import { USDC_MAINNET, MORPHO_STRATEGY_FACTORY_MAINNET, YIELD_DONATING_TOKENIZED_STRATEGY_MAINNET, SAFE_MULTISEND_MAINNET } from "src/constants.sol";

/**
 * @title GenerateProposalCalldata
 * @notice Generates calldata for Shutter DAO proposal to deploy strategy and deposit funds
 * @dev Run with: forge script script/shutter/GenerateProposalCalldata.s.sol -vvvv
 *
 *      This script outputs ready-to-use calldata for:
 *      - TX 0: Deploy PaymentSplitter via Factory
 *      - TX 1: Deploy MorphoCompounderStrategy via Factory
 *      - TX 2: Approve USDC to Strategy
 *      - TX 3: Deposit USDC into Strategy
 *      - BATCHED: All 4 operations via MultiSend (recommended)
 */
contract GenerateProposalCalldata is Script {
    // ══════════════════════════════════════════════════════════════════════════════
    // SHUTTER DAO CONFIGURATION - Update these values before generating
    // ══════════════════════════════════════════════════════════════════════════════

    address constant SHUTTER_TREASURY = 0x36bD3044ab68f600f6d3e081056F34f2a58432c4;
    address constant PAYMENT_SPLITTER_FACTORY = address(0); // TODO: Set after Octant deploys
    address constant DRAGON_FUNDING_POOL = address(0); // TODO: Set actual address
    address constant KEEPER_BOT = address(0); // TODO: Set dedicated keeper address

    string constant STRATEGY_NAME = "SHUGrantPool";
    uint256 constant DEPOSIT_AMOUNT = 1_200_000e6; // 1.2M USDC

    // ══════════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES (from src/constants.sol)
    // ══════════════════════════════════════════════════════════════════════════════

    address constant USDC = USDC_MAINNET;
    address constant MORPHO_STRATEGY_FACTORY = MORPHO_STRATEGY_FACTORY_MAINNET;
    address constant TOKENIZED_STRATEGY = YIELD_DONATING_TOKENIZED_STRATEGY_MAINNET;
    address constant MULTISEND = SAFE_MULTISEND_MAINNET;

    function run() public view {
        console.log(unicode"══════════════════════════════════════════════════════════════════════════════");
        console.log("SHUTTER DAO PROPOSAL CALLDATA GENERATOR");
        console.log(unicode"══════════════════════════════════════════════════════════════════════════════");
        console.log("");

        _logConfiguration();

        if (PAYMENT_SPLITTER_FACTORY == address(0) || DRAGON_FUNDING_POOL == address(0) || KEEPER_BOT == address(0)) {
            console.log(unicode"⚠️  WARNING: Placeholder addresses detected. Update configuration before use.");
            console.log("");
        }

        // Build PaymentSplitter configuration
        address[] memory payees = new address[](1);
        payees[0] = DRAGON_FUNDING_POOL;
        string[] memory payeeNames = new string[](1);
        payeeNames[0] = "DragonFundingPool";
        uint256[] memory shares = new uint256[](1);
        shares[0] = 100;

        // Precompute addresses (requires factory to be deployed)
        address predictedPS = address(0);
        address predictedStrategy = address(0);

        if (PAYMENT_SPLITTER_FACTORY != address(0)) {
            predictedPS = PaymentSplitterFactory(PAYMENT_SPLITTER_FACTORY).predictDeterministicAddress(
                SHUTTER_TREASURY
            );
            console.log("--- PRECOMPUTED ADDRESSES ---");
            console.log("PaymentSplitter:", predictedPS);

            // Build strategy parameters for CREATE2 prediction
            address ysUsdc = MorphoCompounderStrategyFactory(MORPHO_STRATEGY_FACTORY).YS_USDC();
            address usdc = MorphoCompounderStrategyFactory(MORPHO_STRATEGY_FACTORY).USDC();

            bytes32 parameterHash = keccak256(
                abi.encode(
                    ysUsdc,
                    usdc,
                    STRATEGY_NAME,
                    SHUTTER_TREASURY,
                    KEEPER_BOT,
                    SHUTTER_TREASURY,
                    predictedPS,
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
                    predictedPS,
                    false,
                    TOKENIZED_STRATEGY
                )
            );

            predictedStrategy = BaseStrategyFactory(MORPHO_STRATEGY_FACTORY).predictStrategyAddress(
                parameterHash,
                SHUTTER_TREASURY,
                strategyBytecode
            );
            console.log("Strategy:       ", predictedStrategy);
            console.log("");
        }

        // Generate calldata for each transaction
        _logTx0(payees, payeeNames, shares);
        _logTx1(predictedPS);
        _logTx2(predictedStrategy);
        _logTx3(predictedStrategy);

        // Generate batched MultiSend calldata
        if (predictedPS != address(0) && predictedStrategy != address(0)) {
            _logBatchedMultiSend(payees, payeeNames, shares, predictedPS, predictedStrategy);
        }
    }

    function _logConfiguration() internal pure {
        console.log("--- CONFIGURATION ---");
        console.log("Treasury:              ", SHUTTER_TREASURY);
        console.log("PaymentSplitter Factory:", PAYMENT_SPLITTER_FACTORY);
        console.log("Strategy Factory:      ", MORPHO_STRATEGY_FACTORY);
        console.log("Dragon Funding Pool:   ", DRAGON_FUNDING_POOL);
        console.log("Keeper Bot:            ", KEEPER_BOT);
        console.log("Deposit Amount:         %s USDC", DEPOSIT_AMOUNT / 1e6);
        console.log("");
    }

    function _logTx0(address[] memory payees, string[] memory payeeNames, uint256[] memory shares) internal pure {
        console.log("--- TX 0: Deploy PaymentSplitter ---");
        console.log("Target:", PAYMENT_SPLITTER_FACTORY);
        console.log("Function: createPaymentSplitter(address[],string[],uint256[])");
        console.log("Selector: 0x31d89943");

        bytes memory callData = abi.encodeCall(
            PaymentSplitterFactory.createPaymentSplitter,
            (payees, payeeNames, shares)
        );
        console.log("Calldata:");
        console.logBytes(callData);
        console.log("");
    }

    function _logTx1(address paymentSplitter) internal pure {
        console.log("--- TX 1: Deploy Strategy ---");
        console.log("Target:", MORPHO_STRATEGY_FACTORY);
        console.log("Function: createStrategy(string,address,address,address,address,bool,address)");

        bytes memory callData = abi.encodeCall(
            MorphoCompounderStrategyFactory.createStrategy,
            (STRATEGY_NAME, SHUTTER_TREASURY, KEEPER_BOT, SHUTTER_TREASURY, paymentSplitter, false, TOKENIZED_STRATEGY)
        );
        console.log("Calldata:");
        console.logBytes(callData);
        console.log("");
    }

    function _logTx2(address strategy) internal pure {
        console.log("--- TX 2: Approve USDC ---");
        console.log("Target:", USDC);
        console.log("Function: approve(address,uint256)");
        console.log("Selector: 0x095ea7b3");

        bytes memory callData = abi.encodeCall(IERC20.approve, (strategy, DEPOSIT_AMOUNT));
        console.log("Calldata:");
        console.logBytes(callData);
        console.log("");
    }

    function _logTx3(address strategy) internal pure {
        console.log("--- TX 3: Deposit USDC ---");
        console.log("Target:", strategy);
        console.log("Function: deposit(uint256,address)");
        console.log("Selector: 0x6e553f65");

        bytes memory callData = abi.encodeCall(IERC4626.deposit, (DEPOSIT_AMOUNT, SHUTTER_TREASURY));
        console.log("Calldata:");
        console.logBytes(callData);
        console.log("");
    }

    function _logBatchedMultiSend(
        address[] memory payees,
        string[] memory payeeNames,
        uint256[] memory shares,
        address predictedPS,
        address predictedStrategy
    ) internal pure {
        console.log(unicode"══════════════════════════════════════════════════════════════════════════════");
        console.log("BATCHED MULTISEND (RECOMMENDED)");
        console.log(unicode"══════════════════════════════════════════════════════════════════════════════");
        console.log("");
        console.log("Target:", MULTISEND);
        console.log("Operation: 1 (DELEGATECALL)");
        console.log("Function: multiSend(bytes)");
        console.log("");

        // Encode individual transactions for MultiSend
        bytes memory tx0 = _encodeMultiSendTx(
            PAYMENT_SPLITTER_FACTORY,
            abi.encodeCall(PaymentSplitterFactory.createPaymentSplitter, (payees, payeeNames, shares))
        );

        bytes memory tx1 = _encodeMultiSendTx(
            MORPHO_STRATEGY_FACTORY,
            abi.encodeCall(
                MorphoCompounderStrategyFactory.createStrategy,
                (STRATEGY_NAME, SHUTTER_TREASURY, KEEPER_BOT, SHUTTER_TREASURY, predictedPS, false, TOKENIZED_STRATEGY)
            )
        );

        bytes memory tx2 = _encodeMultiSendTx(
            USDC,
            abi.encodeCall(IERC20.approve, (predictedStrategy, DEPOSIT_AMOUNT))
        );

        bytes memory tx3 = _encodeMultiSendTx(
            predictedStrategy,
            abi.encodeCall(IERC4626.deposit, (DEPOSIT_AMOUNT, SHUTTER_TREASURY))
        );

        bytes memory packedTxs = abi.encodePacked(tx0, tx1, tx2, tx3);
        bytes memory multiSendCalldata = abi.encodeCall(MultiSendCallOnly.multiSend, (packedTxs));

        console.log("Full Calldata for execTransactionFromModule:");
        console.logBytes(multiSendCalldata);
        console.log("");
        console.log("Azorius call:");
        console.log("  execTransactionFromModule(");
        console.log("    to:", MULTISEND);
        console.log("    value: 0");
        console.log("    data: <calldata above>");
        console.log("    operation: 1 (DELEGATECALL)");
        console.log("  )");
    }

    function _encodeMultiSendTx(address to, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), to, uint256(0), data.length, data);
    }
}
