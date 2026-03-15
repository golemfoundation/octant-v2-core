// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { HarnessProperQF } from "test/unit/mechanisms/harness/HarnessProperQF.sol";
import { ProperQF } from "src/mechanisms/voting-strategy/ProperQF.sol";

/// @title QVM Gas Benchmark
/// @notice Deterministic gas benchmarks for ProperQF storage operations.
///         Run with `forge snapshot --match-path 'test/gas/**'` to generate .gas-snapshot.
///         CI diffs the snapshot against the committed baseline on every PR.
/// @dev Each test function is a single gas scenario. Keep tests minimal and deterministic:
///      fixed setUp, no randomness, no console.log. The test name IS the benchmark label.
contract QVMGasBenchmark is Test {
    HarnessProperQF qf;

    /// @dev Quantization step (2^32) and minimum aligned contribution
    uint256 constant STEP = uint256(1) << 32;
    uint256 constant MIN_WEIGHT = uint256(1) << 16;
    uint256 constant ALIGNED_CONTRIBUTION = 100 * STEP; // 100 steps
    uint256 constant ALIGNED_WEIGHT = 10 * MIN_WEIGHT;

    function setUp() public {
        qf = new HarnessProperQF();
    }

    // ── Per-operation micro-benchmarks ───────────────────────────────────
    // These isolate individual operations for diagnosing regressions.

    /// @notice Gas cost of processVoteUnchecked on a cold project (first vote)
    function test_gas_processVoteUnchecked_cold() public {
        qf.exposed_processVoteUnchecked(1, ALIGNED_CONTRIBUTION, ALIGNED_WEIGHT);
    }

    /// @notice Gas cost of processVoteUnchecked on a warm project (second vote)
    function test_gas_processVoteUnchecked_warm() public {
        qf.exposed_processVoteUnchecked(1, ALIGNED_CONTRIBUTION, ALIGNED_WEIGHT);
        qf.exposed_processVoteUnchecked(1, ALIGNED_CONTRIBUTION, ALIGNED_WEIGHT);
    }

    /// @notice Gas cost of processVote on a cold project
    function test_gas_processVote_cold() public {
        qf.exposed_processVote(1, ALIGNED_CONTRIBUTION, ALIGNED_WEIGHT);
    }

    /// @notice Gas cost of processVote on a warm project
    function test_gas_processVote_warm() public {
        qf.exposed_processVote(1, ALIGNED_CONTRIBUTION, ALIGNED_WEIGHT);
        qf.exposed_processVote(1, ALIGNED_CONTRIBUTION, ALIGNED_WEIGHT);
    }

    /// @notice Gas cost of reading project tally (packed storage decode)
    function test_gas_getTally() public {
        qf.exposed_processVoteUnchecked(1, ALIGNED_CONTRIBUTION, ALIGNED_WEIGHT);
        qf.getTally(1);
    }

    /// @notice Gas cost of reading totalFunding
    function test_gas_totalFunding() public {
        qf.exposed_processVoteUnchecked(1, ALIGNED_CONTRIBUTION, ALIGNED_WEIGHT);
        qf.totalFunding();
    }

    /// @notice Gas cost of setAlpha
    function test_gas_setAlpha() public {
        qf.exposed_setAlpha(6000, 10000);
    }

    // ── Lifetime scenario: 1000-project epoch ───────────────────────────
    //
    // Models a mature Octant epoch with 1000 projects, 200 voters, ~3950 total votes.
    //
    // Popularity distribution:
    //   50 popular projects:  20 votes each  (1000 votes)
    //   200 mid-tier projects: 8 votes each  (1600 votes)
    //   300 active projects:   3 votes each  ( 900 votes)
    //   450 tail projects:     1 vote each   ( 450 votes)
    //
    // Storage pattern:
    //   1000 cold SSTOREs (first vote on each project)
    //   2950 warm SSTOREs (subsequent votes)
    //   1000 SLOADs       (tally sweep at epoch end)
    //
    // This is the headline number for storage layer cost at production scale.

    /// @notice Full epoch lifecycle: seed + accumulate + tally for 1000 projects
    function test_gas_epoch_1000_projects() public {
        // Phase 1: Seed - first vote on all 1000 projects (all cold SSTOREs)
        for (uint256 i = 1; i <= 1000; i++) {
            qf.exposed_processVoteUnchecked(i, ALIGNED_CONTRIBUTION, ALIGNED_WEIGHT);
        }

        // Phase 2: Accumulate - subsequent votes with realistic popularity distribution

        // Popular tier: 50 projects get 19 more votes each
        for (uint256 i = 1; i <= 50; i++) {
            for (uint256 v = 0; v < 19; v++) {
                qf.exposed_processVoteUnchecked(i, ALIGNED_CONTRIBUTION, ALIGNED_WEIGHT);
            }
        }

        // Mid-tier: 200 projects get 7 more votes each
        for (uint256 i = 51; i <= 250; i++) {
            for (uint256 v = 0; v < 7; v++) {
                qf.exposed_processVoteUnchecked(i, ALIGNED_CONTRIBUTION, ALIGNED_WEIGHT);
            }
        }

        // Active tier: 300 projects get 2 more votes each
        for (uint256 i = 251; i <= 550; i++) {
            for (uint256 v = 0; v < 2; v++) {
                qf.exposed_processVoteUnchecked(i, ALIGNED_CONTRIBUTION, ALIGNED_WEIGHT);
            }
        }

        // Tail tier: 450 projects stay at 1 vote (no more writes)

        // Phase 3: Tally - read all 1000 project tallies for funding distribution
        for (uint256 i = 1; i <= 1000; i++) {
            qf.getTally(i);
        }
    }

    /// @notice Seed phase only: first vote on all 1000 projects (isolates cold SSTORE cost)
    function test_gas_epoch_seed_1000() public {
        for (uint256 i = 1; i <= 1000; i++) {
            qf.exposed_processVoteUnchecked(i, ALIGNED_CONTRIBUTION, ALIGNED_WEIGHT);
        }
    }

    /// @notice Tally sweep: read all 1000 project tallies (isolates packed SLOAD cost)
    function test_gas_epoch_tally_1000() public {
        // Seed first so there's data to read
        for (uint256 i = 1; i <= 1000; i++) {
            qf.exposed_processVoteUnchecked(i, ALIGNED_CONTRIBUTION, ALIGNED_WEIGHT);
        }
        // Measure tally reads
        for (uint256 i = 1; i <= 1000; i++) {
            qf.getTally(i);
        }
    }
}
