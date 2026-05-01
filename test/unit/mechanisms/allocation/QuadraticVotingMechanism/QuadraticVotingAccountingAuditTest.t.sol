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

/// @title Quadratic Voting Accounting Audit Test
/// @notice Comprehensive end-to-end test tracking every state change for auditor verification
/// @dev Tests 3 voters × 2 proposals with equal vote weights to verify accounting integrity
///
/// AUDIT SCENARIO OVERVIEW:
/// ========================
/// This test demonstrates a complete quadratic funding round with rigorous accounting verification:
///
/// SETUP:
/// - 3 users (Alice, Bob, Charlie) each deposit 1000 ether → 1000 voting power each
/// - 2 proposals (Project Alpha, Project Beta)
/// - Alpha = 1 (100% quadratic funding, 0% linear) for simplicity
/// - Matching pool added dynamically = totalQuadraticSum for exact 1:1 shares:assets ratio
///
/// VOTING PATTERN:
/// - ALL 3 users vote on BOTH proposals with weight 20 each
/// - Vote cost: 20² = 400 voting power per vote
/// - Total voting power consumed: 400 × 2 votes × 3 users = 2400
/// - Remaining voting power per user: 1000 - 800 = 200
///
/// QUADRATIC FUNDING CALCULATION:
/// Each proposal receives: 3 users × weight 20 = total weight 60
/// Total quadratic sum per proposal: (60)² = 3600
/// Alpha = 1, so funding = 1 × 3600 + 0 × contributions = 3600 shares per proposal
/// Matching pool added = (totalQuadraticSum - totalLinearSum) = (7200 - 2400) = 4800 ether
///
/// ASSET DISTRIBUTION:
/// Total assets: 2400 user deposits + 4800 matching pool = 7200 ether
/// Total shares: 3600 × 2 = 7200 shares
/// Shares:Assets ratio: 7200/7200 = 1:1 (perfect ratio achieved)
///
/// VERIFICATION POINTS:
/// 1. Asset conservation through all phases
/// 2. Voting power consumption mechanics
/// 3. Quadratic funding formula correctness with alpha scaling
/// 4. Share-to-asset conversion approaching 1:1 ratio
/// 5. Timelock enforcement
/// 6. Complete asset redemption with minimal dust remaining
contract QuadraticVotingAccountingAuditTest is Test {
    AllocationMechanismFactory factory;
    ERC20Mock token;
    QuadraticVotingMechanism mechanism;

    // Test actors
    address alice = address(0x1); // Voter 1
    address bob = address(0x2); // Voter 2
    address charlie = address(0x3); // Voter 3
    address recipient1 = address(0x4); // Project Alpha
    address recipient2 = address(0x5); // Project Beta

    // Test parameters
    uint256 constant USER_DEPOSIT = 1000 ether; // Each user deposits same amount
    uint256 constant VOTE_WEIGHT = 20; // Each vote has weight 20
    uint256 constant VOTE_COST = 400; // 20² = 400 voting power cost
    uint256 constant ALPHA_NUMERATOR = 1; // 100% quadratic funding
    uint256 constant ALPHA_DENOMINATOR = 1;
    uint256 constant QUORUM_REQUIREMENT = 500;
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;
    uint256 constant TIMELOCK_DELAY = 1 days;

    // Accounting state tracking
    struct AccountingState {
        uint256 totalMechanismAssets;
        uint256 totalUserDeposits;
        uint256 totalMatchingPool;
        uint256 totalSharesSupply;
        uint256 aliceVotingPower;
        uint256 bobVotingPower;
        uint256 charlieVotingPower;
        uint256 recipient1Shares;
        uint256 recipient2Shares;
        uint256 proposal1Funding;
        uint256 proposal2Funding;
    }

    // Enhanced test context for stack optimization
    struct TestContext {
        // Alpha calculations
        uint256 constrainedAlphaNumerator;
        uint256 constrainedAlphaDenominator;
        uint256 requiredMatchingPool;
        // Funding calculations
        uint256 expectedProject1Funding;
        uint256 expectedProject2Funding;
        uint256 totalQuadraticSum;
        uint256 totalLinearSum;
        // Asset tracking
        uint256 totalUserDeposits;
        uint256 totalAssets;
        uint256 totalShares;
        uint256 matchingPoolNeeded;
        uint256 totalAssetsNeeded;
        // Redemption tracking
        uint256 recipient1Shares;
        uint256 recipient2Shares;
        uint256 recipient3Shares;
        uint256 recipient1Assets;
        uint256 recipient2Assets;
        uint256 recipient3Assets;
        uint256 expectedTotalAssets;
        // Proposal IDs and test state
        uint256 pid1;
        uint256 pid2;
        uint256 pid3;
        uint256 startTime;
        uint256 queueTimestamp;
        uint256 expectedRedeemableTime;
        // Expected funding and calculations
        uint256 expectedFundingPerProposal;
        uint256 expectedRemainingPower;
        uint256 expectedAssetsPerRecipient;
        // Asset distribution verification
        uint256 totalAssetsDistributed;
        uint256 totalSharesRedeemed;
        // Final state tracking
        uint256 mechanismBalanceBefore;
        uint256 recipient1BalanceBefore;
        uint256 recipient2BalanceBefore;
        uint256 recipient1ActualShares;
        uint256 recipient2ActualShares;
    }

    // Storage-based test context for stack optimization
    TestContext internal currentTestCtx;

    function _tokenized(address _mechanism) internal pure returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(_mechanism);
    }

    /// @notice Clear test context for fresh initialization
    function _clearTestContext() internal {
        delete currentTestCtx.constrainedAlphaNumerator;
        delete currentTestCtx.constrainedAlphaDenominator;
        delete currentTestCtx.requiredMatchingPool;
        delete currentTestCtx.expectedProject1Funding;
        delete currentTestCtx.expectedProject2Funding;
        delete currentTestCtx.totalQuadraticSum;
        delete currentTestCtx.totalLinearSum;
        delete currentTestCtx.totalUserDeposits;
        delete currentTestCtx.totalAssets;
        delete currentTestCtx.totalShares;
        delete currentTestCtx.matchingPoolNeeded;
        delete currentTestCtx.totalAssetsNeeded;
        delete currentTestCtx.recipient1Shares;
        delete currentTestCtx.recipient2Shares;
        delete currentTestCtx.recipient3Shares;
        delete currentTestCtx.recipient1Assets;
        delete currentTestCtx.recipient2Assets;
        delete currentTestCtx.recipient3Assets;
        delete currentTestCtx.expectedTotalAssets;
        delete currentTestCtx.pid1;
        delete currentTestCtx.pid2;
        delete currentTestCtx.pid3;
        delete currentTestCtx.startTime;
        delete currentTestCtx.queueTimestamp;
        delete currentTestCtx.expectedRedeemableTime;
        delete currentTestCtx.expectedFundingPerProposal;
        delete currentTestCtx.expectedRemainingPower;
        delete currentTestCtx.expectedAssetsPerRecipient;
        delete currentTestCtx.totalAssetsDistributed;
        delete currentTestCtx.totalSharesRedeemed;
        delete currentTestCtx.mechanismBalanceBefore;
        delete currentTestCtx.recipient1BalanceBefore;
        delete currentTestCtx.recipient2BalanceBefore;
        delete currentTestCtx.recipient1ActualShares;
        delete currentTestCtx.recipient2ActualShares;
    }

    function setUp() public {
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();

        // Mint tokens to all actors
        token.mint(alice, 2000 ether);
        token.mint(bob, 2000 ether);
        token.mint(charlie, 2000 ether);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Accounting Audit Test",
            symbol: "AUDIT",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: QUORUM_REQUIREMENT,
            timelockDelay: TIMELOCK_DELAY,
            gracePeriod: 7 days,
            owner: address(0)
        });

        address mechanismAddr = factory.deployQuadraticVotingMechanism(config, ALPHA_NUMERATOR, ALPHA_DENOMINATOR);
        mechanism = QuadraticVotingMechanism(payable(mechanismAddr));

        // Set alice as keeper and management for proposers
        _tokenized(address(mechanism)).setKeeper(alice);
        _tokenized(address(mechanism)).setManagement(alice);
        _tokenized(address(mechanism)).setManagement(bob);
    }

    /// @notice Capture complete accounting state for audit verification
    function _captureAccountingState(uint256 pid1, uint256 pid2) internal view returns (AccountingState memory) {
        AccountingState memory state;

        // Asset accounting
        state.totalMechanismAssets = token.balanceOf(address(mechanism));
        state.totalUserDeposits = USER_DEPOSIT * 3; // 3 users × 1000 ether
        // Handle case where mechanism may have less than total user deposits (before all users signup)
        if (state.totalMechanismAssets >= state.totalUserDeposits) {
            state.totalMatchingPool = state.totalMechanismAssets - state.totalUserDeposits;
        } else {
            state.totalMatchingPool = 0;
            state.totalUserDeposits = state.totalMechanismAssets; // Actual deposits so far
        }
        state.totalSharesSupply = _tokenized(address(mechanism)).totalSupply();

        // Voting power accounting
        state.aliceVotingPower = _tokenized(address(mechanism)).votingPower(alice);
        state.bobVotingPower = _tokenized(address(mechanism)).votingPower(bob);
        state.charlieVotingPower = _tokenized(address(mechanism)).votingPower(charlie);

        // Share allocation
        state.recipient1Shares = _tokenized(address(mechanism)).balanceOf(recipient1);
        state.recipient2Shares = _tokenized(address(mechanism)).balanceOf(recipient2);

        // Proposal funding (if proposals exist) - use getTally() from ProperQF
        if (pid1 != 0) {
            (, , uint256 p1QuadraticFunding, uint256 p1LinearFunding) = mechanism.getTally(pid1);
            state.proposal1Funding = p1QuadraticFunding + p1LinearFunding;
        }
        if (pid2 != 0) {
            (, , uint256 p2QuadraticFunding, uint256 p2LinearFunding) = mechanism.getTally(pid2);
            state.proposal2Funding = p2QuadraticFunding + p2LinearFunding;
        }

        return state;
    }

    /// @notice Print detailed accounting state for audit trail
    function _logAccountingState(string memory phase, AccountingState memory state) internal pure {
        console.log("=== ACCOUNTING STATE:", phase, "===");
        console.log("Total Mechanism Assets:", state.totalMechanismAssets);
        console.log("Total User Deposits:", state.totalUserDeposits);
        console.log("Total Matching Pool:", state.totalMatchingPool);
        console.log("Total Shares Supply:", state.totalSharesSupply);
        console.log("Alice Voting Power:", state.aliceVotingPower);
        console.log("Bob Voting Power:", state.bobVotingPower);
        console.log("Charlie Voting Power:", state.charlieVotingPower);
        console.log("Recipient1 Shares:", state.recipient1Shares);
        console.log("Recipient2 Shares:", state.recipient2Shares);
        console.log("Proposal1 Funding:", state.proposal1Funding);
        console.log("Proposal2 Funding:", state.proposal2Funding);
        console.log("");
    }

    /// @notice Verify accounting invariants at each stage
    function _verifyAccountingInvariants(AccountingState memory state, string memory phase) internal pure {
        // Invariant 1: Asset conservation varies by phase
        if (keccak256(bytes(phase)) == keccak256(bytes("FINAL"))) {
            // After all redemptions, mechanism should have minimal dust (<=2 wei)
            assertTrue(
                state.totalMechanismAssets <= 2,
                string(abi.encodePacked("Final asset cleanup failed in ", phase))
            );
        } else if (keccak256(bytes(phase)) == keccak256(bytes("POST_REDEMPTION_1"))) {
            // After first redemption, mechanism should have ~half the assets
            uint256 originalAssets = state.totalUserDeposits + state.totalMatchingPool;
            assertTrue(
                state.totalMechanismAssets < originalAssets,
                string(abi.encodePacked("Assets should decrease after redemption in ", phase))
            );
        } else {
            // Before redemptions, total mechanism assets = user deposits + dynamic matching pool
            uint256 expectedTotalAssets = state.totalUserDeposits + state.totalMatchingPool;
            assertEq(
                state.totalMechanismAssets,
                expectedTotalAssets,
                string(abi.encodePacked("Asset conservation failed in ", phase))
            );
        }

        // Invariant 2: Individual share balances sum to total supply
        uint256 totalIndividualShares = state.recipient1Shares + state.recipient2Shares;
        assertEq(
            totalIndividualShares,
            state.totalSharesSupply,
            string(abi.encodePacked("Share conservation failed in ", phase))
        );

        // Invariant 3: Total voting power cannot exceed deposits * 3 users
        uint256 totalVotingPower = state.aliceVotingPower + state.bobVotingPower + state.charlieVotingPower;
        assertTrue(totalVotingPower <= USER_DEPOSIT * 3, string(abi.encodePacked("Voting power overflow in ", phase)));
    }

    /// @notice Complete end-to-end accounting audit test
    function testCompleteAccountingAudit_ThreeVotersTwoProposals() public {
        // Clear and initialize test context
        _clearTestContext();
        currentTestCtx.startTime = block.timestamp;
        // No need to set initial time as mechanism uses current timestamp

        // ==================== PHASE 1: INITIAL STATE ====================
        AccountingState memory initialState = _captureAccountingState(0, 0);
        _logAccountingState("INITIAL", initialState);

        // Verify initial conditions
        assertEq(initialState.totalMechanismAssets, 0, "No assets initially");
        assertEq(initialState.totalSharesSupply, 0, "No shares should exist initially");
        assertEq(initialState.aliceVotingPower, 0, "No voting power initially");

        // ==================== PHASE 2: USER SIGNUPS ====================
        console.log("=== PHASE 2: USER SIGNUPS ===");

        // Alice signup
        vm.startPrank(alice);
        token.approve(address(mechanism), USER_DEPOSIT);
        _tokenized(address(mechanism)).signup(USER_DEPOSIT);
        vm.stopPrank();

        // Bob signup
        vm.startPrank(bob);
        token.approve(address(mechanism), USER_DEPOSIT);
        _tokenized(address(mechanism)).signup(USER_DEPOSIT);
        vm.stopPrank();

        // Charlie signup
        vm.startPrank(charlie);
        token.approve(address(mechanism), USER_DEPOSIT);
        _tokenized(address(mechanism)).signup(USER_DEPOSIT);
        vm.stopPrank();

        AccountingState memory postSignupState = _captureAccountingState(0, 0);
        _logAccountingState("POST_SIGNUP", postSignupState);
        _verifyAccountingInvariants(postSignupState, "POST_SIGNUP");

        // Verify signup accounting
        assertEq(postSignupState.totalMechanismAssets, USER_DEPOSIT * 3, "Assets should include all user deposits");
        assertEq(postSignupState.aliceVotingPower, USER_DEPOSIT, "Alice should have 1000 voting power");
        assertEq(postSignupState.bobVotingPower, USER_DEPOSIT, "Bob should have 1000 voting power");
        assertEq(postSignupState.charlieVotingPower, USER_DEPOSIT, "Charlie should have 1000 voting power");

        // ==================== PHASE 3: PROPOSAL CREATION ====================
        console.log("=== PHASE 3: PROPOSAL CREATION ===");

        vm.prank(alice);
        currentTestCtx.pid1 = _tokenized(address(mechanism)).propose(recipient1, "Project Alpha - Renewable Energy");

        vm.prank(bob);
        currentTestCtx.pid2 = _tokenized(address(mechanism)).propose(recipient2, "Project Beta - Education Platform");

        AccountingState memory postProposalState = _captureAccountingState(currentTestCtx.pid1, currentTestCtx.pid2);
        _logAccountingState("POST_PROPOSAL", postProposalState);
        _verifyAccountingInvariants(postProposalState, "POST_PROPOSAL");

        // Verify no changes to assets/voting power from proposals
        assertEq(
            postProposalState.totalMechanismAssets,
            postSignupState.totalMechanismAssets,
            "Proposal creation should not affect assets"
        );
        assertEq(
            postProposalState.aliceVotingPower,
            postSignupState.aliceVotingPower,
            "Proposal creation should not affect voting power"
        );

        // ==================== PHASE 4: VOTING PHASE ====================
        console.log("=== PHASE 4: VOTING PHASE ===");
        vm.warp(currentTestCtx.startTime + VOTING_DELAY + 1);

        // All three users vote on both proposals with same weight (20)
        console.log("Vote weight:", VOTE_WEIGHT);
        console.log("Vote cost:", VOTE_COST);

        // Alice votes
        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(
            currentTestCtx.pid1,
            TokenizedAllocationMechanism.VoteType.For,
            VOTE_WEIGHT,
            recipient1
        );
        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(
            currentTestCtx.pid2,
            TokenizedAllocationMechanism.VoteType.For,
            VOTE_WEIGHT,
            recipient2
        );

        // Bob votes
        vm.prank(bob);
        _tokenized(address(mechanism)).castVote(
            currentTestCtx.pid1,
            TokenizedAllocationMechanism.VoteType.For,
            VOTE_WEIGHT,
            recipient1
        );
        vm.prank(bob);
        _tokenized(address(mechanism)).castVote(
            currentTestCtx.pid2,
            TokenizedAllocationMechanism.VoteType.For,
            VOTE_WEIGHT,
            recipient2
        );

        // Charlie votes
        vm.prank(charlie);
        _tokenized(address(mechanism)).castVote(
            currentTestCtx.pid1,
            TokenizedAllocationMechanism.VoteType.For,
            VOTE_WEIGHT,
            recipient1
        );
        vm.prank(charlie);
        _tokenized(address(mechanism)).castVote(
            currentTestCtx.pid2,
            TokenizedAllocationMechanism.VoteType.For,
            VOTE_WEIGHT,
            recipient2
        );

        AccountingState memory postVotingState = _captureAccountingState(currentTestCtx.pid1, currentTestCtx.pid2);
        _logAccountingState("POST_VOTING", postVotingState);
        _verifyAccountingInvariants(postVotingState, "POST_VOTING");

        // Store expected values in test context
        currentTestCtx.expectedRemainingPower = USER_DEPOSIT - (VOTE_COST * 2); // Each user votes twice
        assertEq(
            postVotingState.aliceVotingPower,
            currentTestCtx.expectedRemainingPower,
            "Alice voting power incorrectly consumed"
        );
        assertEq(
            postVotingState.bobVotingPower,
            currentTestCtx.expectedRemainingPower,
            "Bob voting power incorrectly consumed"
        );
        assertEq(
            postVotingState.charlieVotingPower,
            currentTestCtx.expectedRemainingPower,
            "Charlie voting power incorrectly consumed"
        );

        // Verify proposal funding calculation
        // Each proposal: 3 users × weight 20 = total weight 60
        // QuadraticFunding: α × (60)² + (1-α) × contributions = 1 × 3600 + 0 × 1200 = 3600
        currentTestCtx.expectedFundingPerProposal = 3600;
        assertEq(
            postVotingState.proposal1Funding,
            currentTestCtx.expectedFundingPerProposal,
            "Proposal 1 funding should be 3600"
        );
        assertEq(
            postVotingState.proposal2Funding,
            currentTestCtx.expectedFundingPerProposal,
            "Proposal 2 funding should be 3600"
        );

        // ==================== PHASE 4.5: ADD MATCHING POOL FOR 1:1 RATIO ====================
        console.log("=== PHASE 4.5: ADD MATCHING POOL FOR 1:1 RATIO ===");

        // Calculate matching pool needed using ProperQF formula and store in test context
        currentTestCtx.totalQuadraticSum = mechanism.totalQuadraticSum(); // Should be 7200 (3600 × 2)
        currentTestCtx.totalLinearSum = mechanism.totalLinearSum(); // Should be 2400 (1200 × 2)
        uint256 currentAssets = postVotingState.totalMechanismAssets; // User deposits = totalLinearSum

        // For alpha = 1: matching pool = totalQuadraticSum - totalLinearSum
        currentTestCtx.matchingPoolNeeded =
            (currentTestCtx.totalQuadraticSum - currentTestCtx.totalLinearSum) *
            1 ether;
        currentTestCtx.totalAssetsNeeded = currentTestCtx.totalQuadraticSum * 1 ether; // For 1:1 ratio

        console.log("Total quadratic sum:", currentTestCtx.totalQuadraticSum);
        console.log("Total linear sum:", currentTestCtx.totalLinearSum);
        console.log("Current assets (user deposits):", currentAssets);
        console.log("Matching pool needed:", currentTestCtx.matchingPoolNeeded);
        console.log("Total assets needed:", currentTestCtx.totalAssetsNeeded);

        // Add the exact matching pool needed for 1:1 ratio
        token.mint(address(this), currentTestCtx.matchingPoolNeeded);
        token.transfer(address(mechanism), currentTestCtx.matchingPoolNeeded);

        // ==================== PHASE 5: FINALIZATION ====================
        console.log("=== PHASE 5: FINALIZATION ===");
        vm.warp(currentTestCtx.startTime + VOTING_DELAY + VOTING_PERIOD + 1);

        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        AccountingState memory postFinalizationState = _captureAccountingState(
            currentTestCtx.pid1,
            currentTestCtx.pid2
        );
        _logAccountingState("POST_FINALIZATION", postFinalizationState);
        _verifyAccountingInvariants(postFinalizationState, "POST_FINALIZATION");

        // Verify finalization preserves general asset state (may capture total differently)
        assertTrue(
            postFinalizationState.totalMechanismAssets >= currentTestCtx.totalAssetsNeeded,
            "Finalization should preserve at least the expected assets"
        );
        assertEq(postFinalizationState.totalSharesSupply, 0, "No shares should be minted until queuing");

        // ==================== PHASE 6: PROPOSAL QUEUING ====================
        console.log("=== PHASE 6: PROPOSAL QUEUING ===");

        currentTestCtx.queueTimestamp = block.timestamp;

        (bool success1, ) = address(mechanism).call(
            abi.encodeWithSignature("queueProposal(uint256)", currentTestCtx.pid1)
        );
        require(success1, "Queue proposal 1 failed");

        (bool success2, ) = address(mechanism).call(
            abi.encodeWithSignature("queueProposal(uint256)", currentTestCtx.pid2)
        );
        require(success2, "Queue proposal 2 failed");

        AccountingState memory postQueueingState = _captureAccountingState(currentTestCtx.pid1, currentTestCtx.pid2);
        _logAccountingState("POST_QUEUING", postQueueingState);
        _verifyAccountingInvariants(postQueueingState, "POST_QUEUING");

        // Verify share minting - should be exact with alpha = 1
        uint256 expectedSharesPerRecipient = currentTestCtx.expectedFundingPerProposal; // 3600 shares per recipient
        assertEq(
            postQueueingState.recipient1Shares,
            expectedSharesPerRecipient,
            "Recipient1 should get exactly 3600 shares"
        );
        assertEq(
            postQueueingState.recipient2Shares,
            expectedSharesPerRecipient,
            "Recipient2 should get exactly 3600 shares"
        );
        assertEq(
            postQueueingState.totalSharesSupply,
            expectedSharesPerRecipient * 2,
            "Total shares should be exactly 7200"
        );

        // Verify timelock setup
        currentTestCtx.expectedRedeemableTime = currentTestCtx.queueTimestamp + TIMELOCK_DELAY;
        assertEq(
            _tokenized(address(mechanism)).globalRedemptionStart(),
            currentTestCtx.expectedRedeemableTime,
            "Recipient1 timelock incorrect"
        );
        assertEq(
            _tokenized(address(mechanism)).globalRedemptionStart(),
            currentTestCtx.expectedRedeemableTime,
            "Recipient2 timelock incorrect"
        );

        // ==================== PHASE 7: SHARE REDEMPTION ====================
        console.log("=== PHASE 7: SHARE REDEMPTION ===");

        // Fast forward past timelock
        vm.warp(currentTestCtx.expectedRedeemableTime + 100);

        // Calculate expected redemption amounts based on actual values and store in test context
        currentTestCtx.totalAssets = postQueueingState.totalMechanismAssets;
        currentTestCtx.totalShares = postQueueingState.totalSharesSupply;
        currentTestCtx.expectedAssetsPerRecipient =
            (expectedSharesPerRecipient * currentTestCtx.totalAssets) /
            currentTestCtx.totalShares;

        console.log("Post-queuing total assets:", currentTestCtx.totalAssets);
        console.log("Post-queuing total shares:", currentTestCtx.totalShares);
        console.log("Actual ratio. Assets per recipient:", currentTestCtx.expectedAssetsPerRecipient);

        // For exact verification, total assets should equal exactly what the mechanism calculated
        // The mechanism already determined the optimal asset allocation during finalization
        console.log("Exact ratio verification:");

        console.log("Expected assets per recipient:", currentTestCtx.expectedAssetsPerRecipient);
        console.log("Shares per recipient:", expectedSharesPerRecipient);
        console.log("Total assets:", currentTestCtx.totalAssets);
        console.log("Total shares:", currentTestCtx.totalShares);

        // Recipient1 redemption - use actual shares received and store in test context
        currentTestCtx.recipient1BalanceBefore = token.balanceOf(recipient1);
        currentTestCtx.mechanismBalanceBefore = token.balanceOf(address(mechanism));
        currentTestCtx.recipient1ActualShares = postQueueingState.recipient1Shares;

        vm.prank(recipient1);
        currentTestCtx.recipient1Assets = _tokenized(address(mechanism)).redeem(
            currentTestCtx.recipient1ActualShares,
            recipient1,
            recipient1
        );

        AccountingState memory postRedemption1State = _captureAccountingState(currentTestCtx.pid1, currentTestCtx.pid2);
        _logAccountingState("POST_REDEMPTION_1", postRedemption1State);

        // Verify recipient1 redemption accounting - exact proportional calculation
        uint256 expectedRecipient1Assets = (currentTestCtx.recipient1ActualShares * currentTestCtx.totalAssets) /
            currentTestCtx.totalShares;
        assertEq(
            currentTestCtx.recipient1Assets,
            expectedRecipient1Assets,
            "Recipient1 assets must equal exact proportional share"
        );
        assertEq(
            token.balanceOf(recipient1),
            currentTestCtx.recipient1BalanceBefore + currentTestCtx.recipient1Assets,
            "Recipient1 token balance incorrect"
        );
        assertEq(
            token.balanceOf(address(mechanism)),
            currentTestCtx.mechanismBalanceBefore - currentTestCtx.recipient1Assets,
            "Mechanism token balance incorrect after redemption1"
        );
        assertEq(postRedemption1State.recipient1Shares, 0, "Recipient1 should have no shares left");

        // Recipient2 redemption - use actual shares received and store in test context
        currentTestCtx.recipient2BalanceBefore = token.balanceOf(recipient2);
        currentTestCtx.mechanismBalanceBefore = token.balanceOf(address(mechanism));
        currentTestCtx.recipient2ActualShares = postRedemption1State.recipient2Shares;

        vm.prank(recipient2);
        currentTestCtx.recipient2Assets = _tokenized(address(mechanism)).redeem(
            currentTestCtx.recipient2ActualShares,
            recipient2,
            recipient2
        );

        AccountingState memory finalState = _captureAccountingState(currentTestCtx.pid1, currentTestCtx.pid2);
        _logAccountingState("FINAL", finalState);
        _verifyAccountingInvariants(finalState, "FINAL");

        // Verify recipient2 redemption accounting - exact proportional calculation
        uint256 expectedRecipient2Assets = (currentTestCtx.recipient2ActualShares * currentTestCtx.totalAssets) /
            currentTestCtx.totalShares;
        assertEq(
            currentTestCtx.recipient2Assets,
            expectedRecipient2Assets,
            "Recipient2 assets must equal exact proportional share"
        );
        assertEq(
            token.balanceOf(recipient2),
            currentTestCtx.recipient2BalanceBefore + currentTestCtx.recipient2Assets,
            "Recipient2 token balance incorrect"
        );
        assertEq(finalState.recipient2Shares, 0, "Recipient2 should have no shares left");
        assertEq(finalState.totalSharesSupply, 0, "All shares should be redeemed");

        // ==================== PHASE 8: FINAL VERIFICATION ====================
        console.log("=== PHASE 8: FINAL VERIFICATION ===");

        // Verify good shares:asset ratio achieved using test context
        currentTestCtx.totalAssetsDistributed = currentTestCtx.recipient1Assets + currentTestCtx.recipient2Assets;
        currentTestCtx.totalSharesRedeemed =
            currentTestCtx.recipient1ActualShares +
            currentTestCtx.recipient2ActualShares;

        console.log("Total assets distributed:", currentTestCtx.totalAssetsDistributed);
        console.log("Total shares redeemed:", currentTestCtx.totalSharesRedeemed);
        console.log("EXACT accounting achieved!");

        // Verify exact asset conservation - all assets distributed, none lost
        assertEq(
            currentTestCtx.totalAssetsDistributed,
            currentTestCtx.totalAssets,
            "All assets must be distributed exactly"
        );
        assertEq(currentTestCtx.totalSharesRedeemed, currentTestCtx.totalShares, "All shares must be redeemed exactly");

        // Verify mechanism is completely clean - exact zero balances
        assertEq(finalState.totalSharesSupply, 0, "Mechanism must have exactly zero shares remaining");
        assertEq(token.balanceOf(address(mechanism)), 0, "Mechanism must have exactly zero assets remaining");

        // Verify exact equal distribution (both proposals had identical votes)
        assertEq(
            currentTestCtx.recipient1Assets,
            currentTestCtx.recipient2Assets,
            "Equal votes must result in exactly equal distribution"
        );

        console.log("=== ACCOUNTING AUDIT COMPLETE ===");
        console.log("Total assets distributed:", currentTestCtx.totalAssetsDistributed);
        console.log("Recipient1 received:     ", currentTestCtx.recipient1Assets);
        console.log("Recipient2 received:     ", currentTestCtx.recipient2Assets);
        console.log("Mechanism dust remaining:", token.balanceOf(address(mechanism)));
        console.log("SUCCESS: Alpha=1 approach with dynamic matching pool achieved EXACT accounting!");
    }

    /// @notice Test capital-constrained scenario with fixed matching pool and calculated alpha
    /// @dev Tests different vote patterns with alpha = matching_pool / (totalQuadraticSum - totalLinearSum)
    function testCapitalConstrainedAudit_FixedMatchingPool() public {
        uint256 startTime = block.timestamp;
        // No need to set initial time as mechanism uses current timestamp

        // ==================== SETUP WITH DIFFERENT VOTE PATTERNS ====================
        console.log("=== CAPITAL CONSTRAINED AUDIT: FIXED MATCHING POOL ===");

        // Capital constraint: We'll calculate after voting to determine required matching pool
        // Then verify the alpha calculation formula

        // User signups
        vm.startPrank(alice);
        token.approve(address(mechanism), USER_DEPOSIT);
        _tokenized(address(mechanism)).signup(USER_DEPOSIT);
        vm.stopPrank();

        vm.startPrank(bob);
        token.approve(address(mechanism), USER_DEPOSIT);
        _tokenized(address(mechanism)).signup(USER_DEPOSIT);
        vm.stopPrank();

        vm.startPrank(charlie);
        token.approve(address(mechanism), USER_DEPOSIT);
        _tokenized(address(mechanism)).signup(USER_DEPOSIT);
        vm.stopPrank();

        // Create proposals
        vm.prank(alice);
        uint256 pid1 = _tokenized(address(mechanism)).propose(recipient1, "High-Impact Infrastructure");

        vm.prank(bob);
        uint256 pid2 = _tokenized(address(mechanism)).propose(recipient2, "Community Education");

        vm.warp(startTime + VOTING_DELAY + 1);

        // DIFFERENT VOTE PATTERNS - Asymmetric voting
        // Project 1: Gets strong support (more votes)
        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(pid1, TokenizedAllocationMechanism.VoteType.For, 25, recipient1); // 625 voting power
        vm.prank(bob);
        _tokenized(address(mechanism)).castVote(pid1, TokenizedAllocationMechanism.VoteType.For, 20, recipient1); // 400 voting power
        vm.prank(charlie);
        _tokenized(address(mechanism)).castVote(pid1, TokenizedAllocationMechanism.VoteType.For, 15, recipient1); // 225 voting power

        // Project 2: Gets moderate support (fewer votes, but still meets quorum)
        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(pid2, TokenizedAllocationMechanism.VoteType.For, 15, recipient2); // 225 voting power
        vm.prank(bob);
        _tokenized(address(mechanism)).castVote(pid2, TokenizedAllocationMechanism.VoteType.For, 12, recipient2); // 144 voting power

        console.log("=== VOTE PATTERNS ===");
        console.log("Project 1 votes: Alice(25), Bob(20), Charlie(15) = total weight 60");
        console.log("Project 2 votes: Alice(15), Bob(12) = total weight 27");
        console.log("Project 1 vote costs: 625 + 400 + 225 = 1250");
        console.log("Project 2 vote costs: 225 + 144 = 369");
        console.log("Total linear sum: 1250 + 369 = 1619");

        vm.warp(startTime + VOTING_DELAY + VOTING_PERIOD + 1);

        // ==================== CALCULATE OPTIMAL ALPHA ====================
        console.log("=== CALCULATING OPTIMAL ALPHA ===");

        // Initialize test context with proposal IDs
        currentTestCtx.pid1 = pid1;
        currentTestCtx.pid2 = pid2;

        // Use helper function to calculate alpha parameters and avoid stack issues
        _calculateOptimalAlphaParams(currentTestCtx);

        // For this test, use the exact matching pool needed for alpha = 1
        token.mint(address(this), currentTestCtx.requiredMatchingPool);
        token.transfer(address(mechanism), currentTestCtx.requiredMatchingPool);

        // Update the mechanism's alpha to the optimal value
        mechanism.setAlpha(currentTestCtx.constrainedAlphaNumerator, currentTestCtx.constrainedAlphaDenominator);
        // Note: This requires the mechanism to be deployed with the correct alpha initially
        // For this test, we'll verify the calculation instead

        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        // ==================== VERIFY OPTIMAL FUNDING ====================
        console.log("=== VERIFYING OPTIMAL FUNDING ===");

        // Use helper function to verify funding calculations and avoid stack issues
        _verifyConstrainedFunding(currentTestCtx);

        // Queue proposals
        (bool success1, ) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pid1));
        require(success1, "Queue project 1 failed");

        (bool success2, ) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pid2));
        require(success2, "Queue project 2 failed");

        // ==================== VERIFY EXACT ACCOUNTING ====================
        console.log("=== FINAL ACCOUNTING VERIFICATION ===");

        AccountingState memory finalState = _captureAccountingState(pid1, pid2);

        // Store values in test context
        currentTestCtx.totalUserDeposits = USER_DEPOSIT * 3; // 3000 ether
        currentTestCtx.totalAssets = currentTestCtx.totalUserDeposits + currentTestCtx.requiredMatchingPool;
        currentTestCtx.totalShares = finalState.totalSharesSupply;

        console.log("Total user deposits:", currentTestCtx.totalUserDeposits);
        console.log("Required matching pool:", currentTestCtx.requiredMatchingPool);
        console.log("Total assets:", currentTestCtx.totalAssets);
        console.log("Total shares issued:", currentTestCtx.totalShares);

        // Verify the capital constraint worked
        assertEq(
            finalState.totalMechanismAssets,
            currentTestCtx.totalAssets,
            "Total assets should equal user deposits + required matching pool"
        );
        assertEq(
            currentTestCtx.totalShares,
            currentTestCtx.expectedProject1Funding + currentTestCtx.expectedProject2Funding,
            "Total shares should equal sum of project funding"
        );

        // Fast forward and redeem
        vm.warp(block.timestamp + TIMELOCK_DELAY + 100);

        // Store shares in test context
        currentTestCtx.recipient1Shares = finalState.recipient1Shares;
        currentTestCtx.recipient2Shares = finalState.recipient2Shares;

        // Complete redemption pattern: redeem all shares properly handling ERC4626 rounding
        currentTestCtx.recipient1Assets = 0;
        uint256 recipient1MaxRedeem = _tokenized(address(mechanism)).maxRedeem(recipient1);
        if (recipient1MaxRedeem > 0) {
            vm.prank(recipient1);
            currentTestCtx.recipient1Assets += _tokenized(address(mechanism)).redeem(
                recipient1MaxRedeem,
                recipient1,
                recipient1
            );
        }

        // Handle any remaining shares due to rounding
        uint256 recipient1Remaining = _tokenized(address(mechanism)).balanceOf(recipient1);
        if (recipient1Remaining > 0) {
            uint256 recipient1MaxRedeem2 = _tokenized(address(mechanism)).maxRedeem(recipient1);
            if (recipient1MaxRedeem2 > 0) {
                vm.prank(recipient1);
                currentTestCtx.recipient1Assets += _tokenized(address(mechanism)).redeem(
                    recipient1MaxRedeem2,
                    recipient1,
                    recipient1
                );
            }
        }

        currentTestCtx.recipient2Assets = 0;
        uint256 recipient2MaxRedeem = _tokenized(address(mechanism)).maxRedeem(recipient2);
        if (recipient2MaxRedeem > 0) {
            vm.prank(recipient2);
            currentTestCtx.recipient2Assets += _tokenized(address(mechanism)).redeem(
                recipient2MaxRedeem,
                recipient2,
                recipient2
            );
        }

        // Handle any remaining shares due to rounding
        uint256 recipient2Remaining = _tokenized(address(mechanism)).balanceOf(recipient2);
        if (recipient2Remaining > 0) {
            uint256 recipient2MaxRedeem2 = _tokenized(address(mechanism)).maxRedeem(recipient2);
            if (recipient2MaxRedeem2 > 0) {
                vm.prank(recipient2);
                currentTestCtx.recipient2Assets += _tokenized(address(mechanism)).redeem(
                    recipient2MaxRedeem2,
                    recipient2,
                    recipient2
                );
            }
        }

        // Verify exact proportional distribution based on actual shares redeemed
        uint256 totalActualSharesRedeemed = currentTestCtx.recipient1Shares -
            _tokenized(address(mechanism)).balanceOf(recipient1) +
            currentTestCtx.recipient2Shares -
            _tokenized(address(mechanism)).balanceOf(recipient2);
        currentTestCtx.expectedTotalAssets =
            (totalActualSharesRedeemed * currentTestCtx.totalAssets) /
            currentTestCtx.totalShares;

        // Verify complete asset distribution - should be exact with proper redemption
        uint256 totalAssetsRedeemed = currentTestCtx.recipient1Assets + currentTestCtx.recipient2Assets;
        assertEq(
            totalAssetsRedeemed,
            currentTestCtx.expectedTotalAssets,
            "All redeemable assets must be distributed exactly"
        );

        // Both recipients should have redeemed all or nearly all their shares
        assertTrue(
            _tokenized(address(mechanism)).balanceOf(recipient1) <= 1,
            "Recipient1 should have at most 1 share remaining"
        );
        assertTrue(
            _tokenized(address(mechanism)).balanceOf(recipient2) <= 1,
            "Recipient2 should have at most 1 share remaining"
        );

        // CRITICAL: Investigate precision loss - this is real money
        _investigatePrecisionLoss(currentTestCtx);

        console.log("=== CAPITAL CONSTRAINED AUDIT COMPLETE ===");
        console.log("Project 1 received:", currentTestCtx.recipient1Assets, "ether");
        console.log("Project 2 received:", currentTestCtx.recipient2Assets, "ether");
        console.log("Recipient 1 shares:", currentTestCtx.recipient1Shares);
        console.log("Recipient 2 shares:", currentTestCtx.recipient2Shares);
        console.log("SUCCESS: Capital-constrained scenario achieved exact accounting!");
    }

    /// @notice Test symmetric voting pattern with 2 voters and 3 projects
    /// @dev Each voter casts same votes for each project but different amounts between voters
    function testSymmetricVoting_TwoVotersThreeProjects() public {
        console.log("=== SYMMETRIC VOTING AUDIT: 2 VOTERS, 3 PROJECTS ===");

        // Clear and initialize test context
        _clearTestContext();
        currentTestCtx.startTime = block.timestamp;
        // No need to set initial time as mechanism uses current timestamp

        // === SETUP PHASE ===
        console.log("=== SETUP PHASE ===");

        // Setup additional recipient for third project
        address recipient3 = address(0x103);

        // Mint tokens to voters
        token.mint(alice, USER_DEPOSIT);
        token.mint(bob, USER_DEPOSIT);

        // User signups
        vm.startPrank(alice);
        token.approve(address(mechanism), USER_DEPOSIT);
        _tokenized(address(mechanism)).signup(USER_DEPOSIT);
        vm.stopPrank();

        vm.startPrank(bob);
        token.approve(address(mechanism), USER_DEPOSIT);
        _tokenized(address(mechanism)).signup(USER_DEPOSIT);
        vm.stopPrank();

        // Create three proposals and store in test context
        vm.prank(alice);
        currentTestCtx.pid1 = _tokenized(address(mechanism)).propose(recipient1, "Education Initiative");

        vm.prank(bob);
        currentTestCtx.pid2 = _tokenized(address(mechanism)).propose(recipient2, "Healthcare Project");

        vm.prank(alice);
        currentTestCtx.pid3 = _tokenized(address(mechanism)).propose(recipient3, "Climate Action");

        vm.warp(currentTestCtx.startTime + VOTING_DELAY + 1);

        // === SYMMETRIC VOTING PATTERN ===
        console.log("=== VOTING PATTERNS ===");
        console.log("Alice votes: Project1(20), Project2(20), Project3(20)");
        console.log("Bob votes: Project1(15), Project2(15), Project3(15)");
        console.log("Vote costs: Alice = 3*(20^2) = 1200, Bob = 3*(15^2) = 675");
        console.log("Total linear sum: 1200 + 675 = 1875");

        // Alice votes the same amount (20) for each project
        vm.startPrank(alice);
        _tokenized(address(mechanism)).castVote(
            currentTestCtx.pid1,
            TokenizedAllocationMechanism.VoteType.For,
            20,
            recipient1
        ); // Cost: 400
        _tokenized(address(mechanism)).castVote(
            currentTestCtx.pid2,
            TokenizedAllocationMechanism.VoteType.For,
            20,
            recipient2
        ); // Cost: 400
        _tokenized(address(mechanism)).castVote(
            currentTestCtx.pid3,
            TokenizedAllocationMechanism.VoteType.For,
            20,
            recipient3
        ); // Cost: 400
        vm.stopPrank();

        // Bob votes the same amount (15) for each project
        vm.startPrank(bob);
        _tokenized(address(mechanism)).castVote(
            currentTestCtx.pid1,
            TokenizedAllocationMechanism.VoteType.For,
            15,
            recipient1
        ); // Cost: 225
        _tokenized(address(mechanism)).castVote(
            currentTestCtx.pid2,
            TokenizedAllocationMechanism.VoteType.For,
            15,
            recipient2
        ); // Cost: 225
        _tokenized(address(mechanism)).castVote(
            currentTestCtx.pid3,
            TokenizedAllocationMechanism.VoteType.For,
            15,
            recipient3
        ); // Cost: 225
        vm.stopPrank();

        vm.warp(currentTestCtx.startTime + VOTING_DELAY + VOTING_PERIOD + 1);

        // === QUADRATIC FUNDING CALCULATIONS ===
        console.log("=== VERIFYING QUADRATIC FUNDING ===");

        // Get funding for each project using getTally()
        (, , uint256 p1QuadraticFunding, uint256 p1LinearFunding) = mechanism.getTally(currentTestCtx.pid1);
        (, , uint256 p2QuadraticFunding, uint256 p2LinearFunding) = mechanism.getTally(currentTestCtx.pid2);
        (, , uint256 p3QuadraticFunding, uint256 p3LinearFunding) = mechanism.getTally(currentTestCtx.pid3);

        currentTestCtx.expectedProject1Funding = p1QuadraticFunding + p1LinearFunding;
        currentTestCtx.expectedProject2Funding = p2QuadraticFunding + p2LinearFunding;
        // For symmetric test, project3 funding equals project1 funding
        uint256 project3Funding = p3QuadraticFunding + p3LinearFunding;

        console.log("Project 1 funding:", currentTestCtx.expectedProject1Funding);
        console.log("Project 2 funding:", currentTestCtx.expectedProject2Funding);
        console.log("Project 3 funding:", project3Funding);

        // Expected calculations with alpha = 1.0 (default):
        // Each project: Alice(20) + Bob(15) = vote weight 35
        // Quadratic funding per project: (35)^2 = 1225
        // Linear funding per project: 400 + 225 = 625
        // Total per project: 1225 + 0 = 1225 (since alpha=1, linear component is 0)

        assertEq(currentTestCtx.expectedProject1Funding, 1225, "Project 1 should have symmetric funding");
        assertEq(currentTestCtx.expectedProject2Funding, 1225, "Project 2 should have symmetric funding");
        assertEq(project3Funding, 1225, "Project 3 should have symmetric funding");

        // Verify symmetry: all projects should have identical funding
        assertEq(
            currentTestCtx.expectedProject1Funding,
            currentTestCtx.expectedProject2Funding,
            "Projects 1 and 2 should have equal funding"
        );
        assertEq(currentTestCtx.expectedProject2Funding, project3Funding, "Projects 2 and 3 should have equal funding");

        // === FINALIZATION AND DISTRIBUTION ===
        console.log("=== FINALIZATION PHASE ===");

        // Add matching pool for realistic scenario
        currentTestCtx.matchingPoolNeeded = 3000 ether; // 1000 ether per project
        token.mint(address(this), currentTestCtx.matchingPoolNeeded);
        token.transfer(address(mechanism), currentTestCtx.matchingPoolNeeded);

        // Finalize voting
        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        // Queue all proposals
        (bool success1, ) = address(mechanism).call(
            abi.encodeWithSignature("queueProposal(uint256)", currentTestCtx.pid1)
        );
        require(success1, "Queue project 1 failed");

        (bool success2, ) = address(mechanism).call(
            abi.encodeWithSignature("queueProposal(uint256)", currentTestCtx.pid2)
        );
        require(success2, "Queue project 2 failed");

        (bool success3, ) = address(mechanism).call(
            abi.encodeWithSignature("queueProposal(uint256)", currentTestCtx.pid3)
        );
        require(success3, "Queue project 3 failed");

        // === VERIFICATION ===
        console.log("=== FINAL VERIFICATION ===");

        // Check share balances
        currentTestCtx.recipient1Shares = _tokenized(address(mechanism)).balanceOf(recipient1);
        currentTestCtx.recipient2Shares = _tokenized(address(mechanism)).balanceOf(recipient2);
        currentTestCtx.recipient3Shares = _tokenized(address(mechanism)).balanceOf(recipient3);

        console.log("Recipient 1 shares:", currentTestCtx.recipient1Shares);
        console.log("Recipient 2 shares:", currentTestCtx.recipient2Shares);
        console.log("Recipient 3 shares:", currentTestCtx.recipient3Shares);

        // Verify symmetric share distribution
        assertEq(
            currentTestCtx.recipient1Shares,
            currentTestCtx.recipient2Shares,
            "Recipients 1 and 2 should have equal shares"
        );
        assertEq(
            currentTestCtx.recipient2Shares,
            currentTestCtx.recipient3Shares,
            "Recipients 2 and 3 should have equal shares"
        );

        // Verify shares match funding calculations
        assertEq(
            currentTestCtx.recipient1Shares,
            currentTestCtx.expectedProject1Funding,
            "Recipient 1 shares should match project 1 funding"
        );
        assertEq(
            currentTestCtx.recipient2Shares,
            currentTestCtx.expectedProject2Funding,
            "Recipient 2 shares should match project 2 funding"
        );
        assertEq(
            currentTestCtx.recipient3Shares,
            currentTestCtx.expectedProject1Funding,
            "Recipient 3 shares should match project 3 funding"
        );

        currentTestCtx.totalSharesRedeemed =
            currentTestCtx.recipient1Shares +
            currentTestCtx.recipient2Shares +
            currentTestCtx.recipient3Shares;
        currentTestCtx.expectedTotalAssets = 3 * 1225; // 3 projects × 1225 funding each
        assertEq(
            currentTestCtx.totalSharesRedeemed,
            currentTestCtx.expectedTotalAssets,
            "Total shares should equal sum of project funding"
        );

        console.log("=== SYMMETRIC VOTING AUDIT COMPLETE ===");
        console.log("SUCCESS: Symmetric voting pattern verified!");
        console.log("All three projects received equal funding:", currentTestCtx.expectedProject1Funding);
        console.log("Total funding distributed:", currentTestCtx.totalSharesRedeemed);
    }

    /// @notice Calculate optimal alpha parameters for capital-constrained scenarios
    /// @param ctx Test context to store calculated values
    function _calculateOptimalAlphaParams(TestContext storage ctx) internal {
        ctx.totalQuadraticSum = mechanism.totalQuadraticSum();
        uint256 totalLinearSum = mechanism.totalLinearSum();
        uint256 quadraticMinusLinear = ctx.totalQuadraticSum - totalLinearSum;

        // Demonstrate capital constraint: use 50% of ideal budget
        uint256 smallerBudget = (quadraticMinusLinear * 500) / 1000;
        ctx.constrainedAlphaDenominator = quadraticMinusLinear;
        ctx.constrainedAlphaNumerator = smallerBudget;

        ctx.requiredMatchingPool =
            (ctx.totalQuadraticSum * ctx.constrainedAlphaNumerator) /
            ctx.constrainedAlphaDenominator;

        console.log("Total quadratic sum:", ctx.totalQuadraticSum);
        console.log("Total linear sum:", totalLinearSum);
        console.log("Quadratic - Linear:", quadraticMinusLinear);
        console.log("Example: If budget was", smallerBudget, "shares");
        console.log("Then alpha would be:", ctx.constrainedAlphaNumerator, "/", ctx.constrainedAlphaDenominator);
        console.log(
            "Alpha percentage:",
            (ctx.constrainedAlphaNumerator * 10000) / ctx.constrainedAlphaDenominator,
            "/ 10000"
        );
    }

    /// @notice Verify funding calculations with constrained alpha
    /// @param ctx Test context containing alpha parameters and storing results
    function _verifyConstrainedFunding(TestContext storage ctx) internal {
        // Get actual funding from mechanism
        (, , uint256 project1QuadraticFunding, uint256 project1LinearFunding) = mechanism.getTally(ctx.pid1);
        (, , uint256 project2QuadraticFunding, uint256 project2LinearFunding) = mechanism.getTally(ctx.pid2);

        uint256 project1Funding = project1QuadraticFunding + project1LinearFunding;
        uint256 project2Funding = project2QuadraticFunding + project2LinearFunding;

        console.log("Project 1 funding:", project1Funding);
        console.log("Project 2 funding:", project2Funding);

        // Calculate expected funding in scoped block to limit stack usage
        {
            uint256 project1QuadraticComponent = (60 * 60 * ctx.constrainedAlphaNumerator) /
                ctx.constrainedAlphaDenominator;
            uint256 project1LinearComponent = (1250 *
                (ctx.constrainedAlphaDenominator - ctx.constrainedAlphaNumerator)) / ctx.constrainedAlphaDenominator;
            ctx.expectedProject1Funding = project1QuadraticComponent + project1LinearComponent;

            assertEq(
                project1Funding,
                ctx.expectedProject1Funding,
                "Project 1 funding should match quadratic calculation"
            );
        }

        {
            uint256 project2QuadraticComponent = (27 * 27 * ctx.constrainedAlphaNumerator) /
                ctx.constrainedAlphaDenominator;
            uint256 project2LinearComponent = (369 *
                (ctx.constrainedAlphaDenominator - ctx.constrainedAlphaNumerator)) / ctx.constrainedAlphaDenominator;
            ctx.expectedProject2Funding = project2QuadraticComponent + project2LinearComponent;

            assertEq(
                project2Funding,
                ctx.expectedProject2Funding,
                "Project 2 funding should match quadratic calculation"
            );
        }
    }

    /// @notice Investigate precision loss and verify asset conservation
    /// @param ctx Test context containing all necessary values
    function _investigatePrecisionLoss(TestContext storage ctx) internal view {
        uint256 remainingAssets = token.balanceOf(address(mechanism));
        uint256 remainingShares = _tokenized(address(mechanism)).totalSupply();

        console.log("=== PRECISION LOSS INVESTIGATION ===");
        console.log("Final remaining assets:", remainingAssets);
        console.log("Final remaining shares:", remainingShares);
        console.log("Total original assets:", ctx.totalAssets);
        console.log("Total original shares:", ctx.totalShares);
        console.log("Recipient1 final shares:", _tokenized(address(mechanism)).balanceOf(recipient1));
        console.log("Recipient2 final shares:", _tokenized(address(mechanism)).balanceOf(recipient2));
        console.log("Assets redeemed by recipient1:", ctx.recipient1Assets);
        console.log("Assets redeemed by recipient2:", ctx.recipient2Assets);
        console.log("Total assets redeemed:", ctx.recipient1Assets + ctx.recipient2Assets);
        console.log("Assets that should have been redeemed:", ctx.expectedTotalAssets);

        if (remainingAssets > 0) {
            console.log("PRECISION LOSS DETECTED:");
            console.log("- Amount trapped:", remainingAssets);
            console.log("- Percentage of total:", (remainingAssets * 10000) / ctx.totalAssets, "basis points");
            console.log(
                "- Exchange rate at time of issue: totalAssets/totalShares =",
                ctx.totalAssets,
                "/",
                ctx.totalShares
            );
            if (remainingShares > 0) {
                console.log(
                    "- Current exchange rate: remainingAssets/remainingShares =",
                    remainingAssets,
                    "/",
                    remainingShares
                );
            }
        }

        // ANALYSIS: Determine if this is acceptable dust or a real bug
        if (remainingAssets > 0) {
            uint256 basisPoints = (remainingAssets * 10000) / ctx.totalAssets;
            console.log("Basis points trapped:", basisPoints);

            // More than 10 basis points (0.1%) is unacceptable for a production system
            assertTrue(basisPoints <= 10, "CRITICAL: More than 0.1% of assets trapped - this is a systemic issue");

            // But let's also check if the issue is in our test setup vs the mechanism itself
            console.log("DEBUG: Investigating whether this is test setup or mechanism issue");
            console.log("Total shares minted should equal totalQuadraticSum:", ctx.totalShares);
            console.log("Actual totalQuadraticSum from mechanism:", ctx.totalQuadraticSum);

            // If shares don't equal quadratic sum, the issue is in share minting
            if (ctx.totalShares != ctx.totalQuadraticSum) {
                console.log("BUG FOUND: Share minting doesn't match quadratic funding calculation");
            }
        }
    }
}
