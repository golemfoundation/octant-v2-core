// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { TokenizedAllocationMechanism } from "src/mechanisms/TokenizedAllocationMechanism.sol";
import { QuadraticVotingMechanism } from "src/mechanisms/mechanism/QuadraticVotingMechanism.sol";
import { QuadraticVotingTestBase } from "./utils/QuadraticVotingTestBase.sol";

/// @title Recipient Verification Tests
/// @notice Tests for recipient verification functionality that prevents reorganization attacks
/// @dev Tests the core security feature that validates expected recipients match proposal recipients
contract RecipientVerificationTest is QuadraticVotingTestBase {
    // Recipients for proposals
    address recipientA = address(0x100);
    address recipientB = address(0x200);
    address recipientC = address(0x300);

    // Test parameters
    uint256 constant INITIAL_BALANCE = 10000 ether;
    uint256 constant DEPOSIT_AMOUNT = 1000 ether;
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;
    uint256 constant QUORUM_SHARES = 100 ether;

    function setUp() public {
        _setUpQuadraticVoting(
            "Recipient Verification Test",
            "RVTEST",
            VOTING_DELAY,
            VOTING_PERIOD,
            QUORUM_SHARES,
            1 days,
            7 days,
            50,
            100
        );

        // Fund test accounts
        token.mint(alice, INITIAL_BALANCE);
        token.mint(bob, INITIAL_BALANCE);
        token.mint(charlie, INITIAL_BALANCE);
    }

    // ============ Core Recipient Verification Tests ============

    /// @notice Test basic recipient mismatch - voting with wrong expected recipient should fail
    function test_BasicRecipientMismatch_ShouldRevert() public {
        _signupUser(alice, DEPOSIT_AMOUNT);

        uint256 pid = _createProposal(recipientA, "Fund Recipient A");
        _moveToVotingPeriod();

        // Try to vote expecting recipient B when proposal is for recipient A
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenizedAllocationMechanism.RecipientMismatch.selector,
                pid,
                recipientB, // expected
                recipientA // actual
            )
        );
        vm.prank(alice);
        _tokenized().castVote(
            pid,
            TokenizedAllocationMechanism.VoteType.For,
            10, // Small weight to minimize cost
            recipientB // Wrong recipient - should cause mismatch
        );
    }

    /// @notice Test valid recipient - voting with correct expected recipient should succeed
    function test_ValidRecipient_ShouldSucceed() public {
        _signupUser(alice, DEPOSIT_AMOUNT);

        uint256 pid = _createProposal(recipientA, "Fund Recipient A");
        _moveToVotingPeriod();

        uint256 alicePowerBefore = _tokenized().votingPower(alice);

        // Vote with correct expected recipient - should succeed
        vm.prank(alice);
        _tokenized().castVote(
            pid,
            TokenizedAllocationMechanism.VoteType.For,
            10, // weight=10, cost=100 (quadratic)
            recipientA // Correct recipient - should succeed
        );

        // Verify vote was recorded successfully
        uint256 alicePowerAfter = _tokenized().votingPower(alice);
        assertEq(
            alicePowerBefore - alicePowerAfter,
            100,
            "Voting power should be reduced by quadratic cost (10^2=100)"
        );
    }

    /// @notice Test multiple proposals with different recipients
    function test_MultipleProposals_DifferentRecipients() public {
        _signupUser(alice, DEPOSIT_AMOUNT);
        _signupUser(bob, DEPOSIT_AMOUNT);

        // Create two proposals with different recipients
        uint256 pid1 = _createProposal(recipientA, "Fund Recipient A");
        uint256 pid2 = _createProposal(recipientB, "Fund Recipient B");
        _moveToVotingPeriod();

        // Vote on proposal 1 expecting recipient A - should succeed
        vm.prank(alice);
        _tokenized().castVote(pid1, TokenizedAllocationMechanism.VoteType.For, 10, recipientA);

        // Try to vote on proposal 1 expecting recipient B - should fail
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenizedAllocationMechanism.RecipientMismatch.selector,
                pid1,
                recipientB, // expected
                recipientA // actual
            )
        );
        vm.prank(bob);
        _tokenized().castVote(pid1, TokenizedAllocationMechanism.VoteType.For, 10, recipientB);

        // Vote on proposal 2 expecting recipient B - should succeed
        vm.prank(bob);
        _tokenized().castVote(pid2, TokenizedAllocationMechanism.VoteType.For, 10, recipientB);

        // Verify final voting powers (cost = weight^2)
        assertEq(_tokenized().votingPower(alice), DEPOSIT_AMOUNT - 100); // 10^2
        assertEq(_tokenized().votingPower(bob), DEPOSIT_AMOUNT - 100); // 10^2
    }

    /// @notice Test recipient verification across multiple proposals
    function test_CrossProposalRecipientConfusion() public {
        _signupUser(alice, DEPOSIT_AMOUNT);
        _signupUser(bob, DEPOSIT_AMOUNT);
        _signupUser(charlie, DEPOSIT_AMOUNT);

        // Create three proposals with different recipients
        uint256 pid1 = _createProposal(recipientA, "Project A");
        uint256 pid2 = _createProposal(recipientB, "Project B");
        uint256 pid3 = _createProposal(recipientC, "Project C");
        _moveToVotingPeriod();

        // Try to vote on pid1 expecting recipientB (from pid2) - should fail
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenizedAllocationMechanism.RecipientMismatch.selector,
                pid1,
                recipientB,
                recipientA
            )
        );
        vm.prank(alice);
        _tokenized().castVote(pid1, TokenizedAllocationMechanism.VoteType.For, 10, recipientB);

        // Try to vote on pid2 expecting recipientC (from pid3) - should fail
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenizedAllocationMechanism.RecipientMismatch.selector,
                pid2,
                recipientC,
                recipientB
            )
        );
        vm.prank(bob);
        _tokenized().castVote(pid2, TokenizedAllocationMechanism.VoteType.For, 10, recipientC);

        // Now vote correctly on all proposals
        vm.prank(alice);
        _tokenized().castVote(pid1, TokenizedAllocationMechanism.VoteType.For, 10, recipientA);

        vm.prank(bob);
        _tokenized().castVote(pid2, TokenizedAllocationMechanism.VoteType.For, 10, recipientB);

        vm.prank(charlie);
        _tokenized().castVote(pid3, TokenizedAllocationMechanism.VoteType.For, 10, recipientC);

        // Verify all votes were recorded (cost = weight^2)
        assertEq(_tokenized().votingPower(alice), DEPOSIT_AMOUNT - 100); // 10^2
        assertEq(_tokenized().votingPower(bob), DEPOSIT_AMOUNT - 100); // 10^2
        assertEq(_tokenized().votingPower(charlie), DEPOSIT_AMOUNT - 100); // 10^2
    }

    // ============ Edge Cases and Security Tests ============

    /// @notice Test recipient verification with zero address (blocked at proposal creation)
    function test_RecipientVerification_ZeroAddress() public {
        _signupUser(alice, DEPOSIT_AMOUNT);

        // Try to create proposal with zero address - should fail at creation
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.InvalidRecipient.selector, address(0)));
        vm.prank(address(this)); // Keeper/management role
        _tokenized().propose(address(0), "Invalid proposal");
    }

    /// @notice Test recipient verification with contract address (blocked at proposal creation)
    function test_RecipientVerification_ContractAddress() public {
        _signupUser(alice, DEPOSIT_AMOUNT);

        // Try to create proposal with mechanism as recipient - should fail
        vm.expectRevert(
            abi.encodeWithSelector(TokenizedAllocationMechanism.InvalidRecipient.selector, address(mechanism))
        );
        vm.prank(address(this)); // Keeper/management role
        _tokenized().propose(address(mechanism), "Self-proposal");
    }

    /// @notice Test recipient verification preserves error message format
    function test_RecipientMismatchErrorFormat() public {
        _signupUser(alice, DEPOSIT_AMOUNT);
        uint256 pid = _createProposal(recipientA, "Test error format");
        _moveToVotingPeriod();

        // Capture the exact error and verify its format
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenizedAllocationMechanism.RecipientMismatch.selector,
                pid, // proposalId
                recipientB, // expected recipient
                recipientA // actual recipient
            )
        );
        vm.prank(alice);
        _tokenized().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 10, recipientB);
    }

    /// @notice Test that only For votes are supported in QuadraticVoting
    function test_QuadraticVotingConstraints() public {
        _signupUser(alice, DEPOSIT_AMOUNT);
        uint256 pid = _createProposal(recipientA, "Test constraints");
        _moveToVotingPeriod();

        // For vote with correct recipient should work
        vm.prank(alice);
        _tokenized().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 10, recipientA);

        // Against vote should fail due to QuadraticVoting constraints
        vm.expectRevert(abi.encodeWithSelector(QuadraticVotingMechanism.OnlyForVotesSupported.selector));
        vm.prank(alice);
        _tokenized().castVote(pid, TokenizedAllocationMechanism.VoteType.Against, 5, recipientA);
    }

    /// @notice Comprehensive end-to-end test with multiple users and proposals
    function test_E2E_RecipientVerification() public {
        // Setup multiple users
        _signupUser(alice, DEPOSIT_AMOUNT);
        _signupUser(bob, DEPOSIT_AMOUNT);
        _signupUser(charlie, DEPOSIT_AMOUNT);

        // Create multiple proposals
        uint256 pid1 = _createProposal(recipientA, "Project for Recipient A");
        uint256 pid2 = _createProposal(recipientB, "Project for Recipient B");
        uint256 pid3 = _createProposal(recipientC, "Project for Recipient C");

        _moveToVotingPeriod();

        // Successful votes with correct recipients
        vm.prank(alice);
        _tokenized().castVote(pid1, TokenizedAllocationMechanism.VoteType.For, 10, recipientA);

        vm.prank(bob);
        _tokenized().castVote(pid2, TokenizedAllocationMechanism.VoteType.For, 10, recipientB);

        vm.prank(charlie);
        _tokenized().castVote(pid3, TokenizedAllocationMechanism.VoteType.For, 10, recipientC);

        // Test failed vote with wrong recipient - use different user to avoid "already voted" error
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenizedAllocationMechanism.RecipientMismatch.selector,
                pid1,
                recipientB,
                recipientA
            )
        );
        vm.prank(bob); // Bob hasn't voted on pid1 yet, so this tests recipient mismatch specifically
        _tokenized().castVote(pid1, TokenizedAllocationMechanism.VoteType.For, 5, recipientB);

        // Verify final state - only successful votes should have reduced voting power
        assertEq(_tokenized().votingPower(alice), DEPOSIT_AMOUNT - 100); // 10^2
        assertEq(_tokenized().votingPower(bob), DEPOSIT_AMOUNT - 100); // 10^2 (only from pid2 vote)
        assertEq(_tokenized().votingPower(charlie), DEPOSIT_AMOUNT - 100); // 10^2
    }

    /// @notice Test the specific attack scenario that recipient verification prevents
    function test_ReorganizationAttackPrevention() public {
        _signupUser(alice, DEPOSIT_AMOUNT);
        _signupUser(bob, DEPOSIT_AMOUNT);

        // Scenario: Alice sees proposal 1 for recipientA and wants to vote for it
        uint256 pid1 = _createProposal(recipientA, "Alice's favorite project");

        // But attacker also creates proposal for recipientB
        uint256 pid2 = _createProposal(recipientB, "Attacker's project");

        _moveToVotingPeriod();

        // Alice votes for what she thinks is proposal 1 (recipientA)
        vm.prank(alice);
        _tokenized().castVote(pid1, TokenizedAllocationMechanism.VoteType.For, 20, recipientA);

        // Now imagine chain reorganization happens and proposal IDs get swapped
        // Alice tries to vote again thinking she's voting for the same project (recipientA)
        // but the proposal ID now points to recipientB's project
        // This should FAIL due to recipient verification
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenizedAllocationMechanism.RecipientMismatch.selector,
                pid2,
                recipientA,
                recipientB
            )
        );
        vm.prank(bob); // Bob tries to vote expecting recipientA but proposal is for recipientB
        _tokenized().castVote(pid2, TokenizedAllocationMechanism.VoteType.For, 15, recipientA);

        // Without recipient verification, Bob's vote would have gone to recipientB
        // With recipient verification, the vote is rejected, protecting Bob from the attack

        // Verify only Alice's legitimate vote went through
        assertEq(_tokenized().votingPower(alice), DEPOSIT_AMOUNT - 400); // 20^2
        assertEq(_tokenized().votingPower(bob), DEPOSIT_AMOUNT); // No vote went through
    }

    /// @notice Test that zero address registration is blocked at core level
    function test_ZeroAddressSignupBlocked() public {
        // Try to signup as zero address using vm.prank - should fail with InvalidUser
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.InvalidUser.selector, address(0)));

        // Use vm.prank to simulate the call coming from address(0)
        vm.prank(address(0));
        _tokenized().signup(0); // Zero deposit to avoid token transfer complications
    }
}
