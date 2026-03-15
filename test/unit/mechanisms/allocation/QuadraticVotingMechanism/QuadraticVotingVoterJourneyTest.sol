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

/// @title Voter Journey Integration Tests
/// @notice Comprehensive tests for voter user journey with full branch coverage
contract QuadraticVotingVoterJourneyTest is Test {
    AllocationMechanismFactory factory;
    ERC20Mock token;
    QuadraticVotingMechanism mechanism;

    address alice = address(0x1);
    address bob = address(0x2);
    address charlie = address(0x3);
    address dave = address(0x4);
    address frank = address(0x6);
    address grace = address(0x7);
    address henry = address(0x8);

    uint256 constant W = 65536; // weight multiplier so weight^2 >= 2^32 (shift=32 quantization)
    uint256 constant LARGE_DEPOSIT = 1000 ether;
    uint256 constant MEDIUM_DEPOSIT = 500 ether;
    uint256 constant SMALL_DEPOSIT = 100 ether;
    uint256 constant QUORUM_REQUIREMENT = 500;
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;

    function _tokenized(address _mechanism) internal pure returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(_mechanism);
    }

    /// @notice Helper function to sign up a user with specified deposit
    /// @param user Address of user to sign up
    /// @param depositAmount Amount of tokens to deposit
    function _signupUser(address user, uint256 depositAmount) internal {
        vm.startPrank(user);
        token.approve(address(mechanism), depositAmount);
        _tokenized(address(mechanism)).signup(depositAmount);
        vm.stopPrank();
    }

    /// @notice Helper function to create a proposal
    /// @param proposer Address creating the proposal
    /// @param recipient Address that will receive funds if proposal passes
    /// @param description Description of the proposal
    /// @return pid The proposal ID
    function _createProposal(
        address proposer,
        address recipient,
        string memory description
    ) internal returns (uint256 pid) {
        vm.prank(proposer);
        pid = _tokenized(address(mechanism)).propose(recipient, description);
    }

    /// @notice Helper function to cast a vote on a proposal
    /// @param voter Address casting the vote
    /// @param pid Proposal ID to vote on
    /// @param weight Vote weight (quadratic cost = weight^2)
    /// @return previousPower Voting power before the vote
    /// @return newPower Voting power after the vote
    function _castVote(
        address voter,
        uint256 pid,
        uint256 weight,
        address recipient
    ) internal returns (uint256 previousPower, uint256 newPower) {
        previousPower = _tokenized(address(mechanism)).votingPower(voter);
        vm.prank(voter);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, weight, recipient);
        newPower = _tokenized(address(mechanism)).votingPower(voter);
    }

    function setUp() public {
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();

        // Mint tokens to test actors
        token.mint(alice, 2000 ether);
        token.mint(bob, 1500 ether);
        token.mint(frank, 200 ether);
        token.mint(grace, 50 ether);
        token.mint(henry, 300 ether);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Voter Journey Test",
            symbol: "VJTEST",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: QUORUM_REQUIREMENT,
            timelockDelay: 1 days,
            gracePeriod: 7 days,
            owner: address(0)
        });

        address mechanismAddr = factory.deployQuadraticVotingMechanism(config, 50, 100); // 50% alpha
        mechanism = QuadraticVotingMechanism(payable(mechanismAddr));
        _tokenized(address(mechanism)).setKeeper(alice);
        _tokenized(address(mechanism)).setManagement(bob);
    }

    /// @notice Test voter registration with various deposit amounts
    function testVoterRegistration_VariousDeposits() public {
        // Use absolute timeline pattern
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingStartTime = deploymentTime + votingDelay;

        // Warp to just before voting starts (signup period)
        vm.warp(votingStartTime - 1);

        // Large deposit registration
        _signupUser(alice, LARGE_DEPOSIT);
        assertEq(_tokenized(address(mechanism)).votingPower(alice), LARGE_DEPOSIT);
        assertEq(token.balanceOf(alice), 2000 ether - LARGE_DEPOSIT);

        // Medium deposit registration
        _signupUser(bob, MEDIUM_DEPOSIT);
        assertEq(_tokenized(address(mechanism)).votingPower(bob), MEDIUM_DEPOSIT);

        // Zero deposit registration
        _signupUser(grace, 0);
        assertEq(_tokenized(address(mechanism)).votingPower(grace), 0);

        // Small deposit registration
        _signupUser(frank, SMALL_DEPOSIT);
        assertEq(_tokenized(address(mechanism)).votingPower(frank), SMALL_DEPOSIT);

        // Verify total mechanism balance
        assertEq(token.balanceOf(address(mechanism)), LARGE_DEPOSIT + MEDIUM_DEPOSIT + SMALL_DEPOSIT);
    }

    /// @notice Test voter registration edge cases
    function testVoterRegistration_EdgeCases() public {
        // Use absolute timeline pattern
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingPeriod = _tokenized(address(mechanism)).votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Warp to just before voting starts (signup period)
        vm.warp(votingStartTime - 1);

        // Register alice first
        _signupUser(alice, LARGE_DEPOSIT);

        // Can register multiple times in QuadraticVotingMechanism (accumulates voting power)
        uint256 alicePowerBefore = _tokenized(address(mechanism)).votingPower(alice);
        vm.startPrank(alice);
        token.approve(address(mechanism), SMALL_DEPOSIT);
        _tokenized(address(mechanism)).signup(SMALL_DEPOSIT);
        vm.stopPrank();

        // Verify voting power accumulated
        uint256 alicePowerAfter = _tokenized(address(mechanism)).votingPower(alice);
        assertEq(alicePowerAfter, alicePowerBefore + SMALL_DEPOSIT, "Multiple signups should accumulate voting power");

        // Cannot register after voting period ends
        vm.warp(votingEndTime + 1);
        vm.startPrank(henry);
        token.approve(address(mechanism), MEDIUM_DEPOSIT);
        vm.expectRevert();
        _tokenized(address(mechanism)).signup(MEDIUM_DEPOSIT);
        vm.stopPrank();

        // Can register at the last valid moment
        vm.warp(votingEndTime - 1);
        _signupUser(bob, MEDIUM_DEPOSIT);

        assertEq(_tokenized(address(mechanism)).votingPower(bob), MEDIUM_DEPOSIT);
    }

    /// @notice Test comprehensive voting patterns
    function testVotingPatterns_Comprehensive() public {
        // Use absolute timeline pattern
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
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
        // Alice votes with weight 31*W, cost = (31*W)^2 = 961*W^2 voting power
        (uint256 alicePrevPower, uint256 aliceNewPower) = _castVote(alice, pid1, 31 * W, charlie);

        assertEq(alicePrevPower - aliceNewPower, 31 * W * 31 * W, "Alice should have spent 961*W*W voting power");
        assertEq(aliceNewPower, LARGE_DEPOSIT - (31 * W * 31 * W));
        assertTrue(mechanism.hasVoted(pid1, alice));

        // Bob votes with weight 10*W, cost = (10*W)^2 = 100*W^2 voting power
        _castVote(bob, pid1, 10 * W, charlie);
        assertEq(_tokenized(address(mechanism)).votingPower(bob), MEDIUM_DEPOSIT - (10 * W * 10 * W));

        // Bob votes again with weight 15*W, cost = (15*W)^2 = 225*W^2 voting power
        _castVote(bob, pid2, 15 * W, dave);
        assertEq(
            _tokenized(address(mechanism)).votingPower(bob),
            MEDIUM_DEPOSIT - (10 * W * 10 * W) - (15 * W * 15 * W)
        );

        // Frank votes with weight 5*W, cost = (5*W)^2 = 25*W^2 voting power
        _castVote(frank, pid2, 5 * W, dave);
        assertEq(_tokenized(address(mechanism)).votingPower(frank), SMALL_DEPOSIT - (5 * W * 5 * W));

        // Note: QuadraticVoting uses ProperQF tallying, not simple vote counts
        // The actual funding calculation will be done during shares conversion
    }

    /// @notice Test voting error conditions
    function testVoting_ErrorConditions() public {
        // Use absolute timeline pattern
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingPeriod = _tokenized(address(mechanism)).votingPeriod();
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
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, 8 * W, charlie);

        // Warp to voting period
        vm.warp(votingStartTime + 1);

        // Cannot vote with more power than available
        vm.expectRevert();
        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(
            pid,
            TokenizedAllocationMechanism.VoteType.For,
            LARGE_DEPOSIT + 1,
            charlie
        );

        // Cannot vote twice
        _castVote(alice, pid, 8 * W, charlie);

        vm.expectRevert(abi.encodeWithSelector(QuadraticVotingMechanism.AlreadyVoted.selector, alice, pid));
        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, 10 * W, charlie);

        // Cannot vote after voting period
        vm.warp(votingEndTime + 1);
        vm.expectRevert();
        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, 8 * W, charlie);

        // Unregistered user cannot vote
        vm.warp(votingStartTime + 500);
        vm.expectRevert();
        vm.prank(henry);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, 1 * W, charlie);
    }

    /// @notice Test voter power conservation and management
    function testVoterPower_ConservationAndManagement() public {
        // Use absolute timeline pattern
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingStartTime = deploymentTime + votingDelay;

        // Warp to just before voting starts (signup period)
        vm.warp(votingStartTime - 1);

        _signupUser(alice, LARGE_DEPOSIT);

        uint256 pid1 = _createProposal(alice, charlie, "Proposal 1");
        uint256 pid2 = _createProposal(alice, dave, "Proposal 2");

        // Warp to voting period
        vm.warp(votingStartTime + 1);

        // Track power consumption across multiple votes
        uint256 initialPower = _tokenized(address(mechanism)).votingPower(alice);
        assertEq(initialPower, LARGE_DEPOSIT);

        // First vote - quadratic cost: (10*W)^2 = 100*W^2
        uint256 vote1Weight = 10 * W;
        (uint256 prevPower1, uint256 newPower1) = _castVote(alice, pid1, vote1Weight, charlie);

        assertEq(prevPower1, initialPower, "Initial power should match");
        assertEq(newPower1, initialPower - (vote1Weight * vote1Weight), "Power consumed correctly");

        // Second vote with remaining power
        uint256 vote2Weight = 10 * W; // Quadratic cost: (10*W)^2 = 100*W^2
        _castVote(alice, pid2, vote2Weight, dave);

        uint256 powerAfterVote2 = _tokenized(address(mechanism)).votingPower(alice);
        assertEq(powerAfterVote2, initialPower - (vote1Weight * vote1Weight) - (vote2Weight * vote2Weight));
        uint256 expectedCost = (10 * W * 10 * W) + (10 * W * 10 * W);
        assertEq(powerAfterVote2, 1000 ether - expectedCost);

        // Verify vote records
        assertTrue(mechanism.hasVoted(pid1, alice));
        assertTrue(mechanism.hasVoted(pid2, alice));
        assertEq(_tokenized(address(mechanism)).votingPower(alice), 1000 ether - expectedCost);
    }
}
