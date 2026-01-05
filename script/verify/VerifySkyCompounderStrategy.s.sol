// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import { SkyCompounderStrategy } from "src/strategies/yieldDonating/SkyCompounderStrategy.sol";

/**
 * @title VerifySkyCompounderStrategy
 * @author Golem Foundation
 * @notice Script to verify deployed SkyCompounderStrategy contract on Ethereum mainnet
 * @dev Prompts user for contract address and verifies using forge verify-contract
 *
 * Usage:
 * forge script script/verify/VerifySkyCompounderStrategy.s.sol:VerifySkyCompounderStrategy \
 *   --rpc-url $ETH_RPC_URL \
 *   --etherscan-api-key $ETHERSCAN_API_KEY
 */
contract VerifySkyCompounderStrategy is Script {
    // Contract address (to be prompted from user)
    address public skyCompounderStrategy;

    // Contract name for verification
    string constant CONTRACT_NAME = "src/strategies/yieldDonating/SkyCompounderStrategy.sol:SkyCompounderStrategy";

    function run() public {
        // Prompt user for contract address
        _promptForAddress();

        // Verify the contract
        _verifyContract();

        // Log summary
        _logSummary();
    }

    function _promptForAddress() internal {
        console.log("=== SKY COMPOUNDER STRATEGY VERIFICATION ===");
        console.log("Please provide the deployed contract address:\n");

        // Prompt for SkyCompounderStrategy address
        try vm.prompt("Enter SkyCompounderStrategy address") returns (string memory addr) {
            skyCompounderStrategy = vm.parseAddress(addr);
            console.log("[OK] SkyCompounderStrategy:", skyCompounderStrategy);
        } catch {
            revert("Invalid SkyCompounderStrategy address");
        }

        console.log("\n=== ADDRESS COLLECTED ===\n");
    }

    function _verifyContract() internal {
        console.log("=== STARTING CONTRACT VERIFICATION ===\n");

        console.log("Verifying SkyCompounderStrategy at", skyCompounderStrategy);

        // Build the forge verify-contract command
        string[] memory inputs = new string[](7);
        inputs[0] = "forge";
        inputs[1] = "verify-contract";
        inputs[2] = vm.toString(skyCompounderStrategy);
        inputs[3] = CONTRACT_NAME;
        inputs[4] = "--chain-id";
        inputs[5] = "1"; // Ethereum mainnet
        inputs[6] = "--watch";

        try vm.ffi(inputs) returns (bytes memory result) {
            console.log("[SUCCESS] SkyCompounderStrategy verification initiated");
            console.log("   Result:", string(result));
        } catch (bytes memory error) {
            console.log("[FAILED] SkyCompounderStrategy verification failed");
            console.log("   Error:", string(error));
        }

        console.log(""); // Empty line for readability
    }

    function _logSummary() internal view {
        console.log("\n=== VERIFICATION SUMMARY ===");
        console.log("Attempted to verify:");
        console.log("- SkyCompounderStrategy:", skyCompounderStrategy);
        console.log("\nNote: Verification is asynchronous. Check Etherscan for final status.");
        console.log("Contract path:", CONTRACT_NAME);
        console.log("==============================\n");
    }
}
