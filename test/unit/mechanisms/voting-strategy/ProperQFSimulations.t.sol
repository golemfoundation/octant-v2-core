// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { HarnessProperQF } from "test/unit/mechanisms/harness/HarnessProperQF.sol";
import { ProperQF } from "src/mechanisms/voting-strategy/ProperQF.sol";
import { console2 as console } from "forge-std/console2.sol";

contract ProperQFSimulationTest is Test {
    HarnessProperQF public qf;

    /// @dev Quantization step for sumContributions (lossy readback tolerance)
    uint256 constant STEP = uint256(1) << 32;

    function setUp() public {
        qf = new HarnessProperQF();
    }

    struct VoterProfile {
        uint256[] contributions; // contributions[i] is amount voted for project i
    }

    /// @notice Helper to generate sample voter profiles with realistic voting patterns
    /// @param numVoters Number of voters to generate
    /// @param numProjects Number of projects each voter can vote for
    /// @param baseContribution Base contribution amount (will be varied per voter/project)
    /// @return VoterProfile[] Array of voter profiles with their contributions
    function generateVoterProfiles(
        uint256 numVoters,
        uint256 numProjects,
        uint256 baseContribution
    ) internal pure returns (VoterProfile[] memory) {
        VoterProfile[] memory voters = new VoterProfile[](numVoters);

        for (uint256 i = 0; i < numVoters; i++) {
            voters[i].contributions = new uint256[](numProjects);

            // Generate varied contribution amounts for each project
            for (uint256 j = 0; j < numProjects; j++) {
                // Create some variation in contribution amounts
                // Using modulo and multiplication to create different patterns
                uint256 variation = ((i + 1) * (j + 1) * 1e18) % 5e18;
                voters[i].contributions[j] = baseContribution + variation;
            }
        }

        return voters;
    }

    /// @notice Simulates a complete voting round with given voter profiles
    /// @param voters Array of voter profiles
    /// @param numProjects Number of projects
    /// @return projectTallies Array of (sumContributions, sumSquareRoots, quadFunding, linearFunding) for each project
    function simulateVotingRound(
        VoterProfile[] memory voters,
        uint256 numProjects
    ) internal returns (uint256[4][] memory projectTallies) {
        projectTallies = new uint256[4][](numProjects);

        // Process all votes
        for (uint256 i = 0; i < voters.length; i++) {
            for (uint256 j = 0; j < numProjects; j++) {
                uint256 contribution = voters[i].contributions[j];
                if (contribution > 0) {
                    qf.exposed_processVote(j + 1, contribution, qf.exposed_sqrt(contribution));
                }
            }
        }

        // Collect results
        for (uint256 i = 0; i < numProjects; i++) {
            (uint256 sumContributions, uint256 sumSquareRoots, uint256 quadraticFunding, uint256 linearFunding) = qf
                .getTally(i + 1);

            projectTallies[i] = [sumContributions, sumSquareRoots, quadraticFunding, linearFunding];
        }
    }

    function test_simulation_small_round() public {
        uint256 numVoters = 3;
        uint256 numProjects = 2;
        uint256 baseContribution = 100e18;

        VoterProfile[] memory voters = generateVoterProfiles(numVoters, numProjects, baseContribution);

        uint256[4][] memory results = simulateVotingRound(voters, numProjects);

        // Verify results
        for (uint256 i = 0; i < numProjects; i++) {
            uint256 expectedContributions = 0;
            uint256 expectedSqrtSum = 0;

            for (uint256 j = 0; j < numVoters; j++) {
                expectedContributions += voters[j].contributions[i];
                expectedSqrtSum += qf.exposed_sqrt(voters[j].contributions[i]);
            }

            // Per-project sumContributions is lossy: tolerance = numVoters * STEP
            assertApproxEqAbs(
                results[i][0],
                expectedContributions,
                numVoters * STEP,
                string.concat("Project ", vm.toString(i), " total contributions mismatch")
            );
            assertEq(results[i][1], expectedSqrtSum, string.concat("Project ", vm.toString(i), " sqrt sum mismatch"));
            assertEq(
                results[i][2],
                expectedSqrtSum * expectedSqrtSum,
                string.concat("Project ", vm.toString(i), " quadratic funding mismatch")
            );
        }
    }

    function test_simulation_medium_round() public {
        uint256 numVoters = 10;
        uint256 numProjects = 5;
        uint256 baseContribution = 50e18;

        VoterProfile[] memory voters = generateVoterProfiles(numVoters, numProjects, baseContribution);

        uint256[4][] memory results = simulateVotingRound(voters, numProjects);

        // Log some interesting metrics
        for (uint256 i = 0; i < numProjects; i++) {
            console.log("Project", i + 1, "stats:");
            console.log("  Total contributions:", results[i][0] / 1e18);
            console.log("  Quadratic funding:", results[i][2] / 1e18);
            console.log("  Linear funding:", results[i][3] / 1e18);
        }
    }

    function test_simulation_large_round() public {
        uint256 numVoters = 50;
        uint256 numProjects = 10;
        uint256 baseContribution = 10e18;

        VoterProfile[] memory voters = generateVoterProfiles(numVoters, numProjects, baseContribution);

        uint256 gasStart = gasleft();
        uint256[4][] memory results = simulateVotingRound(voters, numProjects);
        uint256 gasUsed = gasStart - gasleft();

        console.log("Gas used for large simulation:", gasUsed);
        console.log("Average gas per vote:", gasUsed / (numVoters * numProjects));

        // Log summary statistics
        uint256 totalQuadratic = 0;
        uint256 totalLinear = 0;
        for (uint256 i = 0; i < numProjects; i++) {
            totalQuadratic += results[i][2];
            totalLinear += results[i][3];
        }

        console.log("Total quadratic funding:", totalQuadratic / 1e18);
        console.log("Total linear funding:", totalLinear / 1e18);
    }

    function test_set_alpha() public {
        // Initial alpha should be 1 (10000/10000)
        (uint256 initialNum, uint256 initialDenom) = qf.getAlpha();
        assertEq(initialNum, 10000);
        assertEq(initialDenom, 10000);

        // Set alpha to 0.6 (6000/10000)
        qf.exposed_setAlpha(6000, 10000);

        // Verify new alpha
        (uint256 newNum, uint256 newDenom) = qf.getAlpha();
        assertEq(newNum, 6000);
        assertEq(newDenom, 10000);
    }

    function test_set_alpha_affects_funding() public {
        // Setup test data
        uint256 projectId = 1;
        uint256 contribution = 100e18;
        uint256 voteWeight = 10e9;

        // Process a vote with initial alpha (1.0)
        qf.exposed_processVote(projectId, contribution, voteWeight);

        // Get initial funding distribution
        (, , uint256 initialQuadratic, ) = qf.getTally(projectId);

        // Set alpha to 0.6
        qf.exposed_setAlpha(6000, 10000);

        // Get new funding distribution
        (, , uint256 newQuadratic, uint256 newLinear) = qf.getTally(projectId);

        // Verify that quadratic portion is 60% of what it was
        assertEq(newQuadratic, (initialQuadratic * 6000) / 10000, "Quadratic funding should be 60% of original");

        // Linear portion should now be 40% of the decoded contribution (was 0% when alpha=1.0)
        // With alpha=0.6, linear funding = (1-α) × decoded_sumC = 0.4 × decoded_sumC
        // Use the actual decoded sumC from getTally since it is lossy
        (uint256 decodedSumC, , , ) = qf.getTally(projectId);
        uint256 expectedLinear = (decodedSumC * 4000) / 10000;
        assertEq(newLinear, expectedLinear, "Linear funding should be 40% of contribution when alpha=0.6");
    }

    function test_set_alpha_reverts() public {
        // Should revert when denominator is 0
        vm.expectRevert(ProperQF.DenominatorMustBePositive.selector);
        qf.exposed_setAlpha(1, 0);

        // Should revert when alpha > 1
        vm.expectRevert(ProperQF.AlphaMustBeLessOrEqualToOne.selector);
        qf.exposed_setAlpha(11, 10);

        // Edge cases should work
        qf.exposed_setAlpha(0, 1); // alpha = 0
        qf.exposed_setAlpha(1, 1); // alpha = 1
    }

    function test_set_alpha_precision() public {
        // Test with high precision values
        qf.exposed_setAlpha(12345, 100000); // alpha = 0.12345

        uint256 projectId = 1;
        uint256 contribution = 100e18;
        uint256 voteWeight = 10e9;

        qf.exposed_processVote(projectId, contribution, voteWeight);

        (, , uint256 quadraticFunding, ) = qf.getTally(projectId);

        // Verify precise calculation
        uint256 expectedQuadratic = (voteWeight * voteWeight * 12345) / 100000;
        assertEq(quadraticFunding, expectedQuadratic, "Quadratic funding should be precisely calculated");
    }

    function test_simulation_totals_match() public {
        /// @notice Test to verify that project-wise sums match contract-wide totals
        uint256 numVoters = 5;
        uint256 numProjects = 3;
        uint256 baseContribution = 100e18;

        VoterProfile[] memory voters = generateVoterProfiles(numVoters, numProjects, baseContribution);
        uint256[4][] memory results = simulateVotingRound(voters, numProjects);

        // Calculate expected totals from individual project results
        uint256 expectedQuadraticSum = 0;
        uint256 decodedLinearSum = 0;
        uint256 expectedTotalFunding = 0;

        for (uint256 i = 0; i < numProjects; i++) {
            // For each project, get the square root sum and calculate quadratic funding
            uint256 sqrtSum = results[i][1];
            expectedQuadraticSum += sqrtSum * sqrtSum;
            decodedLinearSum += results[i][0]; // decoded (lossy) per-project values
            // With alpha = 1.0, totalFunding = quadraticSum only
            expectedTotalFunding += sqrtSum * sqrtSum;
        }

        // Get actual totals from contract
        uint256 actualQuadraticSum = qf.totalQuadraticSum();
        uint256 actualLinearSum = qf.totalLinearSum();
        uint256 actualTotalFunding = qf.totalFunding();

        // Quadratic totals are exact (computed from lossless sumSquareRoots)
        assertEq(actualQuadraticSum, expectedQuadraticSum, "Total quadratic sum mismatch");
        // totalLinearSum is exact (delta cancellation), but decoded per-project sums are lossy.
        // The difference is bounded by numVoters * numProjects * STEP.
        assertApproxEqAbs(
            actualLinearSum,
            decodedLinearSum,
            numVoters * numProjects * STEP,
            "Total linear sum mismatch"
        );
        assertEq(actualTotalFunding, expectedTotalFunding, "Total funding mismatch");
    }

    function test_simulation_totals_accumulate_correctly() public {
        /// @notice Test to verify totals accumulate correctly as votes are processed
        uint256 numVoters = 3;
        uint256 numProjects = 2;
        uint256 baseContribution = 100e18;

        VoterProfile[] memory voters = generateSimpleVoterProfiles(numVoters, numProjects, baseContribution, 0);

        // Track running totals per project
        uint256[] memory projectQuadraticSums = new uint256[](numProjects);
        uint256[] memory projectLinearSums = new uint256[](numProjects);

        // Process votes one by one and check totals after each vote
        for (uint256 i = 0; i < voters.length; i++) {
            for (uint256 j = 0; j < numProjects; j++) {
                uint256 contribution = voters[i].contributions[j];
                if (contribution > 0) {
                    uint256 sqrtContribution = qf.exposed_sqrt(contribution);

                    // Update running totals for this project
                    projectQuadraticSums[j] += sqrtContribution;
                    projectLinearSums[j] += contribution;

                    // Process the vote
                    qf.exposed_processVote(j + 1, contribution, sqrtContribution);

                    // Calculate expected totals across all projects
                    uint256 expectedQuadraticSum = 0;
                    uint256 expectedLinearSum = 0;
                    uint256 expectedTotalFunding = 0;

                    for (uint256 k = 0; k < numProjects; k++) {
                        expectedQuadraticSum += projectQuadraticSums[k] * projectQuadraticSums[k];
                        expectedLinearSum += projectLinearSums[k];
                        // With alpha = 1.0, totalFunding = quadraticSum only
                        expectedTotalFunding += projectQuadraticSums[k] * projectQuadraticSums[k];
                    }

                    // Verify running totals match contract state
                    assertEq(qf.totalQuadraticSum(), expectedQuadraticSum, "Running quadratic sum mismatch");
                    assertEq(qf.totalLinearSum(), expectedLinearSum, "Running linear sum mismatch");
                    assertEq(qf.totalFunding(), expectedTotalFunding, "Running total funding mismatch");
                }
            }
        }
    }

    /// @notice Helper to generate simple voter profiles with predictable voting patterns
    /// @param numVoters Number of voters to generate
    /// @param numProjects Number of projects each voter can vote for
    /// @param baseContribution Base contribution amount (will be constant for all votes)
    /// @param pattern 0=uniform, 1=increasing per project, 2=increasing per voter
    /// @return VoterProfile[] Array of voter profiles with predictable contributions
    function generateSimpleVoterProfiles(
        uint256 numVoters,
        uint256 numProjects,
        uint256 baseContribution,
        uint256 pattern
    ) internal pure returns (VoterProfile[] memory) {
        VoterProfile[] memory voters = new VoterProfile[](numVoters);

        for (uint256 i = 0; i < numVoters; i++) {
            voters[i].contributions = new uint256[](numProjects);

            for (uint256 j = 0; j < numProjects; j++) {
                // Different patterns for easier verification
                if (pattern == 0) {
                    // Uniform contributions
                    voters[i].contributions[j] = baseContribution;
                } else if (pattern == 1) {
                    // Increasing per project (1x, 2x, 3x, etc.)
                    voters[i].contributions[j] = baseContribution * (j + 1);
                } else if (pattern == 2) {
                    // Increasing per voter (1x, 2x, 3x, etc.)
                    voters[i].contributions[j] = baseContribution * (i + 1);
                }
            }
        }

        return voters;
    }

    /// @notice Test using simple voter profiles with uniform contributions
    function test_simulation_simple_uniform() public {
        uint256 numVoters = 3;
        uint256 numProjects = 2;
        uint256 baseContribution = 100e18;

        // Generate uniform contributions
        VoterProfile[] memory voters = generateSimpleVoterProfiles(numVoters, numProjects, baseContribution, 0);

        uint256[4][] memory results = simulateVotingRound(voters, numProjects);

        // For uniform contributions, we can easily calculate expected values
        uint256 expectedContributionPerProject = baseContribution * numVoters;
        uint256 expectedSqrtSumPerProject = qf.exposed_sqrt(baseContribution) * numVoters;
        uint256 expectedQuadraticPerProject = expectedSqrtSumPerProject * expectedSqrtSumPerProject;

        for (uint256 i = 0; i < numProjects; i++) {
            assertApproxEqAbs(
                results[i][0],
                expectedContributionPerProject,
                numVoters * STEP,
                "Uniform contributions mismatch"
            );
            assertEq(results[i][2], expectedQuadraticPerProject, "Uniform quadratic funding mismatch");
        }

        // Verify global totals (exact: delta cancellation)
        assertEq(qf.totalQuadraticSum(), expectedQuadraticPerProject * numProjects, "Total quadratic sum mismatch");
        assertEq(qf.totalLinearSum(), expectedContributionPerProject * numProjects, "Total linear sum mismatch");
    }

    /// @notice Test using simple voter profiles with increasing contributions per project
    function test_simulation_simple_even_projects() public {
        uint256 numVoters = 2;
        uint256 numProjects = 3;
        uint256 baseContribution = 100e18;

        // Generate increasing contributions per project
        VoterProfile[] memory voters = generateSimpleVoterProfiles(numVoters, numProjects, baseContribution, 0);

        uint256[4][] memory results = simulateVotingRound(voters, numProjects);

        // For increasing contributions per project, we can easily calculate expected values
        uint256 expectedContributionPerProject = baseContribution * numVoters;
        uint256 expectedSqrtSumPerProject = qf.exposed_sqrt(baseContribution) * numVoters;
        uint256 expectedQuadraticPerProject = expectedSqrtSumPerProject * expectedSqrtSumPerProject;

        for (uint256 i = 0; i < numProjects; i++) {
            assertApproxEqAbs(
                results[i][0],
                expectedContributionPerProject,
                numVoters * STEP,
                " contributions per project mismatch"
            );
            assertEq(
                results[i][2],
                expectedQuadraticPerProject,
                " contributions per project quadratic funding mismatch"
            );
        }

        // Verify global totals (exact: delta cancellation)
        assertEq(qf.totalQuadraticSum(), expectedQuadraticPerProject * numProjects, "Total quadratic sum mismatch");
        assertEq(qf.totalLinearSum(), expectedContributionPerProject * numProjects, "Total linear sum mismatch");
    }

    function test_simulation_totals_print() public {
        /// @notice Test with 3 projects, 3 voters, each voting 100e18 for each project
        uint256 numVoters = 3;
        uint256 numProjects = 3;
        uint256 baseContribution = 100e18;

        VoterProfile[] memory voters = generateSimpleVoterProfiles(numVoters, numProjects, baseContribution, 0);

        // Track running totals per project
        uint256[] memory projectQuadraticSums = new uint256[](numProjects);
        uint256[] memory projectLinearSums = new uint256[](numProjects);

        console.log("\n=== Initial State ===");
        console.log("Base contribution per vote:", baseContribution / 1e18, "tokens");
        console.log("Number of voters:", numVoters);
        console.log("Number of projects:", numProjects);

        // Process votes one by one and check totals after each vote
        for (uint256 i = 0; i < voters.length; i++) {
            console.log("\n--- Processing Voter", i + 1, "---");
            for (uint256 j = 0; j < numProjects; j++) {
                uint256 contribution = voters[i].contributions[j];
                if (contribution > 0) {
                    uint256 sqrtContribution = qf.exposed_sqrt(contribution);

                    // Update running totals for this project
                    projectQuadraticSums[j] += sqrtContribution;
                    projectLinearSums[j] += contribution;

                    // Process the vote
                    qf.exposed_processVote(j + 1, contribution, sqrtContribution);

                    console.log("Project", j + 1);
                    console.log("- Vote:", contribution / 1e18);
                    console.log("- Sqrt:", sqrtContribution / 1e9);
                }
            }
        }

        console.log("\n=== Final Totals ===");
        // Print per-project totals
        for (uint256 i = 0; i < numProjects; i++) {
            (uint256 sumContributions, uint256 sumSquareRoots, uint256 quadraticFunding, uint256 linearFunding) = qf
                .getTally(i + 1);

            console.log("\nProject", i + 1, "Stats:");
            console.log("Total Contributions:", sumContributions / 1e18);
            console.log("Sum of Square Roots:", sumSquareRoots / 1e9);
            console.log("Quadratic Funding:", quadraticFunding / 1e18);
            console.log("Linear Funding:", linearFunding / 1e18);
        }

        // Print contract-wide totals
        console.log("\n=== Contract Totals ===");
        console.log("Total Quadratic Sum:", qf.totalQuadraticSum() / 1e18);
        console.log("Total Linear Sum:", qf.totalLinearSum() / 1e18);
        console.log("Total Funding:", qf.totalFunding() / 1e18);

        // Verify expected totals
        uint256 expectedContributionPerProject = baseContribution * numVoters;
        uint256 expectedSqrtPerVote = qf.exposed_sqrt(baseContribution);
        uint256 expectedSqrtSumPerProject = expectedSqrtPerVote * numVoters;
        uint256 expectedQuadraticPerProject = expectedSqrtSumPerProject * expectedSqrtSumPerProject;

        for (uint256 i = 0; i < numProjects; i++) {
            // projectLinearSums tracks running totals before encoding, so they are exact
            assertEq(
                projectLinearSums[i],
                expectedContributionPerProject,
                string.concat("Project ", vm.toString(i + 1), " linear sum mismatch")
            );
            assertEq(
                projectQuadraticSums[i] * projectQuadraticSums[i],
                expectedQuadraticPerProject,
                string.concat("Project ", vm.toString(i + 1), " quadratic sum mismatch")
            );
        }
    }
}
