// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import { Script, console } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { MorphoCompounderStrategyFactory } from "src/factories/MorphoCompounderStrategyFactory.sol";
import { MorphoCompounderStrategy } from "src/strategies/yieldDonating/MorphoCompounderStrategy.sol";
import { BaseStrategyFactory } from "src/factories/BaseStrategyFactory.sol";
import { MultiSendCallOnly } from "src/utils/libs/Safe/MultiSendCallOnly.sol";

import { USDC_MAINNET, SAFE_MULTISEND_MAINNET } from "src/constants.sol";

/**
 * @title GenerateProposalCalldata
 * @notice Generates calldata for Shutter DAO proposal to deploy strategy and deposit funds
 * @dev Run with: forge script partners/shutter_dao_0x36/script/GenerateProposalCalldata.s.sol --fork-url $ETH_RPC_URL -vvvv
 *
 *      This script outputs ready-to-use calldata for:
 *      - TX 0: Deploy MorphoCompounderStrategy via Factory
 *      - TX 1: Approve USDC to Strategy
 *      - TX 2: Deposit USDC into Strategy
 *      - BATCHED: All 3 operations via MultiSend (recommended)
 *
 *      V2 contracts deployed 2025-01-22:
 *      - MorphoCompounderStrategyFactory V2: 0xd8Df22cB3c3876487961aC2500889664632674d7
 *      - YieldDonatingTokenizedStrategy V2: 0xea648c313b497fECfBC629e73cB61Db34181F067
 */
contract GenerateProposalCalldata is Script {
    // ══════════════════════════════════════════════════════════════════════════════
    // SHUTTER DAO CONFIGURATION - Update these values before generating
    // ══════════════════════════════════════════════════════════════════════════════

    address constant SHUTTER_TREASURY = 0x36bD3044ab68f600f6d3e081056F34f2a58432c4;
    address constant DRAGON_FUNDING_POOL = 0x4B4505dEdE6408642511Fc0586b62676111e4904;
    address constant KEEPER_BOT = 0x06c2c4dB3776D500636DE63e4F109386dCBa6Ae2;

    string constant STRATEGY_NAME = "SHUGrantPool";
    string constant STRATEGY_SYMBOL = "yvSHU";
    uint256 constant DEPOSIT_AMOUNT = 1_200_000e6; // 1.2M USDC

    // ══════════════════════════════════════════════════════════════════════════════
    // MAINNET ADDRESSES
    // V2 contracts with symbol param support (deployed 2025-01-22)
    // ══════════════════════════════════════════════════════════════════════════════

    address constant USDC = USDC_MAINNET;
    address constant MORPHO_STRATEGY_FACTORY = 0xd8Df22cB3c3876487961aC2500889664632674d7;
    address constant TOKENIZED_STRATEGY = 0xea648c313b497fECfBC629e73cB61Db34181F067;
    address constant MULTISEND = SAFE_MULTISEND_MAINNET;

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
        address ysUsdc = MorphoCompounderStrategyFactory(MORPHO_STRATEGY_FACTORY).YS_USDC();
        address usdc = MorphoCompounderStrategyFactory(MORPHO_STRATEGY_FACTORY).USDC();

        bytes32 parameterHash = keccak256(
            abi.encode(
                ysUsdc,
                usdc,
                STRATEGY_NAME,
                STRATEGY_SYMBOL,
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
                STRATEGY_SYMBOL,
                SHUTTER_TREASURY,
                KEEPER_BOT,
                SHUTTER_TREASURY,
                DRAGON_FUNDING_POOL,
                false,
                TOKENIZED_STRATEGY
            )
        );

        address predictedStrategy = BaseStrategyFactory(MORPHO_STRATEGY_FACTORY).predictStrategyAddress(
            parameterHash,
            SHUTTER_TREASURY,
            strategyBytecode
        );
        console.log("Strategy:", predictedStrategy);
        console.log("");

        // ══════════════════════════════════════════════════════════════════════════════
        // GENERATE CALLDATA
        // ══════════════════════════════════════════════════════════════════════════════

        _logTx0(KEEPER_BOT, DRAGON_FUNDING_POOL);
        _logTx1(predictedStrategy);
        _logTx2(predictedStrategy);

        // Generate batched MultiSend calldata
        _logBatchedMultiSend(KEEPER_BOT, DRAGON_FUNDING_POOL, predictedStrategy);
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

    function _logTx0(address keeper, address donationAddress) internal pure {
        console.log("--- TX 0: Deploy Strategy ---");
        console.log("Target:", MORPHO_STRATEGY_FACTORY);
        console.log("Function: createStrategy(string,string,address,address,address,address,bool,address)");

        bytes memory callData = abi.encodeCall(
            MorphoCompounderStrategyFactory.createStrategy,
            (STRATEGY_NAME, STRATEGY_SYMBOL, SHUTTER_TREASURY, keeper, SHUTTER_TREASURY, donationAddress, false, TOKENIZED_STRATEGY)
        );
        console.log("Calldata:");
        console.logBytes(callData);
        console.log("");
    }

    function _logTx1(address strategy) internal pure {
        console.log("--- TX 1: Approve USDC ---");
        console.log("Target:", USDC);
        console.log("Function: approve(address,uint256)");
        console.log("Selector: 0x095ea7b3");

        bytes memory callData = abi.encodeCall(IERC20.approve, (strategy, DEPOSIT_AMOUNT));
        console.log("Calldata:");
        console.logBytes(callData);
        console.log("");
    }

    function _logTx2(address strategy) internal pure {
        console.log("--- TX 2: Deposit USDC ---");
        console.log("Target:", strategy);
        console.log("Function: deposit(uint256,address)");
        console.log("Selector: 0x6e553f65");

        bytes memory callData = abi.encodeCall(IERC4626.deposit, (DEPOSIT_AMOUNT, SHUTTER_TREASURY));
        console.log("Calldata:");
        console.logBytes(callData);
        console.log("");
    }

    function _logBatchedMultiSend(address keeper, address donationAddress, address predictedStrategy) internal pure {
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
            MORPHO_STRATEGY_FACTORY,
            abi.encodeCall(
                MorphoCompounderStrategyFactory.createStrategy,
                (STRATEGY_NAME, STRATEGY_SYMBOL, SHUTTER_TREASURY, keeper, SHUTTER_TREASURY, donationAddress, false, TOKENIZED_STRATEGY)
            )
        );

        bytes memory tx1 = _encodeMultiSendTx(
            USDC,
            abi.encodeCall(IERC20.approve, (predictedStrategy, DEPOSIT_AMOUNT))
        );

        bytes memory tx2 = _encodeMultiSendTx(
            predictedStrategy,
            abi.encodeCall(IERC4626.deposit, (DEPOSIT_AMOUNT, SHUTTER_TREASURY))
        );

        bytes memory packedTxs = abi.encodePacked(tx0, tx1, tx2);
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
