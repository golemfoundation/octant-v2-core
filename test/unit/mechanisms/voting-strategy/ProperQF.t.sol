// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { HarnessProperQF } from "test/unit/mechanisms/harness/HarnessProperQF.sol";
import { ProperQF } from "src/mechanisms/voting-strategy/ProperQF.sol";
import { console2 as console } from "forge-std/console2.sol";

contract ProperQFTest is Test {
    HarnessProperQF public qf;

    /// @dev Quantization step for sumContributions (lossy readback tolerance)
    uint256 constant STEP = uint256(1) << 32;

    // Capture AlphaUpdated event
    event AlphaUpdated(uint256 oldNumerator, uint256 oldDenominator, uint256 newNumerator, uint256 newDenominator);

    function setUp() public {
        qf = new HarnessProperQF();
    }

    function test_sqrt() public view {
        assertEq(qf.exposed_sqrt(0), 0, "sqrt(0) should be 0");
        assertEq(qf.exposed_sqrt(1), 1, "sqrt(1) should be 1");
        assertEq(qf.exposed_sqrt(4), 2, "sqrt(4) should be 2");
        assertEq(qf.exposed_sqrt(9), 3, "sqrt(9) should be 3");
        assertEq(qf.exposed_sqrt(16), 4, "sqrt(16) should be 4");
        assertEq(qf.exposed_sqrt(100), 10, "sqrt(100) should be 10");
    }

    function testFuzz_sqrt(uint256 x) public view {
        // Bound input to prevent overflow
        x = bound(x, 0, type(uint128).max);

        uint256 result = qf.exposed_sqrt(x);

        // Check that result^2 <= x < (result+1)^2
        if (x > 0) {
            assertTrue(result * result <= x);
            assertTrue(x < (result + 1) * (result + 1) || result == type(uint128).max);
        }
    }

    function test_initial_state() public view {
        (uint256 sumC, uint256 sumSR, uint256 quadF, uint256 linearF) = qf.getTally(1);
        assertEq(sumC, 0, "Initial sumContributions should be 0");
        assertEq(sumSR, 0, "Initial sumSquareRoots should be 0");
        assertEq(quadF, 0, "Initial quadraticFunding should be 0");
        assertEq(linearF, 0, "Initial linearFunding should be 0");
        assertEq(qf.totalQuadraticSum(), 0, "Initial totalQuadraticSum should be 0");
        assertEq(qf.totalLinearSum(), 0, "Initial totalLinearSum should be 0");
        assertEq(qf.totalFunding(), 0, "Initial totalFunding should be 0");
    }

    function test_process_vote() public {
        uint256 projectId = 1;
        uint256 contribution = 100e18;

        qf.exposed_processVote(projectId, contribution, qf.exposed_sqrt(contribution));

        (uint256 sumC, uint256 sumSR, uint256 quadF, uint256 linearF) = qf.getTally(projectId);

        uint256 expectedSqrt = qf.exposed_sqrt(contribution);
        uint256 expectedQuad = (expectedSqrt * expectedSqrt);
        // With default alpha = 1.0 (10000/10000), linearFunding = (1-α) × contribution = 0
        uint256 expectedLinear = 0;

        assertApproxEqAbs(sumC, contribution, STEP, "sumContributions incorrect");
        assertEq(sumSR, expectedSqrt, "sumSquareRoots incorrect");
        assertEq(quadF, expectedQuad, "quadraticFunding incorrect");
        assertEq(linearF, expectedLinear, "linearFunding incorrect");
        assertEq(qf.totalQuadraticSum(), expectedQuad, "totalQuadraticSum incorrect");
        assertEq(qf.totalLinearSum(), contribution, "totalLinearSum incorrect");
        // With alpha = 1.0, totalFunding = alpha * quadratic + (1-alpha) * linear = 1.0 * quadratic + 0 * linear
        assertEq(qf.totalFunding(), expectedQuad, "totalFunding incorrect");
    }

    function test_multiple_votes_same_project() public {
        uint256 projectId = 1;
        uint256 contribution1 = 100e18;
        uint256 contribution2 = 200e18;

        qf.exposed_processVote(projectId, contribution1, qf.exposed_sqrt(contribution1));
        qf.exposed_processVote(projectId, contribution2, qf.exposed_sqrt(contribution2));

        (uint256 sumC, uint256 sumSR, , ) = qf.getTally(projectId);

        // 2 votes on same project: cumulative quantization error up to 2*STEP
        assertApproxEqAbs(sumC, contribution1 + contribution2, 2 * STEP, "sumContributions incorrect");
        assertEq(sumSR, qf.exposed_sqrt(contribution1) + qf.exposed_sqrt(contribution2), "sumSquareRoots incorrect");
    }

    function testFuzz_process_vote(uint256 contribution) public {
        // Bound contribution to prevent overflow; upper bound is the packed field max
        uint256 contribMax = uint256(type(uint96).max) << 32;
        contribution = bound(contribution, STEP, contribMax);

        uint256 projectId = 1;
        qf.exposed_processVote(projectId, contribution, qf.exposed_sqrt(contribution));

        (uint256 sumC, uint256 sumSR, , ) = qf.getTally(projectId);
        assertApproxEqAbs(sumC, contribution, STEP, "sumContributions incorrect");
        assertEq(sumSR, qf.exposed_sqrt(contribution), "sumSquareRoots incorrect");
    }

    function test_zero_contribution_reverts() public {
        vm.expectRevert(ProperQF.ContributionMustBePositive.selector);
        qf.exposed_processVote(1, 0, 0);
    }

    function test_zero_voteWeight_reverts() public {
        vm.expectRevert(ProperQF.VoteWeightMustBePositive.selector);
        qf.exposed_processVote(1, 100, 0);
    }

    function test_voteWeight_too_large_reverts() public {
        // Set voteWeight to 11 when contribution is 100
        // 11^2 = 121 which is > 100
        vm.expectRevert(ProperQF.SquareRootTooLarge.selector);
        qf.exposed_processVote(1, 100, 11);
    }

    function test_setAlpha_zero_denominator_reverts() public {
        // Try to set alpha with zero denominator
        vm.expectRevert(ProperQF.DenominatorMustBePositive.selector);
        qf.exposed_setAlpha(1, 0);
    }

    function test_setAlpha_numerator_greater_than_denominator_reverts() public {
        // Try to set alpha with numerator > denominator (alpha > 1)
        vm.expectRevert(ProperQF.AlphaMustBeLessOrEqualToOne.selector);
        qf.exposed_setAlpha(11, 10);
    }

    function test_setAlpha_success() public {
        // Set alpha to 0.6 (6/10)
        qf.exposed_setAlpha(6, 10);
        (uint256 numerator, uint256 denominator) = qf.getAlpha();
        assertEq(numerator, 6, "Alpha numerator should be 6");
        assertEq(denominator, 10, "Alpha denominator should be 10");

        // Check that an AlphaUpdated event was emitted
        vm.expectEmit(true, true, true, true);
        emit AlphaUpdated(6, 10, 7, 10);
        qf.exposed_setAlpha(7, 10);
    }

    function test_setAlphaDecimal_success() public {
        // Set alpha to 0.75 using decimal format
        qf.exposed_setAlphaDecimal(75 * 10 ** 16); // 0.75e18

        (uint256 numerator, uint256 denominator) = qf.getAlpha();
        assertEq(numerator, 75 * 10 ** 16, "Alpha numerator should be 0.75e18");
        assertEq(denominator, 10 ** 18, "Alpha denominator should be 1e18");
    }

    function test_setAlphaPercentage_success() public {
        // Set alpha to 80% using percentage format
        qf.exposed_setAlphaPercentage(80);

        (uint256 numerator, uint256 denominator) = qf.getAlpha();
        assertEq(numerator, 80, "Alpha numerator should be 80");
        assertEq(denominator, 100, "Alpha denominator should be 100");
    }

    function test_setAlphaDecimal_over_one_reverts() public {
        // Try to set alpha to 1.1 using decimal format
        vm.expectRevert(HarnessProperQF.AlphaMustBeLEQOne.selector);
        qf.exposed_setAlphaDecimal(11 * 10 ** 17); // 1.1e18
    }

    function test_multiple_projects_votes() public {
        // Test setup with three different projects
        uint256 project1 = 1;
        uint256 project2 = 2;
        uint256 project3 = 3;

        // Define contributions for each project
        uint256 contribution1 = 100e18;
        uint256 contribution2 = 200e18;
        uint256 contribution3 = 300e18;

        // Process votes for each project
        qf.exposed_processVote(project1, contribution1, qf.exposed_sqrt(contribution1));
        qf.exposed_processVote(project2, contribution2, qf.exposed_sqrt(contribution2));
        qf.exposed_processVote(project3, contribution3, qf.exposed_sqrt(contribution3));

        // Check results for project 1
        {
            (uint256 sumC1, uint256 sumSR1, uint256 quadF1, uint256 linearF1) = qf.getTally(project1);
            uint256 expectedQuad1 = qf.exposed_sqrt(contribution1) ** 2;

            assertApproxEqAbs(sumC1, contribution1, STEP, "Project 1 sumContributions incorrect");
            assertEq(sumSR1, qf.exposed_sqrt(contribution1), "Project 1 sumSquareRoots incorrect");
            assertEq(quadF1, expectedQuad1, "Project 1 quadraticFunding incorrect");
            // With default alpha = 1.0, linearFunding = (1-α) × contribution = 0
            assertEq(linearF1, 0, "Project 1 linearFunding incorrect");
        }

        // Check results for project 2
        {
            (uint256 sumC2, uint256 sumSR2, uint256 quadF2, uint256 linearF2) = qf.getTally(project2);
            uint256 expectedQuad2 = qf.exposed_sqrt(contribution2) ** 2;

            assertApproxEqAbs(sumC2, contribution2, STEP, "Project 2 sumContributions incorrect");
            assertEq(sumSR2, qf.exposed_sqrt(contribution2), "Project 2 sumSquareRoots incorrect");
            assertEq(quadF2, expectedQuad2, "Project 2 quadraticFunding incorrect");
            // With default alpha = 1.0, linearFunding = (1-α) × contribution = 0
            assertEq(linearF2, 0, "Project 2 linearFunding incorrect");
        }

        // Check results for project 3
        {
            (uint256 sumC3, uint256 sumSR3, uint256 quadF3, uint256 linearF3) = qf.getTally(project3);
            uint256 expectedQuad3 = qf.exposed_sqrt(contribution3) ** 2;

            assertApproxEqAbs(sumC3, contribution3, STEP, "Project 3 sumContributions incorrect");
            assertEq(sumSR3, qf.exposed_sqrt(contribution3), "Project 3 sumSquareRoots incorrect");
            assertEq(quadF3, expectedQuad3, "Project 3 quadraticFunding incorrect");
            // With default alpha = 1.0, linearFunding = (1-α) × contribution = 0
            assertEq(linearF3, 0, "Project 3 linearFunding incorrect");
        }

        // Check global totals (exact: delta cancellation preserves totalLinearSum)
        uint256 expectedTotalQuadratic = qf.exposed_sqrt(contribution1) ** 2 +
            qf.exposed_sqrt(contribution2) ** 2 +
            qf.exposed_sqrt(contribution3) ** 2;

        uint256 expectedTotalLinear = contribution1 + contribution2 + contribution3;

        assertEq(qf.totalQuadraticSum(), expectedTotalQuadratic, "Total quadratic sum incorrect");
        assertEq(qf.totalLinearSum(), expectedTotalLinear, "Total linear sum incorrect");
        // With alpha = 1.0, totalFunding = alpha * quadratic + (1-alpha) * linear = 1.0 * quadratic + 0 * linear
        assertEq(qf.totalFunding(), expectedTotalQuadratic, "Total funding incorrect");
    }

    function test_multiple_votes_multiple_projects() public {
        // Test setup with three different projects and multiple voters
        uint256 project1 = 1;
        uint256 project2 = 2;
        uint256 project3 = 3;

        // First round of contributions
        uint256 contribution1A = 100e18;
        uint256 contribution2A = 200e18;
        uint256 contribution3A = 300e18;

        // Second round of contributions
        uint256 contribution1B = 150e18;
        uint256 contribution2B = 250e18;
        uint256 contribution3B = 350e18;

        // Process first round of votes
        qf.exposed_processVote(project1, contribution1A, qf.exposed_sqrt(contribution1A));
        qf.exposed_processVote(project2, contribution2A, qf.exposed_sqrt(contribution2A));
        qf.exposed_processVote(project3, contribution3A, qf.exposed_sqrt(contribution3A));

        // Process second round of votes
        qf.exposed_processVote(project1, contribution1B, qf.exposed_sqrt(contribution1B));
        qf.exposed_processVote(project2, contribution2B, qf.exposed_sqrt(contribution2B));
        qf.exposed_processVote(project3, contribution3B, qf.exposed_sqrt(contribution3B));

        // Check results for project 1 (2 votes: tolerance = 2*STEP)
        {
            (uint256 sumC1, uint256 sumSR1, uint256 quadF1, uint256 linearF1) = qf.getTally(project1);
            uint256 expectedSumC1 = contribution1A + contribution1B;
            uint256 expectedSumSR1 = qf.exposed_sqrt(contribution1A) + qf.exposed_sqrt(contribution1B);
            uint256 expectedQuad1 = expectedSumSR1 * expectedSumSR1;

            assertApproxEqAbs(sumC1, expectedSumC1, 2 * STEP, "Project 1 sumContributions incorrect");
            assertEq(sumSR1, expectedSumSR1, "Project 1 sumSquareRoots incorrect");
            assertEq(quadF1, expectedQuad1, "Project 1 quadraticFunding incorrect");
            // With default alpha = 1.0, linearFunding = (1-α) × contribution = 0
            assertEq(linearF1, 0, "Project 1 linearFunding incorrect");
        }

        // Check results for project 2 (2 votes: tolerance = 2*STEP)
        {
            (uint256 sumC2, uint256 sumSR2, uint256 quadF2, uint256 linearF2) = qf.getTally(project2);
            uint256 expectedSumC2 = contribution2A + contribution2B;
            uint256 expectedSumSR2 = qf.exposed_sqrt(contribution2A) + qf.exposed_sqrt(contribution2B);
            uint256 expectedQuad2 = expectedSumSR2 * expectedSumSR2;

            assertApproxEqAbs(sumC2, expectedSumC2, 2 * STEP, "Project 2 sumContributions incorrect");
            assertEq(sumSR2, expectedSumSR2, "Project 2 sumSquareRoots incorrect");
            assertEq(quadF2, expectedQuad2, "Project 2 quadraticFunding incorrect");
            // With default alpha = 1.0, linearFunding = (1-α) × contribution = 0
            assertEq(linearF2, 0, "Project 2 linearFunding incorrect");
        }

        // Check results for project 3 (2 votes: tolerance = 2*STEP)
        {
            (uint256 sumC3, uint256 sumSR3, uint256 quadF3, uint256 linearF3) = qf.getTally(project3);
            uint256 expectedSumC3 = contribution3A + contribution3B;
            uint256 expectedSumSR3 = qf.exposed_sqrt(contribution3A) + qf.exposed_sqrt(contribution3B);
            uint256 expectedQuad3 = expectedSumSR3 * expectedSumSR3;

            assertApproxEqAbs(sumC3, expectedSumC3, 2 * STEP, "Project 3 sumContributions incorrect");
            assertEq(sumSR3, expectedSumSR3, "Project 3 sumSquareRoots incorrect");
            assertEq(quadF3, expectedQuad3, "Project 3 quadraticFunding incorrect");
            // With default alpha = 1.0, linearFunding = (1-α) × contribution = 0
            assertEq(linearF3, 0, "Project 3 linearFunding incorrect");
        }

        // Check global totals (exact: delta cancellation preserves totalLinearSum)
        uint256 expectedTotalQuadratic = (qf.exposed_sqrt(contribution1A) + qf.exposed_sqrt(contribution1B)) ** 2 +
            (qf.exposed_sqrt(contribution2A) + qf.exposed_sqrt(contribution2B)) ** 2 +
            (qf.exposed_sqrt(contribution3A) + qf.exposed_sqrt(contribution3B)) ** 2;

        uint256 expectedTotalLinear = (contribution1A + contribution1B) +
            (contribution2A + contribution2B) +
            (contribution3A + contribution3B);

        assertEq(qf.totalQuadraticSum(), expectedTotalQuadratic, "Total quadratic sum incorrect");
        assertEq(qf.totalLinearSum(), expectedTotalLinear, "Total linear sum incorrect");
        // With alpha = 1.0, totalFunding = alpha * quadratic + (1-alpha) * linear = 1.0 * quadratic + 0 * linear
        assertEq(qf.totalFunding(), expectedTotalQuadratic, "Total funding incorrect");

        // Verify quadratic effect
        // The quadratic funding amount should be greater than the sum of individual quadratic amounts
        uint256 individualQuad1 = qf.exposed_sqrt(contribution1A) ** 2 + qf.exposed_sqrt(contribution1B) ** 2;
        uint256 combinedQuad1 = (qf.exposed_sqrt(contribution1A) + qf.exposed_sqrt(contribution1B)) ** 2;
        assertTrue(
            combinedQuad1 > individualQuad1,
            "Quadratic funding should incentivize multiple smaller contributions over single large ones"
        );
    }

    function test_gas_process_single_vote() public {
        // Setup test values
        uint256 projectId = 1;
        uint256 contribution = 100e18;
        uint256 voteWeight = 10e9;

        // Warm up the storage slots to get consistent gas measurements
        qf.exposed_processVote(2, 1e18, 1e9);
        vm.roll(block.number + 1); // Move to next block to reset gas calculations

        // Measure gas for processing a single vote
        uint256 gasStart = gasleft();
        qf.exposed_processVote(projectId, contribution, voteWeight);
        uint256 gasUsed = gasStart - gasleft();

        // Log gas usage
        console.log("Gas used for processing single vote with warm totals but cold project:", gasUsed);

        // Optional: Add assertions to ensure the vote was processed correctly
        (uint256 sumC, uint256 sumSR, , ) = qf.getTally(projectId);
        assertApproxEqAbs(sumC, contribution, STEP, "Contribution not recorded correctly");
        assertEq(sumSR, voteWeight, "Vote weight not recorded correctly");
    }

    function test_gas_process_vote_cold_storage() public {
        // Setup test values
        uint256 projectId = 1;
        uint256 contribution = 100e18;
        uint256 voteWeight = 10e9;

        // Measure gas for processing a vote with cold storage
        uint256 gasStart = gasleft();
        qf.exposed_processVote(projectId, contribution, voteWeight);
        uint256 gasUsed = gasStart - gasleft();

        // Log gas usage
        console.log("Gas used for processing vote (cold storage):", gasUsed);
    }

    function test_gas_process_vote_warm_storage() public {
        // Setup test values
        uint256 projectId = 1;
        uint256 contribution = 100e18;
        uint256 voteWeight = 10e9;

        // Warm up storage
        qf.exposed_processVote(projectId, 1e18, 1e9);
        vm.roll(block.number + 1); // Move to next block to reset gas calculations

        // Measure gas for processing a vote with warm storage
        uint256 gasStart = gasleft();
        qf.exposed_processVote(projectId, contribution, voteWeight);
        uint256 gasUsed = gasStart - gasleft();

        // Log gas usage
        console.log("Gas used for processing vote (warm storage):", gasUsed);
    }

    function test_setAlphaPercentage_over_hundred_reverts() public {
        // Try to set alpha to 101% using percentage format
        vm.expectRevert(HarnessProperQF.PercentageMustBeLEQ100.selector);
        qf.exposed_setAlphaPercentage(101);
    }

    function test_getTally_with_alpha() public {
        // Set up project with some contributions
        uint256 projectId = 1;
        uint256 contribution = 100e18;
        uint256 sqrtContribution = qf.exposed_sqrt(contribution);

        qf.exposed_processVote(projectId, contribution, sqrtContribution);

        // Test with default alpha (1.0)
        {
            (uint256 sumC, uint256 sumSR, uint256 quadraticFunding, uint256 linearFunding) = qf.getTally(projectId);

            // Check correct values returned with default alpha (10000/10000 = 1.0)
            assertApproxEqAbs(sumC, contribution, STEP);
            assertEq(sumSR, sqrtContribution);
            assertEq(quadraticFunding, sqrtContribution * sqrtContribution);
            // With alpha = 1.0, linearFunding = (1-α) × contribution = 0
            assertEq(linearFunding, 0);
        }

        // Change alpha to 0.6 (60/100)
        qf.exposed_setAlpha(60, 100);

        // Test with alpha of 0.6
        {
            (uint256 sumC, uint256 sumSR, uint256 quadraticFunding, uint256 linearFunding) = qf.getTally(projectId);

            // Check correct values returned with alpha = 0.6
            assertApproxEqAbs(sumC, contribution, STEP);
            assertEq(sumSR, sqrtContribution);

            // quadraticFunding should be 60% of the square
            uint256 expectedQuadratic = (sqrtContribution * sqrtContribution * 60) / 100;
            assertEq(quadraticFunding, expectedQuadratic);

            // linearFunding = (1-α) × decoded_sumC; use decoded value for assertion
            uint256 expectedLinear = (sumC * 40) / 100;
            assertEq(linearFunding, expectedLinear);
        }
    }

    function test_getAlpha() public {
        // Check default alpha values
        (uint256 numerator, uint256 denominator) = qf.getAlpha();
        assertEq(numerator, 10000, "Default alpha numerator should be 10000");
        assertEq(denominator, 10000, "Default alpha denominator should be 10000");

        // Set a new alpha and check that getAlpha returns the new values
        qf.exposed_setAlpha(3, 5);
        (numerator, denominator) = qf.getAlpha();
        assertEq(numerator, 3, "Alpha numerator should be updated to 3");
        assertEq(denominator, 5, "Alpha denominator should be updated to 5");
    }
}
