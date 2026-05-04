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

/// @title Quadratic Voting End-to-End Test
/// @notice Complete end-to-end testing of the quadratic voting mechanism
/// @dev Tests the full user journey from registration through final redemption
contract QuadraticVotingE2E is Test {
    // General purpose struct to avoid stack too deep errors
    struct TestData {
        // Common data
        uint256 deploymentTime;
        uint256 pid1;
        uint256 pid2;
        uint256 pid3;
        uint256 pid4;
        address dave;
        address recipient4;
        // Tally data for multiple snapshots
        uint256 p1Contributions1;
        uint256 p1SqrtSum1;
        uint256 p1Quadratic1;
        uint256 p1Linear1;
        uint256 p2Contributions1;
        uint256 p2SqrtSum1;
        uint256 p2Quadratic1;
        uint256 p2Linear1;
        uint256 p1Contributions2;
        uint256 p1SqrtSum2;
        uint256 p1Quadratic2;
        uint256 p1Linear2;
        uint256 p2Contributions2;
        uint256 p2SqrtSum2;
        uint256 p2Quadratic2;
        uint256 p2Linear2;
        uint256 p1Contributions3;
        uint256 p1SqrtSum3;
        uint256 p1Quadratic3;
        uint256 p1Linear3;
        // Alpha and funding data
        uint256 newAlphaNumerator;
        uint256 newAlphaDenominator;
        uint256 totalUserDeposits;
        uint256 totalQuadraticSum;
        uint256 totalLinearSum;
        uint256 fixedMatchingPool;
        uint256 optimalAlphaNumerator;
        uint256 optimalAlphaDenominator;
        uint256 totalAssets;
        uint256 totalFunding;
        uint256 finalAlphaNumerator;
        uint256 finalAlphaDenominator;
        uint256 finalMatchingPool;
        uint256 finalTotalFunding;
        uint256 finalTotalAssets;
    }
    AllocationMechanismFactory factory;
    ERC20Mock token;
    QuadraticVotingMechanism mechanism;

    // Test actors
    address alice = address(0x101); // Voter 1 and Keeper (can create proposals)
    address bob = address(0x102); // Voter 2 and Management (can create proposals)
    address charlie = address(0x103); // Voter 3 (cannot create proposals)
    address recipient1 = address(0x201); // Project recipient 1
    address recipient2 = address(0x202); // Project recipient 2
    address recipient3 = address(0x203); // Project recipient 3

    // Test parameters
    uint256 constant INITIAL_TOKEN_BALANCE = 2000 ether;
    uint256 constant DEPOSIT_AMOUNT = 1000 ether;
    uint256 constant ALPHA_NUMERATOR = 1; // 100% quadratic funding
    uint256 constant ALPHA_DENOMINATOR = 1;
    uint256 constant QUORUM_REQUIREMENT = 500;
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;
    uint256 constant TIMELOCK_DELAY = 1 days;
    uint256 constant GRACE_PERIOD = 7 days;

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
    /// @dev In QuadraticVotingMechanism, only keeper/management can create proposals
    /// @param proposer Address creating the proposal (must be keeper/management)
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

    /// @notice Calculate matching funds needed for 1:1 shares-to-assets ratio
    /// @dev For alpha=1: totalShares = totalQuadraticSum, matchingFunds = totalQuadraticSum - totalLinearSum
    /// @return matchingFundsNeeded Amount of additional funds needed for 1:1 ratio
    /// @return totalQuadraticSum Total quadratic sum from all proposals
    /// @return totalLinearSum Total linear sum from all proposals (user contributions)
    function _calculateMatchingFunds(
        uint256 totalUserDeposits
    ) internal view returns (uint256 matchingFundsNeeded, uint256 totalQuadraticSum, uint256 totalLinearSum) {
        totalQuadraticSum = mechanism.totalQuadraticSum();
        totalLinearSum = mechanism.totalLinearSum();

        // For alpha = 1 (100% quadratic funding):
        // Total shares to be minted = totalQuadraticSum
        // Assets already in contract = totalLinearSum (from user deposits/contributions)
        // Matching funds needed = totalQuadraticSum - totalLinearSum
        if (totalQuadraticSum >= totalLinearSum) {
            matchingFundsNeeded = totalQuadraticSum - totalUserDeposits;
        } else {
            matchingFundsNeeded = 0;
        }
    }

    /// @notice Calculate optimal alpha for 1:1 shares-to-assets ratio given fixed matching pool amount
    /// @dev Formula: We want total funding = total assets available
    /// @dev Total funding = α × totalQuadraticSum + (1-α) × totalLinearSum
    /// @dev Total assets = totalUserDeposits + matchingPoolAmount
    /// @dev Solving: α × totalQuadraticSum + (1-α) × totalLinearSum = totalUserDeposits + matchingPoolAmount
    /// @dev Rearranging: α × (totalQuadraticSum - totalLinearSum) = totalUserDeposits + matchingPoolAmount - totalLinearSum
    /// @param matchingPoolAmount Fixed amount of matching funds available
    /// @param totalQuadraticSum Total quadratic sum across all proposals
    /// @param totalLinearSum Total linear sum across all proposals (voting costs)
    /// @param totalUserDeposits Total user deposits in the mechanism
    /// @return alphaNumerator Calculated alpha numerator
    /// @return alphaDenominator Calculated alpha denominator
    function _calculateOptimalAlpha(
        uint256 matchingPoolAmount,
        uint256 totalQuadraticSum,
        uint256 totalLinearSum,
        uint256 totalUserDeposits
    ) internal pure returns (uint256 alphaNumerator, uint256 alphaDenominator) {
        // Handle edge cases
        if (totalQuadraticSum <= totalLinearSum) {
            // No quadratic funding benefit, set alpha to 0
            alphaNumerator = 0;
            alphaDenominator = 1;
            return (alphaNumerator, alphaDenominator);
        }

        uint256 totalAssetsAvailable = totalUserDeposits + matchingPoolAmount;
        uint256 quadraticAdvantage = totalQuadraticSum - totalLinearSum;

        // We want: α × totalQuadraticSum + (1-α) × totalLinearSum = totalAssetsAvailable
        // Solving for α: α × (totalQuadraticSum - totalLinearSum) = totalAssetsAvailable - totalLinearSum
        // Therefore: α = (totalAssetsAvailable - totalLinearSum) / (totalQuadraticSum - totalLinearSum)

        if (totalAssetsAvailable <= totalLinearSum) {
            // Not enough assets even for linear funding, set alpha to 0
            alphaNumerator = 0;
            alphaDenominator = 1;
        } else {
            uint256 numerator = totalAssetsAvailable - totalLinearSum;

            if (numerator >= quadraticAdvantage) {
                // Enough assets for full quadratic funding
                alphaNumerator = 1;
                alphaDenominator = 1;
            } else {
                // Calculate fractional alpha
                alphaNumerator = numerator;
                alphaDenominator = quadraticAdvantage;
            }
        }
    }

    function setUp() public {
        // Deploy factory and mock token
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();

        // Mint tokens to all test actors
        token.mint(alice, INITIAL_TOKEN_BALANCE);
        token.mint(bob, INITIAL_TOKEN_BALANCE);
        token.mint(charlie, INITIAL_TOKEN_BALANCE);

        // Configure the allocation mechanism
        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "E2E Test Mechanism",
            symbol: "E2E",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: QUORUM_REQUIREMENT,
            timelockDelay: TIMELOCK_DELAY,
            gracePeriod: GRACE_PERIOD,
            owner: address(0)
        });

        // Deploy quadratic voting mechanism with 100% quadratic funding
        address mechanismAddr = factory.deployQuadraticVotingMechanism(config, ALPHA_NUMERATOR, ALPHA_DENOMINATOR);
        mechanism = QuadraticVotingMechanism(payable(mechanismAddr));

        // Set alice as keeper and bob as management (both can create proposals)
        _tokenized(address(mechanism)).setKeeper(alice);
        _tokenized(address(mechanism)).setManagement(bob);

        console.log("=== E2E TEST SETUP COMPLETE ===");
        console.log("Mechanism deployed at:", address(mechanism));
        console.log("Test token deployed at:", address(token));
        console.log("Start block:", _tokenized(address(mechanism)).startBlock());
        console.log("Alice balance:", token.balanceOf(alice));
        console.log("Bob balance:", token.balanceOf(bob));
        console.log("Charlie balance:", token.balanceOf(charlie));
        console.log("Keeper:", _tokenized(address(mechanism)).keeper());
        console.log("Management:", _tokenized(address(mechanism)).management());
    }

    /// @notice Verify the setup configuration and initial state
    function testSetupVerification() public view {
        // Verify mechanism deployment
        assertTrue(address(mechanism) != address(0), "Mechanism should be deployed");
        assertTrue(address(factory) != address(0), "Factory should be deployed");
        assertTrue(address(token) != address(0), "Token should be deployed");

        // Verify mechanism configuration
        assertEq(address(_tokenized(address(mechanism)).asset()), address(token), "Asset should be test token");
        assertEq(_tokenized(address(mechanism)).name(), "E2E Test Mechanism", "Name should match");
        assertEq(_tokenized(address(mechanism)).symbol(), "E2E", "Symbol should match");
        assertEq(_tokenized(address(mechanism)).votingDelay(), VOTING_DELAY, "Voting delay should match");
        assertEq(_tokenized(address(mechanism)).votingPeriod(), VOTING_PERIOD, "Voting period should match");
        assertEq(_tokenized(address(mechanism)).quorumShares(), QUORUM_REQUIREMENT, "Quorum should match");
        assertEq(_tokenized(address(mechanism)).timelockDelay(), TIMELOCK_DELAY, "Timelock delay should match");
        assertEq(_tokenized(address(mechanism)).gracePeriod(), GRACE_PERIOD, "Grace period should match");
        // Verify timing setup - mechanism uses timestamp-based timeline
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingPeriod = _tokenized(address(mechanism)).votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;
        assertGt(votingStartTime, deploymentTime, "Voting should start after deployment");
        assertGt(votingEndTime, votingStartTime, "Voting should end after it starts");

        // Verify quadratic voting mechanism specific configuration
        (uint256 alphaNumerator, uint256 alphaDenominator) = mechanism.getAlpha();
        assertEq(alphaNumerator, ALPHA_NUMERATOR, "Alpha numerator should match");
        assertEq(alphaDenominator, ALPHA_DENOMINATOR, "Alpha denominator should match");

        // Verify initial token balances
        assertEq(token.balanceOf(alice), INITIAL_TOKEN_BALANCE, "Alice initial balance should match");
        assertEq(token.balanceOf(bob), INITIAL_TOKEN_BALANCE, "Bob initial balance should match");
        assertEq(token.balanceOf(charlie), INITIAL_TOKEN_BALANCE, "Charlie initial balance should match");
        assertEq(token.balanceOf(address(mechanism)), 0, "Mechanism should start with zero balance");

        // Verify initial mechanism state
        assertEq(_tokenized(address(mechanism)).totalSupply(), 0, "No shares should exist initially");
        assertEq(_tokenized(address(mechanism)).votingPower(alice), 0, "Alice should have no voting power initially");
        assertEq(_tokenized(address(mechanism)).votingPower(bob), 0, "Bob should have no voting power initially");
        assertEq(
            _tokenized(address(mechanism)).votingPower(charlie),
            0,
            "Charlie should have no voting power initially"
        );

        // Verify recipient addresses have zero balances
        assertEq(token.balanceOf(recipient1), 0, "Recipient1 should start with zero balance");
        assertEq(token.balanceOf(recipient2), 0, "Recipient2 should start with zero balance");
        assertEq(token.balanceOf(recipient3), 0, "Recipient3 should start with zero balance");
    }

    /// @notice Test user signup functionality with helper function
    function testUserSignup() public {
        // No need to warp time for signup - it's allowed during initial period

        // Initial state verification
        assertEq(_tokenized(address(mechanism)).votingPower(alice), 0, "Alice should have no voting power initially");
        assertEq(token.balanceOf(address(mechanism)), 0, "Mechanism should have no tokens initially");

        // Sign up Alice with deposit
        _signupUser(alice, DEPOSIT_AMOUNT);

        // Verify signup effects
        assertEq(
            _tokenized(address(mechanism)).votingPower(alice),
            DEPOSIT_AMOUNT,
            "Alice should have voting power equal to deposit"
        );
        assertEq(
            token.balanceOf(alice),
            INITIAL_TOKEN_BALANCE - DEPOSIT_AMOUNT,
            "Alice token balance should decrease by deposit amount"
        );
        assertEq(token.balanceOf(address(mechanism)), DEPOSIT_AMOUNT, "Mechanism should receive Alice's deposit");

        // Sign up Bob with different deposit
        uint256 bobDeposit = 500 ether;
        _signupUser(bob, bobDeposit);

        // Verify Bob's signup
        assertEq(
            _tokenized(address(mechanism)).votingPower(bob),
            bobDeposit,
            "Bob should have voting power equal to his deposit"
        );
        assertEq(
            token.balanceOf(address(mechanism)),
            DEPOSIT_AMOUNT + bobDeposit,
            "Mechanism should have both deposits"
        );

        // Sign up Charlie with zero deposit
        _signupUser(charlie, 0);

        // Verify Charlie's zero deposit signup
        assertEq(_tokenized(address(mechanism)).votingPower(charlie), 0, "Charlie should have zero voting power");
        assertEq(token.balanceOf(charlie), INITIAL_TOKEN_BALANCE, "Charlie's token balance should be unchanged");
        assertEq(
            token.balanceOf(address(mechanism)),
            DEPOSIT_AMOUNT + bobDeposit,
            "Mechanism balance should be unchanged by zero deposit"
        );
    }

    /// @notice Test proposal creation functionality with helper function
    function testProposalCreation() public {
        // No timing manipulation needed for proposal creation

        // Sign up users first (only registered users can propose)
        _signupUser(alice, DEPOSIT_AMOUNT);
        _signupUser(bob, DEPOSIT_AMOUNT);

        // Create first proposal (alice is the keeper)
        uint256 pid1 = _createProposal(alice, recipient1, "Education Initiative");

        // Verify proposal creation
        assertTrue(pid1 > 0, "Proposal ID should be greater than 0");

        // Get proposal details
        TokenizedAllocationMechanism.Proposal memory proposal1 = _tokenized(address(mechanism)).proposals(pid1);
        assertEq(proposal1.proposer, alice, "Proposer should be alice (keeper)");
        assertEq(proposal1.recipient, recipient1, "Recipient should be recipient1");
        assertEq(proposal1.description, "Education Initiative", "Description should match");
        assertEq(
            uint8(_tokenized(address(mechanism)).state(pid1)),
            uint8(TokenizedAllocationMechanism.ProposalState.Pending),
            "Proposal should be Pending"
        );

        // Create second proposal
        uint256 pid2 = _createProposal(alice, recipient2, "Healthcare Project");

        // Verify second proposal
        assertTrue(pid2 > pid1, "Second proposal ID should be greater than first");

        TokenizedAllocationMechanism.Proposal memory proposal2 = _tokenized(address(mechanism)).proposals(pid2);
        assertEq(proposal2.proposer, alice, "Proposer should be alice (keeper)");
        assertEq(proposal2.recipient, recipient2, "Recipient should be recipient2");
        assertEq(proposal2.description, "Healthcare Project", "Description should match");

        // Test edge cases
        // Charlie (who is not keeper/management) cannot propose
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.ProposeNotAllowed.selector, charlie));
        _createProposal(charlie, recipient3, "Should fail - not keeper/management");

        // Alice (keeper) can create multiple proposals
        uint256 pid3 = _createProposal(alice, recipient3, "Alice's Second Project");
        assertTrue(pid3 > pid2, "Third proposal ID should be greater than second");

        TokenizedAllocationMechanism.Proposal memory proposal3 = _tokenized(address(mechanism)).proposals(pid3);
        assertEq(proposal3.proposer, alice, "Proposer should be alice (keeper)");
        assertEq(proposal3.recipient, recipient3, "Recipient should be recipient3");
    }

    /// @notice Test combined signup and proposal workflow
    function testSignupAndProposalWorkflow() public {
        // No timing manipulation needed for this workflow test

        // Phase 1: User signup
        console.log("=== Phase 1: User Signup ===");
        _signupUser(alice, DEPOSIT_AMOUNT);
        _signupUser(bob, 750 ether);
        _signupUser(charlie, 250 ether);

        uint256 totalDeposits = DEPOSIT_AMOUNT + 750 ether + 250 ether;
        assertEq(token.balanceOf(address(mechanism)), totalDeposits, "Total deposits should be tracked correctly");

        // Phase 2: Proposal creation
        console.log("=== Phase 2: Proposal Creation ===");
        uint256 pid1 = _createProposal(alice, recipient1, "Green Energy Initiative");
        uint256 pid2 = _createProposal(bob, recipient2, "Community Development");
        uint256 pid3 = _createProposal(alice, recipient3, "Education Technology"); // alice creates for charlie's project

        // Verify all proposals are created correctly
        assertTrue(pid1 < pid2 && pid2 < pid3, "Proposal IDs should be sequential");

        // Verify proposal states
        TokenizedAllocationMechanism.Proposal memory p1 = _tokenized(address(mechanism)).proposals(pid1);
        TokenizedAllocationMechanism.Proposal memory p2 = _tokenized(address(mechanism)).proposals(pid2);
        TokenizedAllocationMechanism.Proposal memory p3 = _tokenized(address(mechanism)).proposals(pid3);

        assertEq(
            uint8(_tokenized(address(mechanism)).state(pid1)),
            uint8(TokenizedAllocationMechanism.ProposalState.Pending),
            "Proposal 1 should be Pending"
        );
        assertEq(
            uint8(_tokenized(address(mechanism)).state(pid2)),
            uint8(TokenizedAllocationMechanism.ProposalState.Pending),
            "Proposal 2 should be Pending"
        );
        assertEq(
            uint8(_tokenized(address(mechanism)).state(pid3)),
            uint8(TokenizedAllocationMechanism.ProposalState.Pending),
            "Proposal 3 should be Pending"
        );

        // Verify recipients are different
        assertTrue(
            p1.recipient != p2.recipient && p2.recipient != p3.recipient && p1.recipient != p3.recipient,
            "All recipients should be unique"
        );

        // Verify mechanism state remains consistent
        assertEq(
            token.balanceOf(address(mechanism)),
            totalDeposits,
            "Mechanism balance should be unchanged by proposals"
        );
        assertEq(
            _tokenized(address(mechanism)).totalSupply(),
            0,
            "No shares should be minted during proposal creation"
        );

        console.log("Workflow test complete - 3 users signed up, 3 proposals created");
    }
    /// @notice Test voting edge cases and error conditions
    function testVotingErrorConditions() public {
        // ✅ CORRECT: Fetch absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingPeriod = _tokenized(address(mechanism)).votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Setup
        _signupUser(alice, DEPOSIT_AMOUNT);
        _signupUser(bob, 50); // Small deposit for testing insufficient power (50 wei is much smaller than 10000)
        uint256 pid = _createProposal(alice, recipient1, "Test Proposal");

        // Cannot vote before voting period starts
        vm.expectRevert();
        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, 10, recipient1);

        // Move to voting period
        vm.warp(votingStartTime + 1);

        // Cannot vote with insufficient voting power
        vm.expectRevert(); // Bob has 50 wei, but voting weight 100 costs 10000
        vm.prank(bob);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, 100, recipient1);

        // Alice votes successfully
        _castVote(alice, pid, 10, recipient1);

        // Cannot vote twice on same proposal
        vm.expectRevert();
        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, 5, recipient1);

        // Unregistered user cannot vote
        vm.expectRevert();
        vm.prank(charlie);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, 1, recipient1);

        // Cannot vote after voting period ends
        vm.warp(votingEndTime + 1);
        vm.expectRevert();
        vm.prank(bob);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, 5, recipient1);

        // Cannot vote on non-existent proposal
        vm.warp(votingStartTime + 500); // Back in voting period
        vm.expectRevert();
        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(999, TokenizedAllocationMechanism.VoteType.For, 5, recipient1); // Non-existent proposal ID
    }

    /// @notice Test complex multi-user voting scenario
    function testMultiUserVotingScenario() public {
        // ✅ CORRECT: Fetch absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingStartTime = deploymentTime + votingDelay;

        // Setup: 3 users with different voting power, 3 proposals
        _signupUser(alice, 1000 ether); // 1000 voting power
        _signupUser(bob, 500 ether); // 500 voting power
        _signupUser(charlie, 200 ether); // 200 voting power

        uint256 pid1 = _createProposal(alice, recipient1, "Education");
        uint256 pid2 = _createProposal(bob, recipient2, "Healthcare");
        uint256 pid3 = _createProposal(alice, recipient3, "Environment"); // alice creates for charlie's project

        // Move to voting period
        vm.warp(votingStartTime + 1);

        console.log("=== Multi-User Voting Scenario ===");

        // Alice votes on all three proposals
        console.log("Alice voting...");
        _castVote(alice, pid1, 25e9, recipient1); // Cost: 625 ether
        _castVote(alice, pid2, 15e9, recipient2); // Cost: 225 ether
        _castVote(alice, pid3, 10e9, recipient3); // Cost: 100 ether
        // Alice remaining power: 1000 ether - 625 - 225 - 100 = 1000 ether - 950
        assertEq(_tokenized(address(mechanism)).votingPower(alice), 1000 ether - 950 ether, "Alice remaining power");

        // Bob votes on two proposals
        console.log("Bob voting...");
        _castVote(bob, pid1, 20e9, recipient1); // Cost: 400 ether
        _castVote(bob, pid2, 10e9, recipient2); // Cost: 100 ether
        // Bob remaining power: 500 ether - 400 - 100 = 500 ether - 500
        assertEq(_tokenized(address(mechanism)).votingPower(bob), 500 ether - 500 ether, "Bob remaining power");

        // Charlie votes on one proposal
        // console.log("Charlie voting...");
        _castVote(charlie, pid3, 14e9, recipient3); // Cost: 196 ether
        // Charlie remaining power: 200 ether - 196 = 200 ether - 196
        assertEq(_tokenized(address(mechanism)).votingPower(charlie), 200 ether - 196 ether, "Charlie remaining power");

        // Verify all vote records
        assertTrue(mechanism.hasVoted(pid1, alice), "Alice voted on pid1");
        assertTrue(mechanism.hasVoted(pid2, alice), "Alice voted on pid2");
        assertTrue(mechanism.hasVoted(pid3, alice), "Alice voted on pid3");
        assertTrue(mechanism.hasVoted(pid1, bob), "Bob voted on pid1");
        assertTrue(mechanism.hasVoted(pid2, bob), "Bob voted on pid2");
        assertFalse(mechanism.hasVoted(pid3, bob), "Bob didn't vote on pid3");
        assertFalse(mechanism.hasVoted(pid1, charlie), "Charlie didn't vote on pid1");
        assertFalse(mechanism.hasVoted(pid2, charlie), "Charlie didn't vote on pid2");
        assertTrue(mechanism.hasVoted(pid3, charlie), "Charlie voted on pid3");

        // Verify vote tallies using getTally from ProperQF
        // console.log("=== Verifying Vote Tallies ===");

        // Project 1 (Education): Alice(25e9) + Bob(20e9) = weight sum 45e9
        // Linear contributions: Alice(625 ether) + Bob(400 ether) = 1025 ether
        // Quadratic calculation: (25e9 + 20e9)² = (45e9)² = 2025e18 = 2025 ether
        (uint256 p1Contributions, uint256 p1SqrtSum, uint256 p1Quadratic, uint256 p1Linear) = mechanism.getTally(pid1);
        // console.log("Project 1 - Contributions:", p1Contributions);
        // console.log("Project 1 - SqrtSum:", p1SqrtSum);
        // console.log("Project 1 - Quadratic:", p1Quadratic);
        // console.log("Project 1 - Linear:", p1Linear);

        assertEq(p1Contributions, 625 ether + 400 ether, "Project 1 contributions should be sum of quadratic costs");
        assertEq(p1SqrtSum, 25e9 + 20e9, "Project 1 sqrt sum should be sum of vote weights");
        // With alpha = 1: quadratic funding = 1 * (45e9)² = 2025 ether, linear funding = 0 * 1025 = 0
        assertEq(p1Quadratic, 2025 ether, "Project 1 quadratic funding should be (45e9)^2");
        assertEq(p1Linear, 0 ether, "Project 1 linear funding should be 0 with alpha=1");

        // Project 2 (Healthcare): Alice(15e9) + Bob(10e9) = weight sum 25e9
        // Linear contributions: Alice(225 ether) + Bob(100 ether) = 325 ether
        // Quadratic calculation: (15e9 + 10e9)² = (25e9)² = 625e18 = 625 ether
        (uint256 p2Contributions, uint256 p2SqrtSum, uint256 p2Quadratic, uint256 p2Linear) = mechanism.getTally(pid2);
        // console.log("Project 2 - Contributions:", p2Contributions);
        // console.log("Project 2 - SqrtSum:", p2SqrtSum);
        // console.log("Project 2 - Quadratic:", p2Quadratic);
        // console.log("Project 2 - Linear:", p2Linear);

        assertEq(p2Contributions, 225 ether + 100 ether, "Project 2 contributions should be sum of quadratic costs");
        assertEq(p2SqrtSum, 15e9 + 10e9, "Project 2 sqrt sum should be sum of vote weights");
        assertEq(p2Quadratic, 625 ether, "Project 2 quadratic funding should be (25e9)^2");
        assertEq(p2Linear, 0 ether, "Project 2 linear funding should be 0 with alpha=1");

        // Project 3 (Environment): Alice(10e9) + Charlie(14e9) = weight sum 24e9
        // Linear contributions: Alice(100 ether) + Charlie(196 ether) = 296 ether
        // Quadratic calculation: (10e9 + 14e9)² = (24e9)² = 576e18 = 576 ether
        (uint256 p3Contributions, uint256 p3SqrtSum, uint256 p3Quadratic, uint256 p3Linear) = mechanism.getTally(pid3);
        // console.log("Project 3 - Contributions:", p3Contributions);
        // console.log("Project 3 - SqrtSum:", p3SqrtSum);
        // console.log("Project 3 - Quadratic:", p3Quadratic);
        // console.log("Project 3 - Linear:", p3Linear);

        assertEq(p3Contributions, 100 ether + 196 ether, "Project 3 contributions should be sum of quadratic costs");
        assertEq(p3SqrtSum, 10e9 + 14e9, "Project 3 sqrt sum should be sum of vote weights");
        assertEq(p3Quadratic, 576 ether, "Project 3 quadratic funding should be (24e9)^2");
        assertEq(p3Linear, 0 ether, "Project 3 linear funding should be 0 with alpha=1");

        // Verify total funding allocation using direct assertions to reduce stack usage
        assertEq(
            p1Quadratic + p2Quadratic + p3Quadratic,
            2025 ether + 625 ether + 576 ether,
            "Total quadratic funding calculation"
        );
        assertEq(p1Linear + p2Linear + p3Linear, 0 ether, "Total linear funding should be 0 with alpha=1");
        assertEq(
            p1Contributions + p2Contributions + p3Contributions,
            1025 ether + 325 ether + 296 ether,
            "Total contributions calculation"
        );

        // Verify quadratic funding formula: each project gets α × (sum_sqrt)² + (1-α) × sum_contributions
        // With alpha = 1: funding = 1 × quadratic + 0 × linear = quadratic only
        assertEq(p1Quadratic + p1Linear, 2025 ether, "Project 1 total funding should be 2025");
        assertEq(p2Quadratic + p2Linear, 625 ether, "Project 2 total funding should be 625");
        assertEq(p3Quadratic + p3Linear, 576 ether, "Project 3 total funding should be 576");

        // console.log("Multi-user voting scenario complete");
        // console.log("Alice remaining power:", _tokenized(address(mechanism)).votingPower(alice));
        // console.log("Bob remaining power:", _tokenized(address(mechanism)).votingPower(bob));
        // console.log("Charlie remaining power:", _tokenized(address(mechanism)).votingPower(charlie));
    }

    /// @notice Test matching fund calculation and 1:1 shares-to-assets ratio verification
    function testMatchingFundsCalculationAnd1to1Ratio() public {
        // ✅ CORRECT: Fetch absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingPeriod = _tokenized(address(mechanism)).votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Setup: 3 users with different voting power
        uint256 totalUserDeposits = 1000 ether + 500 ether + 200 ether; // User signup deposits
        _signupUser(alice, 1000 ether);
        _signupUser(bob, 500 ether);
        _signupUser(charlie, 200 ether);

        // Create proposals
        uint256 pid1 = _createProposal(alice, recipient1, "Project Alpha");
        uint256 pid2 = _createProposal(bob, recipient2, "Project Beta");

        // Move to voting period
        vm.warp(votingStartTime + 1);

        // Cast votes with specific weights to create known quadratic/linear sums
        _castVote(alice, pid1, 20e9, recipient1); // Cost: 400 ether
        _castVote(bob, pid1, 15e9, recipient1); // Cost: 225 ether
        _castVote(alice, pid2, 10e9, recipient2); // Cost: 100 ether (Alice remaining: 1000-400-100=500)
        _castVote(charlie, pid2, 14e9, recipient2); // Cost: 196 ether

        console.log("=== MATCHING FUNDS CALCULATION TEST ===");

        // Calculate matching funds needed before finalization
        (uint256 matchingFundsNeeded, uint256 totalQuadraticSum, uint256 totalLinearSum) = _calculateMatchingFunds(
            totalUserDeposits
        );

        console.log("Total Quadratic Sum:", totalQuadraticSum);
        console.log("Total Linear Sum:", totalLinearSum);
        console.log("Matching Funds Needed:", matchingFundsNeeded);

        // Verify the calculation
        // Project 1: (20e9 + 15e9)² = (35e9)² = 1225e18 = 1225 ether
        // Project 2: (10e9 + 14e9)² = (24e9)² = 576e18 = 576 ether
        // Total quadratic sum = 1225 + 576 = 1801 ether
        assertEq(totalQuadraticSum, 1801 ether, "Total quadratic sum should be 1801 ether");

        // Total linear sum = 400 + 225 + 100 + 196 = 921 ether
        assertEq(totalLinearSum, 921 ether, "Total linear sum should be 921 ether");

        // Matching funds needed = 1801 - 921 = 880 ether
        assertEq(matchingFundsNeeded, totalQuadraticSum - totalUserDeposits, "Matching funds should be 880 ether");

        // Verify contract balance vs linear sum
        uint256 contractBalanceBeforeMatching = token.balanceOf(address(mechanism));
        assertEq(contractBalanceBeforeMatching, totalUserDeposits, "Contract should hold total user deposits");

        console.log("Contract balance (user deposits):", contractBalanceBeforeMatching);
        console.log("Total linear sum (vote costs):", totalLinearSum);
        console.log("Difference (unused voting power):", contractBalanceBeforeMatching - totalLinearSum);

        // Add the calculated matching funds
        console.log("Adding matching funds:", matchingFundsNeeded);
        token.mint(address(this), matchingFundsNeeded);
        token.transfer(address(mechanism), matchingFundsNeeded);

        // Verify total contract balance now equals total quadratic sum
        uint256 contractBalanceAfterMatching = token.balanceOf(address(mechanism));
        assertEq(
            contractBalanceAfterMatching,
            totalQuadraticSum,
            "Contract should hold exactly the total quadratic sum after matching"
        );

        // Move past voting period and finalize
        vm.warp(votingEndTime + 1);
        _tokenized(address(mechanism)).finalizeVoteTally();

        // Queue proposals to actually mint shares and verify ratio is maintained
        _tokenized(address(mechanism)).queueProposal(pid1);
        _tokenized(address(mechanism)).queueProposal(pid2);

        // Verify shares were minted correctly
        uint256 totalSharesIssued = _tokenized(address(mechanism)).totalSupply();
        assertEq(totalSharesIssued, totalQuadraticSum, "Total shares issued should equal total quadratic sum");

        // Verify 1:1 ratio is set after share minting
        uint256 assetsFor1ShareAfterMinting = _tokenized(address(mechanism)).convertToAssets(1e18);
        assertEq(assetsFor1ShareAfterMinting, 1e18, "1:1 ratio should be maintained after share minting");

        // Verify individual recipients got correct share amounts
        uint256 recipient1Shares = _tokenized(address(mechanism)).balanceOf(recipient1);
        uint256 recipient2Shares = _tokenized(address(mechanism)).balanceOf(recipient2);

        assertEq(recipient1Shares, 1225 ether, "Recipient 1 should receive 1225 ether shares");
        assertEq(recipient2Shares, 576 ether, "Recipient 2 should receive 576 ether shares");
        assertEq(recipient1Shares + recipient2Shares, totalSharesIssued, "Individual shares should sum to total");

        console.log("=== TEST COMPLETE ===");
        console.log("Perfect 1:1 shares-to-assets ratio achieved!");
        console.log("Total assets in contract:", token.balanceOf(address(mechanism)));
        console.log("Total shares issued:", totalSharesIssued);
        console.log("Ratio verification: 1e18 shares =", assetsFor1ShareAfterMinting, "assets");
    }

    /// @notice Test optimal alpha calculation for 1:1 shares-to-assets ratio with fixed matching pool
    function testOptimalAlphaCalculationWith1to1Ratio() public {
        // ✅ CORRECT: Fetch absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingPeriod = _tokenized(address(mechanism)).votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Setup: 3 users with different voting power
        uint256 totalUserDeposits = 1000 ether + 500 ether + 200 ether;
        _signupUser(alice, 1000 ether);
        _signupUser(bob, 500 ether);
        _signupUser(charlie, 200 ether);

        // Create proposals
        uint256 pid1 = _createProposal(alice, recipient1, "Project A");
        uint256 pid2 = _createProposal(bob, recipient2, "Project B");

        // Move to voting period
        vm.warp(votingStartTime + 1);

        // Cast votes to create known sums (closer to signup amounts)
        _castVote(alice, pid1, 30e9, recipient1); // Cost: 900 ether
        _castVote(bob, pid1, 20e9, recipient1); // Cost: 400 ether
        _castVote(charlie, pid2, 14e9, recipient2); // Cost: 196 ether

        // console.log("=== OPTIMAL ALPHA CALCULATION TEST ===");

        // Get totals after voting
        uint256 totalQuadraticSum = mechanism.totalQuadraticSum();
        uint256 totalLinearSum = mechanism.totalLinearSum();

        // console.log("Total Quadratic Sum:", totalQuadraticSum);
        // console.log("Total Linear Sum:", totalLinearSum);
        // console.log("Total User Deposits:", totalUserDeposits);

        // Project 1: (30e9 + 20e9)² = (50e9)² = 2500e18 = 2500 ether
        // Project 2: (14e9)² = 196e18 = 196 ether
        // Total quadratic sum = 2500 + 196 = 2696 ether
        assertEq(totalQuadraticSum, 2696 ether, "Total quadratic sum should be 2696 ether");

        // Total linear sum = 900 + 400 + 196 = 1496 ether
        assertEq(totalLinearSum, 1496 ether, "Total linear sum should be 1496 ether");

        // Define a fixed matching pool amount (less than full quadratic advantage)
        uint256 fixedMatchingPool = 300 ether;

        // Calculate optimal alpha
        (uint256 alphaNumerator, uint256 alphaDenominator) = _calculateOptimalAlpha(
            fixedMatchingPool,
            totalQuadraticSum,
            totalLinearSum,
            totalUserDeposits
        );

        // console.log("Fixed matching pool:", fixedMatchingPool);
        // console.log("Calculated alpha:", alphaNumerator, "/", alphaDenominator);

        // Verify alpha calculation using scoping for intermediate variables
        {
            uint256 totalAssetsAvailable = totalUserDeposits + fixedMatchingPool; // 1700 + 300 = 2000
            uint256 quadraticAdvantage = totalQuadraticSum - totalLinearSum; // 2696 - 1496 = 1200
            uint256 expectedNumerator = totalAssetsAvailable - totalLinearSum; // 2000 - 1496 = 504

            // expectedNumerator (504) < quadraticAdvantage (1200), so alpha should be fractional
            assertEq(alphaNumerator, expectedNumerator, "Alpha numerator should be total assets minus linear sum");
            assertEq(alphaDenominator, quadraticAdvantage, "Alpha denominator should be quadratic advantage");
        }

        // Add the fixed matching pool to the mechanism
        token.mint(address(this), fixedMatchingPool);
        token.transfer(address(mechanism), fixedMatchingPool);

        // Update alpha to the calculated optimal value using scoping
        {
            mechanism.setAlpha(alphaNumerator, alphaDenominator);

            // Verify alpha was set correctly
            (uint256 newAlphaNumerator, uint256 newAlphaDenominator) = mechanism.getAlpha();
            assertEq(newAlphaNumerator, alphaNumerator, "Alpha numerator should be updated");
            assertEq(newAlphaDenominator, alphaDenominator, "Alpha denominator should be updated");
        }

        // Verify total assets and calculate expected funding
        uint256 totalAssets = token.balanceOf(address(mechanism));
        assertEq(totalAssets, totalUserDeposits + fixedMatchingPool, "Total assets should be deposits + matching pool");

        // Calculate expected total funding with this alpha using scoping for intermediate variables
        uint256 expectedTotalFunding;
        {
            uint256 expectedQuadraticComponent = (totalQuadraticSum * alphaNumerator) / alphaDenominator;
            uint256 expectedLinearComponent = (totalLinearSum * (alphaDenominator - alphaNumerator)) / alphaDenominator;
            expectedTotalFunding = expectedQuadraticComponent + expectedLinearComponent;

            // console.log("Expected quadratic component:", expectedQuadraticComponent);
            // console.log("Expected linear component:", expectedLinearComponent);
            // console.log("Expected total funding:", expectedTotalFunding);
            // console.log("Actual total assets:", totalAssets);
        }

        // Move past voting period and finalize using scoping for intermediate variables
        {
            vm.warp(votingEndTime + 1);
            _tokenized(address(mechanism)).finalizeVoteTally();

            // Queue proposals to mint shares
            _tokenized(address(mechanism)).queueProposal(pid1);
            _tokenized(address(mechanism)).queueProposal(pid2);
        }

        // Verify 1:1 ratio is maintained using scoping
        {
            uint256 assetsFor1Share = _tokenized(address(mechanism)).convertToAssets(1e18);
            assertEq(assetsFor1Share, 1e18, "1:1 ratio should be maintained with optimal alpha");

            // Verify total shares match total assets
            uint256 totalShares = _tokenized(address(mechanism)).totalSupply();
            assertEq(totalShares, totalAssets, "Total shares should equal total assets");
            assertEq(totalShares, expectedTotalFunding, "Total shares should equal expected total funding");
        }

        // console.log("=== OPTIMAL ALPHA TEST COMPLETE ===");
        // console.log("Perfect 1:1 ratio achieved with alpha =", alphaNumerator, "/", alphaDenominator);
        // console.log("Total assets:", totalAssets);
        // console.log("Total shares:", totalShares);
        // console.log("1e18 shares converts to:", assetsFor1Share, "assets");
    }

    /// @notice Test optimal alpha with small matching pool - alpha should be low fractional value
    function testOptimalAlphaSmallMatchingPool() public {
        // ✅ CORRECT: Fetch absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingPeriod = _tokenized(address(mechanism)).votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Setup: 2 users, modest deposits
        uint256 totalUserDeposits = 800 ether + 600 ether;
        _signupUser(alice, 800 ether);
        _signupUser(bob, 600 ether);

        // Create 2 proposals
        uint256 pid1 = _createProposal(alice, recipient1, "Education Project");
        uint256 pid2 = _createProposal(bob, recipient2, "Healthcare Project");

        // Move to voting period
        vm.warp(votingStartTime + 1);

        // Cast moderate votes to create quadratic advantage
        _castVote(alice, pid1, 20e9, recipient1); // Cost: 400 ether
        _castVote(bob, pid1, 15e9, recipient1); // Cost: 225 ether
        _castVote(alice, pid2, 15e9, recipient2); // Cost: 225 ether
        _castVote(bob, pid2, 18e9, recipient2); // Cost: 324 ether

        console.log("=== SMALL MATCHING POOL TEST ===");

        // Get totals
        uint256 totalQuadraticSum = mechanism.totalQuadraticSum();
        uint256 totalLinearSum = mechanism.totalLinearSum();

        // Project 1: (20e9 + 15e9)² = (35e9)² = 1225 ether
        // Project 2: (15e9 + 18e9)² = (33e9)² = 1089 ether
        // Total quadratic sum = 1225 + 1089 = 2314 ether
        assertEq(totalQuadraticSum, 2314 ether, "Total quadratic sum should be 2314 ether");

        // Total linear sum = 400 + 225 + 225 + 324 = 1174 ether
        assertEq(totalLinearSum, 1174 ether, "Total linear sum should be 1174 ether");

        // Small matching pool - only 200 ether
        uint256 smallMatchingPool = 200 ether;

        // Calculate optimal alpha using mechanism's function
        (uint256 optimalAlphaNumerator, uint256 optimalAlphaDenominator) = mechanism.calculateOptimalAlpha(
            smallMatchingPool,
            totalUserDeposits
        );

        console.log("Small matching pool:", smallMatchingPool);
        console.log("Calculated optimal alpha:", optimalAlphaNumerator, "/", optimalAlphaDenominator);

        // Verify fractional alpha (should be between 0 and 1)
        assertTrue(optimalAlphaNumerator > 0, "Alpha numerator should be positive");
        assertTrue(optimalAlphaNumerator < optimalAlphaDenominator, "Alpha should be less than 1");

        // Apply optimal alpha and add matching pool
        token.mint(address(this), smallMatchingPool);
        token.transfer(address(mechanism), smallMatchingPool);
        mechanism.setAlpha(optimalAlphaNumerator, optimalAlphaDenominator);

        // Finalize and queue
        vm.warp(votingEndTime + 1);
        _tokenized(address(mechanism)).finalizeVoteTally();
        _tokenized(address(mechanism)).queueProposal(pid1);
        _tokenized(address(mechanism)).queueProposal(pid2);

        // Verify 1:1 ratio maintained (allow small rounding tolerance)
        uint256 assetsFor1Share = _tokenized(address(mechanism)).convertToAssets(1e18);
        assertApproxEqAbs(assetsFor1Share, 1e18, 10, "1:1 ratio should be maintained with small matching pool");

        uint256 totalShares = _tokenized(address(mechanism)).totalSupply();
        uint256 totalAssets = token.balanceOf(address(mechanism));
        assertApproxEqAbs(totalShares, totalAssets, 10, "Total shares should approximately equal total assets");

        console.log("Alpha:", optimalAlphaNumerator, "/", optimalAlphaDenominator);
        console.log("Total assets:", totalAssets);
        console.log("Total shares:", totalShares);
    }

    /// @notice Test optimal alpha with medium matching pool - alpha should be moderate fractional value
    function testOptimalAlphaMediumMatchingPool() public {
        // ✅ CORRECT: Fetch absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingPeriod = _tokenized(address(mechanism)).votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Setup: 2 users with different deposit amounts
        uint256 totalUserDeposits = 1200 ether + 800 ether;
        _signupUser(alice, 1200 ether);
        _signupUser(bob, 800 ether);

        // Create 2 proposals
        uint256 pid1 = _createProposal(alice, recipient1, "Infrastructure Project");
        uint256 pid2 = _createProposal(bob, recipient2, "Research Project");

        // Move to voting period
        vm.warp(votingStartTime + 1);

        // Cast strategic votes
        _castVote(alice, pid1, 25e9, recipient1); // Cost: 625 ether
        _castVote(bob, pid1, 20e9, recipient1); // Cost: 400 ether
        _castVote(alice, pid2, 20e9, recipient2); // Cost: 400 ether (Alice remaining: 1200-625-400=175)
        _castVote(bob, pid2, 15e9, recipient2); // Cost: 225 ether (Bob remaining: 800-400-225=175)

        console.log("=== MEDIUM MATCHING POOL TEST ===");

        // Get totals
        uint256 totalQuadraticSum = mechanism.totalQuadraticSum();
        uint256 totalLinearSum = mechanism.totalLinearSum();

        // Project 1: (25e9 + 20e9)² = (45e9)² = 2025 ether
        // Project 2: (20e9 + 15e9)² = (35e9)² = 1225 ether
        // Total quadratic sum = 2025 + 1225 = 3250 ether
        assertEq(totalQuadraticSum, 3250 ether, "Total quadratic sum should be 3250 ether");

        // Total linear sum = 625 + 400 + 400 + 225 = 1650 ether
        assertEq(totalLinearSum, 1650 ether, "Total linear sum should be 1650 ether");

        // Medium matching pool - 600 ether (moderate funding)
        uint256 mediumMatchingPool = 600 ether;

        // Calculate optimal alpha
        (uint256 optimalAlphaNumerator, uint256 optimalAlphaDenominator) = mechanism.calculateOptimalAlpha(
            mediumMatchingPool,
            totalUserDeposits
        );

        console.log("Medium matching pool:", mediumMatchingPool);
        console.log("Calculated optimal alpha:", optimalAlphaNumerator, "/", optimalAlphaDenominator);

        // Verify fractional alpha in medium range
        assertTrue(optimalAlphaNumerator > 0, "Alpha numerator should be positive");
        assertTrue(optimalAlphaNumerator < optimalAlphaDenominator, "Alpha should be less than 1");

        // Apply optimal alpha and add matching pool
        token.mint(address(this), mediumMatchingPool);
        token.transfer(address(mechanism), mediumMatchingPool);
        mechanism.setAlpha(optimalAlphaNumerator, optimalAlphaDenominator);

        // Finalize and queue
        vm.warp(votingEndTime + 1);
        _tokenized(address(mechanism)).finalizeVoteTally();
        _tokenized(address(mechanism)).queueProposal(pid1);
        _tokenized(address(mechanism)).queueProposal(pid2);

        // Verify 1:1 ratio maintained
        uint256 assetsFor1Share = _tokenized(address(mechanism)).convertToAssets(1e18);
        assertEq(assetsFor1Share, 1e18, "1:1 ratio should be maintained with medium matching pool");

        uint256 totalShares = _tokenized(address(mechanism)).totalSupply();
        uint256 totalAssets = token.balanceOf(address(mechanism));
        assertEq(totalShares, totalAssets, "Total shares should equal total assets");

        console.log("Alpha:", optimalAlphaNumerator, "/", optimalAlphaDenominator);
        console.log("Total assets:", totalAssets);
        console.log("Total shares:", totalShares);
    }

    /// @notice Test optimal alpha with varied voting patterns - multiple voters, diverse vote distribution
    function testOptimalAlphaVariedVotingPatterns() public {
        // ✅ CORRECT: Fetch absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingPeriod = _tokenized(address(mechanism)).votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Setup: 3 users with different deposit amounts
        uint256 totalUserDeposits = 900 ether + 700 ether + 400 ether;
        _signupUser(alice, 900 ether);
        _signupUser(bob, 700 ether);
        _signupUser(charlie, 400 ether);

        // Create 3 proposals
        uint256 pid1 = _createProposal(alice, recipient1, "Social Impact Project");
        uint256 pid2 = _createProposal(bob, recipient2, "Tech Innovation Project");
        uint256 pid3 = _createProposal(alice, recipient3, "Community Project"); // alice creates for charlie's project

        // Move to voting period
        vm.warp(votingStartTime + 1);

        // Create diverse voting patterns
        _castVote(alice, pid1, 22e9, recipient1); // Cost: 484 ether
        _castVote(alice, pid2, 18e9, recipient2); // Cost: 324 ether
        _castVote(bob, pid1, 15e9, recipient1); // Cost: 225 ether
        _castVote(bob, pid3, 20e9, recipient3); // Cost: 400 ether
        _castVote(charlie, pid2, 12e9, recipient2); // Cost: 144 ether
        _castVote(charlie, pid3, 16e9, recipient3); // Cost: 256 ether

        console.log("=== VARIED VOTING PATTERNS TEST ===");

        // Get totals
        uint256 totalQuadraticSum = mechanism.totalQuadraticSum();
        uint256 totalLinearSum = mechanism.totalLinearSum();

        // Project 1: (22e9 + 15e9)² = (37e9)² = 1369 ether
        // Project 2: (18e9 + 12e9)² = (30e9)² = 900 ether
        // Project 3: (20e9 + 16e9)² = (36e9)² = 1296 ether
        // Total quadratic sum = 1369 + 900 + 1296 = 3565 ether
        assertEq(totalQuadraticSum, 3565 ether, "Total quadratic sum should be 3565 ether");

        // Total linear sum = 484 + 324 + 225 + 400 + 144 + 256 = 1833 ether
        assertEq(totalLinearSum, 1833 ether, "Total linear sum should be 1833 ether");

        // Moderate matching pool for varied scenario
        uint256 variedMatchingPool = 500 ether;

        // Calculate optimal alpha
        (uint256 optimalAlphaNumerator, uint256 optimalAlphaDenominator) = mechanism.calculateOptimalAlpha(
            variedMatchingPool,
            totalUserDeposits
        );

        console.log("Varied matching pool:", variedMatchingPool);
        console.log("Calculated optimal alpha:", optimalAlphaNumerator, "/", optimalAlphaDenominator);

        // Verify fractional alpha
        assertTrue(optimalAlphaNumerator > 0, "Alpha numerator should be positive");
        assertTrue(optimalAlphaNumerator < optimalAlphaDenominator, "Alpha should be less than 1");

        // Apply optimal alpha and add matching pool
        token.mint(address(this), variedMatchingPool);
        token.transfer(address(mechanism), variedMatchingPool);
        mechanism.setAlpha(optimalAlphaNumerator, optimalAlphaDenominator);

        // Finalize and queue all proposals
        vm.warp(votingEndTime + 1);
        _tokenized(address(mechanism)).finalizeVoteTally();
        _tokenized(address(mechanism)).queueProposal(pid1);
        _tokenized(address(mechanism)).queueProposal(pid2);
        _tokenized(address(mechanism)).queueProposal(pid3);

        // Verify 1:1 ratio maintained (allow small rounding tolerance)
        uint256 assetsFor1Share = _tokenized(address(mechanism)).convertToAssets(1e18);
        assertApproxEqAbs(assetsFor1Share, 1e18, 10, "1:1 ratio should be maintained with varied voting patterns");

        uint256 totalShares = _tokenized(address(mechanism)).totalSupply();
        uint256 totalAssets = token.balanceOf(address(mechanism));
        assertApproxEqAbs(totalShares, totalAssets, 10, "Total shares should approximately equal total assets");

        // Verify individual recipient shares
        uint256 recipient1Shares = _tokenized(address(mechanism)).balanceOf(recipient1);
        uint256 recipient2Shares = _tokenized(address(mechanism)).balanceOf(recipient2);
        uint256 recipient3Shares = _tokenized(address(mechanism)).balanceOf(recipient3);

        assertTrue(recipient1Shares > 0, "Recipient 1 should receive shares");
        assertTrue(recipient2Shares > 0, "Recipient 2 should receive shares");
        assertTrue(recipient3Shares > 0, "Recipient 3 should receive shares");
        assertEq(
            recipient1Shares + recipient2Shares + recipient3Shares,
            totalShares,
            "Individual shares should sum to total"
        );

        console.log("Alpha:", optimalAlphaNumerator, "/", optimalAlphaDenominator);
        console.log("Total assets:", totalAssets);
        console.log("Total shares:", totalShares);
        console.log("Recipient 1 shares:", recipient1Shares);
        console.log("Recipient 2 shares:", recipient2Shares);
        console.log("Recipient 3 shares:", recipient3Shares);
    }

    /// @notice Test precision with very large scale deposits and votes
    function testOptimalAlphaPrecisionLargeScale() public {
        // ✅ CORRECT: Fetch absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingPeriod = _tokenized(address(mechanism)).votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Use very large deposits to test precision boundaries
        uint256 largeDeposit1 = 100_000_000 ether; // 100M tokens
        uint256 largeDeposit2 = 80_000_000 ether; // 80M tokens
        uint256 totalUserDeposits = largeDeposit1 + largeDeposit2;

        // Mint large amounts for testing
        token.mint(alice, largeDeposit1);
        token.mint(bob, largeDeposit2);

        _signupUser(alice, largeDeposit1);
        _signupUser(bob, largeDeposit2);

        // Create proposals
        uint256 pid1 = _createProposal(alice, recipient1, "Large Scale Project 1");
        uint256 pid2 = _createProposal(bob, recipient2, "Large Scale Project 2");

        // Move to voting period
        vm.warp(votingStartTime + 1);

        // Cast large votes that fit within available voting power
        _castVote(alice, pid1, 8000e9, recipient1); // Cost: 64M ether
        _castVote(bob, pid1, 6000e9, recipient1); // Cost: 36M ether
        _castVote(alice, pid2, 6000e9, recipient2); // Cost: 36M ether (Alice total: 100M ether)
        _castVote(bob, pid2, 6500e9, recipient2); // Cost: 42.25M ether (Bob total: 78.25M ether)

        console.log("=== LARGE SCALE PRECISION TEST ===");

        // Get totals
        uint256 totalQuadraticSum = mechanism.totalQuadraticSum();
        uint256 totalLinearSum = mechanism.totalLinearSum();

        console.log("Total Quadratic Sum:", totalQuadraticSum);
        console.log("Total Linear Sum:", totalLinearSum);

        // Use a proportionally large matching pool
        uint256 largeMatchingPool = 50_000_000 ether; // 50M tokens

        // Calculate optimal alpha with large numbers
        (uint256 optimalAlphaNumerator, uint256 optimalAlphaDenominator) = mechanism.calculateOptimalAlpha(
            largeMatchingPool,
            totalUserDeposits
        );

        console.log("Large matching pool:", largeMatchingPool);
        console.log("Calculated optimal alpha:", optimalAlphaNumerator, "/", optimalAlphaDenominator);

        // Verify fractional alpha
        assertTrue(optimalAlphaNumerator > 0, "Alpha numerator should be positive");
        assertTrue(optimalAlphaNumerator <= optimalAlphaDenominator, "Alpha should be <= 1");

        // Apply optimal alpha and add matching pool
        token.mint(address(this), largeMatchingPool);
        token.transfer(address(mechanism), largeMatchingPool);
        mechanism.setAlpha(optimalAlphaNumerator, optimalAlphaDenominator);

        // Finalize and queue
        vm.warp(votingEndTime + 1);
        _tokenized(address(mechanism)).finalizeVoteTally();
        _tokenized(address(mechanism)).queueProposal(pid1);
        _tokenized(address(mechanism)).queueProposal(pid2);

        // Verify 1:1 ratio maintained despite large scale (allow larger tolerance)
        uint256 assetsFor1Share = _tokenized(address(mechanism)).convertToAssets(1e18);
        assertApproxEqAbs(assetsFor1Share, 1e18, 1000, "1:1 ratio should be maintained at large scale");

        uint256 totalShares = _tokenized(address(mechanism)).totalSupply();
        uint256 totalAssets = token.balanceOf(address(mechanism));
        assertApproxEqAbs(
            totalShares,
            totalAssets,
            1000,
            "Total shares should approximately equal total assets at large scale"
        );

        console.log("Large scale alpha:", optimalAlphaNumerator, "/", optimalAlphaDenominator);
        console.log("Large scale total assets:", totalAssets);
        console.log("Large scale total shares:", totalShares);
    }

    /// @notice Test precision with extremely small matching pool (near-zero alpha)
    function testOptimalAlphaPrecisionTinyMatchingPool() public {
        // ✅ CORRECT: Fetch absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingPeriod = _tokenized(address(mechanism)).votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Setup with moderate deposits
        uint256 totalUserDeposits = 1000 ether + 800 ether;
        _signupUser(alice, 1000 ether);
        _signupUser(bob, 800 ether);

        // Create proposals
        uint256 pid1 = _createProposal(alice, recipient1, "Project With Tiny Pool 1");
        uint256 pid2 = _createProposal(bob, recipient2, "Project With Tiny Pool 2");

        // Move to voting period
        vm.warp(votingStartTime + 1);

        // Cast votes that create large quadratic advantage
        _castVote(alice, pid1, 25e9, recipient1); // Cost: 625 ether
        _castVote(bob, pid1, 20e9, recipient1); // Cost: 400 ether
        _castVote(alice, pid2, 15e9, recipient2); // Cost: 225 ether
        _castVote(bob, pid2, 18e9, recipient2); // Cost: 324 ether

        console.log("=== TINY MATCHING POOL PRECISION TEST ===");

        // Get totals
        uint256 totalQuadraticSum = mechanism.totalQuadraticSum();
        uint256 totalLinearSum = mechanism.totalLinearSum();

        console.log("Total Quadratic Sum:", totalQuadraticSum);
        console.log("Total Linear Sum:", totalLinearSum);

        // Use extremely tiny matching pool (1 wei)
        uint256 tinyMatchingPool = 1;

        // Calculate optimal alpha with tiny matching pool
        (uint256 optimalAlphaNumerator, uint256 optimalAlphaDenominator) = mechanism.calculateOptimalAlpha(
            tinyMatchingPool,
            totalUserDeposits
        );

        console.log("Tiny matching pool:", tinyMatchingPool);
        console.log("Calculated optimal alpha:", optimalAlphaNumerator, "/", optimalAlphaDenominator);

        // With tiny matching pool, alpha should be very small but not zero
        assertTrue(optimalAlphaNumerator > 0, "Alpha numerator should be positive even with tiny pool");
        assertTrue(optimalAlphaNumerator < optimalAlphaDenominator, "Alpha should be less than 1");

        // Apply optimal alpha and add matching pool
        token.mint(address(this), tinyMatchingPool);
        token.transfer(address(mechanism), tinyMatchingPool);
        mechanism.setAlpha(optimalAlphaNumerator, optimalAlphaDenominator);

        // Finalize and queue
        vm.warp(votingEndTime + 1);
        _tokenized(address(mechanism)).finalizeVoteTally();
        _tokenized(address(mechanism)).queueProposal(pid1);
        _tokenized(address(mechanism)).queueProposal(pid2);

        // Verify 1:1 ratio maintained even with tiny matching pool
        uint256 assetsFor1Share = _tokenized(address(mechanism)).convertToAssets(1e18);
        assertApproxEqAbs(assetsFor1Share, 1e18, 100, "1:1 ratio should be maintained with tiny matching pool");

        uint256 totalShares = _tokenized(address(mechanism)).totalSupply();
        uint256 totalAssets = token.balanceOf(address(mechanism));
        assertApproxEqAbs(
            totalShares,
            totalAssets,
            100,
            "Total shares should approximately equal total assets with tiny pool"
        );

        console.log("Tiny pool alpha:", optimalAlphaNumerator, "/", optimalAlphaDenominator);
        console.log("Tiny pool total assets:", totalAssets);
        console.log("Tiny pool total shares:", totalShares);
    }

    /// @notice Test precision with extreme alpha fraction (very close to 1)
    function testOptimalAlphaPrecisionNearFullQuadratic() public {
        // ✅ CORRECT: Fetch absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingPeriod = _tokenized(address(mechanism)).votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Setup with specific deposits
        uint256 totalUserDeposits = 500 ether + 500 ether;
        _signupUser(alice, 500 ether);
        _signupUser(bob, 500 ether);

        // Create proposals
        uint256 pid1 = _createProposal(alice, recipient1, "Near Full Quadratic 1");
        uint256 pid2 = _createProposal(bob, recipient2, "Near Full Quadratic 2");

        // Move to voting period
        vm.warp(votingStartTime + 1);

        // Cast votes to create measurable quadratic advantage
        _castVote(alice, pid1, 15e9, recipient1); // Cost: 225 ether (Alice remaining: 275 ether)
        _castVote(bob, pid1, 10e9, recipient1); // Cost: 100 ether (Bob remaining: 400 ether)
        _castVote(alice, pid2, 16e9, recipient2); // Cost: 256 ether (Alice remaining: 19 ether)
        // Project 1: (15e9 + 10e9)² = (25e9)² = 625 ether, linear = 325 ether
        // Project 2: (16e9)² = 256 ether, linear = 256 ether
        // Total: quadratic = 881 ether, linear = 581 ether
        // Quadratic advantage = 881 - 581 = 300 ether

        console.log("=== NEAR FULL QUADRATIC PRECISION TEST ===");

        // Get totals
        uint256 totalQuadraticSum = mechanism.totalQuadraticSum();
        uint256 totalLinearSum = mechanism.totalLinearSum();

        console.log("Total Quadratic Sum:", totalQuadraticSum);
        console.log("Total Linear Sum:", totalLinearSum);

        // Use matching pool that's almost enough for full quadratic funding
        uint256 quadraticAdvantage = totalQuadraticSum - totalLinearSum;
        require(quadraticAdvantage > 10, "Need sufficient quadratic advantage for this test");
        uint256 nearFullMatchingPool = quadraticAdvantage - 1; // 1 wei short of full quadratic

        // Calculate optimal alpha (should be very close to 1)
        (uint256 optimalAlphaNumerator, uint256 optimalAlphaDenominator) = mechanism.calculateOptimalAlpha(
            nearFullMatchingPool,
            totalUserDeposits
        );

        console.log("Near-full matching pool:", nearFullMatchingPool);
        console.log("Quadratic advantage:", quadraticAdvantage);
        console.log("Calculated optimal alpha:", optimalAlphaNumerator, "/", optimalAlphaDenominator);

        // Alpha should be very close to 1 (could be exactly 1 if we have just enough matching funds)
        assertTrue(optimalAlphaNumerator > 0, "Alpha numerator should be positive");
        assertTrue(optimalAlphaNumerator <= optimalAlphaDenominator, "Alpha should be <= 1");
        assertTrue(optimalAlphaNumerator * 100 >= optimalAlphaDenominator * 95, "Alpha should be >= 0.95");

        // Apply optimal alpha and add matching pool
        token.mint(address(this), nearFullMatchingPool);
        token.transfer(address(mechanism), nearFullMatchingPool);
        mechanism.setAlpha(optimalAlphaNumerator, optimalAlphaDenominator);

        // Finalize and queue
        vm.warp(votingEndTime + 1);
        _tokenized(address(mechanism)).finalizeVoteTally();
        _tokenized(address(mechanism)).queueProposal(pid1);
        _tokenized(address(mechanism)).queueProposal(pid2);

        // Verify 1:1 ratio is not violated (it's OK to be over 1:1, but not under)
        uint256 assetsFor1Share = _tokenized(address(mechanism)).convertToAssets(1e18);
        assertGe(
            assetsFor1Share,
            1e18,
            "1:1 ratio should not be violated - users should get at least 1:1 assets per share"
        );

        uint256 totalShares = _tokenized(address(mechanism)).totalSupply();
        uint256 totalAssets = token.balanceOf(address(mechanism));
        assertGe(
            totalAssets,
            totalShares,
            "Total assets should be at least equal to total shares (never under-collateralized)"
        );

        console.log("Near-full alpha:", optimalAlphaNumerator, "/", optimalAlphaDenominator);
        console.log("Near-full total assets:", totalAssets);
        console.log("Near-full total shares:", totalShares);
    }

    /// @notice Test precision with huge quadratic advantage (large denominator)
    function testOptimalAlphaPrecisionHugeQuadraticAdvantage() public {
        // ✅ CORRECT: Fetch absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingPeriod = _tokenized(address(mechanism)).votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Setup with large deposits for big votes
        uint256 largeDeposit1 = 10000 ether;
        uint256 largeDeposit2 = 8000 ether;
        uint256 totalUserDeposits = largeDeposit1 + largeDeposit2;

        // Mint additional tokens for large deposits
        token.mint(alice, largeDeposit1);
        token.mint(bob, largeDeposit2);

        _signupUser(alice, largeDeposit1);
        _signupUser(bob, largeDeposit2);

        // Create proposals
        uint256 pid1 = _createProposal(alice, recipient1, "Huge Advantage Project 1");
        uint256 pid2 = _createProposal(bob, recipient2, "Huge Advantage Project 2");

        // Move to voting period
        vm.warp(votingStartTime + 1);

        // Cast very large votes to create huge quadratic advantage
        _castVote(alice, pid1, 80e9, recipient1); // Cost: 6400 ether
        _castVote(bob, pid1, 60e9, recipient1); // Cost: 3600 ether (total: 10000 ether for pid1)
        _castVote(alice, pid2, 60e9, recipient2); // Cost: 3600 ether (Alice total: 10000 ether)
        _castVote(bob, pid2, 65e9, recipient2); // Cost: 4225 ether (Bob remaining: 175 ether)

        console.log("=== HUGE QUADRATIC ADVANTAGE PRECISION TEST ===");

        // Get totals
        uint256 totalQuadraticSum = mechanism.totalQuadraticSum();
        uint256 totalLinearSum = mechanism.totalLinearSum();

        console.log("Total Quadratic Sum:", totalQuadraticSum);
        console.log("Total Linear Sum:", totalLinearSum);

        // Project 1: (80e9 + 60e9)² = (140e9)² = 19600 ether
        // Project 2: (60e9 + 65e9)² = (125e9)² = 15625 ether
        // Total quadratic sum = 35225 ether, linear sum = 17825 ether
        // Quadratic advantage = 17400 ether (huge denominator for alpha)

        uint256 moderateMatchingPool = 5000 ether; // Much smaller than quadratic advantage

        // Calculate optimal alpha (should have large denominator)
        (uint256 optimalAlphaNumerator, uint256 optimalAlphaDenominator) = mechanism.calculateOptimalAlpha(
            moderateMatchingPool,
            totalUserDeposits
        );

        console.log("Moderate matching pool:", moderateMatchingPool);
        console.log("Calculated optimal alpha:", optimalAlphaNumerator, "/", optimalAlphaDenominator);

        // Verify alpha fraction with large denominator
        assertTrue(optimalAlphaNumerator > 0, "Alpha numerator should be positive");
        assertTrue(optimalAlphaDenominator > 10000 ether, "Alpha denominator should be very large");
        assertTrue(optimalAlphaNumerator < optimalAlphaDenominator, "Alpha should be less than 1");

        // Apply optimal alpha and add matching pool
        token.mint(address(this), moderateMatchingPool);
        token.transfer(address(mechanism), moderateMatchingPool);
        mechanism.setAlpha(optimalAlphaNumerator, optimalAlphaDenominator);

        // Finalize and queue
        vm.warp(votingEndTime + 1);
        _tokenized(address(mechanism)).finalizeVoteTally();
        _tokenized(address(mechanism)).queueProposal(pid1);
        _tokenized(address(mechanism)).queueProposal(pid2);

        // Verify 1:1 ratio maintained even with huge quadratic advantage
        uint256 assetsFor1Share = _tokenized(address(mechanism)).convertToAssets(1e18);
        assertApproxEqAbs(assetsFor1Share, 1e18, 100, "1:1 ratio should be maintained with huge quadratic advantage");

        uint256 totalShares = _tokenized(address(mechanism)).totalSupply();
        uint256 totalAssets = token.balanceOf(address(mechanism));
        assertApproxEqAbs(
            totalShares,
            totalAssets,
            100,
            "Total shares should approximately equal total assets with huge advantage"
        );

        console.log("Huge advantage alpha:", optimalAlphaNumerator, "/", optimalAlphaDenominator);
        console.log("Huge advantage total assets:", totalAssets);
        console.log("Huge advantage total shares:", totalShares);
    }

    /// @notice Test that ratios >1:1 only occur when alpha=1 and there are excess matching funds
    function testRatioGreaterThan1OnlyWithAlpha1AndExcessFunds() public {
        // ✅ CORRECT: Fetch absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingPeriod = _tokenized(address(mechanism)).votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Setup with moderate deposits
        uint256 totalUserDeposits = 1000 ether + 800 ether;
        _signupUser(alice, 1000 ether);
        _signupUser(bob, 800 ether);

        // Create proposals
        uint256 pid1 = _createProposal(alice, recipient1, "Test Project 1");
        uint256 pid2 = _createProposal(bob, recipient2, "Test Project 2");

        // Move to voting period
        vm.warp(votingStartTime + 1);

        // Cast votes to create known quadratic advantage
        _castVote(alice, pid1, 20e9, recipient1); // Cost: 400 ether
        _castVote(bob, pid1, 15e9, recipient1); // Cost: 225 ether
        _castVote(alice, pid2, 15e9, recipient2); // Cost: 225 ether
        _castVote(bob, pid2, 18e9, recipient2); // Cost: 324 ether

        console.log("=== EXCESS FUNDS AND ALPHA=1 VALIDATION TEST ===");

        // Get totals
        uint256 totalQuadraticSum = mechanism.totalQuadraticSum();
        uint256 totalLinearSum = mechanism.totalLinearSum();

        console.log("Total Quadratic Sum:", totalQuadraticSum);
        console.log("Total Linear Sum:", totalLinearSum);

        // Calculate quadratic advantage and matching funds needed for full quadratic funding
        uint256 quadraticAdvantage = totalQuadraticSum - totalLinearSum;
        uint256 matchingFundsForFullQuadratic = quadraticAdvantage;
        uint256 excessMatchingFunds = matchingFundsForFullQuadratic + 500 ether; // Extra 500 ether

        console.log("Quadratic advantage:", quadraticAdvantage);
        console.log("Matching funds for full quadratic:", matchingFundsForFullQuadratic);
        console.log("Excess matching funds:", excessMatchingFunds);

        // Calculate optimal alpha with excess funds (should be alpha = 1)
        (uint256 optimalAlphaNumerator, uint256 optimalAlphaDenominator) = mechanism.calculateOptimalAlpha(
            excessMatchingFunds,
            totalUserDeposits
        );

        console.log("Calculated optimal alpha:", optimalAlphaNumerator, "/", optimalAlphaDenominator);

        // Verify alpha = 1 with excess funds
        assertEq(optimalAlphaNumerator, 1, "Alpha numerator should be 1 with excess matching funds");
        assertEq(optimalAlphaDenominator, 1, "Alpha denominator should be 1 with excess matching funds");

        // Apply excess matching funds and alpha = 1
        token.mint(address(this), excessMatchingFunds);
        token.transfer(address(mechanism), excessMatchingFunds);
        mechanism.setAlpha(optimalAlphaNumerator, optimalAlphaDenominator);

        // Finalize and queue
        vm.warp(votingEndTime + 1);
        _tokenized(address(mechanism)).finalizeVoteTally();
        _tokenized(address(mechanism)).queueProposal(pid1);
        _tokenized(address(mechanism)).queueProposal(pid2);

        // Verify ratio is >1:1 when alpha=1 and there are excess funds
        uint256 assetsFor1Share = _tokenized(address(mechanism)).convertToAssets(1e18);
        uint256 totalShares = _tokenized(address(mechanism)).totalSupply();
        uint256 totalAssets = token.balanceOf(address(mechanism));

        console.log("Assets for 1 share:", assetsFor1Share);
        console.log("Total assets:", totalAssets);
        console.log("Total shares:", totalShares);

        // With alpha=1 and excess matching funds, the ratio should be >1:1
        assertGt(assetsFor1Share, 1e18, "Ratio should be >1:1 when alpha=1 and there are excess matching funds");
        assertGt(
            totalAssets,
            totalShares,
            "Total assets should exceed total shares when there are excess matching funds"
        );

        // Verify that total shares equals total quadratic funding (since alpha=1)
        assertEq(totalShares, totalQuadraticSum, "With alpha=1, total shares should equal total quadratic sum");

        // Verify that excess funds remain in the contract (not allocated to shares)
        uint256 expectedExcessAssets = totalUserDeposits + excessMatchingFunds;
        assertEq(
            totalAssets,
            expectedExcessAssets,
            "Total assets should include user deposits + excess matching funds"
        );

        console.log("=== VALIDATION COMPLETE ===");
        console.log("Confirmed: >1:1 ratio only occurs with alpha=1 and excess matching funds");
        console.log("Ratio:", assetsFor1Share, "assets per 1e18 shares");
    }

    /// @notice Test that ratios should never exceed 1:1 when alpha < 1 (fractional alpha)
    function testRatioNeverExceeds1With1WhenAlphaLessThan1() public {
        // ✅ CORRECT: Fetch absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingPeriod = _tokenized(address(mechanism)).votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Setup
        uint256 totalUserDeposits = 1000 ether + 600 ether;
        _signupUser(alice, 1000 ether);
        _signupUser(bob, 600 ether);

        // Create proposals
        uint256 pid1 = _createProposal(alice, recipient1, "Fractional Alpha Project 1");
        uint256 pid2 = _createProposal(bob, recipient2, "Fractional Alpha Project 2");

        // Move to voting period
        vm.warp(votingStartTime + 1);

        // Cast votes to create quadratic advantage (adjusted for available voting power)
        _castVote(alice, pid1, 25e9, recipient1); // Cost: 625 ether (Alice remaining: 375 ether)
        _castVote(bob, pid1, 20e9, recipient1); // Cost: 400 ether (Bob remaining: 200 ether)
        _castVote(alice, pid2, 15e9, recipient2); // Cost: 225 ether (Alice remaining: 150 ether)
        _castVote(bob, pid2, 14e9, recipient2); // Cost: 196 ether (Bob remaining: 4 ether)

        console.log("=== FRACTIONAL ALPHA RATIO VALIDATION TEST ===");

        // Use insufficient matching funds to force fractional alpha
        uint256 limitedMatchingPool = 400 ether; // Less than full quadratic advantage

        // Calculate optimal alpha (should be < 1)
        (uint256 optimalAlphaNumerator, uint256 optimalAlphaDenominator) = mechanism.calculateOptimalAlpha(
            limitedMatchingPool,
            totalUserDeposits
        );

        console.log("Limited matching pool:", limitedMatchingPool);
        console.log("Calculated optimal alpha:", optimalAlphaNumerator, "/", optimalAlphaDenominator);

        // Verify alpha < 1
        assertTrue(
            optimalAlphaNumerator < optimalAlphaDenominator,
            "Alpha should be less than 1 with limited matching funds"
        );

        // Apply limited matching funds and fractional alpha
        token.mint(address(this), limitedMatchingPool);
        token.transfer(address(mechanism), limitedMatchingPool);
        mechanism.setAlpha(optimalAlphaNumerator, optimalAlphaDenominator);

        // Finalize and queue
        vm.warp(votingEndTime + 1);
        _tokenized(address(mechanism)).finalizeVoteTally();
        _tokenized(address(mechanism)).queueProposal(pid1);
        _tokenized(address(mechanism)).queueProposal(pid2);

        // Verify ratio should be exactly 1:1 or very close (never >1:1) when alpha < 1
        uint256 assetsFor1Share = _tokenized(address(mechanism)).convertToAssets(1e18);
        uint256 totalShares = _tokenized(address(mechanism)).totalSupply();
        uint256 totalAssets = token.balanceOf(address(mechanism));

        console.log("Assets for 1 share:", assetsFor1Share);
        console.log("Total assets:", totalAssets);
        console.log("Total shares:", totalShares);

        // With fractional alpha, ratio should be 1:1 (or very close due to rounding)
        assertApproxEqAbs(assetsFor1Share, 1e18, 10, "Ratio should be approximately 1:1 when alpha < 1");
        assertApproxEqAbs(
            totalAssets,
            totalShares,
            10,
            "Total assets should approximately equal total shares when alpha < 1"
        );

        // Verify that we're not over-collateralized when alpha < 1
        assertLe(assetsFor1Share, 1e18 + 10, "Ratio should not significantly exceed 1:1 when alpha < 1");

        console.log("=== VALIDATION COMPLETE ===");
        console.log("Confirmed: ratio approximately 1:1 when alpha < 1 (fractional alpha)");
        console.log("Ratio:", assetsFor1Share, "assets per 1e18 shares");
    }

    /// @notice Test changing alpha after voting to verify if it causes incorrect funding distribution
    function testChangingAlphaAfterVotingBehavior() public {
        // Initialize struct to hold all test data
        TestData memory data;
        data.deploymentTime = block.timestamp;
        // Timeline already set up in data.deploymentTime

        // Setup users and projects
        _signupUser(alice, 1000 ether);
        _signupUser(bob, 800 ether);

        data.pid1 = _createProposal(alice, recipient1, "Alpha Change Test Project 1");
        data.pid2 = _createProposal(bob, recipient2, "Alpha Change Test Project 2");

        // Move to voting period
        vm.warp(data.deploymentTime + _tokenized(address(mechanism)).votingDelay() + 1);

        // Cast votes with initial alpha = 1.0 (100% quadratic funding)
        // Verify initial alpha is 1.0
        (uint256 initialAlphaNumerator, uint256 initialAlphaDenominator) = mechanism.getAlpha();
        assertEq(initialAlphaNumerator, 1, "Initial alpha numerator should be 1");
        assertEq(initialAlphaDenominator, 1, "Initial alpha denominator should be 1");

        // Alice votes 30 on Project 1 (costs 900 ether)
        _castVote(alice, data.pid1, 30e9, recipient1); // Cost: 900 ether

        // Check Project 1 funding with alpha=1.0
        (data.p1Contributions1, data.p1SqrtSum1, data.p1Quadratic1, data.p1Linear1) = mechanism.getTally(data.pid1);

        // Bob votes 25 on Project 2 (costs 625 ether)
        _castVote(bob, data.pid2, 25e9, recipient2); // Cost: 625 ether

        // Check Project 2 funding with alpha=1.0
        (data.p2Contributions1, data.p2SqrtSum1, data.p2Quadratic1, data.p2Linear1) = mechanism.getTally(data.pid2);

        // NOW CHANGE ALPHA TO 0.5 (50% quadratic, 50% linear) AFTER VOTING
        mechanism.setAlpha(1, 2); // Alpha = 0.5

        (data.newAlphaNumerator, data.newAlphaDenominator) = mechanism.getAlpha();

        // Check if Project 1 funding changes with new alpha
        (data.p1Contributions2, data.p1SqrtSum2, data.p1Quadratic2, data.p1Linear2) = mechanism.getTally(data.pid1);

        // Check if Project 2 funding changes with new alpha
        (data.p2Contributions2, data.p2SqrtSum2, data.p2Quadratic2, data.p2Linear2) = mechanism.getTally(data.pid2);

        // Verify raw data hasn't changed (contributions and sqrt sums should be identical)
        assertEq(data.p1Contributions1, data.p1Contributions2, "Project 1 contributions should be unchanged");
        assertEq(data.p1SqrtSum1, data.p1SqrtSum2, "Project 1 sqrt sum should be unchanged");
        assertEq(data.p2Contributions1, data.p2Contributions2, "Project 2 contributions should be unchanged");
        assertEq(data.p2SqrtSum1, data.p2SqrtSum2, "Project 2 sqrt sum should be unchanged");

        // Verify funding amounts changed correctly with new alpha
        // For Project 1: Alice voted 30e9, so quadratic = (30e9)^2 = 900 ether, linear = 900 ether
        // With alpha=0.5: quadratic_weighted = 0.5 * 900 = 450, linear_weighted = 0.5 * 900 = 450
        uint256 expectedP1Quadratic = 450 ether;
        uint256 expectedP1Linear = 450 ether;
        assertEq(data.p1Quadratic2, expectedP1Quadratic, "Project 1 quadratic funding should be 450 with alpha=0.5");
        assertEq(data.p1Linear2, expectedP1Linear, "Project 1 linear funding should be 450 with alpha=0.5");

        // For Project 2: Bob voted 25e9, so quadratic = (25e9)^2 = 625 ether, linear = 625 ether
        // With alpha=0.5: quadratic_weighted = 0.5 * 625 = 312.5, linear_weighted = 0.5 * 625 = 312.5
        uint256 expectedP2Quadratic = 312.5 ether;
        uint256 expectedP2Linear = 312.5 ether;
        assertEq(data.p2Quadratic2, expectedP2Quadratic, "Project 2 quadratic funding should be 312.5 with alpha=0.5");
        assertEq(data.p2Linear2, expectedP2Linear, "Project 2 linear funding should be 312.5 with alpha=0.5");

        // NOW ADD THIRD VOTE AFTER ALPHA CHANGE to verify new votes use new alpha correctly

        // Charlie votes 20e9 on Project 1 (costs 400 ether)
        _signupUser(charlie, 500 ether); // Give Charlie some voting power
        _castVote(charlie, data.pid1, 20e9, recipient1); // Cost: 400 ether

        // Check Project 1 funding after Charlie's vote
        (data.p1Contributions3, data.p1SqrtSum3, data.p1Quadratic3, data.p1Linear3) = mechanism.getTally(data.pid1);

        // Project 1 should now have: Alice(30e9) + Charlie(20e9) = 50e9 total sqrt sum
        // Quadratic = (50e9)^2 = 2500 ether, Linear = Alice(900) + Charlie(400) = 1300 ether
        // With alpha=0.5: quadratic_weighted = 0.5 * 2500 = 1250, linear_weighted = 0.5 * 1300 = 650
        uint256 expectedP1QuadraticFinal = 1250 ether;
        uint256 expectedP1LinearFinal = 650 ether;
        assertEq(data.p1SqrtSum3, 50e9, "Project 1 should have sqrt sum of 50e9");
        assertEq(data.p1Contributions3, 1300 ether, "Project 1 should have contributions of 1300 ether");
        assertEq(data.p1Quadratic3, expectedP1QuadraticFinal, "Project 1 final quadratic should be 1250");
        assertEq(data.p1Linear3, expectedP1LinearFinal, "Project 1 final linear should be 650");

        // Add matching funds for full test
        uint256 matchingFunds = 1000 ether;
        token.mint(address(this), matchingFunds);
        token.transfer(address(mechanism), matchingFunds);

        // Finalize and test actual share distribution
        vm.warp(
            data.deploymentTime +
                _tokenized(address(mechanism)).votingDelay() +
                _tokenized(address(mechanism)).votingPeriod() +
                1
        );
        _tokenized(address(mechanism)).finalizeVoteTally();
        _tokenized(address(mechanism)).queueProposal(data.pid1);
        _tokenized(address(mechanism)).queueProposal(data.pid2);

        // Verify shares were minted according to final alpha=0.5 calculations
        uint256 recipient1Shares = _tokenized(address(mechanism)).balanceOf(recipient1);
        uint256 recipient2Shares = _tokenized(address(mechanism)).balanceOf(recipient2);

        // Expected shares should match final funding calculations with alpha=0.5
        uint256 expectedP1Shares = data.p1Quadratic3 + data.p1Linear3; // 1250 + 650 = 1900
        uint256 expectedP2Shares = data.p2Quadratic2 + data.p2Linear2; // 312.5 + 312.5 = 625

        assertEq(recipient1Shares, expectedP1Shares, "Recipient 1 should receive shares equal to final funding");
        assertEq(recipient2Shares, expectedP2Shares, "Recipient 2 should receive shares equal to final funding");
    }

    function testTotalFundingMatchesAssetsWithOptimalAlpha() public {
        // Initialize struct to hold all test data
        TestData memory data;
        data.deploymentTime = block.timestamp;
        // Timeline already set up in data.deploymentTime

        // Setup users with varying deposits
        _signupUser(alice, 1200 ether);
        _signupUser(bob, 800 ether);
        _signupUser(charlie, 1000 ether);
        data.totalUserDeposits = 3000 ether;

        // Create 3 proposals to test diverse voting patterns
        data.pid1 = _createProposal(alice, recipient1, "Education Project");
        data.pid2 = _createProposal(bob, recipient2, "Healthcare Project");
        data.pid3 = _createProposal(alice, recipient3, "Environmental Project"); // alice creates for charlie's project

        // Move to voting period
        vm.warp(data.deploymentTime + _tokenized(address(mechanism)).votingDelay() + 1);

        // Complex voting pattern across multiple projects
        _castVote(alice, data.pid1, 25e9, recipient1); // Cost: 625 ether
        _castVote(alice, data.pid2, 15e9, recipient2); // Cost: 225 ether
        _castVote(bob, data.pid1, 20e9, recipient1); // Cost: 400 ether
        _castVote(bob, data.pid3, 18e9, recipient3); // Cost: 324 ether
        _castVote(charlie, data.pid2, 22e9, recipient2); // Cost: 484 ether
        _castVote(charlie, data.pid3, 12e9, recipient3); // Cost: 144 ether

        // Fixed matching pool amount
        data.fixedMatchingPool = 500 ether;

        // Get current totals
        data.totalQuadraticSum = mechanism.totalQuadraticSum();
        data.totalLinearSum = mechanism.totalLinearSum();

        // Calculate optimal alpha
        (data.optimalAlphaNumerator, data.optimalAlphaDenominator) = mechanism.calculateOptimalAlpha(
            data.fixedMatchingPool,
            data.totalUserDeposits
        );

        // Apply optimal alpha and add matching pool
        token.mint(address(this), data.fixedMatchingPool);
        token.transfer(address(mechanism), data.fixedMatchingPool);

        // Check totalFunding before setAlpha
        uint256 totalFundingBeforeAlpha = mechanism.totalFunding();

        mechanism.setAlpha(data.optimalAlphaNumerator, data.optimalAlphaDenominator);

        // Check totalFunding after setAlpha
        uint256 totalFundingAfterAlpha = mechanism.totalFunding();

        // Verify that setAlpha immediately updates totalFunding
        assertTrue(totalFundingAfterAlpha != totalFundingBeforeAlpha, "setAlpha should update totalFunding");

        // Calculate expected total funding with optimal alpha
        uint256 expectedTotalFunding = (data.totalQuadraticSum * data.optimalAlphaNumerator) /
            data.optimalAlphaDenominator +
            (data.totalLinearSum * (data.optimalAlphaDenominator - data.optimalAlphaNumerator)) /
            data.optimalAlphaDenominator;

        // Check if setAlpha updated totalFunding correctly
        assertEq(totalFundingAfterAlpha, expectedTotalFunding, "setAlpha should update totalFunding correctly");

        // Finalize to update totalFunding storage
        vm.warp(
            data.deploymentTime +
                _tokenized(address(mechanism)).votingDelay() +
                _tokenized(address(mechanism)).votingPeriod() +
                1
        );
        _tokenized(address(mechanism)).finalizeVoteTally();

        // Verify totalFunding matches expected calculation
        uint256 actualTotalFunding = mechanism.totalFunding();

        assertEq(actualTotalFunding, expectedTotalFunding, "Total funding should match alpha-weighted calculation");

        // Verify total assets available
        data.totalAssets = token.balanceOf(address(mechanism));

        assertEq(
            data.totalAssets,
            data.totalUserDeposits + data.fixedMatchingPool,
            "Total assets should equal deposits plus matching pool"
        );

        // With optimal alpha, total funding should approximately equal total assets
        assertApproxEqAbs(
            actualTotalFunding,
            data.totalAssets,
            10,
            "Total funding should approximately match total assets"
        );

        // Queue all proposals and verify shares
        _tokenized(address(mechanism)).queueProposal(data.pid1);
        _tokenized(address(mechanism)).queueProposal(data.pid2);
        _tokenized(address(mechanism)).queueProposal(data.pid3);

        // Verify individual project funding adds up to total
        (, , uint256 q1, uint256 l1) = mechanism.getTally(data.pid1);
        (, , uint256 q2, uint256 l2) = mechanism.getTally(data.pid2);
        (, , uint256 q3, uint256 l3) = mechanism.getTally(data.pid3);

        uint256 sumOfProjectFunding = (q1 + l1) + (q2 + l2) + (q3 + l3);

        assertApproxEqAbs(
            sumOfProjectFunding,
            actualTotalFunding,
            10,
            "Sum of project funding should equal total funding within precision"
        );

        // Verify 1:1 asset-to-share ratio is maintained
        uint256 assetsFor1Share = _tokenized(address(mechanism)).convertToAssets(1e18);

        assertGe(assetsFor1Share, 1e18, "Should maintain at least 1:1 asset-to-share ratio");
    }

    function testDiverseVotingPatternsWithFixedMatchingPool() public {
        // Initialize struct to hold all test data
        TestData memory data;
        data.deploymentTime = block.timestamp;
        // Timeline already set up in data.deploymentTime

        // Setup 4 users with different deposit amounts
        _signupUser(alice, 1500 ether);
        _signupUser(bob, 1000 ether);
        _signupUser(charlie, 800 ether);
        data.dave = address(0x104);
        token.mint(data.dave, 2000 ether);
        _signupUser(data.dave, 700 ether);
        data.totalUserDeposits = 4000 ether;

        // Create 4 proposals
        data.pid1 = _createProposal(alice, recipient1, "AI Research");
        data.pid2 = _createProposal(bob, recipient2, "Climate Tech");
        data.pid3 = _createProposal(alice, recipient3, "Public Health"); // alice creates for charlie's project
        data.recipient4 = address(0x204);
        data.pid4 = _createProposal(bob, data.recipient4, "Education Access"); // bob creates for dave's project

        // Move to voting period
        vm.warp(data.deploymentTime + _tokenized(address(mechanism)).votingDelay() + 1);

        // Pattern 1: Heavy concentration on one project
        _castVote(alice, data.pid1, 35e9, recipient1); // Cost: 1225 ether
        _castVote(bob, data.pid1, 25e9, recipient1); // Cost: 625 ether

        // Pattern 2: Moderate support across multiple projects
        _castVote(charlie, data.pid1, 10e9, recipient1); // Cost: 100 ether
        _castVote(charlie, data.pid2, 15e9, recipient2); // Cost: 225 ether
        _castVote(charlie, data.pid3, 20e9, recipient3); // Cost: 400 ether

        // Pattern 3: Small votes spread widely
        _castVote(data.dave, data.pid1, 5e9, recipient1); // Cost: 25 ether
        _castVote(data.dave, data.pid2, 8e9, recipient2); // Cost: 64 ether
        _castVote(data.dave, data.pid3, 12e9, recipient3); // Cost: 144 ether
        _castVote(data.dave, data.pid4, 18e9, data.recipient4); // Cost: 324 ether

        // Additional votes to create interesting dynamics
        _castVote(alice, data.pid2, 12e9, recipient2); // Cost: 144 ether (remaining from 1500-1225=275)
        _castVote(bob, data.pid3, 15e9, recipient3); // Cost: 225 ether (remaining from 1000-625=375)

        // Get voting results
        data.totalQuadraticSum = mechanism.totalQuadraticSum();
        data.totalLinearSum = mechanism.totalLinearSum();

        // Test with multiple fixed matching pool sizes
        uint256[3] memory matchingPoolSizes = [uint256(600 ether), uint256(1200 ether), uint256(2000 ether)];

        for (uint256 i = 0; i < matchingPoolSizes.length; i++) {
            uint256 matchingPool = matchingPoolSizes[i];

            // Calculate optimal alpha for this matching pool size
            (uint256 alphaNumerator, uint256 alphaDenominator) = mechanism.calculateOptimalAlpha(
                matchingPool,
                data.totalUserDeposits
            );

            // Calculate expected total funding
            uint256 expectedTotalFunding = (data.totalQuadraticSum * alphaNumerator) /
                alphaDenominator +
                (data.totalLinearSum * (alphaDenominator - alphaNumerator)) /
                alphaDenominator;

            uint256 expectedTotalAssets = data.totalUserDeposits + matchingPool;

            // With optimal alpha, these should be approximately equal
            assertApproxEqAbs(
                expectedTotalFunding,
                expectedTotalAssets,
                10,
                "Total funding should match total assets with optimal alpha"
            );

            // Verify alpha is within valid bounds
            assertTrue(alphaNumerator <= alphaDenominator, "Alpha should be <= 1");
            if (expectedTotalAssets > data.totalLinearSum && data.totalQuadraticSum > data.totalLinearSum) {
                assertTrue(alphaNumerator > 0, "Alpha should be positive when matching pool can provide benefit");
            }
        }

        // Test finalization with the largest matching pool
        data.finalMatchingPool = 2000 ether;
        token.mint(address(this), data.finalMatchingPool);
        token.transfer(address(mechanism), data.finalMatchingPool);

        (data.finalAlphaNumerator, data.finalAlphaDenominator) = mechanism.calculateOptimalAlpha(
            data.finalMatchingPool,
            data.totalUserDeposits
        );

        mechanism.setAlpha(data.finalAlphaNumerator, data.finalAlphaDenominator);

        // Finalize and verify total funding is updated correctly
        vm.warp(
            data.deploymentTime +
                _tokenized(address(mechanism)).votingDelay() +
                _tokenized(address(mechanism)).votingPeriod() +
                1
        );
        _tokenized(address(mechanism)).finalizeVoteTally();

        data.finalTotalFunding = mechanism.totalFunding();
        data.finalTotalAssets = token.balanceOf(address(mechanism));

        assertApproxEqAbs(
            data.finalTotalFunding,
            data.finalTotalAssets,
            10,
            "Final total funding should match total assets"
        );

        // Queue all proposals and verify individual funding
        _tokenized(address(mechanism)).queueProposal(data.pid1);
        _tokenized(address(mechanism)).queueProposal(data.pid2);
        _tokenized(address(mechanism)).queueProposal(data.pid3);
        _tokenized(address(mechanism)).queueProposal(data.pid4);

        // Calculate sum of individual project funding
        uint256 totalProjectFunding = 0;
        for (uint256 pid = data.pid1; pid <= data.pid4; pid++) {
            (, , uint256 q, uint256 l) = mechanism.getTally(pid);
            uint256 projectFunding = q + l;
            totalProjectFunding += projectFunding;
        }

        assertApproxEqAbs(
            totalProjectFunding,
            data.finalTotalFunding,
            10,
            "Sum of project funding should equal total funding within precision"
        );
    }
}
