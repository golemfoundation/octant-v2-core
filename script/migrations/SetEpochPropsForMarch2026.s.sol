// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import { BatchScript } from "../helpers/BatchScript.sol";

interface IEpochs {
    function auth() external view returns (address);
    function setEpochProps(uint256 _epochDuration, uint256 _decisionWindow) external;
    function getCurrentEpoch() external view returns (uint256);
    function getCurrentEpochEnd() external view returns (uint256);
    function epochPropsIndex() external view returns (uint256);
    function getEpochDuration() external view returns (uint256);
    function getDecisionWindow() external view returns (uint256);
}

interface IAuth {
    function multisig() external view returns (address);
}

/**
 * @title SetEpochPropsForMarch2026
 * @notice Batched Safe transaction to set Octant epoch to end on March 4, 2026
 * @dev Run: CHAIN=mainnet WALLET_TYPE=ledger MNEMONIC_INDEX=0 \
 *           forge script partners/shutter_dao_0x36/script/SetEpochPropsForMarch2026.s.sol \
 *           --fork-url $ETH_RPC_URL --ffi
 *
 *      setEpochProps behavior:
 *        1. Authorization: checks msg.sender == Auth(auth).multisig()
 *        2. Caps current props at current epoch (sets props.to = currentEpoch)
 *        3. Queues new props at epochPropsIndex++ (does NOT immediately activate)
 *        4. getEpochDuration/getDecisionWindow/getCurrentEpochEnd remain UNCHANGED
 *        5. New props activate only after epoch transition (when currentEpoch ends)
 *
 *      Call chain:
 *        Safe.execTransaction(to=MultiSendCallOnly, operation=DELEGATECALL)
 *          └─> MultiSendCallOnly.multiSend() [in Safe's context]
 *                └─> CALL Epochs.setEpochProps() [msg.sender = Safe]
 */
contract SetEpochPropsForMarch2026 is Script, BatchScript {
    // Octant contract addresses (verified in test/integration/shutter/OctantEpochs.t.sol)
    address constant EPOCHS_CONTRACT = 0xc292eBCa7855CB464755Aa638f9784c131F27D59;
    address constant AUTH_CONTRACT = 0x287493F76b8A1833E9E0BF2dE0D972Fb16C6C8ae;
    address constant OCTANT_MULTISIG = 0xa40FcB633d0A6c0d27aA9367047635Ff656229B0;

    // Target date: March 4, 2026 00:00:00 UTC
    uint64 constant MARCH_4_2026 = 1772600400;

    // Expected current state (must match on-chain or script fails)
    uint64 constant EXPECTED_CURRENT_EPOCH_END = 1767715200; // Jan 6, 2026
    uint256 constant EXPECTED_EPOCH_PROPS_INDEX = 1;
    uint256 constant EXPECTED_EPOCH_DURATION = 90 days;
    uint256 constant EXPECTED_DECISION_WINDOW = 14 days;

    // New epoch parameters
    uint256 constant NEW_EPOCH_DURATION = MARCH_4_2026 - EXPECTED_CURRENT_EPOCH_END; // 56 days
    uint256 constant NEW_DECISION_WINDOW = 14 days;

    IEpochs public epochs;

    function run() public isBatch(OCTANT_MULTISIG) {
        epochs = IEpochs(EPOCHS_CONTRACT);

        // Verify all preconditions before proceeding
        _verifyChain();
        _verifyAddresses();
        _verifyCurrentState();

        // Log current state and proposed changes
        _logCurrentState();
        _logProposedChanges();

        // Prompt for confirmation
        _confirmExecution();

        // Add setEpochProps to batch
        _addSetEpochProps();

        // Execute batch (sends to Safe backend)
        executeBatch(true);

        // Log summary
        _logSummary();
    }

    function _verifyChain() internal view {
        require(block.chainid == 1, "Must run on mainnet (chainId=1)");
        console.log("Chain verified: mainnet");
    }

    function _verifyAddresses() internal view {
        // Verify epochs.auth() returns expected Auth contract
        address authAddr = epochs.auth();
        require(authAddr == AUTH_CONTRACT, "Auth contract address mismatch");

        // Verify Auth.multisig() returns the Safe we're sending from
        address multisig = IAuth(authAddr).multisig();
        require(multisig == OCTANT_MULTISIG, "Multisig address mismatch - Safe would not be authorized");

        console.log("Addresses verified:");
        console.log("  epochs.auth() =", authAddr);
        console.log("  Auth.multisig() =", multisig);
    }

    function _verifyCurrentState() internal view {
        // Verify epoch hasn't already transitioned
        uint256 currentEpochEnd = epochs.getCurrentEpochEnd();
        require(
            currentEpochEnd == EXPECTED_CURRENT_EPOCH_END,
            "Current epoch end mismatch - epoch may have transitioned or setEpochProps already called"
        );

        // Verify epochPropsIndex hasn't been incremented
        uint256 propsIndex = epochs.epochPropsIndex();
        require(
            propsIndex == EXPECTED_EPOCH_PROPS_INDEX,
            "epochPropsIndex mismatch - setEpochProps may have already been called"
        );

        // Verify current epoch parameters match expected
        require(epochs.getEpochDuration() == EXPECTED_EPOCH_DURATION, "Epoch duration mismatch");
        require(epochs.getDecisionWindow() == EXPECTED_DECISION_WINDOW, "Decision window mismatch");

        // Verify target date is in the future relative to current epoch end
        require(MARCH_4_2026 > currentEpochEnd, "Target date must be after current epoch end");

        console.log("Current state verified");
    }

    function _logCurrentState() internal view {
        console.log("\n========================================");
        console.log("           CURRENT STATE");
        console.log("========================================");
        console.log("Epochs Contract:", EPOCHS_CONTRACT);
        console.log("Octant Multisig:", OCTANT_MULTISIG);
        console.log("");
        console.log("getCurrentEpoch():", epochs.getCurrentEpoch());
        console.log("getCurrentEpochEnd():", epochs.getCurrentEpochEnd(), "(Jan 6, 2026)");
        console.log("getEpochDuration():", epochs.getEpochDuration());
        console.log("  (%d days)", epochs.getEpochDuration() / 1 days);
        console.log("getDecisionWindow():", epochs.getDecisionWindow());
        console.log("  (%d days)", epochs.getDecisionWindow() / 1 days);
        console.log("epochPropsIndex():", epochs.epochPropsIndex());
    }

    function _logProposedChanges() internal view {
        console.log("\n========================================");
        console.log("          PROPOSED CHANGES");
        console.log("========================================");
        console.log("Function: Epochs.setEpochProps(uint256,uint256)");
        console.log("");
        console.log("Parameters:");
        console.log("  _epochDuration: %d (%d days)", NEW_EPOCH_DURATION, NEW_EPOCH_DURATION / 1 days);
        console.log("  _decisionWindow: %d (%d days)", NEW_DECISION_WINDOW, NEW_DECISION_WINDOW / 1 days);
        console.log("");
        console.log("Immediate effects (after Safe executes):");
        console.log("  epochPropsIndex: 1 -> 2");
        console.log("  Current props.to: 0 ->", epochs.getCurrentEpoch(), "(capped at current epoch)");
        console.log("");
        console.log("Deferred effects (after Jan 6, 2026 epoch transition):");
        console.log("  getEpochDuration(): %d -> %d", EXPECTED_EPOCH_DURATION, NEW_EPOCH_DURATION);
        console.log("  getCurrentEpochEnd(): %d -> %d (March 4, 2026)", EXPECTED_CURRENT_EPOCH_END, MARCH_4_2026);
        console.log("========================================\n");
    }

    function _confirmExecution() internal {
        string memory response = vm.prompt("Type 'yes' to proceed with transaction submission");
        require(
            keccak256(bytes(response)) == keccak256(bytes("yes")),
            "Execution cancelled by user"
        );
        console.log("User confirmed execution\n");
    }

    function _addSetEpochProps() internal {
        console.log("Adding setEpochProps to batch...");

        bytes memory callData = abi.encodeCall(IEpochs.setEpochProps, (NEW_EPOCH_DURATION, NEW_DECISION_WINDOW));

        // addToBatch simulates with vm.prank(safe) - will revert if unauthorized
        addToBatch(EPOCHS_CONTRACT, callData);

        console.log("Transaction added and simulated successfully");
    }

    function _logSummary() internal pure {
        console.log("\n========================================");
        console.log("         TRANSACTION SUBMITTED");
        console.log("========================================");
        console.log("Transaction sent to Safe transaction service.");
        console.log("Safe signers must now approve the transaction.");
        console.log("========================================\n");
    }
}
