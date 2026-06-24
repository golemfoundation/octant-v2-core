// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { TokenizedAllocationMechanism } from "src/mechanisms/TokenizedAllocationMechanism.sol";
import { QuadraticVotingTestBase } from "../utils/QuadraticVotingTestBase.sol";

/// @title Proposal State Journey Tests
/// @notice Comprehensive tests for all possible proposal states and recipient experiences
contract QuadraticVotingProposalStateTest is QuadraticVotingTestBase {
    uint256 constant LARGE_DEPOSIT = 1000 ether;
    uint256 constant MEDIUM_DEPOSIT = 500 ether;
    uint256 constant QUORUM_REQUIREMENT = 500;
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;
    uint256 constant TIMELOCK_DELAY = 1 days;
    uint256 constant GRACE_PERIOD = 7 days;

    function setUp() public {
        _setUpQuadraticVoting(
            "Proposal State Test",
            "PSTEST",
            VOTING_DELAY,
            VOTING_PERIOD,
            QUORUM_REQUIREMENT,
            TIMELOCK_DELAY,
            GRACE_PERIOD,
            50,
            100
        );

        token.mint(alice, 2000 ether);
        token.mint(bob, 1500 ether);
        _setRoles(alice, bob);

        // Pre-fund matching pool - this will be included in total assets during finalize
        uint256 matchingPoolAmount = 2000 ether;
        token.mint(address(this), matchingPoolAmount);
        token.transfer(address(mechanism), matchingPoolAmount);
    }

    /// @notice Test PENDING state - proposal created before mechanism starts
    function testProposalState_Pending() public {
        // Get absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized().votingDelay();
        uint256 votingStartTime = deploymentTime + votingDelay;

        // Before voting starts (still in delay period) - warp before creating proposal
        vm.warp(deploymentTime + 10);

        // Register and create proposal
        vm.startPrank(alice);
        token.approve(address(mechanism), LARGE_DEPOSIT);
        _tokenized().signup(LARGE_DEPOSIT);
        uint256 pid = _tokenized().propose(charlie, "Charlie's Pending Proposal");
        vm.stopPrank();

        // Verify PENDING state
        assertEq(uint256(_tokenized().state(pid)), uint256(TokenizedAllocationMechanism.ProposalState.Pending));

        // Recipient can monitor but cannot vote yet
        TokenizedAllocationMechanism.Proposal memory proposal = _tokenized().proposals(pid);
        assertEq(proposal.recipient, charlie);
        assertEq(proposal.proposer, alice);

        // Move closer to start but still pending
        vm.warp(votingStartTime - 1);
        assertEq(uint256(_tokenized().state(pid)), uint256(TokenizedAllocationMechanism.ProposalState.Pending));
    }

    /// @notice Test ACTIVE state - proposal during voting delay and voting period
    function testProposalState_Active() public {
        // Get absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized().votingDelay();
        uint256 votingPeriod = _tokenized().votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Setup and create proposal
        vm.startPrank(alice);
        token.approve(address(mechanism), LARGE_DEPOSIT);
        _tokenized().signup(LARGE_DEPOSIT);
        uint256 pid = _tokenized().propose(dave, "Dave's Active Proposal");
        vm.stopPrank();

        // During voting delay - PENDING (before voting can start)
        vm.warp(votingStartTime - 50);
        assertEq(uint256(_tokenized().state(pid)), uint256(TokenizedAllocationMechanism.ProposalState.Pending));

        // During voting period - ACTIVE
        vm.warp(votingStartTime + 50);
        assertEq(uint256(_tokenized().state(pid)), uint256(TokenizedAllocationMechanism.ProposalState.Active));

        // Recipient can monitor voting progress
        vm.prank(alice);
        _tokenized().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 30, dave);

        (, , uint256 quadraticFunding, uint256 linearFunding) = mechanism.getTally(pid);
        uint256 forVotes = quadraticFunding + linearFunding;
        assertEq(forVotes, 900);

        // TALLYING after voting ends but before finalized
        vm.warp(votingEndTime + 10);
        assertEq(uint256(_tokenized().state(pid)), uint256(TokenizedAllocationMechanism.ProposalState.Tallying));
    }

    /// @notice Test CANCELED state - proposer cancels before queuing
    function testProposalState_Canceled() public {
        // Get absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized().votingDelay();
        uint256 votingPeriod = _tokenized().votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Setup
        vm.startPrank(alice);
        token.approve(address(mechanism), LARGE_DEPOSIT);
        _tokenized().signup(LARGE_DEPOSIT);
        uint256 pid = _tokenized().propose(eve, "Eve's Canceled Proposal");
        vm.stopPrank();

        // Proposer cancels during active period
        vm.warp(votingStartTime + 50);
        vm.prank(alice);
        _tokenized().cancelProposal(pid);

        // Verify CANCELED state
        assertEq(uint256(_tokenized().state(pid)), uint256(TokenizedAllocationMechanism.ProposalState.Canceled));

        // Recipient cannot receive anything from canceled proposal
        TokenizedAllocationMechanism.Proposal memory proposal = _tokenized().proposals(pid);
        assertTrue(proposal.canceled);

        // Cannot vote on canceled proposal
        vm.expectRevert();
        vm.prank(alice);
        _tokenized().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 8, dave);

        // State remains CANCELED permanently
        vm.warp(votingEndTime + 100);
        assertEq(uint256(_tokenized().state(pid)), uint256(TokenizedAllocationMechanism.ProposalState.Canceled));
    }

    /// @notice Test DEFEATED state - proposal fails to meet quorum or has negative votes
    function testProposalState_Defeated() public {
        // Get absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized().votingDelay();
        uint256 votingPeriod = _tokenized().votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Setup voters
        vm.startPrank(alice);
        token.approve(address(mechanism), LARGE_DEPOSIT);
        _tokenized().signup(LARGE_DEPOSIT);
        vm.stopPrank();

        vm.startPrank(bob);
        token.approve(address(mechanism), MEDIUM_DEPOSIT);
        _tokenized().signup(MEDIUM_DEPOSIT);
        vm.stopPrank();

        // Create proposals that will be defeated
        vm.prank(alice);
        uint256 pidLowVotes = _tokenized().propose(frank, "Frank's Low Vote Proposal");

        vm.prank(bob);
        uint256 pidNegativeVotes = _tokenized().propose(grace, "Grace's Low Vote Proposal");

        vm.warp(votingStartTime + 1);

        // Proposal 1: Insufficient votes (below quorum)
        vm.prank(alice);
        _tokenized().castVote(pidLowVotes, TokenizedAllocationMechanism.VoteType.For, 10, frank);

        // Proposal 2: Low total votes (below quorum)
        vm.prank(alice);
        _tokenized().castVote(pidNegativeVotes, TokenizedAllocationMechanism.VoteType.For, 15, grace);
        vm.prank(bob);
        _tokenized().castVote(pidNegativeVotes, TokenizedAllocationMechanism.VoteType.For, 10, grace);

        // Finalize voting
        vm.warp(votingEndTime + 1);
        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        // Verify DEFEATED states
        assertEq(
            uint256(_tokenized().state(pidLowVotes)),
            uint256(TokenizedAllocationMechanism.ProposalState.Defeated)
        );
        assertEq(
            uint256(_tokenized().state(pidNegativeVotes)),
            uint256(TokenizedAllocationMechanism.ProposalState.Defeated)
        );

        // Recipients get nothing from defeated proposals
        assertEq(_tokenized().balanceOf(frank), 0);
        assertEq(_tokenized().balanceOf(grace), 0);

        // Cannot queue defeated proposals should revert with NoQuorum
        vm.expectRevert();
        _tokenized().queueProposal(pidLowVotes);

        vm.expectRevert();
        _tokenized().queueProposal(pidNegativeVotes);
    }

    /// @notice Test SUCCEEDED state - proposal meets quorum but not yet queued
    function testProposalState_Succeeded() public {
        // Get absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized().votingDelay();
        uint256 votingPeriod = _tokenized().votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Setup
        vm.startPrank(alice);
        token.approve(address(mechanism), LARGE_DEPOSIT);
        _tokenized().signup(LARGE_DEPOSIT);
        uint256 pid = _tokenized().propose(henry, "Henry's Successful Proposal");
        vm.stopPrank();

        vm.warp(votingStartTime + 1);

        // Vote to meet quorum
        vm.prank(alice);
        _tokenized().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 30, henry);

        vm.warp(votingEndTime + 1);
        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        // Verify SUCCEEDED state
        assertEq(uint256(_tokenized().state(pid)), uint256(TokenizedAllocationMechanism.ProposalState.Succeeded));

        // Recipient knows they will receive allocation but shares not minted yet
        assertEq(_tokenized().balanceOf(henry), 0);

        // Proposal can be queued by admin
        TokenizedAllocationMechanism.Proposal memory proposal = _tokenized().proposals(pid);
        assertFalse(proposal.canceled);

        // Verify vote tallies are correct using getTally() from ProperQF
        (, , uint256 quadraticFunding, uint256 linearFunding) = mechanism.getTally(pid);
        uint256 forVotes = quadraticFunding + linearFunding;
        uint256 againstVotes = 0; // QuadraticVoting only supports For votes
        assertEq(forVotes, 900);
        assertEq(againstVotes, 0);
        assertTrue(forVotes - againstVotes >= QUORUM_REQUIREMENT);
    }

    /// @notice Test QUEUED state - proposal queued with shares minted and timelock active
    function testProposalState_Queued() public {
        // Get absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized().votingDelay();
        uint256 votingPeriod = _tokenized().votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Setup successful proposal
        vm.startPrank(alice);
        token.approve(address(mechanism), LARGE_DEPOSIT);
        _tokenized().signup(LARGE_DEPOSIT);
        uint256 pid = _tokenized().propose(charlie, "Charlie's Queued Proposal");
        vm.stopPrank();

        vm.warp(votingStartTime + 1);

        vm.prank(alice);
        _tokenized().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 30, charlie);

        vm.warp(votingEndTime + 1);
        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        // Queue the proposal
        uint256 timestampBefore = block.timestamp;
        (bool success2, ) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pid));
        require(success2, "Queue failed");

        // Verify QUEUED state
        assertEq(uint256(_tokenized().state(pid)), uint256(TokenizedAllocationMechanism.ProposalState.Queued));

        // Recipient receives shares but cannot redeem yet due to timelock
        uint256 expectedShares = 900;
        assertEq(_tokenized().balanceOf(charlie), expectedShares);
        assertEq(_tokenized().proposalShares(pid), expectedShares);

        // Timelock is active
        uint256 globalRedemptionStart = _tokenized().globalRedemptionStart();
        assertEq(globalRedemptionStart, timestampBefore + TIMELOCK_DELAY);
        assertEq(_tokenized().globalRedemptionStart(), globalRedemptionStart);

        // Cannot redeem during timelock
        vm.expectRevert("Allocation: redeem more than max");
        vm.prank(charlie);
        _tokenized().redeem(expectedShares, charlie, charlie);

        // Cannot queue again
        vm.expectRevert(TokenizedAllocationMechanism.AlreadyQueued.selector);
        (bool success3, ) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pid));
        assertFalse(success3);
    }

    /// @notice Test share redemption after timelock - proposal remains in Queued state
    function testProposalState_ShareRedemption() public {
        // Get absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized().votingDelay();
        uint256 votingPeriod = _tokenized().votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Setup and execute successful proposal
        vm.startPrank(alice);
        token.approve(address(mechanism), LARGE_DEPOSIT);
        _tokenized().signup(LARGE_DEPOSIT);
        uint256 pid = _tokenized().propose(dave, "Dave's Executed Proposal");
        vm.stopPrank();

        vm.warp(votingStartTime + 1);

        vm.prank(alice);
        _tokenized().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 30, dave);

        vm.warp(votingEndTime + 1);
        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        (bool success2, ) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pid));
        require(success2, "Queue failed");

        // Fast forward past timelock
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        // Recipient redeems shares
        uint256 expectedShares = 900;
        uint256 daveTokensBefore = token.balanceOf(dave);

        vm.prank(dave);
        uint256 assetsReceived = _tokenized().redeem(expectedShares, dave, dave);

        // After redemption, the proposal remains in Queued state
        // The state logic checks for shares balance and redeemable time

        // Verify redemption effects
        assertEq(_tokenized().balanceOf(dave), 0);
        assertEq(token.balanceOf(dave), daveTokensBefore + assetsReceived);

        // With matching pool: total assets = 1000 (alice) + 2000 (matching pool) = 3000 ether
        // 900 shares out of 900 total shares = 100% of 3000 ether = 3000 ether
        uint256 expectedAssets = 3000 ether;
        assertEq(assetsReceived, expectedAssets);

        // During redemption period, proposals with shares are in REDEEMABLE state
        assertEq(uint256(_tokenized().state(pid)), uint256(TokenizedAllocationMechanism.ProposalState.Redeemable));
    }

    /// @notice Test EXPIRED state - proposal queued but grace period exceeded
    function testProposalState_Expired() public {
        // Get absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized().votingDelay();
        uint256 votingPeriod = _tokenized().votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Setup proposal that will expire
        vm.startPrank(alice);
        token.approve(address(mechanism), LARGE_DEPOSIT);
        _tokenized().signup(LARGE_DEPOSIT);
        uint256 pid = _tokenized().propose(eve, "Eve's Expired Proposal");
        vm.stopPrank();

        vm.warp(votingStartTime + 1);

        vm.prank(alice);
        _tokenized().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 30, eve);

        vm.warp(votingEndTime + 1);
        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        (bool success2, ) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pid));
        require(success2, "Queue failed");

        // Fast forward past timelock + grace period
        vm.warp(block.timestamp + TIMELOCK_DELAY + GRACE_PERIOD + 1);

        // Verify EXPIRED state
        assertEq(uint256(_tokenized().state(pid)), uint256(TokenizedAllocationMechanism.ProposalState.Expired));

        // Recipient still has shares but cannot redeem (expired)
        assertEq(_tokenized().balanceOf(eve), 900);

        // Redemption should fail due to expiration
        vm.expectRevert("Allocation: redeem more than max");
        vm.prank(eve);
        _tokenized().redeem(900, eve, eve);
    }

    /// @notice Test complete recipient journey through multiple proposal states
    function testRecipientJourney_MultipleProposalStates() public {
        // Get absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized().votingDelay();
        uint256 votingPeriod = _tokenized().votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Setup multiple voters
        vm.startPrank(alice);
        token.approve(address(mechanism), LARGE_DEPOSIT);
        _tokenized().signup(LARGE_DEPOSIT);
        vm.stopPrank();

        vm.startPrank(bob);
        token.approve(address(mechanism), MEDIUM_DEPOSIT);
        _tokenized().signup(MEDIUM_DEPOSIT);
        vm.stopPrank();

        // Before voting starts (still in delay period) - warp before creating proposals
        vm.warp(deploymentTime + 10);

        // Create proposals that will have different outcomes
        vm.prank(alice);
        uint256 pidSuccessful = _tokenized().propose(charlie, "Charlie's Success Story");

        vm.prank(bob);
        uint256 pidDefeated = _tokenized().propose(dave, "Dave's Defeat");

        vm.prank(alice);
        uint256 pidCanceled = _tokenized().propose(eve, "Eve's Cancellation");

        // Start with all in PENDING
        assertEq(
            uint256(_tokenized().state(pidSuccessful)),
            uint256(TokenizedAllocationMechanism.ProposalState.Pending)
        );
        assertEq(uint256(_tokenized().state(pidDefeated)), uint256(TokenizedAllocationMechanism.ProposalState.Pending));
        assertEq(uint256(_tokenized().state(pidCanceled)), uint256(TokenizedAllocationMechanism.ProposalState.Pending));

        // Move to ACTIVE
        vm.warp(votingStartTime + 1);
        assertEq(
            uint256(_tokenized().state(pidSuccessful)),
            uint256(TokenizedAllocationMechanism.ProposalState.Active)
        );
        assertEq(uint256(_tokenized().state(pidDefeated)), uint256(TokenizedAllocationMechanism.ProposalState.Active));
        assertEq(uint256(_tokenized().state(pidCanceled)), uint256(TokenizedAllocationMechanism.ProposalState.Active));

        // Cancel one proposal
        vm.prank(alice);
        _tokenized().cancelProposal(pidCanceled);
        assertEq(
            uint256(_tokenized().state(pidCanceled)),
            uint256(TokenizedAllocationMechanism.ProposalState.Canceled)
        );

        // Vote on remaining proposals
        vm.prank(alice);
        _tokenized().castVote(pidSuccessful, TokenizedAllocationMechanism.VoteType.For, 30, charlie);

        vm.prank(bob);
        _tokenized().castVote(pidDefeated, TokenizedAllocationMechanism.VoteType.For, 10, dave); // Below quorum

        // Finalize
        vm.warp(votingEndTime + 1);
        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        // Check final states
        assertEq(
            uint256(_tokenized().state(pidSuccessful)),
            uint256(TokenizedAllocationMechanism.ProposalState.Succeeded)
        );
        assertEq(
            uint256(_tokenized().state(pidDefeated)),
            uint256(TokenizedAllocationMechanism.ProposalState.Defeated)
        );
        assertEq(
            uint256(_tokenized().state(pidCanceled)),
            uint256(TokenizedAllocationMechanism.ProposalState.Canceled)
        );

        // Queue successful proposal
        (bool success2, ) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pidSuccessful));
        require(success2, "Queue failed");

        assertEq(
            uint256(_tokenized().state(pidSuccessful)),
            uint256(TokenizedAllocationMechanism.ProposalState.Queued)
        );

        // Verify recipient outcomes
        assertEq(_tokenized().balanceOf(charlie), 900); // Success
        assertEq(_tokenized().balanceOf(dave), 0); // Defeated
        assertEq(_tokenized().balanceOf(eve), 0); // Canceled

        // Fast forward and redeem
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        vm.prank(charlie);
        uint256 charlieAssets = _tokenized().redeem(900, charlie, charlie);

        // With matching pool: total assets = 1500 (alice + bob) + 2000 (matching pool) = 3500 ether
        // 900 shares out of 900 total shares = 100% of 3500 ether = 3500 ether
        uint256 expectedAssets = 3500 ether;
        assertEq(charlieAssets, expectedAssets);

        // Final verification: Charlie got paid, others didn't
        assertGt(token.balanceOf(charlie), 0);
        assertEq(token.balanceOf(dave), 0);
        assertEq(token.balanceOf(eve), 0);
    }
}
