// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";

// Strategy implementations
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

// Factory contracts
import { MorphoCompounderStrategyFactory } from "src/factories/MorphoCompounderStrategyFactory.sol";
import { SkyCompounderStrategyFactory } from "src/factories/SkyCompounderStrategyFactory.sol";
import { PaymentSplitterFactory } from "src/factories/PaymentSplitterFactory.sol";
import { YearnV3StrategyFactory } from "src/factories/yieldDonating/YearnV3StrategyFactory.sol";

/**
 * @title VerifyDeployedContracts
 * @author Golem Foundation
 * @notice Script to verify all 5 deployed contracts on Ethereum mainnet
 * @dev Prompts user for contract addresses and verifies each one using forge verify-contract
 *
 * Usage:
 * forge script script/verify/VerifyDeployedContracts.s.sol:VerifyDeployedContracts \
 *   --rpc-url $ETH_RPC_URL \
 *   --etherscan-api-key $ETHERSCAN_API_KEY
 */
contract VerifyDeployedContracts is Script {
    // Contract addresses (to be prompted from user)
    address public yieldDonatingStrategy;
    address public morphoFactory;
    address public skyFactory;
    address public paymentSplitterFactory;
    address public yearnV3Factory;

    // Contract names for verification
    string constant YIELD_DONATING_NAME =
        "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol:YieldDonatingTokenizedStrategy";
    string constant MORPHO_FACTORY_NAME =
        "src/factories/MorphoCompounderStrategyFactory.sol:MorphoCompounderStrategyFactory";
    string constant SKY_FACTORY_NAME = "src/factories/SkyCompounderStrategyFactory.sol:SkyCompounderStrategyFactory";
    string constant PAYMENT_SPLITTER_FACTORY_NAME = "src/factories/PaymentSplitterFactory.sol:PaymentSplitterFactory";
    string constant YEARN_V3_FACTORY_NAME =
        "src/factories/yieldDonating/YearnV3StrategyFactory.sol:YearnV3StrategyFactory";

    function run() public {
        // Prompt user for all contract addresses
        _promptForAddresses();

        // Verify each contract
        _verifyContracts();

        // Log summary
        _logSummary();
    }

    function _promptForAddresses() internal {
        console.log("=== CONTRACT VERIFICATION SETUP ===");
        console.log("Please provide the deployed contract addresses:\n");

        // Prompt for YieldDonatingTokenizedStrategy
        try vm.prompt("Enter YieldDonatingTokenizedStrategy address") returns (string memory addr) {
            yieldDonatingStrategy = vm.parseAddress(addr);
            console.log("[OK] YieldDonatingTokenizedStrategy:", yieldDonatingStrategy);
        } catch {
            revert("Invalid YieldDonatingTokenizedStrategy address");
        }

        // Prompt for MorphoCompounderStrategyFactory
        try vm.prompt("Enter MorphoCompounderStrategyFactory address") returns (string memory addr) {
            morphoFactory = vm.parseAddress(addr);
            console.log("[OK] MorphoCompounderStrategyFactory:", morphoFactory);
        } catch {
            revert("Invalid MorphoCompounderStrategyFactory address");
        }

        // Prompt for SkyCompounderStrategyFactory
        try vm.prompt("Enter SkyCompounderStrategyFactory address") returns (string memory addr) {
            skyFactory = vm.parseAddress(addr);
            console.log("[OK] SkyCompounderStrategyFactory:", skyFactory);
        } catch {
            revert("Invalid SkyCompounderStrategyFactory address");
        }

        // Prompt for PaymentSplitterFactory
        try vm.prompt("Enter PaymentSplitterFactory address") returns (string memory addr) {
            paymentSplitterFactory = vm.parseAddress(addr);
            console.log("[OK] PaymentSplitterFactory:", paymentSplitterFactory);
        } catch {
            revert("Invalid PaymentSplitterFactory address");
        }

        // Prompt for YearnV3StrategyFactory
        try vm.prompt("Enter YearnV3StrategyFactory address") returns (string memory addr) {
            yearnV3Factory = vm.parseAddress(addr);
            console.log("[OK] YearnV3StrategyFactory:", yearnV3Factory);
        } catch {
            revert("Invalid YearnV3StrategyFactory address");
        }

        console.log("\n=== ALL ADDRESSES COLLECTED ===\n");
    }

    function _verifyContracts() internal {
        console.log("=== STARTING CONTRACT VERIFICATION ===\n");

        // Verify YieldDonatingTokenizedStrategy
        _verifyContract(yieldDonatingStrategy, YIELD_DONATING_NAME, "YieldDonatingTokenizedStrategy");

        // Verify MorphoCompounderStrategyFactory
        _verifyContract(morphoFactory, MORPHO_FACTORY_NAME, "MorphoCompounderStrategyFactory");

        // Verify SkyCompounderStrategyFactory
        _verifyContract(skyFactory, SKY_FACTORY_NAME, "SkyCompounderStrategyFactory");

        // Verify PaymentSplitterFactory
        _verifyContract(paymentSplitterFactory, PAYMENT_SPLITTER_FACTORY_NAME, "PaymentSplitterFactory");

        // Verify YearnV3StrategyFactory
        _verifyContract(yearnV3Factory, YEARN_V3_FACTORY_NAME, "YearnV3StrategyFactory");
    }

    function _verifyContract(address contractAddress, string memory contractName, string memory displayName) internal {
        console.log("Verifying", displayName, "at", contractAddress);

        // Build the forge verify-contract command
        string[] memory inputs = new string[](7);
        inputs[0] = "forge";
        inputs[1] = "verify-contract";
        inputs[2] = vm.toString(contractAddress);
        inputs[3] = contractName;
        inputs[4] = "--chain-id";
        inputs[5] = "1"; // Ethereum mainnet
        inputs[6] = "--watch";

        try vm.ffi(inputs) returns (bytes memory result) {
            console.log("[SUCCESS]", displayName, "verification initiated");
            console.log("   Result:", string(result));
        } catch (bytes memory error) {
            console.log("[FAILED]", displayName, "verification failed");
            console.log("   Error:", string(error));
        }

        console.log(""); // Empty line for readability
    }

    function _logSummary() internal view {
        console.log("\n=== VERIFICATION SUMMARY ===");
        console.log("Attempted to verify the following contracts:");
        console.log("- YieldDonatingTokenizedStrategy:", yieldDonatingStrategy);
        console.log("- MorphoCompounderStrategyFactory:", morphoFactory);
        console.log("- SkyCompounderStrategyFactory:", skyFactory);
        console.log("- PaymentSplitterFactory:", paymentSplitterFactory);
        console.log("- YearnV3StrategyFactory:", yearnV3Factory);
        console.log("\nNote: Verification is asynchronous. Check Etherscan for final status.");
        console.log("==============================\n");
    }
}
