// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/console.sol";
import { TokenizedAllocationMechanism } from "src/mechanisms/TokenizedAllocationMechanism.sol";
import { QuadraticVotingMechanism } from "src/mechanisms/mechanism/QuadraticVotingMechanism.sol";
import { QuadraticVotingTestBase } from "../utils/QuadraticVotingTestBase.sol";

/// @title Voter Journey Integration Tests
/// @notice Comprehensive tests for voter user journey with full branch coverage
contract QuadraticVotingVoterJourneyTest is QuadraticVotingTestBase {
    uint256 constant LARGE_DEPOSIT = 1000 ether;
    uint256 constant MEDIUM_DEPOSIT = 500 ether;
    uint256 constant SMALL_DEPOSIT = 100 ether;
    uint256 constant QUORUM_REQUIREMENT = 500;
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;

    function setUp() public {
        _setUpQuadraticVoting(
            "Voter Journey Test",
            "VJTEST",
            VOTING_DELAY,
            VOTING_PERIOD,
            QUORUM_REQUIREMENT,
            1 days,
            7 days,
            50,
            100
        );

        // Mint tokens to test actors
        token.mint(alice, 2000 ether);
        token.mint(bob, 1500 ether);
        token.mint(frank, 200 ether);
        token.mint(grace, 50 ether);
        token.mint(henry, 300 ether);
        _setRoles(alice, bob);
    }

    /// @notice Test voter registration with various deposit amounts
    function testVoterRegistration_VariousDeposits() public {
        // Use absolute timeline pattern
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized().votingDelay();
        uint256 votingStartTime = deploymentTime + votingDelay;

        // Warp to just before voting starts (signup period)
        vm.warp(votingStartTime - 1);

        // Large deposit registration
        _signupUser(alice, LARGE_DEPOSIT);
        assertEq(_tokenized().votingPower(alice), LARGE_DEPOSIT);
        assertEq(token.balanceOf(alice), 2000 ether - LARGE_DEPOSIT);

        // Medium deposit registration
        _signupUser(bob, MEDIUM_DEPOSIT);
        assertEq(_tokenized().votingPower(bob), MEDIUM_DEPOSIT);

        // Zero deposit registration
        _signupUser(grace, 0);
        assertEq(_tokenized().votingPower(grace), 0);

        // Small deposit registration
        _signupUser(frank, SMALL_DEPOSIT);
        assertEq(_tokenized().votingPower(frank), SMALL_DEPOSIT);

        // Verify total mechanism balance
        assertEq(token.balanceOf(address(mechanism)), LARGE_DEPOSIT + MEDIUM_DEPOSIT + SMALL_DEPOSIT);
    }

    /// @notice Test voter registration edge cases
    function testVoterRegistration_EdgeCases() public {
        // Use absolute timeline pattern
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized().votingDelay();
        uint256 votingPeriod = _tokenized().votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Warp to just before voting starts (signup period)
        vm.warp(votingStartTime - 1);

        // Register alice first
        _signupUser(alice, LARGE_DEPOSIT);

        // Can register multiple times in QuadraticVotingMechanism (accumulates voting power)
        uint256 alicePowerBefore = _tokenized().votingPower(alice);
        vm.startPrank(alice);
        token.approve(address(mechanism), SMALL_DEPOSIT);
        _tokenized().signup(SMALL_DEPOSIT);
        vm.stopPrank();

        // Verify voting power accumulated
        uint256 alicePowerAfter = _tokenized().votingPower(alice);
        assertEq(alicePowerAfter, alicePowerBefore + SMALL_DEPOSIT, "Multiple signups should accumulate voting power");

        // Cannot register after voting period ends
        vm.warp(votingEndTime + 1);
        vm.startPrank(henry);
        token.approve(address(mechanism), MEDIUM_DEPOSIT);
        vm.expectRevert();
        _tokenized().signup(MEDIUM_DEPOSIT);
        vm.stopPrank();

        // Can register at the last valid moment
        vm.warp(votingEndTime - 1);
        _signupUser(bob, MEDIUM_DEPOSIT);

        assertEq(_tokenized().votingPower(bob), MEDIUM_DEPOSIT);
    }

    /// @notice Test comprehensive voting patterns
    function testVotingPatterns_Comprehensive() public {
        // Use absolute timeline pattern
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized().votingDelay();
        uint256 votingStartTime = deploymentTime + votingDelay;

        // Warp to just before voting starts (signup period)
        vm.warp(votingStartTime - 1);

        // Register voters
        _signupUser(alice, LARGE_DEPOSIT);
        _signupUser(bob, MEDIUM_DEPOSIT);
        _signupUser(frank, SMALL_DEPOSIT);

        // Create proposals
        uint256 pid1 = _createProposal(alice, charlie, "Fund Charlie's Project");
        uint256 pid2 = _createProposal(bob, dave, "Fund Dave's Project");

        // Warp to voting period
        vm.warp(votingStartTime + 1);

        // Quadratic voting - cost is weight^2
        // Alice votes with weight 31, cost = 31^2 = 961 voting power
        (uint256 alicePrevPower, uint256 aliceNewPower) = _castVote(alice, pid1, 31, charlie);

        assertEq(alicePrevPower - aliceNewPower, 31 * 31, "Alice should have spent 961 voting power");
        assertEq(aliceNewPower, LARGE_DEPOSIT - (31 * 31));
        assertTrue(mechanism.hasVoted(pid1, alice));

        // Bob votes with weight 10, cost = 10^2 = 100 voting power
        _castVote(bob, pid1, 10, charlie);
        assertEq(_tokenized().votingPower(bob), MEDIUM_DEPOSIT - (10 * 10));

        // Bob votes again with weight 15, cost = 15^2 = 225 voting power
        _castVote(bob, pid2, 15, dave);
        assertEq(_tokenized().votingPower(bob), MEDIUM_DEPOSIT - 100 - 225);

        // Frank votes with weight 5, cost = 5^2 = 25 voting power
        _castVote(frank, pid2, 5, dave);
        assertEq(_tokenized().votingPower(frank), SMALL_DEPOSIT - 25);

        // Note: QuadraticVoting uses ProperQF tallying, not simple vote counts
        // The actual funding calculation will be done during shares conversion
    }

    /// @notice Test voting error conditions
    function testVoting_ErrorConditions() public {
        // Use absolute timeline pattern
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized().votingDelay();
        uint256 votingPeriod = _tokenized().votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Warp to just before voting starts (signup period)
        vm.warp(votingStartTime - 1);

        _signupUser(alice, LARGE_DEPOSIT);
        uint256 pid = _createProposal(alice, charlie, "Test Proposal");

        // Cannot vote before voting period
        vm.warp(votingStartTime - 50);
        vm.expectRevert();
        vm.prank(alice);
        _tokenized().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 8, charlie);

        // Warp to voting period
        vm.warp(votingStartTime + 1);

        // Cannot vote with more power than available
        vm.expectRevert();
        vm.prank(alice);
        _tokenized().castVote(pid, TokenizedAllocationMechanism.VoteType.For, LARGE_DEPOSIT + 1, charlie);

        // Cannot vote twice
        _castVote(alice, pid, 8, charlie);

        vm.expectRevert(abi.encodeWithSelector(QuadraticVotingMechanism.AlreadyVoted.selector, alice, pid));
        vm.prank(alice);
        _tokenized().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 10, charlie);

        // Cannot vote after voting period
        vm.warp(votingEndTime + 1);
        vm.expectRevert();
        vm.prank(alice);
        _tokenized().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 8, charlie);

        // Unregistered user cannot vote
        vm.warp(votingStartTime + 500);
        vm.expectRevert();
        vm.prank(henry);
        _tokenized().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 1, charlie);
    }

    /// @notice Test voter power conservation and management
    function testVoterPower_ConservationAndManagement() public {
        // Use absolute timeline pattern
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized().votingDelay();
        uint256 votingStartTime = deploymentTime + votingDelay;

        // Warp to just before voting starts (signup period)
        vm.warp(votingStartTime - 1);

        _signupUser(alice, LARGE_DEPOSIT);

        uint256 pid1 = _createProposal(alice, charlie, "Proposal 1");
        uint256 pid2 = _createProposal(alice, dave, "Proposal 2");

        // Warp to voting period
        vm.warp(votingStartTime + 1);

        // Track power consumption across multiple votes
        uint256 initialPower = _tokenized().votingPower(alice);
        assertEq(initialPower, LARGE_DEPOSIT);

        // First vote - quadratic cost: 10^2 = 100
        uint256 vote1Weight = 10;
        (uint256 prevPower1, uint256 newPower1) = _castVote(alice, pid1, vote1Weight, charlie);

        assertEq(prevPower1, initialPower, "Initial power should match");
        assertEq(newPower1, initialPower - (vote1Weight * vote1Weight), "Power consumed correctly");

        // Second vote with remaining power
        uint256 vote2Weight = 10; // Quadratic cost: 10^2 = 100
        _castVote(alice, pid2, vote2Weight, dave);

        uint256 powerAfterVote2 = _tokenized().votingPower(alice);
        assertEq(powerAfterVote2, initialPower - (vote1Weight * vote1Weight) - (vote2Weight * vote2Weight));
        assertEq(powerAfterVote2, 1000 ether - (10 * 10) - (10 * 10)); // 1000 ether - 200 voting power units

        // Verify vote records
        assertTrue(mechanism.hasVoted(pid1, alice));
        assertTrue(mechanism.hasVoted(pid2, alice));
        assertEq(_tokenized().votingPower(alice), 1000 ether - 200);
    }
}
