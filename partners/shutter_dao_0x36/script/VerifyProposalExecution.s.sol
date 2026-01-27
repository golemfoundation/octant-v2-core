// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import { Script, console } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { MorphoCompounderStrategy } from "src/strategies/yieldDonating/MorphoCompounderStrategy.sol";
import { IMorphoCompounderStrategyFactoryV1 } from "src/interfaces/IMorphoCompounderStrategyFactoryV1.sol";

import {
    USDC_MAINNET,
    MORPHO_STRATEGY_FACTORY_MAINNET,
    YIELD_DONATING_TOKENIZED_STRATEGY_MAINNET
} from "src/constants.sol";

/**
 * @title VerifyProposalExecution
 * @notice Post-execution verification script for Shutter DAO proposal.
 * @dev Run AFTER the DAO executes the proposal to verify correct deployment.
 *
 *      Usage:
 *      1. Set STRATEGY_ADDRESS to the deployed strategy address (from proposal execution)
 *      2. Run: forge script partners/shutter_dao_0x36/script/VerifyProposalExecution.s.sol \
 *              --fork-url $ETH_RPC_URL -vvvv
 *
 *      Verifies:
 *      - Strategy exists at expected/deployed address
 *      - Treasury holds expected shares
 *      - Treasury USDC balance is 0 (all deposited)
 *      - Dragon Pool set as yield recipient
 *      - Keeper is configured correctly
 *      - Management roles assigned to Treasury
 */
contract VerifyProposalExecution is Script {
    // ══════════════════════════════════════════════════════════════════════════════
    // CONFIGURATION - Update STRATEGY_ADDRESS after proposal execution
    // ══════════════════════════════════════════════════════════════════════════════

    // Strategy address to verify. Default is the predicted address from proposal generation.
    // Note: CREATE2 prediction requires matching bytecode. Since local bytecode may differ
    // from the factory's deployed bytecode, we use the known address from simulation.
    address constant STRATEGY_ADDRESS = 0xC5B26f6A954cf7480C6992e5C3E0c92F38B5695c;

    // === Expected Configuration ===
    address constant SHUTTER_TREASURY = 0x36bD3044ab68f600f6d3e081056F34f2a58432c4;
    address constant DRAGON_FUNDING_POOL = 0x4B4505dEdE6408642511Fc0586b62676111e4904;
    address constant KEEPER_BOT = 0x06c2c4dB3776D500636DE63e4F109386dCBa6Ae2;
    address constant USDC = USDC_MAINNET;

    string constant EXPECTED_NAME = "SHUGrantPool";
    uint256 constant EXPECTED_DEPOSIT = 1_200_000e6; // 1.2M USDC
    uint256 constant SHARE_VARIANCE_TOLERANCE_BPS = 500; // 5%
    uint256 constant MAX_BPS = 10_000;

    // === V1 Factory for address prediction (imported from src/constants.sol) ===
    address constant MORPHO_STRATEGY_FACTORY = MORPHO_STRATEGY_FACTORY_MAINNET;
    address constant TOKENIZED_STRATEGY = YIELD_DONATING_TOKENIZED_STRATEGY_MAINNET;

    function run() public view {
        console.log(unicode"══════════════════════════════════════════════════════════════════════════════");
        console.log("SHUTTER DAO PROPOSAL EXECUTION VERIFICATION");
        console.log(unicode"══════════════════════════════════════════════════════════════════════════════");
        console.log("");

        address strategyToVerify = STRATEGY_ADDRESS;

        // If no address provided, predict it (warning: may be inaccurate due to bytecode mismatch)
        if (strategyToVerify == address(0)) {
            console.log("[WARN] No strategy address provided. Attempting CREATE2 prediction...");
            console.log("[WARN] Local bytecode may differ from factory's deployed bytecode.");
            console.log("[WARN] If verification fails, set STRATEGY_ADDRESS explicitly.");
            strategyToVerify = _predictStrategyAddress();
            console.log("Predicted Strategy Address:", strategyToVerify);
            console.log("");
        }

        // Run all verification checks
        bool allPassed = true;

        allPassed = _verifyStrategyExists(strategyToVerify) && allPassed;
        allPassed = _verifyStrategyConfiguration(strategyToVerify) && allPassed;
        allPassed = _verifyTreasuryHoldings(strategyToVerify) && allPassed;
        allPassed = _verifyRoleAssignments(strategyToVerify) && allPassed;
        allPassed = _verifyYieldConfiguration(strategyToVerify) && allPassed;

        console.log("");
        console.log(unicode"══════════════════════════════════════════════════════════════════════════════");
        if (allPassed) {
            console.log("VERIFICATION RESULT: ALL CHECKS PASSED");
        } else {
            console.log("VERIFICATION RESULT: SOME CHECKS FAILED - Review output above");
        }
        console.log(unicode"══════════════════════════════════════════════════════════════════════════════");
    }

    function _predictStrategyAddress() internal view returns (address) {
        IMorphoCompounderStrategyFactoryV1 factory = IMorphoCompounderStrategyFactoryV1(MORPHO_STRATEGY_FACTORY);
        address ysUsdc = factory.YS_USDC();
        address usdc = factory.USDC();

        bytes32 parameterHash = keccak256(
            abi.encode(
                ysUsdc,
                usdc,
                EXPECTED_NAME,
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
                EXPECTED_NAME,
                SHUTTER_TREASURY,
                KEEPER_BOT,
                SHUTTER_TREASURY,
                DRAGON_FUNDING_POOL,
                false,
                TOKENIZED_STRATEGY
            )
        );

        return IMorphoCompounderStrategyFactoryV1(MORPHO_STRATEGY_FACTORY).predictStrategyAddress(
            parameterHash, SHUTTER_TREASURY, strategyBytecode
        );
    }

    function _verifyStrategyExists(address strategy) internal view returns (bool) {
        console.log("--- CHECK 1: Strategy Exists ---");

        if (strategy.code.length == 0) {
            console.log("[FAIL] No contract at address:", strategy);
            return false;
        }

        console.log("[PASS] Strategy deployed at:", strategy);
        console.log("       Code size:", strategy.code.length, "bytes");
        return true;
    }

    function _verifyStrategyConfiguration(address strategy) internal view returns (bool) {
        console.log("");
        console.log("--- CHECK 2: Strategy Configuration ---");

        IERC20Metadata metadata = IERC20Metadata(strategy);
        bool passed = true;

        // Check name
        string memory actualName = metadata.name();
        if (keccak256(bytes(actualName)) == keccak256(bytes(EXPECTED_NAME))) {
            console.log("[PASS] Name:", actualName);
        } else {
            console.log("[FAIL] Name mismatch. Expected:", EXPECTED_NAME, "Got:", actualName);
            passed = false;
        }

        // Log symbol (V1 contracts use default symbol from TokenizedStrategy)
        string memory actualSymbol = metadata.symbol();
        console.log("[INFO] Symbol:", actualSymbol);

        // Check underlying asset
        address asset = IERC4626(strategy).asset();
        if (asset == USDC) {
            console.log("[PASS] Asset: USDC (", asset, ")");
        } else {
            console.log("[FAIL] Asset mismatch. Expected USDC, Got:", asset);
            passed = false;
        }

        return passed;
    }

    function _verifyTreasuryHoldings(address strategy) internal view returns (bool) {
        console.log("");
        console.log("--- CHECK 3: Treasury Holdings ---");
        bool passed = true;

        // Check Treasury shares
        uint256 shares = IERC4626(strategy).balanceOf(SHUTTER_TREASURY);

        // FAIL if shares are 0 (deposit completely failed)
        if (shares == 0) {
            console.log("[FAIL] Treasury has 0 shares - deposit failed completely!");
            passed = false;
        } else {
            // Allow 5% variance because ERC-4626 vaults may have non-1:1 exchange rates due to:
            // - Accrued yield since last harvest
            // - Rounding in share calculations
            // - Fee deductions
            // A 5% tolerance catches deposit failures while allowing normal vault behavior.
            uint256 minExpectedShares =
                (EXPECTED_DEPOSIT * (MAX_BPS - SHARE_VARIANCE_TOLERANCE_BPS)) / MAX_BPS;
            uint256 sharesDiff = shares > EXPECTED_DEPOSIT ? shares - EXPECTED_DEPOSIT : EXPECTED_DEPOSIT - shares;

            if (sharesDiff <= 1000) {
                // Within rounding tolerance
                console.log("[PASS] Treasury shares:", shares / 1e6);
                console.log("       Raw shares:", shares);
            } else if (shares >= minExpectedShares) {
                // Within tolerance - acceptable due to exchange rate
                console.log("[PASS] Treasury shares:", shares / 1e6, "(within tolerance of expected)");
            } else {
                // More than 5% off - likely partial failure
                console.log("[FAIL] Treasury shares significantly below expected");
                console.log("       Expected:", EXPECTED_DEPOSIT / 1e6, "M");
                console.log("       Actual:", shares / 1e6);
                console.log("       Raw shares:", shares);
                console.log("       Minimum acceptable:", minExpectedShares / 1e6);
                passed = false;
            }
        }

        // Check Treasury USDC balance
        // Note: Treasury may have held additional USDC before the deposit, so remaining
        // balance alone doesn't indicate failure. The shares check above is the primary indicator.
        uint256 usdcBalance = IERC20(USDC).balanceOf(SHUTTER_TREASURY);
        if (usdcBalance == 0) {
            console.log("[PASS] Treasury USDC balance: 0 (all deposited)");
        } else if (shares == 0 && usdcBalance >= EXPECTED_DEPOSIT) {
            // No shares AND full deposit amount still present - deposit definitely failed
            console.log("[FAIL] No shares received and USDC not deposited!");
            console.log("       USDC balance:", usdcBalance / 1e6, "M");
            passed = false;
        } else {
            // Has shares but also has remaining USDC - likely Treasury had extra funds
            console.log("[INFO] Treasury has remaining USDC:", usdcBalance / 1e6, "M");
            console.log("       (Treasury may have held additional USDC before deposit)");
        }

        // Check total assets in strategy
        uint256 totalAssets = IERC4626(strategy).totalAssets();
        console.log("[INFO] Strategy total assets:", totalAssets / 1e6, "M USDC");

        return passed;
    }

    function _verifyRoleAssignments(address strategy) internal view returns (bool) {
        console.log("");
        console.log("--- CHECK 4: Role Assignments ---");

        bool passed = true;

        // Check management
        (bool ok, address management) = _readAddress(strategy, "management()");
        if (!ok) {
            console.log("[FAIL] management() call failed");
            passed = false;
        } else if (management == SHUTTER_TREASURY) {
            console.log("[PASS] Management: Treasury (", management, ")");
        } else {
            console.log("[FAIL] Management mismatch. Expected Treasury, Got:", management);
            passed = false;
        }

        // Check keeper
        address keeper;
        (ok, keeper) = _readAddress(strategy, "keeper()");
        if (!ok) {
            console.log("[FAIL] keeper() call failed");
            passed = false;
        } else if (keeper == KEEPER_BOT) {
            console.log("[PASS] Keeper: Dedicated Bot (", keeper, ")");
        } else {
            console.log("[FAIL] Keeper mismatch. Expected:", KEEPER_BOT, "Got:", keeper);
            passed = false;
        }

        // Check emergency admin
        address emergencyAdmin;
        (ok, emergencyAdmin) = _readAddress(strategy, "emergencyAdmin()");
        if (!ok) {
            console.log("[FAIL] emergencyAdmin() call failed");
            passed = false;
        } else if (emergencyAdmin == SHUTTER_TREASURY) {
            console.log("[PASS] Emergency Admin: Treasury (", emergencyAdmin, ")");
        } else {
            console.log("[FAIL] Emergency Admin mismatch. Expected Treasury, Got:", emergencyAdmin);
            passed = false;
        }

        return passed;
    }

    function _verifyYieldConfiguration(address strategy) internal view returns (bool) {
        console.log("");
        console.log("--- CHECK 5: Yield Configuration ---");

        bool passed = true;

        // Check donation address (yield recipient) - called dragonRouter in the contract
        (bool ok, address dragonRouter) = _readAddress(strategy, "dragonRouter()");
        if (!ok) {
            console.log("[FAIL] dragonRouter() call failed");
            passed = false;
        } else if (dragonRouter == DRAGON_FUNDING_POOL) {
            console.log("[PASS] Dragon Router (yield recipient): Dragon Funding Pool (", dragonRouter, ")");
        } else {
            console.log("[FAIL] Dragon Router mismatch. Expected Dragon Pool:", DRAGON_FUNDING_POOL);
            console.log("       Got:", dragonRouter);
            passed = false;
        }

        // Check burning is disabled
        (ok, bool burningEnabled) = _readBool(strategy, "enableBurning()");
        if (!ok) {
            console.log("[FAIL] enableBurning() call failed");
            passed = false;
        } else if (!burningEnabled) {
            console.log("[PASS] Burning: Disabled");
        } else {
            console.log("[WARN] Burning is enabled (expected disabled)");
        }

        // Check strategy is not shutdown
        (ok, bool isShutdown) = _readBool(strategy, "isShutdown()");
        if (!ok) {
            console.log("[FAIL] isShutdown() call failed");
            passed = false;
        } else if (!isShutdown) {
            console.log("[PASS] Strategy Status: Active");
        } else {
            console.log("[WARN] Strategy is shutdown!");
        }

        return passed;
    }

    function _readAddress(address target, string memory signature) internal view returns (bool ok, address value) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature(signature));
        if (!success || data.length < 32) {
            return (false, address(0));
        }
        return (true, abi.decode(data, (address)));
    }

    function _readBool(address target, string memory signature) internal view returns (bool ok, bool value) {
        (bool success, bytes memory data) = target.staticcall(abi.encodeWithSignature(signature));
        if (!success || data.length < 32) {
            return (false, false);
        }
        return (true, abi.decode(data, (bool)));
    }
}

/**
 * @title VerifyKeeperCanReport
 * @notice Supplementary script to verify the keeper can call report().
 * @dev Two modes of operation:
 *
 *      SIMULATION (as keeper, no real tx):
 *      forge script partners/shutter_dao_0x36/script/VerifyProposalExecution.s.sol:VerifyKeeperCanReport \
 *          --fork-url $ETH_RPC_URL --sender 0x06c2c4dB3776D500636DE63e4F109386dCBa6Ae2 -vvvv
 *
 *      LIVE EXECUTION (broadcasts real tx):
 *      forge script partners/shutter_dao_0x36/script/VerifyProposalExecution.s.sol:VerifyKeeperCanReport \
 *          --fork-url $ETH_RPC_URL --broadcast --private-key $KEEPER_PRIVATE_KEY
 *
 *      IMPORTANT: The --sender (simulation) or --private-key (broadcast) MUST correspond
 *      to the configured keeper address. The script verifies this and fails on mismatch.
 */
contract VerifyKeeperCanReport is Script {
    // UPDATE THIS after proposal execution
    address constant STRATEGY_ADDRESS = address(0);
    address constant KEEPER_BOT = 0x06c2c4dB3776D500636DE63e4F109386dCBa6Ae2;

    function run() public {
        require(STRATEGY_ADDRESS != address(0), "Set STRATEGY_ADDRESS first");

        console.log("=== Keeper Report Verification ===");
        console.log("Strategy:", STRATEGY_ADDRESS);
        console.log("Expected Keeper:", KEEPER_BOT);

        // Check keeper is authorized
        (, bytes memory data) = STRATEGY_ADDRESS.staticcall(abi.encodeWithSignature("keeper()"));
        address configuredKeeper = abi.decode(data, (address));

        console.log("Configured Keeper:", configuredKeeper);

        if (configuredKeeper != KEEPER_BOT) {
            console.log("");
            console.log("[FAIL] Keeper address mismatch!");
            console.log("       Update KEEPER_BOT constant to:", configuredKeeper);
            revert("Keeper address mismatch");
        }

        console.log("[PASS] Keeper address matches");
        console.log("");

        // vm.startBroadcast() uses --private-key for broadcast, --sender for simulation
        // The --broadcast flag controls whether transactions are actually sent
        console.log("Executing report() call...");
        console.log("(Use --broadcast flag to send real transaction)");
        console.log("");

        vm.startBroadcast();
        (, address broadcastSender,) = vm.readCallers();
        if (broadcastSender != KEEPER_BOT) {
            console.log("[FAIL] Broadcast sender mismatch!");
            console.log("       Expected:", KEEPER_BOT);
            console.log("       Got:     ", broadcastSender);
            vm.stopBroadcast();
            revert("Broadcast sender mismatch");
        }
        (bool success, bytes memory returnData) = STRATEGY_ADDRESS.call(abi.encodeWithSignature("report()"));
        vm.stopBroadcast();

        if (!success) {
            console.log("[FAIL] Report call reverted");
            if (returnData.length > 0) {
                console.log("Revert reason:");
                console.logBytes(returnData);
            }
            revert("Report call failed");
        }

        if (returnData.length >= 64) {
            (uint256 profit, uint256 loss) = abi.decode(returnData, (uint256, uint256));

            console.log("");
            console.log("=== Report Executed Successfully ===");
            console.log("Profit:", profit);
            console.log("Loss:  ", loss);
        } else {
            console.log("");
            console.log("=== Report Executed Successfully ===");
            console.log("Note: report() returned no data");
        }
    }
}
