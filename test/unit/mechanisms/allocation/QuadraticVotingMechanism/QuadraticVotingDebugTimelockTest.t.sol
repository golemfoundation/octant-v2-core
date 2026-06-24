// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/console.sol";
import {QuadraticVotingTestBase} from "../utils/QuadraticVotingTestBase.sol";

contract QuadraticVotingDebugTimelockTest is QuadraticVotingTestBase {
    uint256 constant LARGE_DEPOSIT = 1000 ether;
    uint256 constant TIMELOCK_DELAY = 1 days;

    function setUp() public {
        // Set timestamp before deploying mechanism
        vm.warp(100000);

        _setUpQuadraticVoting("Debug Test", "DEBUG", 100, 1000, 500, TIMELOCK_DELAY, 7 days, 50, 100);
        token.mint(alice, 2000 ether);
        _tokenized().setKeeper(alice);
    }

    function testDebugTimelock() public {
        console.log("Initial timestamp:", block.timestamp);

        // Setup successful proposal during delay period (before voting starts)
        _signup(alice, LARGE_DEPOSIT);
        uint256 pid = _propose(alice, charlie, "Charlie's Project");

        // Move to voting period: startTime + votingDelay = 100000 + 100 = 100100
        vm.warp(100100);

        _vote(alice, pid, 31, charlie); // 31^2 = 961 > 500 quorum

        // Move past voting period: startTime + votingDelay + votingPeriod = 100000 + 100 + 1000 = 101100
        vm.warp(101101);
        (bool success,) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        console.log("=== BEFORE QUEUING ===");
        console.log("Current timestamp:", block.timestamp);
        console.log("Charlie redeemableAfter BEFORE:", _tokenized().globalRedemptionStart());
        console.log("Charlie balance BEFORE:", _tokenized().balanceOf(charlie));
        console.log("Charlie maxRedeem BEFORE:", _tokenized().maxRedeem(charlie));

        uint256 queueTime = block.timestamp;
        console.log("Queue time:", queueTime);
        console.log("Timelock delay:", _tokenized().timelockDelay());
        console.log("Expected redeemable time:", queueTime + TIMELOCK_DELAY);

        (bool success2,) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pid));
        require(success2, "Queue failed");

        console.log("=== AFTER QUEUING ===");
        console.log("Current timestamp:", block.timestamp);
        console.log("Charlie redeemableAfter AFTER:", _tokenized().globalRedemptionStart());
        console.log("Charlie balance AFTER:", _tokenized().balanceOf(charlie));
        console.log("Charlie maxRedeem AFTER:", _tokenized().maxRedeem(charlie));

        // Check if timelock is working
        uint256 maxRedeem = _tokenized().maxRedeem(charlie);
        console.log("Max redeem immediately after queue:", maxRedeem);

        if (maxRedeem == 0) {
            console.log("SUCCESS: Timelock is blocking redemption");
        } else {
            console.log("FAILURE: Timelock is NOT blocking redemption");
            console.log("Expected: 0, Got:", maxRedeem);
        }

        // Debug the _availableWithdrawLimit logic step by step
        uint256 redeemableTime = _tokenized().globalRedemptionStart();
        console.log("Debug - redeemableTime:", redeemableTime);
        console.log("Debug - block.timestamp:", block.timestamp);
        console.log("Debug - block.timestamp < redeemableTime:", block.timestamp < redeemableTime);

        if (redeemableTime == 0) {
            console.log("DEBUG: redeemableTime is 0 - this should not happen after queuing");
        } else if (block.timestamp < redeemableTime) {
            console.log("DEBUG: We are in timelock period - should return 0");
        } else {
            console.log("DEBUG: We are past timelock - should allow redemption");
        }
    }
}
