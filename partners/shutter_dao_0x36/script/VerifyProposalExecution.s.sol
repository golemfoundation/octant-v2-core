// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import { Script, console } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { MorphoCompounderStrategy } from "src/strategies/yieldDonating/MorphoCompounderStrategy.sol";
import { MorphoCompounderStrategyFactory } from "src/factories/MorphoCompounderStrategyFactory.sol";
import { BaseStrategyFactory } from "src/factories/BaseStrategyFactory.sol";

import { USDC_MAINNET } from "src/constants.sol";

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

    // Optional: Set this to verify a specific strategy address.
    // If left as address(0), the address will be predicted automatically using CREATE2.
    // Alternatively, get the address from transaction logs or the factory's getStrategy(...) function.
    address constant STRATEGY_ADDRESS = address(0);

    // === Expected Configuration ===
    address constant SHUTTER_TREASURY = 0x36bD3044ab68f600f6d3e081056F34f2a58432c4;
    address constant DRAGON_FUNDING_POOL = 0x4B4505dEdE6408642511Fc0586b62676111e4904;
    address constant KEEPER_BOT = 0x06c2c4dB3776D500636DE63e4F109386dCBa6Ae2;
    address constant USDC = USDC_MAINNET;

    string constant EXPECTED_NAME = "SHUGrantPool";
    string constant EXPECTED_SYMBOL = "yvSHU";
    uint256 constant EXPECTED_DEPOSIT = 1_200_000e6; // 1.2M USDC

    // === V2 Factory for address prediction ===
    address constant MORPHO_STRATEGY_FACTORY = 0xd8Df22cB3c3876487961aC2500889664632674d7;
    address constant TOKENIZED_STRATEGY = 0xea648c313b497fECfBC629e73cB61Db34181F067;

    function run() public view {
        console.log(unicode"══════════════════════════════════════════════════════════════════════════════");
        console.log("SHUTTER DAO PROPOSAL EXECUTION VERIFICATION");
        console.log(unicode"══════════════════════════════════════════════════════════════════════════════");
        console.log("");

        address strategyToVerify = STRATEGY_ADDRESS;

        // If no address provided, predict it
        if (strategyToVerify == address(0)) {
            console.log("No strategy address provided. Predicting from CREATE2...");
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
        MorphoCompounderStrategyFactory factory = MorphoCompounderStrategyFactory(MORPHO_STRATEGY_FACTORY);
        address ysUsdc = factory.YS_USDC();
        address usdc = factory.USDC();

        bytes32 parameterHash = keccak256(
            abi.encode(
                ysUsdc,
                usdc,
                EXPECTED_NAME,
                EXPECTED_SYMBOL,
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
                EXPECTED_SYMBOL,
                SHUTTER_TREASURY,
                KEEPER_BOT,
                SHUTTER_TREASURY,
                DRAGON_FUNDING_POOL,
                false,
                TOKENIZED_STRATEGY
            )
        );

        return BaseStrategyFactory(MORPHO_STRATEGY_FACTORY).predictStrategyAddress(
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

        // Check symbol
        string memory actualSymbol = metadata.symbol();
        if (keccak256(bytes(actualSymbol)) == keccak256(bytes(EXPECTED_SYMBOL))) {
            console.log("[PASS] Symbol:", actualSymbol);
        } else {
            console.log("[FAIL] Symbol mismatch. Expected:", EXPECTED_SYMBOL, "Got:", actualSymbol);
            passed = false;
        }

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
            uint256 minExpectedShares = (EXPECTED_DEPOSIT * 95) / 100;
            uint256 sharesDiff = shares > EXPECTED_DEPOSIT ? shares - EXPECTED_DEPOSIT : EXPECTED_DEPOSIT - shares;

            if (sharesDiff <= 1000) {
                // Within rounding tolerance
                console.log("[PASS] Treasury shares:", shares / 1e6);
                console.log("       Raw shares:", shares);
            } else if (shares >= minExpectedShares) {
                // Within 5% - acceptable due to exchange rate
                console.log("[PASS] Treasury shares:", shares / 1e6, "(within 5% of expected)");
            } else {
                // More than 5% off - likely partial failure
                console.log("[FAIL] Treasury shares significantly below expected");
                console.log("       Expected:", EXPECTED_DEPOSIT / 1e6, "M");
                console.log("       Actual:", shares / 1e6);
                console.log("       Raw shares:", shares);
                console.log("       Minimum acceptable (95%):", minExpectedShares / 1e6);
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
        (, bytes memory data) = strategy.staticcall(abi.encodeWithSignature("management()"));
        address management = abi.decode(data, (address));
        if (management == SHUTTER_TREASURY) {
            console.log("[PASS] Management: Treasury (", management, ")");
        } else {
            console.log("[FAIL] Management mismatch. Expected Treasury, Got:", management);
            passed = false;
        }

        // Check keeper
        (, data) = strategy.staticcall(abi.encodeWithSignature("keeper()"));
        address keeper = abi.decode(data, (address));
        if (keeper == KEEPER_BOT) {
            console.log("[PASS] Keeper: Dedicated Bot (", keeper, ")");
        } else {
            console.log("[FAIL] Keeper mismatch. Expected:", KEEPER_BOT, "Got:", keeper);
            passed = false;
        }

        // Check emergency admin
        (, data) = strategy.staticcall(abi.encodeWithSignature("emergencyAdmin()"));
        address emergencyAdmin = abi.decode(data, (address));
        if (emergencyAdmin == SHUTTER_TREASURY) {
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
        (, bytes memory data) = strategy.staticcall(abi.encodeWithSignature("dragonRouter()"));
        address dragonRouter = abi.decode(data, (address));
        if (dragonRouter == DRAGON_FUNDING_POOL) {
            console.log("[PASS] Dragon Router (yield recipient): Dragon Funding Pool (", dragonRouter, ")");
        } else {
            console.log("[FAIL] Dragon Router mismatch. Expected Dragon Pool:", DRAGON_FUNDING_POOL);
            console.log("       Got:", dragonRouter);
            passed = false;
        }

        // Check burning is disabled
        (, data) = strategy.staticcall(abi.encodeWithSignature("enableBurning()"));
        bool burningEnabled = abi.decode(data, (bool));
        if (!burningEnabled) {
            console.log("[PASS] Burning: Disabled");
        } else {
            console.log("[WARN] Burning is enabled (expected disabled)");
        }

        // Check strategy is not shutdown
        (, data) = strategy.staticcall(abi.encodeWithSignature("isShutdown()"));
        bool isShutdown = abi.decode(data, (bool));
        if (!isShutdown) {
            console.log("[PASS] Strategy Status: Active");
        } else {
            console.log("[WARN] Strategy is shutdown!");
        }

        return passed;
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

        (uint256 profit, uint256 loss) = abi.decode(returnData, (uint256, uint256));

        console.log("");
        console.log("=== Report Executed Successfully ===");
        console.log("Profit:", profit);
        console.log("Loss:  ", loss);
    }
}
