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

contract QuadraticVotingSimpleTimelockTest is Test {
    AllocationMechanismFactory factory;
    ERC20Mock token;
    QuadraticVotingMechanism mechanism;

    address alice = address(0x1);
    address charlie = address(0x3);

    function _tokenized(address _mechanism) internal pure returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(_mechanism);
    }

    function setUp() public {
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();
        token.mint(alice, 2000 ether);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Simple Test",
            symbol: "SIMPLE",
            votingDelay: 10,
            votingPeriod: 100,
            quorumShares: 500, // Adjusted for quadratic funding
            timelockDelay: 1000, // 1000 seconds for easier testing
            gracePeriod: 5000, // 5000 seconds
            owner: address(0)
        });

        address mechanismAddr = factory.deployQuadraticVotingMechanism(config, 50, 100); // 50% alpha
        mechanism = QuadraticVotingMechanism(payable(mechanismAddr));
        _tokenized(address(mechanism)).setKeeper(alice);
    }

    function testSimpleTimelock() public {
        // Get absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingPeriod = _tokenized(address(mechanism)).votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Setup
        vm.startPrank(alice);
        token.approve(address(mechanism), 1000 ether);
        _tokenized(address(mechanism)).signup(1000 ether);
        uint256 pid = _tokenized(address(mechanism)).propose(charlie, "Test");
        vm.stopPrank();

        vm.warp(votingStartTime + 1);
        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, 25, charlie); // Cost: 25^2 = 625

        // Debug: Check what quadratic funding this generates
        (uint256 sumContributions, , uint256 quadraticFunding, uint256 linearFunding) = mechanism.getProposalFunding(
            pid
        );
        console.log("Funding amounts:");
        console.log("  sumContributions:", sumContributions);
        console.log("  quadraticFunding:", quadraticFunding);
        console.log("  linearFunding:", linearFunding);

        vm.warp(votingEndTime + 1);
        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        console.log("=== BEFORE QUEUING ===");
        console.log("Current timestamp:", block.timestamp);
        console.log("Charlie redeemableAfter:", _tokenized(address(mechanism)).globalRedemptionStart());
        console.log("Charlie balance:", _tokenized(address(mechanism)).balanceOf(charlie));
        console.log("Charlie maxRedeem:", _tokenized(address(mechanism)).maxRedeem(charlie));

        uint256 queueTime = block.timestamp;
        (bool success2, ) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pid));
        require(success2, "Queue failed");

        console.log("=== AFTER QUEUING ===");
        console.log("Queue time:", queueTime);
        console.log("Current timestamp:", block.timestamp);
        console.log("Timelock delay:", _tokenized(address(mechanism)).timelockDelay());
        console.log("Expected redeemable time:", queueTime + 1000);
        console.log("Charlie redeemableAfter:", _tokenized(address(mechanism)).globalRedemptionStart());
        console.log("Charlie balance:", _tokenized(address(mechanism)).balanceOf(charlie));
        console.log("Charlie maxRedeem:", _tokenized(address(mechanism)).maxRedeem(charlie));

        // Verify shares were minted and timelock set correctly
        assertGt(_tokenized(address(mechanism)).balanceOf(charlie), 0, "Should have shares after queue");
        assertEq(
            _tokenized(address(mechanism)).globalRedemptionStart(),
            queueTime + 1000,
            "Should have correct redeemableAfter"
        );

        // Test 1: Should be blocked immediately after queuing
        assertEq(_tokenized(address(mechanism)).maxRedeem(charlie), 0, "Should be blocked at queue time");

        // Test 2: Should be blocked during timelock period (1 second before expiry)
        vm.warp(queueTime + 999);
        assertEq(_tokenized(address(mechanism)).maxRedeem(charlie), 0, "Should be blocked 1 second before expiry");

        // Test 3: Should be allowed at timelock expiry
        vm.warp(queueTime + 1000);
        assertGt(_tokenized(address(mechanism)).maxRedeem(charlie), 0, "Should be allowed at timelock expiry");

        // Test 4: Should still be allowed after timelock expiry
        vm.warp(queueTime + 1001);
        assertGt(_tokenized(address(mechanism)).maxRedeem(charlie), 0, "Should be allowed after timelock expiry");
    }

    /// @notice Test that getProposalFunding returns zero for cancelled proposals
    function test_CancelledProposalReturnsZeroFunding() public {
        // Get timeline calculations
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingStartTime = deploymentTime + votingDelay;

        // Setup user
        vm.startPrank(alice);
        token.approve(address(mechanism), 1000 ether);
        _tokenized(address(mechanism)).signup(1000 ether);
        uint256 pid = _tokenized(address(mechanism)).propose(charlie, "Test cancelled funding");
        vm.stopPrank();

        // Vote on proposal during active period
        vm.warp(votingStartTime + 1);
        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20, charlie); // Cost: 20^2 = 400

        // Verify proposal has non-zero funding before cancellation
        (uint256 sumContributions, uint256 sumSquareRoots, uint256 quadraticFunding, uint256 linearFunding) = mechanism
            .getProposalFunding(pid);
        assertTrue(sumContributions > 0, "Should have contributions before cancellation");
        assertTrue(sumSquareRoots > 0, "Should have square roots before cancellation");
        assertTrue(quadraticFunding > 0, "Should have quadratic funding before cancellation");

        // Cancel the proposal (alice is proposer and keeper)
        vm.prank(alice);
        _tokenized(address(mechanism)).cancelProposal(pid);

        // Verify proposal is cancelled
        assertEq(
            uint(_tokenized(address(mechanism)).state(pid)),
            uint(TokenizedAllocationMechanism.ProposalState.Canceled)
        );

        // Verify getProposalFunding returns all zeros for cancelled proposal
        (sumContributions, sumSquareRoots, quadraticFunding, linearFunding) = mechanism.getProposalFunding(pid);
        assertEq(sumContributions, 0, "Cancelled proposal should have zero contributions");
        assertEq(sumSquareRoots, 0, "Cancelled proposal should have zero square roots");
        assertEq(quadraticFunding, 0, "Cancelled proposal should have zero quadratic funding");
        assertEq(linearFunding, 0, "Cancelled proposal should have zero linear funding");
    }

    /// @notice Test that previewRedeem returns 0 outside of redemption period
    function test_PreviewRedeemRedemptionPeriod() public {
        // Get timeline calculations
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingPeriod = _tokenized(address(mechanism)).votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Setup user
        vm.startPrank(alice);
        token.approve(address(mechanism), 1000 ether);
        _tokenized(address(mechanism)).signup(1000 ether);
        uint256 pid = _tokenized(address(mechanism)).propose(charlie, "Test previewRedeem");
        vm.stopPrank();

        uint256 testShares = 100 ether;

        // Phase 1: Before finalization - should return 0 (no redemption period set)
        assertEq(_tokenized(address(mechanism)).previewRedeem(testShares), 0, "Should return 0 before finalization");

        // Vote and finalize
        vm.warp(votingStartTime + 1);
        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, 30, charlie); // High vote to meet quorum

        vm.warp(votingEndTime + 1);
        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        // Queue the proposal to set redemption period
        _tokenized(address(mechanism)).queueProposal(pid);

        uint256 globalRedemptionStart = _tokenized(address(mechanism)).globalRedemptionStart();
        uint256 gracePeriod = _tokenized(address(mechanism)).gracePeriod();
        uint256 globalRedemptionEnd = globalRedemptionStart + gracePeriod;

        // Phase 2: Before redemption period starts - should return 0
        vm.warp(globalRedemptionStart - 1);
        assertEq(
            _tokenized(address(mechanism)).previewRedeem(testShares),
            0,
            "Should return 0 before redemption starts"
        );

        // Phase 3: During redemption period - should return non-zero
        vm.warp(globalRedemptionStart + 1);
        uint256 previewDuringPeriod = _tokenized(address(mechanism)).previewRedeem(testShares);
        assertTrue(previewDuringPeriod > 0, "Should return non-zero during redemption period");

        // Phase 4: At end of redemption period - should still return non-zero
        vm.warp(globalRedemptionEnd);
        uint256 previewAtEnd = _tokenized(address(mechanism)).previewRedeem(testShares);
        assertTrue(previewAtEnd > 0, "Should return non-zero at end of redemption period");
        assertEq(previewAtEnd, previewDuringPeriod, "Should be consistent during redemption period");

        // Phase 5: After redemption period ends - should return 0
        vm.warp(globalRedemptionEnd + 1);
        assertEq(_tokenized(address(mechanism)).previewRedeem(testShares), 0, "Should return 0 after redemption ends");
    }
}
