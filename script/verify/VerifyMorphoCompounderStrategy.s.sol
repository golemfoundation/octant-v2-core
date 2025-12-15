// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import { MorphoCompounderStrategy } from "src/strategies/yieldDonating/MorphoCompounderStrategy.sol";

/**
 * @title VerifyMorphoCompounderStrategy
 * @author Golem Foundation
 * @notice Script to verify deployed MorphoCompounderStrategy contract on Ethereum mainnet
 * @dev Prompts user for contract address and verifies using forge verify-contract
 *
 * Usage:
 * forge script script/verify/VerifyMorphoCompounderStrategy.s.sol:VerifyMorphoCompounderStrategy \
 *   --rpc-url $ETH_RPC_URL \
 *   --etherscan-api-key $ETHERSCAN_API_KEY
 */
contract VerifyMorphoCompounderStrategy is Script {
    // Contract address (to be prompted from user)
    address public morphoCompounderStrategy;

    // Contract name for verification
    string constant CONTRACT_NAME =
        "src/strategies/yieldDonating/MorphoCompounderStrategy.sol:MorphoCompounderStrategy";

    function run() public {
        // Prompt user for contract address
        _promptForAddress();

        // Verify the contract
        _verifyContract();

        // Log summary
        _logSummary();
    }

    function _promptForAddress() internal {
        console.log("=== MORPHO COMPOUNDER STRATEGY VERIFICATION ===");
        console.log("Please provide the deployed contract address:\n");

        // Prompt for MorphoCompounderStrategy address
        try vm.prompt("Enter MorphoCompounderStrategy address") returns (string memory addr) {
            morphoCompounderStrategy = vm.parseAddress(addr);
            console.log("[OK] MorphoCompounderStrategy:", morphoCompounderStrategy);
        } catch {
            revert("Invalid MorphoCompounderStrategy address");
        }

        console.log("\n=== ADDRESS COLLECTED ===\n");
    }

    function _verifyContract() internal {
        console.log("=== STARTING CONTRACT VERIFICATION ===\n");

        console.log("Verifying MorphoCompounderStrategy at", morphoCompounderStrategy);

        // Build the forge verify-contract command
        string[] memory inputs = new string[](7);
        inputs[0] = "forge";
        inputs[1] = "verify-contract";
        inputs[2] = vm.toString(morphoCompounderStrategy);
        inputs[3] = CONTRACT_NAME;
        inputs[4] = "--chain-id";
        inputs[5] = "1"; // Ethereum mainnet
        inputs[6] = "--watch";

        try vm.ffi(inputs) returns (bytes memory result) {
            console.log("[SUCCESS] MorphoCompounderStrategy verification initiated");
            console.log("   Result:", string(result));
        } catch (bytes memory error) {
            console.log("[FAILED] MorphoCompounderStrategy verification failed");
            console.log("   Error:", string(error));
        }

        console.log(""); // Empty line for readability
    }

    function _logSummary() internal view {
        console.log("\n=== VERIFICATION SUMMARY ===");
        console.log("Attempted to verify the following contracts:");
        console.log("- MorphoCompounderStrategy:", morphoCompounderStrategy);
        console.log("\nNote: Verification is asynchronous. Check Etherscan for final status.");
        console.log("==============================\n");
    }
}
