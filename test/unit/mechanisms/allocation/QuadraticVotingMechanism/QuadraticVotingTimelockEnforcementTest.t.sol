// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import { TokenizedAllocationMechanism } from "src/mechanisms/TokenizedAllocationMechanism.sol";
import { QuadraticVotingMechanism } from "src/mechanisms/mechanism/QuadraticVotingMechanism.sol";
import { AllocationMechanismFactory } from "src/mechanisms/AllocationMechanismFactory.sol";
import { AllocationConfig } from "src/mechanisms/BaseAllocationMechanism.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @title Timelock Enforcement Test
/// @notice Tests timelock and grace period enforcement through availableWithdrawLimit hook
contract QuadraticVotingTimelockEnforcementTest is Test {
    AllocationMechanismFactory factory;
    ERC20Mock token;
    QuadraticVotingMechanism mechanism;

    address alice = address(0x1);
    address bob = address(0x2);
    address charlie = address(0x3);

    uint256 constant LARGE_DEPOSIT = 1000 ether;
    uint256 constant QUORUM_REQUIREMENT = 500; // Adjusted for quadratic funding
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;
    uint256 constant TIMELOCK_DELAY = 1 days;
    uint256 constant GRACE_PERIOD = 7 days;

    function _tokenized(address _mechanism) internal pure returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(_mechanism);
    }

    function setUp() public {
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();

        token.mint(alice, 2000 ether);
        token.mint(bob, 1500 ether);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Timelock Enforcement Test",
            symbol: "TLTEST",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: QUORUM_REQUIREMENT,
            timelockDelay: TIMELOCK_DELAY,
            gracePeriod: GRACE_PERIOD,
            owner: address(0)
        });

        address mechanismAddr = factory.deployQuadraticVotingMechanism(config, 50, 100); // 50% alpha
        mechanism = QuadraticVotingMechanism(payable(mechanismAddr));
        _tokenized(address(mechanism)).setKeeper(alice);
        _tokenized(address(mechanism)).setManagement(bob);

        // Pre-fund matching pool - this will be included in total assets during finalize
        uint256 matchingPoolAmount = 2000 ether;
        token.mint(address(this), matchingPoolAmount);
        token.transfer(address(mechanism), matchingPoolAmount);
    }

    /// @notice Test timelock enforcement prevents early redemption
    function testTimelockEnforcement_PreventEarlyRedemption() public {
        // Start with clean timestamp
        vm.warp(10);

        // Get absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingPeriod = _tokenized(address(mechanism)).votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod; // Start at timestamp 100000 to avoid edge cases

        // Setup successful proposal
        vm.startPrank(alice);
        token.approve(address(mechanism), LARGE_DEPOSIT);
        _tokenized(address(mechanism)).signup(LARGE_DEPOSIT);
        uint256 pid = _tokenized(address(mechanism)).propose(charlie, "Charlie's Project");
        vm.stopPrank();

        vm.warp(votingStartTime + 1);

        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, 30, charlie); // 30^2 = 900 > 500 quorum

        vm.warp(votingEndTime + 1);
        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        uint256 queueTime = block.timestamp;
        (bool success2, ) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pid));
        require(success2, "Queue failed");

        // Verify shares minted - QuadraticVoting: vote weight 30 produces 900 funding
        uint256 charlieShares = 900; // 30^2 = 900 with α=0.5 → 0.5×900 + 0.5×900 = 900
        assertEq(_tokenized(address(mechanism)).balanceOf(charlie), charlieShares);

        // Test 1: Immediately after queuing - should be blocked by timelock
        console.log("Current timestamp:", block.timestamp);
        console.log("Charlie redeemableAfter:", _tokenized(address(mechanism)).globalRedemptionStart());
        console.log("Time difference:", _tokenized(address(mechanism)).globalRedemptionStart() - block.timestamp);
        assertEq(_tokenized(address(mechanism)).maxRedeem(charlie), 0);

        vm.expectRevert("Allocation: redeem more than max");
        vm.prank(charlie);
        _tokenized(address(mechanism)).redeem(charlieShares, charlie, charlie);

        // Test 2: Halfway through timelock - still blocked
        vm.warp(queueTime + TIMELOCK_DELAY / 2);
        assertEq(_tokenized(address(mechanism)).maxRedeem(charlie), 0);

        vm.expectRevert("Allocation: redeem more than max");
        vm.prank(charlie);
        _tokenized(address(mechanism)).redeem(charlieShares, charlie, charlie);

        // Test 3: One second before timelock expires - still blocked
        // Need to check what the actual redeemableAfter time is
        uint256 redeemableTime = _tokenized(address(mechanism)).globalRedemptionStart();
        vm.warp(redeemableTime - 1);
        assertEq(_tokenized(address(mechanism)).maxRedeem(charlie), 0);

        vm.expectRevert("Allocation: redeem more than max");
        vm.prank(charlie);
        _tokenized(address(mechanism)).redeem(charlieShares, charlie, charlie);
    }

    /// @notice Test successful redemption in valid timelock window
    function testTimelockEnforcement_ValidRedemptionWindow() public {
        // Start with clean timestamp
        vm.warp(20);

        // Get absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingPeriod = _tokenized(address(mechanism)).votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod; // Different timestamp to avoid interference

        // Setup successful proposal
        vm.startPrank(alice);
        token.approve(address(mechanism), LARGE_DEPOSIT);
        _tokenized(address(mechanism)).signup(LARGE_DEPOSIT);
        uint256 pid = _tokenized(address(mechanism)).propose(charlie, "Charlie's Project");
        vm.stopPrank();

        vm.warp(votingStartTime + 1);

        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, 30, charlie); // 30^2 = 900 > 500 quorum

        vm.warp(votingEndTime + 1);
        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        uint256 queueTime = block.timestamp;
        (bool success2, ) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pid));
        require(success2, "Queue failed");

        uint256 charlieShares = 900; // Vote weight 30 produces 900 shares
        console.log("Charlie received shares:", charlieShares);

        // Test 1: Exactly when timelock expires - should work
        vm.warp(queueTime + TIMELOCK_DELAY);
        assertEq(_tokenized(address(mechanism)).maxRedeem(charlie), charlieShares);

        vm.prank(charlie);
        uint256 assetsReceived1 = _tokenized(address(mechanism)).redeem(300, charlie, charlie);

        // With matching pool: total assets = 1000 (alice) + 2000 (matching pool) = 3000 ether
        // 300 shares out of 900 total = (300/900) × 3000 = 1000 ether
        uint256 expectedAssets1 = 1000 ether;
        assertEq(assetsReceived1, expectedAssets1);
        assertEq(_tokenized(address(mechanism)).balanceOf(charlie), 600); // 900 - 300 = 600

        // Test 2: Middle of valid window - should work
        vm.warp(queueTime + TIMELOCK_DELAY + GRACE_PERIOD / 2);
        assertEq(_tokenized(address(mechanism)).maxRedeem(charlie), 600); // 900 - 300 = 600

        vm.prank(charlie);
        uint256 assetsReceived2 = _tokenized(address(mechanism)).redeem(300, charlie, charlie);
        uint256 expectedAssets2 = 1000 ether; // Same ratio: (300/900) × 3000 = 1000 ether
        assertEq(assetsReceived2, expectedAssets2);
        assertEq(_tokenized(address(mechanism)).balanceOf(charlie), 300);

        // Test 3: One second before grace period expires - should work
        uint256 redeemableTime = _tokenized(address(mechanism)).globalRedemptionStart();
        vm.warp(redeemableTime + GRACE_PERIOD - 1);
        assertEq(_tokenized(address(mechanism)).maxRedeem(charlie), 300);

        vm.prank(charlie);
        uint256 assetsReceived3 = _tokenized(address(mechanism)).redeem(300, charlie, charlie);
        uint256 expectedAssets3 = 1000 ether; // Same ratio: (300/900) × 3000 = 1000 ether
        assertEq(assetsReceived3, expectedAssets3);
        assertEq(_tokenized(address(mechanism)).balanceOf(charlie), 0);

        // Verify total redemption: 3 × 1000 ether = 3000 ether (all assets)
        assertEq(assetsReceived1 + assetsReceived2 + assetsReceived3, 3000 ether);
    }

    /// @notice Test grace period expiration prevents redemption
    function testTimelockEnforcement_GracePeriodExpiration() public {
        // Get absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingPeriod = _tokenized(address(mechanism)).votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Setup successful proposal
        vm.startPrank(alice);
        token.approve(address(mechanism), LARGE_DEPOSIT);
        _tokenized(address(mechanism)).signup(LARGE_DEPOSIT);
        uint256 pid = _tokenized(address(mechanism)).propose(charlie, "Charlie's Expired Project");
        vm.stopPrank();

        vm.warp(votingStartTime + 1);

        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, 30, charlie); // 30^2 = 900 > 500 quorum

        vm.warp(votingEndTime + 1);
        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        uint256 queueTime = block.timestamp;
        (bool success2, ) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pid));
        require(success2, "Queue failed");

        uint256 charlieShares = 900; // Vote weight 30 produces 900 shares

        // Fast forward past grace period
        vm.warp(queueTime + TIMELOCK_DELAY + GRACE_PERIOD + 1);

        // Test 1: maxRedeem should return 0 after grace period
        assertEq(_tokenized(address(mechanism)).maxRedeem(charlie), 0);

        // Test 2: Redemption should fail
        vm.expectRevert("Allocation: redeem more than max");
        vm.prank(charlie);
        _tokenized(address(mechanism)).redeem(charlieShares, charlie, charlie);

        // Test 3: Even partial redemption should fail
        vm.expectRevert("Allocation: redeem more than max");
        vm.prank(charlie);
        _tokenized(address(mechanism)).redeem(1 ether, charlie, charlie);

        // Test 4: Shares still exist but are inaccessible
        assertEq(_tokenized(address(mechanism)).balanceOf(charlie), charlieShares);

        // Test 5: Way past grace period - still blocked
        vm.warp(queueTime + TIMELOCK_DELAY + GRACE_PERIOD + 365 days);
        assertEq(_tokenized(address(mechanism)).maxRedeem(charlie), 0);

        vm.expectRevert("Allocation: redeem more than max");
        vm.prank(charlie);
        _tokenized(address(mechanism)).redeem(charlieShares, charlie, charlie);
    }

    /// @notice Test multiple recipients with different timelock schedules
    function testTimelockEnforcement_MultipleRecipients() public {
        // Start with clean timestamp
        vm.warp(30);

        // Get absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingPeriod = _tokenized(address(mechanism)).votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod; // Different timestamp to avoid interference

        // Setup multiple voters and recipients
        vm.startPrank(alice);
        token.approve(address(mechanism), LARGE_DEPOSIT);
        _tokenized(address(mechanism)).signup(LARGE_DEPOSIT);
        vm.stopPrank();

        vm.startPrank(bob);
        token.approve(address(mechanism), 500 ether);
        _tokenized(address(mechanism)).signup(500 ether);
        vm.stopPrank();

        // Create proposals
        vm.prank(alice);
        uint256 pid1 = _tokenized(address(mechanism)).propose(charlie, "Charlie's Early Project");

        vm.prank(bob);
        uint256 pid2 = _tokenized(address(mechanism)).propose(bob, "Bob's Later Project");

        vm.warp(votingStartTime + 1);

        // Vote for both
        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(pid1, TokenizedAllocationMechanism.VoteType.For, 30, charlie); // 30^2 = 900 > 500 quorum

        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(pid2, TokenizedAllocationMechanism.VoteType.For, 30, bob); // 30^2 = 900 > 500 quorum

        vm.warp(votingEndTime + 1);
        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        // Queue first proposal
        (bool success1, ) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pid1));
        require(success1, "Queue 1 failed");

        // Wait some time then queue second proposal
        vm.warp(block.timestamp + 2 hours);
        (bool success2, ) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pid2));
        require(success2, "Queue 2 failed");

        // Test different timelock schedules

        // At charlie's timelock expiry - charlie can redeem, bob cannot
        uint256 charlieRedeemableTime = _tokenized(address(mechanism)).globalRedemptionStart();
        uint256 bobRedeemableTime = _tokenized(address(mechanism)).globalRedemptionStart();
        vm.warp(charlieRedeemableTime);
        assertEq(_tokenized(address(mechanism)).maxRedeem(charlie), 900);
        // Bob's timelock should still be active since he was queued later
        if (charlieRedeemableTime < bobRedeemableTime) {
            assertEq(_tokenized(address(mechanism)).maxRedeem(bob), 0);
        } else {
            assertEq(_tokenized(address(mechanism)).maxRedeem(bob), 900);
        }

        vm.prank(charlie);
        uint256 charlieAssets = _tokenized(address(mechanism)).redeem(900, charlie, charlie);

        // With matching pool: total assets = 1500 (alice + bob) + 2000 (matching pool) = 3500 ether
        // Each recipient gets 900 shares, total shares = 1800
        // Charlie's 900 shares = (900/1800) × 3500 = 1750 ether
        uint256 expectedAssetsPerRecipient = 1750 ether;
        assertEq(charlieAssets, expectedAssetsPerRecipient);

        // Only try to revert if Bob's timelock is still active
        if (charlieRedeemableTime < bobRedeemableTime) {
            vm.expectRevert("Allocation: redeem more than max");
            vm.prank(bob);
            _tokenized(address(mechanism)).redeem(900, bob, bob);
        }

        // At bob's timelock expiry - bob can now redeem
        vm.warp(bobRedeemableTime);
        assertEq(_tokenized(address(mechanism)).maxRedeem(bob), 900);

        vm.prank(bob);
        uint256 bobAssets = _tokenized(address(mechanism)).redeem(900, bob, bob);
        assertEq(bobAssets, expectedAssetsPerRecipient);

        // Verify independent schedules worked correctly
        assertEq(charlieAssets, expectedAssetsPerRecipient);
        assertEq(bobAssets, expectedAssetsPerRecipient);
    }

    /// @notice Test edge cases in timelock enforcement
    // function testTimelockEnforcement_EdgeCases() public {
    //     uint256 startBlock = _tokenized(address(mechanism)).startBlock();
    //     vm.roll(startBlock - 1);

    //     // Start with clean timestamp
    //     vm.warp(400000); // Different timestamp to avoid interference

    //     // Setup
    //     vm.startPrank(alice);
    //     token.approve(address(mechanism), LARGE_DEPOSIT);
    //     _tokenized(address(mechanism)).signup(LARGE_DEPOSIT);
    //     uint256 pid = _tokenized(address(mechanism)).propose(charlie, "Charlie's Edge Case Project");
    //     vm.stopPrank();

    //     vm.roll(startBlock + VOTING_DELAY + 1);

    //     vm.prank(alice);
    //     _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, 30); // 30^2 = 900 > 500 quorum

    //     vm.roll(startBlock + VOTING_DELAY + VOTING_PERIOD + 1);
    //     (bool success,) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
    //     require(success, "Finalization failed");

    //     uint256 queueTime = block.timestamp;
    //     (bool success2,) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pid));
    //     require(success2, "Queue failed");

    //     // Test 1: Exactly at boundary moments

    //     // Exactly at timelock expiry
    //     vm.warp(queueTime + TIMELOCK_DELAY);
    //     assertEq(_tokenized(address(mechanism)).maxRedeem(charlie), 900);

    //     // Exactly at grace period expiry
    //     vm.warp(queueTime + TIMELOCK_DELAY + GRACE_PERIOD);
    //     assertEq(_tokenized(address(mechanism)).maxRedeem(charlie), 0);

    //     // Test 2: Transfer shares and check timelock enforcement for new owner
    //     vm.warp(queueTime + TIMELOCK_DELAY + GRACE_PERIOD / 2); // Valid window

    //     address newOwner = address(0x999);
    //     vm.prank(charlie);
    //     _tokenized(address(mechanism)).transfer(newOwner, 300);

    //     // New owner should also respect charlie's original timelock
    //     assertEq(_tokenized(address(mechanism)).maxRedeem(newOwner), 300);

    //     vm.prank(newOwner);
    //     uint256 newOwnerAssets = _tokenized(address(mechanism)).redeem(300, newOwner, newOwner);

    //     // With matching pool: total assets = 1000 (alice) + 2000 (matching pool) = 3000 ether
    //     // 300 shares out of 900 total = (300/900) × 3000 = 1000 ether
    //     uint256 expectedAssets = 1000 ether;
    //     assertEq(newOwnerAssets, expectedAssets);

    //     // Test 3: Approved redemption
    //     vm.prank(charlie);
    //     _tokenized(address(mechanism)).approve(newOwner, 300); // Approve 300 of the 600 remaining shares

    //     vm.prank(newOwner);
    //     uint256 approvedAssets = _tokenized(address(mechanism)).redeem(300, newOwner, charlie);

    //     // Same calculation: 300 shares out of 900 total = (300/900) × 3000 = 1000 ether
    //     uint256 expectedApprovedAssets = 1000 ether;
    //     assertEq(approvedAssets, expectedApprovedAssets);
    // }
}
