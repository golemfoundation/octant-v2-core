// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import { ProperQF } from "src/mechanisms/voting-strategy/ProperQF.sol";
import { Overflow, BelowMinStep } from "uint-quantization-lib/src/UintQuantizationLib.sol";

/// @notice Test harness that wraps ProperQF for direct testing
contract ProperQFHarness is ProperQF(18) {
    function processVoteUnchecked(uint256 projectId, uint256 contribution, uint256 voteWeight) external {
        _processVoteUnchecked(projectId, contribution, voteWeight);
    }

    function processVote(uint256 projectId, uint256 contribution, uint256 voteWeight) external {
        _processVote(projectId, contribution, voteWeight);
    }
}

/// @title ProperQF Overflow & Packing Test
/// @notice Tests overflow boundaries for the symmetric PackedProject layout:
///         uint128 sumContributions (shift=32) + uint128 sumSquareRoots (no quantization)
contract ProperQFOverflowTest is Test {
    ProperQFHarness properQF;

    /// @dev Step size for sumContributions quantization
    uint256 constant STEP = uint256(1) << 32;
    /// @dev Maximum representable sumContributions after decode
    uint256 constant CONTRIBUTIONS_MAX = uint256(type(uint128).max) << 32;

    function setUp() public {
        properQF = new ProperQFHarness();
    }

    /// @notice Test 1000 users each voting with step-aligned contributions on same project
    function test1000Users_MaxWeight_SameProject() public {
        uint256 projectId = 1;
        // Use step-aligned contribution so assertions stay exact
        uint256 voteWeight = 1 << 16; // 65536
        uint256 contribution = uint256(voteWeight) * voteWeight; // 2^32 = 1 STEP
        uint256 numUsers = 1000;

        for (uint256 i = 0; i < numUsers; i++) {
            properQF.processVoteUnchecked(projectId, contribution, voteWeight);
        }

        (uint256 sumContrib, uint256 sumSqrt, uint256 quadFund, ) = properQF.getTally(projectId);

        uint256 expectedSumSqrt = numUsers * voteWeight;
        uint256 expectedSumContrib = numUsers * contribution;
        uint256 expectedQuadFund = expectedSumSqrt * expectedSumSqrt;

        assertEq(sumSqrt, expectedSumSqrt, "Sum square roots should match expected");
        assertEq(sumContrib, expectedSumContrib, "Sum contributions should match expected");
        assertEq(quadFund, expectedQuadFund, "Quadratic funding should match expected");

        assertTrue(sumContrib <= CONTRIBUTIONS_MAX, "Sum contributions should fit in packed storage");
        assertTrue(sumSqrt <= type(uint128).max, "Sum square roots should fit in uint128");
    }

    /// @notice Test 1000 users split between two projects
    function test1000Users_TwoProjects() public {
        uint256 projectA = 1;
        uint256 projectB = 2;
        uint256 voteWeight = 1 << 16;
        uint256 contribution = uint256(voteWeight) * voteWeight;

        for (uint256 i = 0; i < 600; i++) {
            properQF.processVoteUnchecked(projectA, contribution, voteWeight);
        }
        for (uint256 i = 0; i < 400; i++) {
            properQF.processVoteUnchecked(projectB, contribution, voteWeight);
        }

        (, , uint256 quadFundA, ) = properQF.getTally(projectA);
        (, , uint256 quadFundB, ) = properQF.getTally(projectB);

        uint256 totalQuadSum = properQF.totalQuadraticSum();
        uint256 totalLinearSum = properQF.totalLinearSum();

        assertEq(totalQuadSum, quadFundA + quadFundB, "Global quadratic sum should equal project sums");
        assertEq(totalLinearSum, 1000 * contribution, "Global linear sum should equal total contributions");

        assertTrue(totalQuadSum <= type(uint256).max, "Global quadratic sum should not overflow");
    }

    /// @notice Test the overflow boundary for sumContributions
    function testOverflowBoundary_Contributions() public pure {
        console.log("=== CONTRIBUTIONS OVERFLOW BOUNDARY ===");
        console.log("CONTRIBUTIONS_MAX:", CONTRIBUTIONS_MAX);
        console.log("STEP:", STEP);

        uint256 maxStored = type(uint128).max;
        uint256 maxDecoded = maxStored << 32;
        assertEq(maxDecoded, CONTRIBUTIONS_MAX, "Max decoded should match CONTRIBUTIONS_MAX");

        // Verify step alignment
        assertEq(CONTRIBUTIONS_MAX % STEP, 0, "Max should be step-aligned");
    }

    /// @notice Test that overflow reverts with Overflow from UintQuantizationLib
    function testOverflowProtection_Contributions() public {
        uint256 projectId = 1;

        // Set up a contribution that would exceed CONTRIBUTIONS_MAX when accumulated
        // CONTRIBUTIONS_MAX + 1 STEP should overflow
        uint256 overflowValue = CONTRIBUTIONS_MAX + STEP;

        vm.expectRevert(abi.encodeWithSelector(Overflow.selector, overflowValue, CONTRIBUTIONS_MAX));
        properQF.processVoteUnchecked(projectId, overflowValue, 1);
    }

    /// @notice Test that uint128 overflow for sumSquareRoots reverts
    /// @dev Going through processVoteUnchecked, the squaring (sumSR * sumSR) overflows
    ///      uint256 before reaching _writeProject's uint128() downcast.
    function testOverflowProtection_SquareRoots() public {
        uint256 projectId = 1;
        uint256 hugeWeight = uint256(type(uint128).max) + 1;

        // processVoteUnchecked panics on the squaring overflow before reaching _writeProject
        vm.expectRevert();
        properQF.processVoteUnchecked(projectId, STEP, hugeWeight);
    }

    /// @notice Lossy round-trip: non-step-aligned value gets floored
    function testLossyRoundTrip() public {
        uint256 projectId = 1;
        // contribution = 5 * STEP + (STEP - 1): not step-aligned
        uint256 contribution = 5 * STEP + (STEP - 1);
        uint256 voteWeight = 1;

        properQF.processVoteUnchecked(projectId, contribution, voteWeight);

        ProperQF.Project memory project = properQF.projects(projectId);
        // Should be floored to 5 * STEP
        assertEq(project.sumContributions, 5 * STEP, "Non-aligned contribution should floor to step boundary");
        assertEq(project.sumSquareRoots, 1, "Square roots should be exact");
    }

    /// @notice Zero round-trip: zero stays zero
    function testZeroRoundTrip() public view {
        ProperQF.Project memory project = properQF.projects(999);
        assertEq(project.sumContributions, 0, "Zero contributions should decode to zero");
        assertEq(project.sumSquareRoots, 0, "Zero square roots should decode to zero");
    }

    /// @notice Step-aligned round-trip: exact preservation
    function testStepAlignedRoundTrip() public {
        uint256 projectId = 1;
        uint256 contribution = 42 * STEP;

        properQF.processVoteUnchecked(projectId, contribution, 1);

        ProperQF.Project memory project = properQF.projects(projectId);
        assertEq(project.sumContributions, contribution, "Step-aligned contribution should round-trip exactly");
    }

    /// @notice Sub-step contribution reverts with BelowMinStep from UintQuantizationLib
    function testSubStepRevertsWithBelowMinStep() public {
        uint256 projectId = 1;
        // Any value < STEP is rejected by the minimum contribution check
        uint256 tinyContribution = STEP - 1;

        vm.expectRevert(abi.encodeWithSelector(BelowMinStep.selector, tinyContribution, STEP));
        properQF.processVoteUnchecked(projectId, tinyContribution, 1);
    }
}
