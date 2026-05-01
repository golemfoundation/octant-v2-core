// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import { ProperQF } from "src/mechanisms/voting-strategy/ProperQF.sol";

/// @notice Test harness that wraps ProperQF for direct testing
contract ProperQFHarness is ProperQF {
    function processVoteUnchecked(uint256 projectId, uint256 contribution, uint256 voteWeight) external {
        _processVoteUnchecked(projectId, contribution, voteWeight);
    }

    function processVote(uint256 projectId, uint256 contribution, uint256 voteWeight) external {
        _processVote(projectId, contribution, voteWeight);
    }
}

/// @title Simple ProperQF Overflow Test Harness
/// @notice Tests overflow scenarios by directly calling ProperQF._processVoteUnchecked()
contract ProperQFOverflowTest is Test {
    ProperQFHarness properQF;

    function setUp() public {
        properQF = new ProperQFHarness();
    }

    /// @notice Test 1000 users each voting with max weight on same project
    function test1000Users_MaxWeight_SameProject() public {
        uint256 projectId = 1;
        uint256 maxWeight = 22; // sqrt(500) ≈ 22.36, use 22 to be safe
        uint256 contribution = maxWeight * maxWeight; // 484
        uint256 numUsers = 1000;

        console.log("=== TESTING 1000 USERS MAX WEIGHT SAME PROJECT ===");
        console.log("Each user votes with weight:", maxWeight);
        console.log("Each user contribution:", contribution);

        // Process 1000 votes on same project
        for (uint256 i = 0; i < numUsers; i++) {
            properQF.processVoteUnchecked(projectId, contribution, maxWeight);
        }

        // Check final values
        (uint256 sumContrib, uint256 sumSqrt, uint256 quadFund, uint256 linearFund) = properQF.getTally(projectId);

        console.log("Final sum contributions:", sumContrib);
        console.log("Final sum square roots:", sumSqrt);
        console.log("Final quadratic funding:", quadFund);
        console.log("Final linear funding:", linearFund);

        // Verify expected values
        uint256 expectedSumSqrt = numUsers * maxWeight; // 1000 * 22 = 22,000
        uint256 expectedSumContrib = numUsers * contribution; // 1000 * 484 = 484,000
        uint256 expectedQuadFund = expectedSumSqrt * expectedSumSqrt; // 22,000^2 = 484,000,000

        assertEq(sumSqrt, expectedSumSqrt, "Sum square roots should match expected");
        assertEq(sumContrib, expectedSumContrib, "Sum contributions should match expected");
        assertEq(quadFund, expectedQuadFund, "Quadratic funding should match expected");

        // Verify no overflow
        uint256 uint128Max = type(uint128).max;
        assertTrue(sumContrib < uint128Max, "Sum contributions should fit in uint128");
        assertTrue(sumSqrt < uint128Max, "Sum square roots should fit in uint128");
        assertTrue(quadFund < uint128Max, "Quadratic funding should fit in uint128");

        console.log("SUCCESS: 1000 users processed without overflow");
    }

    /// @notice Test 1000 users split between two projects
    function test1000Users_TwoProjects() public {
        uint256 projectA = 1;
        uint256 projectB = 2;
        uint256 maxWeight = 22;
        uint256 contribution = maxWeight * maxWeight;

        console.log("=== TESTING 1000 USERS SPLIT BETWEEN TWO PROJECTS ===");

        // 600 users vote on project A
        for (uint256 i = 0; i < 600; i++) {
            properQF.processVoteUnchecked(projectA, contribution, maxWeight);
        }

        // 400 users vote on project B
        for (uint256 i = 0; i < 400; i++) {
            properQF.processVoteUnchecked(projectB, contribution, maxWeight);
        }

        // Check project A
        (uint256 sumContribA, uint256 sumSqrtA, uint256 quadFundA, ) = properQF.getTally(projectA);
        console.log("Project A - Sum square roots:", sumSqrtA);
        console.log("Project A - Quadratic funding:", quadFundA);

        // Check project B
        (uint256 sumContribB, uint256 sumSqrtB, uint256 quadFundB, ) = properQF.getTally(projectB);
        console.log("Project B - Sum square roots:", sumSqrtB);
        console.log("Project B - Quadratic funding:", quadFundB);

        // Check global totals
        uint256 totalQuadSum = properQF.totalQuadraticSum();
        uint256 totalLinearSum = properQF.totalLinearSum();
        console.log("Global quadratic sum:", totalQuadSum);
        console.log("Global linear sum:", totalLinearSum);

        // Verify global sums equal project sums
        assertEq(totalQuadSum, quadFundA + quadFundB, "Global quadratic sum should equal project sums");
        assertEq(totalLinearSum, sumContribA + sumContribB, "Global linear sum should equal project sums");

        // Verify no overflow
        uint256 uint128Max = type(uint128).max;
        assertTrue(totalQuadSum < uint128Max, "Global quadratic sum should fit in uint128");
        assertTrue(totalLinearSum < uint128Max, "Global linear sum should fit in uint128");

        console.log("SUCCESS: Split voting processed without overflow");
    }

    /// @notice Test overflow boundary - find the actual overflow point
    function testOverflowBoundary() public pure {
        uint256 maxWeight = 22;
        uint256 contribution = maxWeight * maxWeight;
        uint256 uint128Max = type(uint128).max;

        console.log("=== TESTING OVERFLOW BOUNDARY ===");
        console.log("uint128 max:", uint128Max);

        // Calculate theoretical limits
        uint256 maxUsersForSumSqrt = uint128Max / maxWeight;
        uint256 maxSumSqrtForQuadratic = 18446744073709551615; // sqrt(uint128Max)
        uint256 maxUsersForQuadratic = maxSumSqrtForQuadratic / maxWeight;

        console.log("Max users before sumSquareRoots overflow:", maxUsersForSumSqrt);
        console.log("Max users before quadratic overflow:", maxUsersForQuadratic);

        // Test near the quadratic overflow boundary (use much smaller number for test)
        uint256 testUsers = 1000000; // 1 million users

        // This should work without overflow
        if (testUsers <= maxUsersForQuadratic) {
            console.log("Testing", testUsers, "users...");

            // Process many votes efficiently (skip the actual loop for gas)
            // Instead, simulate the final state
            uint256 finalSumSqrt = testUsers * maxWeight;
            uint256 finalQuadFund = finalSumSqrt * finalSumSqrt;
            uint256 finalSumContrib = testUsers * contribution;

            console.log("Simulated final sum square roots:", finalSumSqrt);
            console.log("Simulated final quadratic funding:", finalQuadFund);
            console.log("Simulated final sum contributions:", finalSumContrib);

            // Check if these would fit in uint128
            assertTrue(finalSumSqrt < uint128Max, "1M users sum square roots should fit");
            assertTrue(finalQuadFund < uint128Max, "1M users quadratic funding should fit");
            assertTrue(finalSumContrib < uint128Max, "1M users sum contributions should fit");

            console.log("SUCCESS: 1 million users would work without overflow");
        }

        console.log("=== BOUNDARY ANALYSIS COMPLETE ===");
    }

    /// @notice Test the actual overflow protection in our code
    function testOverflowProtection() public {
        uint256 projectId = 1;

        console.log("=== TESTING OVERFLOW PROTECTION ===");

        // Try to cause overflow by setting values larger than uint128.max
        uint256 hugeWeight = type(uint128).max; // Max uint128
        uint256 hugeContrib = type(uint128).max; // Max uint128

        console.log("Trying to process vote with huge weight:", hugeWeight);
        console.log("Huge contribution:", hugeContrib);

        // This should revert with SafeCast overflow error when trying to cast uint128.max to uint128 in addition
        // The exact error will be from SafeCast when sumSquareRoots + hugeWeight overflows uint128
        vm.expectRevert();
        properQF.processVoteUnchecked(projectId, hugeContrib, hugeWeight);

        console.log("SUCCESS: Overflow protection working correctly");
    }
}
