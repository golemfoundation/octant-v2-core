// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import { Script, console } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { PaymentSplitterFactory } from "src/factories/PaymentSplitterFactory.sol";
import { LidoStrategyFactory } from "src/factories/LidoStrategyFactory.sol";
import { LidoStrategy } from "src/strategies/yieldSkimming/LidoStrategy.sol";
import { BaseStrategyFactory } from "src/factories/BaseStrategyFactory.sol";

/**
 * @title GenerateProposalCalldata
 * @notice Generates calldata for Nouns DAO proposal to deploy Lido yield strategy
 * @dev Run with: forge script partners/nouns_dao/script/GenerateProposalCalldata.s.sol --fork-url $ETH_RPC_URL -vvvv
 *
 *      This script outputs ready-to-use data for the Nouns DAO UI (nouns.wtf/vote):
 *      - Transaction 1: Deploy PaymentSplitter via Factory
 *      - Transaction 2: Deploy LidoStrategy via Factory
 *      - Transaction 3: Approve wstETH to Strategy
 *      - Transaction 4: Deposit wstETH into Strategy
 *
 *      OUTPUT FORMAT:
 *      The script outputs each transaction with:
 *      - Target: Contract address to call
 *      - Value: ETH to send (always 0)
 *      - Function: Human-readable signature for Nouns UI
 *      - Calldata: ABI-encoded parameters (WITHOUT selector) for Nouns UI
 *
 *      PREREQUISITES:
 *      - LidoStrategyFactory must be deployed to mainnet (update LIDO_STRATEGY_FACTORY)
 *      - Update all placeholder addresses before production use
 */
contract GenerateProposalCalldata is Script {
    // ══════════════════════════════════════════════════════════════════════════════
    // CONFIGURATION - UPDATE THESE VALUES BEFORE GENERATING PROPOSAL
    // ══════════════════════════════════════════════════════════════════════════════

    /// @notice Nouns DAO Treasury (Executor/Timelock) - DO NOT CHANGE
    address constant NOUNS_TREASURY = 0xb1a32FC9F9D8b2cf86C068Cae13108809547ef71;

    /// @notice PaymentSplitter Factory (already deployed on mainnet) - DO NOT CHANGE
    address constant PAYMENT_SPLITTER_FACTORY = 0x5711765E0756B45224fc1FdA1B41ab344682bBcb;

    /// @notice wstETH token address on Ethereum mainnet - DO NOT CHANGE
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    /// @notice Tokenized Strategy implementation - DO NOT CHANGE
    address constant TOKENIZED_STRATEGY = 0x8cf7246a74704bBE59c9dF614ccB5e3d9717d8Ac;

    // ═══════════════════════════════════════════════════════════════════════════════
    // TODO: UPDATE THESE VALUES BEFORE PRODUCTION
    // ═══════════════════════════════════════════════════════════════════════════════

    /// @notice LidoStrategyFactory address
    /// @dev TODO: Deploy LidoStrategyFactory to mainnet and update this address
    address constant LIDO_STRATEGY_FACTORY = address(0);

    /// @notice Dragon Funding Pool recipient address
    /// @dev TODO: Set the actual grant recipient address
    address constant DRAGON_FUNDING_POOL = address(0);

    /// @notice Keeper bot address for calling report()
    /// @dev TODO: Set dedicated keeper EOA or bot address
    /// @dev CRITICAL: Do NOT use Treasury - would require governance vote for each harvest
    address constant KEEPER_BOT = address(0);

    /// @notice Emergency admin address
    /// @dev TODO: Set emergency admin (can be same as Treasury for DAO control)
    address constant EMERGENCY_ADMIN = address(0);

    /// @notice Strategy name (appears in token metadata)
    string constant STRATEGY_NAME = "NounsLidoStrategy";

    /// @notice Amount of wstETH to deposit (18 decimals)
    /// @dev 1000 wstETH = 1000e18 = 1000000000000000000000
    /// @dev TODO: Set actual deposit amount
    uint256 constant DEPOSIT_AMOUNT = 1000e18;

    // ══════════════════════════════════════════════════════════════════════════════
    // MAIN SCRIPT
    // ══════════════════════════════════════════════════════════════════════════════

    function run() public {
        _printHeader();

        // Resolve addresses (deploy temp factories in test mode)
        (
            address lidoStrategyFactory,
            address dragonPool,
            address keeper,
            address emergencyAdmin,
            bool isTestMode
        ) = _resolveAddresses();

        if (isTestMode) {
            _printTestModeWarning();
        }

        // Precompute deterministic addresses
        (address predictedPS, address predictedStrategy) = _computeAddresses(
            lidoStrategyFactory,
            dragonPool,
            keeper,
            emergencyAdmin
        );

        _printConfiguration(lidoStrategyFactory, dragonPool, keeper, emergencyAdmin);
        _printPrecomputedAddresses(predictedPS, predictedStrategy);

        // Generate and print all 4 transactions
        _printTransaction1_DeployPaymentSplitter(dragonPool);
        _printTransaction2_DeployStrategy(lidoStrategyFactory, keeper, emergencyAdmin, predictedPS);
        _printTransaction3_ApproveWstETH(predictedStrategy);
        _printTransaction4_DepositWstETH(predictedStrategy);

        // Print summary for Nouns DAO UI
        _printNounsUISummary(lidoStrategyFactory, predictedStrategy);

        _printFooter();
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // ADDRESS RESOLUTION
    // ══════════════════════════════════════════════════════════════════════════════

    function _resolveAddresses()
        internal
        returns (
            address lidoStrategyFactory,
            address dragonPool,
            address keeper,
            address emergencyAdmin,
            bool isTestMode
        )
    {
        isTestMode = LIDO_STRATEGY_FACTORY == address(0) ||
            DRAGON_FUNDING_POOL == address(0) ||
            KEEPER_BOT == address(0) ||
            EMERGENCY_ADMIN == address(0);

        // Resolve LidoStrategyFactory
        if (LIDO_STRATEGY_FACTORY == address(0)) {
            LidoStrategyFactory tempFactory = new LidoStrategyFactory();
            lidoStrategyFactory = address(tempFactory);
        } else {
            lidoStrategyFactory = LIDO_STRATEGY_FACTORY;
        }

        // Resolve Dragon Funding Pool
        dragonPool = DRAGON_FUNDING_POOL == address(0) ? makeAddr("DragonFundingPool") : DRAGON_FUNDING_POOL;

        // Resolve Keeper Bot
        keeper = KEEPER_BOT == address(0) ? makeAddr("KeeperBot") : KEEPER_BOT;

        // Resolve Emergency Admin (default to Treasury)
        emergencyAdmin = EMERGENCY_ADMIN == address(0) ? NOUNS_TREASURY : EMERGENCY_ADMIN;
    }

    function _computeAddresses(
        address lidoStrategyFactory,
        address, // dragonPool - not used for address prediction
        address keeper,
        address emergencyAdmin
    ) internal view returns (address predictedPS, address predictedStrategy) {
        // Predict PaymentSplitter address
        predictedPS = PaymentSplitterFactory(PAYMENT_SPLITTER_FACTORY).predictDeterministicAddress(NOUNS_TREASURY);

        // Predict Strategy address
        bytes32 parameterHash = keccak256(
            abi.encode(WSTETH, STRATEGY_NAME, NOUNS_TREASURY, keeper, emergencyAdmin, predictedPS, false, TOKENIZED_STRATEGY)
        );

        bytes memory strategyBytecode = abi.encodePacked(
            type(LidoStrategy).creationCode,
            abi.encode(WSTETH, STRATEGY_NAME, NOUNS_TREASURY, keeper, emergencyAdmin, predictedPS, false, TOKENIZED_STRATEGY)
        );

        predictedStrategy = BaseStrategyFactory(lidoStrategyFactory).predictStrategyAddress(
            parameterHash,
            NOUNS_TREASURY,
            strategyBytecode
        );
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // TRANSACTION GENERATORS
    // ══════════════════════════════════════════════════════════════════════════════

    function _printTransaction1_DeployPaymentSplitter(address dragonPool) internal pure {
        console.log("");
        console.log("================================================================================");
        console.log("TRANSACTION 1: Deploy PaymentSplitter");
        console.log("================================================================================");
        console.log("");

        // Build parameters
        address[] memory payees = new address[](1);
        payees[0] = dragonPool;
        string[] memory payeeNames = new string[](1);
        payeeNames[0] = "NounsGrants";
        uint256[] memory shares = new uint256[](1);
        shares[0] = 100;

        // Function signature for Nouns UI
        string memory signature = "createPaymentSplitter(address[],string[],uint256[])";

        // Calldata (parameters only, no selector) - this is what Nouns UI expects
        bytes memory calldataParams = abi.encode(payees, payeeNames, shares);

        console.log("TARGET (copy this):");
        console.log("  ", PAYMENT_SPLITTER_FACTORY);
        console.log("");
        console.log("VALUE:");
        console.log("  0");
        console.log("");
        console.log("FUNCTION (copy this):");
        console.log("  ", signature);
        console.log("");
        console.log("PARAMETERS:");
        console.log("  payees:     [", dragonPool, "]");
        console.log("  payeeNames: [\"NounsGrants\"]");
        console.log("  shares:     [100]");
        console.log("");
        console.log("CALLDATA (copy this - parameters only, no selector):");
        console.logBytes(calldataParams);
    }

    function _printTransaction2_DeployStrategy(
        address lidoStrategyFactory,
        address keeper,
        address emergencyAdmin,
        address paymentSplitter
    ) internal pure {
        console.log("");
        console.log("================================================================================");
        console.log("TRANSACTION 2: Deploy LidoStrategy");
        console.log("================================================================================");
        console.log("");

        // Function signature for Nouns UI
        string memory signature = "createStrategy(string,address,address,address,address,bool,address)";

        // Calldata (parameters only, no selector)
        bytes memory calldataParams = abi.encode(
            STRATEGY_NAME,
            NOUNS_TREASURY,
            keeper,
            emergencyAdmin,
            paymentSplitter,
            false,
            TOKENIZED_STRATEGY
        );

        console.log("TARGET (copy this):");
        console.log("  ", lidoStrategyFactory);
        console.log("");
        console.log("VALUE:");
        console.log("  0");
        console.log("");
        console.log("FUNCTION (copy this):");
        console.log("  ", signature);
        console.log("");
        console.log("PARAMETERS:");
        console.log("  _name:                     %s", STRATEGY_NAME);
        console.log("  _management:               ", NOUNS_TREASURY);
        console.log("  _keeper:                   ", keeper);
        console.log("  _emergencyAdmin:           ", emergencyAdmin);
        console.log("  _donationAddress:          ", paymentSplitter);
        console.log("  _enableBurning:            false");
        console.log("  _tokenizedStrategyAddress: ", TOKENIZED_STRATEGY);
        console.log("");
        console.log("CALLDATA (copy this - parameters only, no selector):");
        console.logBytes(calldataParams);
    }

    function _printTransaction3_ApproveWstETH(address strategy) internal pure {
        console.log("");
        console.log("================================================================================");
        console.log("TRANSACTION 3: Approve wstETH to Strategy");
        console.log("================================================================================");
        console.log("");

        // Function signature for Nouns UI
        string memory signature = "approve(address,uint256)";

        // Calldata (parameters only, no selector)
        bytes memory calldataParams = abi.encode(strategy, DEPOSIT_AMOUNT);

        console.log("TARGET (copy this):");
        console.log("  ", WSTETH);
        console.log("");
        console.log("VALUE:");
        console.log("  0");
        console.log("");
        console.log("FUNCTION (copy this):");
        console.log("  ", signature);
        console.log("");
        console.log("PARAMETERS:");
        console.log("  spender: ", strategy);
        console.log("  amount:  %s (%s wstETH)", DEPOSIT_AMOUNT, DEPOSIT_AMOUNT / 1e18);
        console.log("");
        console.log("CALLDATA (copy this - parameters only, no selector):");
        console.logBytes(calldataParams);
    }

    function _printTransaction4_DepositWstETH(address strategy) internal pure {
        console.log("");
        console.log("================================================================================");
        console.log("TRANSACTION 4: Deposit wstETH into Strategy");
        console.log("================================================================================");
        console.log("");

        // Function signature for Nouns UI
        string memory signature = "deposit(uint256,address)";

        // Calldata (parameters only, no selector)
        bytes memory calldataParams = abi.encode(DEPOSIT_AMOUNT, NOUNS_TREASURY);

        console.log("TARGET (copy this):");
        console.log("  ", strategy);
        console.log("");
        console.log("VALUE:");
        console.log("  0");
        console.log("");
        console.log("FUNCTION (copy this):");
        console.log("  ", signature);
        console.log("");
        console.log("PARAMETERS:");
        console.log("  assets:   %s (%s wstETH)", DEPOSIT_AMOUNT, DEPOSIT_AMOUNT / 1e18);
        console.log("  receiver: ", NOUNS_TREASURY);
        console.log("");
        console.log("CALLDATA (copy this - parameters only, no selector):");
        console.logBytes(calldataParams);
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // SUMMARY OUTPUT
    // ══════════════════════════════════════════════════════════════════════════════

    function _printNounsUISummary(address lidoStrategyFactory, address predictedStrategy) internal pure {
        console.log("");
        console.log("================================================================================");
        console.log("NOUNS DAO UI SUMMARY - COPY/PASTE READY");
        console.log("================================================================================");
        console.log("");
        console.log("Add these 4 transactions in order on nouns.wtf/vote:");
        console.log("");
        console.log("--------------------------------------------------------------------------------");
        console.log("TX 1 - Deploy PaymentSplitter");
        console.log("--------------------------------------------------------------------------------");
        console.log("Target:   ", PAYMENT_SPLITTER_FACTORY);
        console.log("Function: createPaymentSplitter(address[],string[],uint256[])");
        console.log("");
        console.log("--------------------------------------------------------------------------------");
        console.log("TX 2 - Deploy LidoStrategy");
        console.log("--------------------------------------------------------------------------------");
        console.log("Target:   ", lidoStrategyFactory);
        console.log("Function: createStrategy(string,address,address,address,address,bool,address)");
        console.log("");
        console.log("--------------------------------------------------------------------------------");
        console.log("TX 3 - Approve wstETH");
        console.log("--------------------------------------------------------------------------------");
        console.log("Target:   ", WSTETH);
        console.log("Function: approve(address,uint256)");
        console.log("");
        console.log("--------------------------------------------------------------------------------");
        console.log("TX 4 - Deposit wstETH");
        console.log("--------------------------------------------------------------------------------");
        console.log("Target:   ", predictedStrategy);
        console.log("Function: deposit(uint256,address)");
        console.log("");
    }

    // ══════════════════════════════════════════════════════════════════════════════
    // PRINT HELPERS
    // ══════════════════════════════════════════════════════════════════════════════

    function _printHeader() internal pure {
        console.log("");
        console.log("================================================================================");
        console.log("    NOUNS DAO PROPOSAL CALLDATA GENERATOR");
        console.log("    Octant v2 - Lido Yield Skimming Strategy");
        console.log("================================================================================");
        console.log("");
    }

    function _printTestModeWarning() internal pure {
        console.log("--------------------------------------------------------------------------------");
        console.log("WARNING: TEST MODE - PLACEHOLDER ADDRESSES DETECTED");
        console.log("--------------------------------------------------------------------------------");
        console.log("The following addresses are placeholders and must be updated for production:");
        console.log("  - LIDO_STRATEGY_FACTORY");
        console.log("  - DRAGON_FUNDING_POOL");
        console.log("  - KEEPER_BOT");
        console.log("  - EMERGENCY_ADMIN");
        console.log("");
        console.log("Temporary test addresses are being used for demonstration.");
        console.log("--------------------------------------------------------------------------------");
        console.log("");
    }

    function _printConfiguration(
        address lidoFactory,
        address dragonPool,
        address keeper,
        address emergencyAdmin
    ) internal pure {
        console.log("CONFIGURATION:");
        console.log("--------------------------------------------------------------------------------");
        console.log("  Treasury (Management):    ", NOUNS_TREASURY);
        console.log("  PaymentSplitter Factory:  ", PAYMENT_SPLITTER_FACTORY);
        console.log("  LidoStrategy Factory:     ", lidoFactory);
        console.log("  Dragon Funding Pool:      ", dragonPool);
        console.log("  Keeper Bot:               ", keeper);
        console.log("  Emergency Admin:          ", emergencyAdmin);
        console.log("  wstETH Token:             ", WSTETH);
        console.log("  Tokenized Strategy Impl:  ", TOKENIZED_STRATEGY);
        console.log("  Strategy Name:             %s", STRATEGY_NAME);
        console.log("  Deposit Amount:            %s wstETH", DEPOSIT_AMOUNT / 1e18);
        console.log("");
    }

    function _printPrecomputedAddresses(address predictedPS, address predictedStrategy) internal pure {
        console.log("PRECOMPUTED ADDRESSES (via CREATE2):");
        console.log("--------------------------------------------------------------------------------");
        console.log("  PaymentSplitter: ", predictedPS);
        console.log("  Strategy:        ", predictedStrategy);
        console.log("");
        console.log("NOTE: These addresses are deterministic. The contracts will deploy to these");
        console.log("exact addresses when the proposal executes.");
    }

    function _printFooter() internal pure {
        console.log("");
        console.log("================================================================================");
        console.log("NEXT STEPS:");
        console.log("================================================================================");
        console.log("");
        console.log("1. Update placeholder addresses in this script:");
        console.log("   - LIDO_STRATEGY_FACTORY: Deploy LidoStrategyFactory to mainnet");
        console.log("   - DRAGON_FUNDING_POOL:   Get actual grant recipient address");
        console.log("   - KEEPER_BOT:            Set up dedicated keeper EOA/bot");
        console.log("   - EMERGENCY_ADMIN:       Decide on emergency admin (Treasury or multisig)");
        console.log("");
        console.log("2. Re-run this script to generate production calldata");
        console.log("");
        console.log("3. Go to nouns.wtf/vote and create a new proposal");
        console.log("   - Add all 4 transactions in order");
        console.log("   - Copy the TARGET, FUNCTION, and CALLDATA for each transaction");
        console.log("");
        console.log("4. Use the proposal template from partners/nouns_dao/README.md");
        console.log("");
        console.log("================================================================================");
        console.log("");
    }
}
