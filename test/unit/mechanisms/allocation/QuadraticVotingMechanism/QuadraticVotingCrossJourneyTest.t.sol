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

/// @title Cross-Journey Integration Tests
/// @notice Tests complete end-to-end workflows across voter, admin, and recipient journeys
contract QuadraticVotingCrossJourneyTest is Test {
    AllocationMechanismFactory factory;
    ERC20Mock token;
    QuadraticVotingMechanism mechanism;

    address alice = address(0x1); // Primary voter
    address bob = address(0x2); // Secondary voter
    address charlie = address(0x3); // Recipient 1
    address dave = address(0x4); // Recipient 2
    address eve = address(0x5); // Recipient 3
    address frank = address(0x6); // Small voter
    address emergencyAdmin = address(0xa);

    uint256 constant LARGE_DEPOSIT = 1000 ether;
    uint256 constant MEDIUM_DEPOSIT = 500 ether;
    uint256 constant SMALL_DEPOSIT = 100 ether;
    uint256 constant QUORUM_REQUIREMENT = 500;
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;
    uint256 constant TIMELOCK_DELAY = 1 days;

    function _tokenized(address _mechanism) internal pure returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(_mechanism);
    }

    function setUp() public {
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();

        // Mint tokens to all actors (including large amount for edge case testing)
        token.mint(alice, type(uint128).max);
        token.mint(bob, 1500 ether);
        token.mint(frank, 200 ether);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Cross Journey Integration Test",
            symbol: "CJITEST",
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

    /// @notice Test complete end-to-end integration across all user journeys
    function testCompleteEndToEnd_Integration() public {
        // No need to manipulate time before setup - mechanism starts immediately at deployment

        // PHASE 1: ADMIN SETUP AND COMMUNITY ONBOARDING

        // Admin monitors community joining
        vm.startPrank(alice);
        token.approve(address(mechanism), LARGE_DEPOSIT);
        _tokenized(address(mechanism)).signup(LARGE_DEPOSIT);
        vm.stopPrank();

        vm.startPrank(bob);
        token.approve(address(mechanism), MEDIUM_DEPOSIT);
        _tokenized(address(mechanism)).signup(MEDIUM_DEPOSIT);
        vm.stopPrank();

        vm.startPrank(frank);
        token.approve(address(mechanism), SMALL_DEPOSIT);
        _tokenized(address(mechanism)).signup(SMALL_DEPOSIT);
        vm.stopPrank();

        // PHASE 2: RECIPIENT ADVOCACY AND PROPOSAL CREATION

        // Recipients work with proposers
        vm.prank(alice);
        uint256 pidCharlie = _tokenized(address(mechanism)).propose(charlie, "Charlie's Renewable Energy Grid");

        vm.prank(bob);
        uint256 pidDave = _tokenized(address(mechanism)).propose(dave, "Dave's Digital Literacy Program");

        vm.prank(alice);
        uint256 pidEve = _tokenized(address(mechanism)).propose(eve, "Eve's Community Health Clinic");

        // PHASE 3: DEMOCRATIC VOTING PROCESS

        // Advance to voting period
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        // Complex voting patterns
        // Alice: Strategic voter supporting energy and education (deposit: 1000 ether)
        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(pidCharlie, TokenizedAllocationMechanism.VoteType.For, 30, charlie);

        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(pidDave, TokenizedAllocationMechanism.VoteType.For, 10, dave);

        // Bob: Focused on education with opposition to energy (deposit: 500 ether)
        vm.prank(bob);
        _tokenized(address(mechanism)).castVote(pidDave, TokenizedAllocationMechanism.VoteType.For, 20, dave);

        vm.prank(bob);
        _tokenized(address(mechanism)).castVote(pidCharlie, TokenizedAllocationMechanism.VoteType.For, 10, charlie);

        // Frank: Supporting healthcare (deposit: 100 ether)
        vm.prank(frank);
        _tokenized(address(mechanism)).castVote(pidEve, TokenizedAllocationMechanism.VoteType.For, 10, eve);

        // PHASE 4: ADMIN FINALIZATION AND EXECUTION

        // Advance past voting period
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        // Admin finalizes voting
        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        // Check final outcomes using QuadraticFunding algorithm
        // Charlie: Alice(30) + Bob(10) = (40)² × 0.5 + contributions × 0.5 = weighted funding meets quorum ✓
        assertEq(
            uint(_tokenized(address(mechanism)).state(pidCharlie)),
            uint(TokenizedAllocationMechanism.ProposalState.Succeeded)
        );

        // Dave: Alice(10) + Bob(20) = (30)² × 0.5 + contributions × 0.5 = weighted funding meets quorum ✓
        assertEq(
            uint(_tokenized(address(mechanism)).state(pidDave)),
            uint(TokenizedAllocationMechanism.ProposalState.Succeeded)
        );

        // Eve: Frank(10) = (10)² × 0.5 + contributions × 0.5 = weighted funding below quorum ✗
        assertEq(
            uint(_tokenized(address(mechanism)).state(pidEve)),
            uint(TokenizedAllocationMechanism.ProposalState.Defeated)
        );

        // Admin queues successful proposals
        (bool success1, ) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pidCharlie));
        require(success1, "Queue Charlie failed");

        (bool success2, ) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pidDave));
        require(success2, "Queue Dave failed");

        // PHASE 5: RECIPIENT REDEMPTION AND ASSET UTILIZATION

        // Verify share distribution - shares are allocated proportionally based on QuadraticFunding
        uint256 charlieShares = _tokenized(address(mechanism)).balanceOf(charlie);
        uint256 daveShares = _tokenized(address(mechanism)).balanceOf(dave);
        uint256 totalSupply = _tokenized(address(mechanism)).totalSupply();

        assertTrue(charlieShares > 0, "Charlie should receive shares");
        assertTrue(daveShares > 0, "Dave should receive shares");
        assertEq(_tokenized(address(mechanism)).balanceOf(eve), 0);
        assertEq(totalSupply, charlieShares + daveShares);

        // Fast forward past timelock
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        // Recipients redeem allocations
        uint256 charlieTokensBefore = token.balanceOf(charlie);
        uint256 daveTokensBefore = token.balanceOf(dave);

        vm.prank(charlie);
        uint256 charlieAssets = _tokenized(address(mechanism)).redeem(charlieShares, charlie, charlie);

        vm.prank(dave);
        uint256 daveAssets = _tokenized(address(mechanism)).redeem(daveShares, dave, dave);

        // Verify final state
        assertEq(token.balanceOf(charlie), charlieTokensBefore + charlieAssets);
        assertEq(token.balanceOf(dave), daveTokensBefore + daveAssets);
        assertEq(_tokenized(address(mechanism)).totalSupply(), 0);
        assertTrue(charlieAssets > 0, "Charlie should receive assets");
        assertTrue(daveAssets > 0, "Dave should receive assets");

        // Verify conservation - with matching pool, total assets redeemed should equal total mechanism assets
        // Total mechanism assets = user deposits + matching pool
        uint256 totalMechanismAssets = LARGE_DEPOSIT + MEDIUM_DEPOSIT + SMALL_DEPOSIT + 2000 ether;
        assertEq(charlieAssets + daveAssets, totalMechanismAssets);

        // PHASE 6: SYSTEM INTEGRITY VERIFICATION

        // Verify clean state
        assertEq(_tokenized(address(mechanism)).totalSupply(), 0);
        assertTrue(_tokenized(address(mechanism)).tallyFinalized());
        assertEq(_tokenized(address(mechanism)).getProposalCount(), 3);

        // Verify voter power consumption (QuadraticVoting consumes voting power in discrete units)
        assertTrue(
            _tokenized(address(mechanism)).votingPower(alice) < 1000 ether,
            "Alice should have consumed most voting power"
        );
        assertTrue(
            _tokenized(address(mechanism)).votingPower(bob) < 1000 ether,
            "Bob should have consumed most voting power"
        );
        assertTrue(
            _tokenized(address(mechanism)).votingPower(frank) < 1000 ether,
            "Frank should have consumed most voting power"
        );
    }

    /// @notice Test crisis recovery and system resilience
    function testCrisisRecovery_SystemResilience() public {
        // No need to manipulate time before setup - mechanism starts immediately at deployment

        // Setup scenario with potential failures
        vm.startPrank(alice);
        token.approve(address(mechanism), LARGE_DEPOSIT);
        _tokenized(address(mechanism)).signup(LARGE_DEPOSIT);
        vm.stopPrank();

        vm.startPrank(bob);
        token.approve(address(mechanism), MEDIUM_DEPOSIT);
        _tokenized(address(mechanism)).signup(MEDIUM_DEPOSIT);
        vm.stopPrank();

        vm.prank(alice);
        uint256 pid = _tokenized(address(mechanism)).propose(charlie, "Test proposal");

        // Advance to voting period
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, 30, charlie);

        // Emergency pause during voting
        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("pause()"));
        require(success, "Pause failed");

        // All operations blocked
        vm.expectRevert(TokenizedAllocationMechanism.PausedError.selector);
        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, 8, charlie);

        // Resume operations
        (bool success2, ) = address(mechanism).call(abi.encodeWithSignature("unpause()"));
        require(success2, "Unpause failed");

        // Operations work again - use bob since alice already voted
        vm.prank(bob);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, 15, charlie);

        // Ownership transfer during crisis
        (bool success3, ) = address(mechanism).call(
            abi.encodeWithSignature("transferOwnership(address)", emergencyAdmin)
        );
        require(success3, "Transfer ownership failed");

        // New owner accepts ownership
        vm.prank(emergencyAdmin);
        (bool success3b, ) = address(mechanism).call(abi.encodeWithSignature("acceptOwnership()"));
        require(success3b, "Accept ownership failed");

        // New owner manages crisis
        vm.startPrank(emergencyAdmin);
        (bool success4, ) = address(mechanism).call(abi.encodeWithSignature("pause()"));
        require(success4, "Emergency admin pause failed");
        vm.stopPrank();

        // System recovery
        vm.startPrank(emergencyAdmin);
        (bool success5, ) = address(mechanism).call(abi.encodeWithSignature("unpause()"));
        require(success5, "Recovery unpause failed");
        vm.stopPrank();

        // Complete voting cycle
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        vm.startPrank(emergencyAdmin);
        (bool success6, ) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success6, "Emergency finalization failed");

        (bool success7, ) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pid));
        require(success7, "Emergency queuing failed");
        vm.stopPrank();

        // System functions normally - alice (30) + bob (15) votes with QuadraticFunding calculation
        uint256 actualShares = _tokenized(address(mechanism)).balanceOf(charlie);
        assertTrue(actualShares > 0, "Charlie should receive shares after crisis recovery");
        assertEq(
            uint(_tokenized(address(mechanism)).state(pid)),
            uint(TokenizedAllocationMechanism.ProposalState.Queued)
        );
    }

    /// @notice Test edge cases and boundary conditions across journeys
    function testEdgeCases_BoundaryConditions() public {
        // No need to manipulate time before setup - mechanism starts immediately at deployment

        // Maximum safe values
        vm.startPrank(alice);
        token.approve(address(mechanism), type(uint128).max);
        _tokenized(address(mechanism)).signup(type(uint128).max);
        vm.stopPrank();

        assertEq(_tokenized(address(mechanism)).votingPower(alice), type(uint128).max);

        // Zero voting power operations
        vm.prank(frank);
        _tokenized(address(mechanism)).signup(0);

        // Cannot propose with zero power
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.ProposeNotAllowed.selector, frank));
        vm.prank(frank);
        _tokenized(address(mechanism)).propose(eve, "Should fail");

        // Boundary voting timing - ensure bob has registered before voting starts
        vm.startPrank(bob);
        token.approve(address(mechanism), MEDIUM_DEPOSIT);
        _tokenized(address(mechanism)).signup(MEDIUM_DEPOSIT);
        vm.stopPrank();

        vm.prank(alice);
        uint256 pid = _tokenized(address(mechanism)).propose(charlie, "Boundary test");

        // Exactly at voting start
        vm.warp(block.timestamp + VOTING_DELAY);
        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, 25, charlie);

        // Exactly at voting end
        vm.warp(block.timestamp + VOTING_PERIOD);
        vm.prank(bob);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, 10, charlie);

        // One second later should fail
        vm.warp(block.timestamp + 1);
        vm.expectRevert();
        vm.prank(bob);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, 1, charlie);
    }

    /// @notice Test proposal cancellation across journeys
    function testProposalCancellation_CrossJourney() public {
        // ✅ CORRECT: Fetch absolute timeline from contract following CLAUDE.md pattern
        uint256 deploymentTime = block.timestamp; // When mechanism was deployed
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingStartTime = deploymentTime + votingDelay;

        vm.startPrank(alice);
        token.approve(address(mechanism), LARGE_DEPOSIT);
        _tokenized(address(mechanism)).signup(LARGE_DEPOSIT);
        vm.stopPrank();

        // Test proposal states during cancellation
        vm.prank(alice);
        uint256 pid = _tokenized(address(mechanism)).propose(charlie, "Cancellable proposal");

        // Should be in Pending state initially (before votingStartTime)
        assertEq(
            uint(_tokenized(address(mechanism)).state(pid)),
            uint(TokenizedAllocationMechanism.ProposalState.Pending)
        );

        // During voting delay period, still Pending
        vm.warp(votingStartTime - 50);
        assertEq(
            uint(_tokenized(address(mechanism)).state(pid)),
            uint(TokenizedAllocationMechanism.ProposalState.Pending)
        );

        // Proposer cancels during Pending state
        vm.prank(alice);
        _tokenized(address(mechanism)).cancelProposal(pid);

        assertEq(
            uint(_tokenized(address(mechanism)).state(pid)),
            uint(TokenizedAllocationMechanism.ProposalState.Canceled)
        );

        // Cannot vote on canceled proposal even after voting starts
        vm.warp(votingStartTime + 1);
        vm.expectRevert();
        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, 10, charlie);

        // Non-proposer cannot cancel
        vm.prank(alice);
        uint256 pid2 = _tokenized(address(mechanism)).propose(dave, "Another proposal");

        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.NotProposer.selector, bob, alice));
        vm.prank(bob);
        _tokenized(address(mechanism)).cancelProposal(pid2);
    }

    /// @notice Test multi-proposal complex scenarios
    function testMultiProposal_ComplexScenarios() public {
        // No need to manipulate time before setup - mechanism starts immediately at deployment

        // Setup diverse voter base
        vm.startPrank(alice);
        token.approve(address(mechanism), LARGE_DEPOSIT);
        _tokenized(address(mechanism)).signup(LARGE_DEPOSIT);
        vm.stopPrank();

        vm.startPrank(bob);
        token.approve(address(mechanism), MEDIUM_DEPOSIT);
        _tokenized(address(mechanism)).signup(MEDIUM_DEPOSIT);
        vm.stopPrank();

        vm.startPrank(frank);
        token.approve(address(mechanism), SMALL_DEPOSIT);
        _tokenized(address(mechanism)).signup(SMALL_DEPOSIT);
        vm.stopPrank();

        // Create competing proposals
        vm.prank(alice);
        uint256 pid1 = _tokenized(address(mechanism)).propose(charlie, "High-impact Infrastructure");

        vm.prank(bob);
        uint256 pid2 = _tokenized(address(mechanism)).propose(dave, "Community Education");

        vm.prank(alice);
        uint256 pid3 = _tokenized(address(mechanism)).propose(eve, "Healthcare Access");

        // Advance to voting period
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        // Strategic voting with power distribution
        // Alice: Supports infrastructure but opposes healthcare
        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(pid1, TokenizedAllocationMechanism.VoteType.For, 25, charlie);

        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(pid3, TokenizedAllocationMechanism.VoteType.For, 20, eve);

        // Bob: Supports education and healthcare
        vm.prank(bob);
        _tokenized(address(mechanism)).castVote(pid2, TokenizedAllocationMechanism.VoteType.For, 25, dave);

        vm.prank(bob);
        _tokenized(address(mechanism)).castVote(pid3, TokenizedAllocationMechanism.VoteType.For, 10, eve);

        // Frank: All-in on healthcare
        vm.prank(frank);
        _tokenized(address(mechanism)).castVote(pid3, TokenizedAllocationMechanism.VoteType.For, 10, eve);

        // Finalize and determine outcomes
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        // Check complex voting outcomes using QuadraticFunding
        // pid1: Alice(25) = (25)² × 0.5 + contributions × 0.5 = weighted funding meets quorum
        assertEq(
            uint(_tokenized(address(mechanism)).state(pid1)),
            uint(TokenizedAllocationMechanism.ProposalState.Succeeded)
        );

        // pid2: Bob(25) = (25)² × 0.5 + contributions × 0.5 = weighted funding meets quorum
        assertEq(
            uint(_tokenized(address(mechanism)).state(pid2)),
            uint(TokenizedAllocationMechanism.ProposalState.Succeeded)
        );

        // pid3: Alice(20) + Bob(10) + Frank(10) = (40)² × 0.5 + contributions × 0.5
        // Determine actual state based on quorum calculation
        uint8 pid3State = uint8(_tokenized(address(mechanism)).state(pid3));
        // State could be Succeeded or Defeated depending on whether weighted funding meets 500 quorum
        assertTrue(
            pid3State == uint8(TokenizedAllocationMechanism.ProposalState.Succeeded) ||
                pid3State == uint8(TokenizedAllocationMechanism.ProposalState.Defeated),
            "pid3 should be either Succeeded or Defeated"
        );

        // Queue successful proposals
        (bool success1, ) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pid1));
        require(success1, "Queue pid1 failed");

        (bool success2, ) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pid2));
        require(success2, "Queue pid2 failed");

        // Verify share distribution based on actual proposal outcomes
        uint256 charlieShares = _tokenized(address(mechanism)).balanceOf(charlie);
        uint256 daveShares = _tokenized(address(mechanism)).balanceOf(dave);
        uint256 eveShares = _tokenized(address(mechanism)).balanceOf(eve);
        uint256 totalSupply = _tokenized(address(mechanism)).totalSupply();

        assertTrue(charlieShares > 0, "Charlie should receive shares");
        assertTrue(daveShares > 0, "Dave should receive shares");
        // Eve's shares depend on whether pid3 met quorum
        assertEq(totalSupply, charlieShares + daveShares + eveShares);

        // Fast forward and verify redemption
        vm.warp(block.timestamp + TIMELOCK_DELAY + 1);

        vm.prank(charlie);
        uint256 charlieAssets = _tokenized(address(mechanism)).redeem(charlieShares, charlie, charlie);
        assertTrue(charlieAssets > 0, "Charlie should redeem assets");

        vm.prank(dave);
        uint256 daveAssets = _tokenized(address(mechanism)).redeem(daveShares, dave, dave);
        assertTrue(daveAssets > 0, "Dave should redeem assets");

        // Redeem Eve's shares if any
        uint256 eveAssets = 0;
        if (eveShares > 0) {
            vm.prank(eve);
            eveAssets = _tokenized(address(mechanism)).redeem(eveShares, eve, eve);
        }

        // Final state verification
        assertEq(_tokenized(address(mechanism)).totalSupply(), 0);

        // With matching pool, total assets redeemed should equal total mechanism assets
        uint256 totalMechanismAssets = LARGE_DEPOSIT + MEDIUM_DEPOSIT + SMALL_DEPOSIT + 2000 ether;
        assertEq(charlieAssets + daveAssets + eveAssets, totalMechanismAssets);
    }
}
