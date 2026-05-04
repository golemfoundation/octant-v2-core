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

/// @title Recipient Journey Integration Tests
/// @notice Comprehensive tests for recipient user journey covering advocacy, allocation, and redemption
contract QuadraticVotingRecipientJourneyTest is Test {
    AllocationMechanismFactory factory;
    ERC20Mock token;
    QuadraticVotingMechanism mechanism;

    address alice = address(0x1);
    address bob = address(0x2);
    address charlie = address(0x3);
    address dave = address(0x4);
    address eve = address(0x5);
    address frank = address(0x6);

    uint256 constant LARGE_DEPOSIT = 1000 ether;
    uint256 constant MEDIUM_DEPOSIT = 500 ether;
    uint256 constant QUORUM_REQUIREMENT = 500;
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;
    uint256 constant TIMELOCK_DELAY = 1 days;

    /// @notice Test context struct for stack optimization
    /// @dev Consolidates all test variables into storage to prevent stack too deep issues
    struct TestContext {
        // Proposal and timing
        uint256 startBlock;
        uint256 pid1;
        uint256 pid2;
        uint256 queueTime;
        // Additional proposal IDs for different test scenarios
        uint256 pidCharlie;
        uint256 pidDave;
        uint256 pidEve;
        // Share and asset tracking
        uint256 charlieShares;
        uint256 daveShares;
        uint256 totalSupply;
        uint256 totalAssets;
        // Charlie redemption tracking
        uint256 charlieMaxRedeem;
        uint256 charliePartialRedeem;
        uint256 charlieAssets1;
        uint256 charlieRemainingShares;
        uint256 charlieMaxRedeem2;
        uint256 charlieAssets2;
        uint256 charlieRemainingAfterSecond;
        uint256 charlieAssets3;
        uint256 charlieMaxRedeem3;
        // Dave redemption tracking
        uint256 daveMaxRedeemShares;
        uint256 daveAssets;
        uint256 daveRemainingShares;
        uint256 daveAssets2;
        uint256 daveMaxRedeem2;
        // Expected values and verification
        uint256 expectedCharlieAssets1;
        uint256 expectedDaveAssets;
        uint256 expectedCharlieAssets2;
        uint256 totalRemainingShares;
        uint256 totalAssetsRedeemed;
        uint256 charlieSharesRedeemed;
        // Funding tracking variables for outcome monitoring
        uint256 charlieQuadraticFunding;
        uint256 charlieLinearFunding;
        uint256 charlieFor;
        uint256 daveQuadraticFunding;
        uint256 daveLinearFunding;
        uint256 daveFor;
        uint256 eveQuadraticFunding;
        uint256 eveLinearFunding;
        uint256 eveFor;
    }

    /// @notice Storage-based test context for stack optimization
    TestContext internal currentTestCtx;

    /// @notice Clear test context for fresh initialization
    function _clearTestContext() internal {
        currentTestCtx.startBlock = 0;
        currentTestCtx.pid1 = 0;
        currentTestCtx.pid2 = 0;
        currentTestCtx.queueTime = 0;
        currentTestCtx.pidCharlie = 0;
        currentTestCtx.pidDave = 0;
        currentTestCtx.pidEve = 0;
        currentTestCtx.charlieShares = 0;
        currentTestCtx.daveShares = 0;
        currentTestCtx.totalSupply = 0;
        currentTestCtx.totalAssets = 0;
        currentTestCtx.charlieMaxRedeem = 0;
        currentTestCtx.charliePartialRedeem = 0;
        currentTestCtx.charlieAssets1 = 0;
        currentTestCtx.charlieRemainingShares = 0;
        currentTestCtx.charlieMaxRedeem2 = 0;
        currentTestCtx.charlieAssets2 = 0;
        currentTestCtx.charlieRemainingAfterSecond = 0;
        currentTestCtx.charlieAssets3 = 0;
        currentTestCtx.charlieMaxRedeem3 = 0;
        currentTestCtx.daveMaxRedeemShares = 0;
        currentTestCtx.daveAssets = 0;
        currentTestCtx.daveRemainingShares = 0;
        currentTestCtx.daveAssets2 = 0;
        currentTestCtx.daveMaxRedeem2 = 0;
        currentTestCtx.expectedCharlieAssets1 = 0;
        currentTestCtx.expectedDaveAssets = 0;
        currentTestCtx.expectedCharlieAssets2 = 0;
        currentTestCtx.totalRemainingShares = 0;
        currentTestCtx.totalAssetsRedeemed = 0;
        currentTestCtx.charlieSharesRedeemed = 0;
        currentTestCtx.charlieQuadraticFunding = 0;
        currentTestCtx.charlieLinearFunding = 0;
        currentTestCtx.charlieFor = 0;
        currentTestCtx.daveQuadraticFunding = 0;
        currentTestCtx.daveLinearFunding = 0;
        currentTestCtx.daveFor = 0;
        currentTestCtx.eveQuadraticFunding = 0;
        currentTestCtx.eveLinearFunding = 0;
        currentTestCtx.eveFor = 0;
    }

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
    /// @param recipient Expected recipient address for the proposal
    function _castVote(address voter, uint256 pid, uint256 weight, address recipient) internal {
        vm.prank(voter);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, weight, recipient);
    }

    function setUp() public {
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();

        token.mint(alice, 2000 ether);
        token.mint(bob, 1500 ether);
        token.mint(frank, 200 ether);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Recipient Journey Test",
            symbol: "RJTEST",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: QUORUM_REQUIREMENT,
            timelockDelay: TIMELOCK_DELAY,
            gracePeriod: 7 days,
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

    /// @notice Test recipient proposal advocacy and creation
    function testRecipientAdvocacy_ProposalCreation() public {
        uint256 startBlock = _tokenized(address(mechanism)).startBlock();
        vm.roll(startBlock - 1);

        // Recipients need proposers with voting power
        _signupUser(alice, LARGE_DEPOSIT);
        _signupUser(bob, MEDIUM_DEPOSIT);

        // Successful proposal creation for recipient
        uint256 pid1 = _createProposal(alice, charlie, "Charlie's Clean Energy Initiative");

        TokenizedAllocationMechanism.Proposal memory proposal1 = _tokenized(address(mechanism)).proposals(pid1);
        assertEq(proposal1.proposer, alice);
        assertEq(proposal1.recipient, charlie);
        assertEq(proposal1.description, "Charlie's Clean Energy Initiative");
        assertFalse(proposal1.canceled);

        // Multiple recipients can have proposals
        _createProposal(bob, dave, "Dave's Education Platform");
        _createProposal(alice, eve, "Eve's Healthcare Program");

        assertEq(_tokenized(address(mechanism)).getProposalCount(), 3);

        // Recipient uniqueness constraint
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.RecipientUsed.selector, charlie));
        vm.prank(bob);
        _tokenized(address(mechanism)).propose(charlie, "Another proposal for Charlie");

        // Recipient cannot self-propose (no voting power)
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.ProposeNotAllowed.selector, charlie));
        vm.prank(charlie);
        _tokenized(address(mechanism)).propose(frank, "Self-initiated proposal");

        // Zero address cannot be recipient
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.InvalidRecipient.selector, address(0)));
        vm.prank(alice);
        _tokenized(address(mechanism)).propose(address(0), "Invalid recipient");
    }

    /// @notice Test recipient monitoring and outcome tracking
    function testRecipientMonitoring_OutcomeTracking() public {
        _clearTestContext();

        // ✅ CORRECT: Fetch absolute timeline from contract
        uint256 deploymentTime = block.timestamp; // When mechanism was deployed
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingPeriod = _tokenized(address(mechanism)).votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Setup voting scenario with multiple outcomes
        _signupUser(alice, LARGE_DEPOSIT);
        _signupUser(bob, MEDIUM_DEPOSIT);
        _signupUser(frank, 100 ether);

        // Create proposals for different recipients
        currentTestCtx.pidCharlie = _createProposal(alice, charlie, "Charlie's Project");
        currentTestCtx.pidDave = _createProposal(bob, dave, "Dave's Project");
        currentTestCtx.pidEve = _createProposal(alice, eve, "Eve's Project");

        // Use absolute warp for voting
        vm.warp(votingStartTime + 1);

        // Create different voting outcomes
        // Charlie: Successful (meets quorum)
        _castVote(alice, currentTestCtx.pidCharlie, 30, charlie);
        _castVote(bob, currentTestCtx.pidCharlie, 15, charlie);

        // Dave: Failed (below quorum)
        _castVote(bob, currentTestCtx.pidDave, 10, dave);

        // Eve: Negative outcome
        _castVote(alice, currentTestCtx.pidEve, 12, eve);
        _castVote(frank, currentTestCtx.pidEve, 8, eve);

        // Recipients can monitor progress in real-time using getTally() from ProperQF
        (, , currentTestCtx.charlieQuadraticFunding, currentTestCtx.charlieLinearFunding) = mechanism.getTally(
            currentTestCtx.pidCharlie
        );
        currentTestCtx.charlieFor = currentTestCtx.charlieQuadraticFunding + currentTestCtx.charlieLinearFunding;
        // Charlie: Alice(25) + Bob(12) = (37)² × 0.5 = 684.5, rounded funding calculation
        assertTrue(currentTestCtx.charlieFor > 0, "Charlie should have funding from QuadraticFunding calculation");

        (, , currentTestCtx.daveQuadraticFunding, currentTestCtx.daveLinearFunding) = mechanism.getTally(
            currentTestCtx.pidDave
        );
        currentTestCtx.daveFor = currentTestCtx.daveQuadraticFunding + currentTestCtx.daveLinearFunding;
        // Dave: Bob(10) = (10)² × 0.5 = 50
        assertTrue(currentTestCtx.daveFor > 0, "Dave should have some funding");

        (, , currentTestCtx.eveQuadraticFunding, currentTestCtx.eveLinearFunding) = mechanism.getTally(
            currentTestCtx.pidEve
        );
        currentTestCtx.eveFor = currentTestCtx.eveQuadraticFunding + currentTestCtx.eveLinearFunding;
        // Eve: Alice(12) + Frank(8) = (20)² × 0.5 = 200
        assertTrue(currentTestCtx.eveFor > 0, "Eve should have funding from For votes");

        // End voting and finalize
        vm.warp(votingEndTime + 1);
        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        // Test outcome tracking
        assertEq(
            uint(_tokenized(address(mechanism)).state(currentTestCtx.pidCharlie)),
            uint(TokenizedAllocationMechanism.ProposalState.Succeeded)
        );
        assertEq(
            uint(_tokenized(address(mechanism)).state(currentTestCtx.pidDave)),
            uint(TokenizedAllocationMechanism.ProposalState.Defeated)
        );
        assertEq(
            uint(_tokenized(address(mechanism)).state(currentTestCtx.pidEve)),
            uint(TokenizedAllocationMechanism.ProposalState.Defeated)
        );
    }

    /// @notice Test recipient share allocation and redemption
    function testRecipientShares_AllocationRedemption() public {
        // ✅ CORRECT: Fetch absolute timeline from contract
        uint256 deploymentTime = block.timestamp; // When mechanism was deployed
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingPeriod = _tokenized(address(mechanism)).votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Setup successful proposal scenario
        _signupUser(alice, LARGE_DEPOSIT);
        _signupUser(bob, MEDIUM_DEPOSIT);

        uint256 pid = _createProposal(alice, charlie, "Charlie's Successful Project");

        // Use absolute warp for voting
        vm.warp(votingStartTime + 1);

        // Generate successful vote outcome
        _castVote(alice, pid, 30, charlie);
        _castVote(bob, pid, 20, charlie);

        vm.warp(votingEndTime + 1);
        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        // Share allocation on queuing
        assertEq(_tokenized(address(mechanism)).balanceOf(charlie), 0);
        assertEq(_tokenized(address(mechanism)).totalSupply(), 0);

        uint256 timestampBefore = block.timestamp;
        (bool success2, ) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pid));
        require(success2, "Queue proposal failed");

        // Verify share allocation based on QuadraticFunding calculation
        uint256 actualShares = _tokenized(address(mechanism)).balanceOf(charlie);
        assertTrue(actualShares > 0, "Charlie should receive shares based on QuadraticFunding");
        assertEq(_tokenized(address(mechanism)).totalSupply(), actualShares);

        // With matching pool: totalAssets = user deposits + matching pool
        uint256 expectedTotalAssets = LARGE_DEPOSIT + MEDIUM_DEPOSIT + 2000 ether; // 1000 + 500 + 2000 = 3500
        assertEq(_tokenized(address(mechanism)).totalAssets(), expectedTotalAssets);
        assertEq(_tokenized(address(mechanism)).proposalShares(pid), actualShares);

        // Timelock enforcement
        uint256 redeemableTime = _tokenized(address(mechanism)).globalRedemptionStart();
        assertEq(redeemableTime, timestampBefore + TIMELOCK_DELAY);
        assertGt(redeemableTime, block.timestamp);

        // Cannot redeem before timelock
        vm.expectRevert("Allocation: redeem more than max");
        vm.prank(charlie);
        _tokenized(address(mechanism)).redeem(actualShares, charlie, charlie);

        // Successful redemption after timelock
        vm.warp(redeemableTime + 1);

        uint256 charlieTokensBefore = token.balanceOf(charlie);
        uint256 mechanismTokensBefore = token.balanceOf(address(mechanism));

        vm.prank(charlie);
        uint256 assetsReceived = _tokenized(address(mechanism)).redeem(actualShares, charlie, charlie);

        // Verify redemption effects
        assertEq(_tokenized(address(mechanism)).balanceOf(charlie), 0);
        assertEq(_tokenized(address(mechanism)).totalSupply(), 0);
        assertEq(token.balanceOf(charlie), charlieTokensBefore + assetsReceived);
        assertEq(token.balanceOf(address(mechanism)), mechanismTokensBefore - assetsReceived);
        // With matching pool: charlie gets 100% of shares, so 100% of total assets
        // Total assets = user deposits + matching pool = (alice + bob) + 2000
        // Since charlie is the only recipient, assetsReceived should equal total assets
        assertEq(assetsReceived, expectedTotalAssets);
    }

    /// @notice Test recipient partial redemption and share management
    function testRecipientShares_PartialRedemption() public {
        _clearTestContext();

        // ✅ CORRECT: Fetch absolute timeline from contract
        uint256 deploymentTime = block.timestamp; // When mechanism was deployed
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingPeriod = _tokenized(address(mechanism)).votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Setup multiple successful recipients
        vm.startPrank(alice);
        token.approve(address(mechanism), LARGE_DEPOSIT);
        _tokenized(address(mechanism)).signup(LARGE_DEPOSIT);
        vm.stopPrank();

        vm.startPrank(bob);
        token.approve(address(mechanism), MEDIUM_DEPOSIT);
        _tokenized(address(mechanism)).signup(MEDIUM_DEPOSIT);
        vm.stopPrank();

        currentTestCtx.pid1 = _createProposal(alice, charlie, "Charlie's Project");
        currentTestCtx.pid2 = _createProposal(bob, dave, "Dave's Project");

        // Use absolute warp for voting
        vm.warp(votingStartTime + 1);

        // Vote for both proposals
        _castVote(alice, currentTestCtx.pid1, 30, charlie);
        _castVote(bob, currentTestCtx.pid2, 25, dave);

        vm.warp(votingEndTime + 1);
        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        // Queue both proposals at the same time to ensure same timelock schedule
        currentTestCtx.queueTime = block.timestamp;

        // Warp to a specific time BEFORE queuing to ensure both get the same timestamp
        vm.warp(currentTestCtx.queueTime);
        (bool success1, ) = address(mechanism).call(
            abi.encodeWithSignature("queueProposal(uint256)", currentTestCtx.pid1)
        );
        require(success1, "Queue proposal 1 failed");

        // Reset to same timestamp for second proposal
        vm.warp(currentTestCtx.queueTime);
        (bool success2, ) = address(mechanism).call(
            abi.encodeWithSignature("queueProposal(uint256)", currentTestCtx.pid2)
        );
        require(success2, "Queue proposal 2 failed");

        // Verify both recipients received shares based on QuadraticFunding calculations
        currentTestCtx.charlieShares = _tokenized(address(mechanism)).balanceOf(charlie);
        currentTestCtx.daveShares = _tokenized(address(mechanism)).balanceOf(dave);
        currentTestCtx.totalSupply = _tokenized(address(mechanism)).totalSupply();

        assertTrue(currentTestCtx.charlieShares > 0, "Charlie should receive shares");
        assertTrue(currentTestCtx.daveShares > 0, "Dave should receive shares");
        assertEq(currentTestCtx.totalSupply, currentTestCtx.charlieShares + currentTestCtx.daveShares);

        // Fast forward past timelock with buffer for safety
        vm.warp(block.timestamp + TIMELOCK_DELAY + 100);

        // Charlie partial redemption (50%) - use maxRedeem to avoid boundary issues
        currentTestCtx.charlieMaxRedeem = _tokenized(address(mechanism)).maxRedeem(charlie);
        currentTestCtx.charliePartialRedeem = currentTestCtx.charlieMaxRedeem / 2; // Redeem half of what's allowed
        vm.prank(charlie);
        currentTestCtx.charlieAssets1 = _tokenized(address(mechanism)).redeem(
            currentTestCtx.charliePartialRedeem,
            charlie,
            charlie
        );

        currentTestCtx.charlieRemainingShares = currentTestCtx.charlieShares - currentTestCtx.charliePartialRedeem;
        assertEq(_tokenized(address(mechanism)).balanceOf(charlie), currentTestCtx.charlieRemainingShares);
        assertEq(
            _tokenized(address(mechanism)).totalSupply(),
            currentTestCtx.totalSupply - currentTestCtx.charliePartialRedeem
        );

        // With matching pool: calculate expected assets based on share-to-asset ratio
        currentTestCtx.totalAssets = LARGE_DEPOSIT + MEDIUM_DEPOSIT + 2000 ether; // 3500 ether
        currentTestCtx.expectedCharlieAssets1 =
            (currentTestCtx.charliePartialRedeem * currentTestCtx.totalAssets) /
            currentTestCtx.totalSupply;
        assertApproxEqAbs(
            currentTestCtx.charlieAssets1,
            currentTestCtx.expectedCharlieAssets1,
            1,
            "Charlie assets1 within 1 wei"
        );

        // Dave full redemption - use maxRedeem to handle any rounding issues
        currentTestCtx.daveMaxRedeemShares = _tokenized(address(mechanism)).maxRedeem(dave);
        vm.prank(dave);
        currentTestCtx.daveAssets = _tokenized(address(mechanism)).redeem(
            currentTestCtx.daveMaxRedeemShares,
            dave,
            dave
        );

        currentTestCtx.daveRemainingShares = currentTestCtx.daveShares - currentTestCtx.daveMaxRedeemShares;
        assertEq(_tokenized(address(mechanism)).balanceOf(dave), currentTestCtx.daveRemainingShares);
        assertEq(
            _tokenized(address(mechanism)).totalSupply(),
            currentTestCtx.charlieRemainingShares + currentTestCtx.daveRemainingShares
        );

        currentTestCtx.expectedDaveAssets =
            (currentTestCtx.daveMaxRedeemShares * currentTestCtx.totalAssets) /
            currentTestCtx.totalSupply;
        assertApproxEqAbs(currentTestCtx.daveAssets, currentTestCtx.expectedDaveAssets, 1, "Dave assets within 1 wei");

        // Charlie remaining redemption - redeem whatever is left and allowed
        currentTestCtx.charlieMaxRedeem2 = _tokenized(address(mechanism)).maxRedeem(charlie);
        vm.prank(charlie);
        currentTestCtx.charlieAssets2 = _tokenized(address(mechanism)).redeem(
            currentTestCtx.charlieMaxRedeem2,
            charlie,
            charlie
        );

        // If Charlie has any remaining shares due to rounding, redeem them too
        currentTestCtx.charlieRemainingAfterSecond = _tokenized(address(mechanism)).balanceOf(charlie);
        currentTestCtx.charlieAssets3 = 0;
        if (currentTestCtx.charlieRemainingAfterSecond > 0) {
            currentTestCtx.charlieMaxRedeem3 = _tokenized(address(mechanism)).maxRedeem(charlie);
            if (currentTestCtx.charlieMaxRedeem3 > 0) {
                vm.prank(charlie);
                currentTestCtx.charlieAssets3 = _tokenized(address(mechanism)).redeem(
                    currentTestCtx.charlieMaxRedeem3,
                    charlie,
                    charlie
                );
            }
        }

        // Charlie should now have redeemed all shares
        assertEq(_tokenized(address(mechanism)).balanceOf(charlie), 0, "Charlie should have redeemed all shares");
        assertEq(_tokenized(address(mechanism)).totalSupply(), currentTestCtx.daveRemainingShares);

        currentTestCtx.expectedCharlieAssets2 =
            (currentTestCtx.charlieMaxRedeem2 * currentTestCtx.totalAssets) /
            currentTestCtx.totalSupply;
        assertApproxEqAbs(
            currentTestCtx.charlieAssets2,
            currentTestCtx.expectedCharlieAssets2,
            2,
            "Charlie assets2 within 2 wei"
        );

        // Let Dave redeem any remaining shares too
        currentTestCtx.daveAssets2 = 0;
        if (currentTestCtx.daveRemainingShares > 0) {
            currentTestCtx.daveMaxRedeem2 = _tokenized(address(mechanism)).maxRedeem(dave);
            if (currentTestCtx.daveMaxRedeem2 > 0) {
                vm.prank(dave);
                currentTestCtx.daveAssets2 = _tokenized(address(mechanism)).redeem(
                    currentTestCtx.daveMaxRedeem2,
                    dave,
                    dave
                );
            }
        }

        // Verify total assets redeemed correctly with matching pool conversion using inline computation
        {
            currentTestCtx.charlieSharesRedeemed =
                currentTestCtx.charliePartialRedeem +
                currentTestCtx.charlieMaxRedeem2;
            if (currentTestCtx.charlieAssets3 > 0) {
                currentTestCtx.charlieSharesRedeemed += currentTestCtx.charlieRemainingAfterSecond;
            }
            assertApproxEqAbs(
                currentTestCtx.charlieAssets1 + currentTestCtx.charlieAssets2 + currentTestCtx.charlieAssets3,
                (currentTestCtx.charlieSharesRedeemed * currentTestCtx.totalAssets) / currentTestCtx.totalSupply,
                3,
                "Charlie total within 3 wei"
            );
        }

        // Both recipients should have redeemed all or nearly all their shares
        currentTestCtx.totalRemainingShares = _tokenized(address(mechanism)).totalSupply();
        assertTrue(currentTestCtx.totalRemainingShares <= 1, "Should have at most 1 remaining share due to rounding");

        // Verify total assets conservation - almost all assets should be redeemed
        currentTestCtx.totalAssetsRedeemed =
            currentTestCtx.charlieAssets1 +
            currentTestCtx.charlieAssets2 +
            currentTestCtx.charlieAssets3 +
            currentTestCtx.daveAssets +
            currentTestCtx.daveAssets2;
        assertApproxEqAbs(
            currentTestCtx.totalAssetsRedeemed,
            currentTestCtx.totalAssets,
            10,
            "Total assets redeemed should be close to total assets"
        );
    }

    /// @notice Test recipient share transferability and ERC20 functionality
    function testRecipientShares_TransferabilityERC20() public {
        // ✅ CORRECT: Fetch absolute timeline from contract
        uint256 deploymentTime = block.timestamp; // When mechanism was deployed
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingPeriod = _tokenized(address(mechanism)).votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Setup successful allocation
        vm.startPrank(alice);
        token.approve(address(mechanism), LARGE_DEPOSIT);
        _tokenized(address(mechanism)).signup(LARGE_DEPOSIT);
        vm.stopPrank();

        uint256 pid = _createProposal(alice, charlie, "Charlie's Project");

        // Use absolute warp for voting
        vm.warp(votingStartTime + 1);

        _castVote(alice, pid, 30, charlie);

        vm.warp(votingEndTime + 1);
        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        (bool success2, ) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pid));
        require(success2, "Queue proposal failed");

        // Charlie receives shares from QuadraticFunding calculation
        uint256 charlieShares = _tokenized(address(mechanism)).balanceOf(charlie);
        assertTrue(charlieShares > 0, "Charlie should receive shares");

        // Test that transfers are blocked before redemption period
        vm.prank(charlie);
        vm.expectRevert("Transfers only allowed during redemption period");
        _tokenized(address(mechanism)).transfer(dave, charlieShares / 3);

        // Fast forward to redemption period start
        vm.warp(block.timestamp + TIMELOCK_DELAY);

        // Test share transferability (use reasonable portion of actual shares)
        uint256 transferAmount = charlieShares / 3; // Transfer 1/3 of shares
        vm.prank(charlie);
        _tokenized(address(mechanism)).transfer(dave, transferAmount);

        // Verify transfer
        assertEq(_tokenized(address(mechanism)).balanceOf(charlie), charlieShares - transferAmount);
        assertEq(_tokenized(address(mechanism)).balanceOf(dave), transferAmount);
        assertEq(_tokenized(address(mechanism)).totalSupply(), charlieShares);

        // Test approval and transferFrom
        uint256 allowanceAmount = charlieShares / 5; // Approve 1/5 of original shares
        vm.prank(charlie);
        _tokenized(address(mechanism)).approve(dave, allowanceAmount);

        assertEq(_tokenized(address(mechanism)).allowance(charlie, dave), allowanceAmount);

        vm.prank(dave);
        _tokenized(address(mechanism)).transferFrom(charlie, eve, allowanceAmount);

        // Verify transferFrom effects
        assertEq(_tokenized(address(mechanism)).balanceOf(charlie), charlieShares - transferAmount - allowanceAmount);
        assertEq(_tokenized(address(mechanism)).balanceOf(eve), allowanceAmount);
        assertEq(_tokenized(address(mechanism)).allowance(charlie, dave), 0);

        // Dave can redeem transferred shares
        vm.prank(dave);
        uint256 daveAssets = _tokenized(address(mechanism)).redeem(transferAmount, dave, dave);

        // With matching pool: total assets = 1000 (alice) + 2000 (matching pool) = 3000 ether
        // Conversion ratio = 3000 ether / 900 shares = 3.333... ether per share
        uint256 totalAssets = LARGE_DEPOSIT + 2000 ether; // 3000 ether
        uint256 expectedDaveAssets = (transferAmount * totalAssets) / charlieShares;
        assertEq(daveAssets, expectedDaveAssets);
        assertEq(_tokenized(address(mechanism)).balanceOf(dave), 0);

        // Eve can redeem transferred shares
        vm.prank(eve);
        uint256 eveAssets = _tokenized(address(mechanism)).redeem(allowanceAmount, eve, eve);

        uint256 expectedEveAssets = (allowanceAmount * totalAssets) / charlieShares;
        assertEq(eveAssets, expectedEveAssets);
        assertEq(_tokenized(address(mechanism)).balanceOf(eve), 0);
    }
}
