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

    // ── _processVoteUnchecked (the hot path) ─────────────────────────────

    /// @notice Gas cost of processVoteUnchecked on a cold project (first vote)
    function test_gas_processVoteUnchecked_cold() public {
        qf.exposed_processVoteUnchecked(1, ALIGNED_CONTRIBUTION, ALIGNED_WEIGHT);
    }

    /// @notice Gas cost of processVoteUnchecked on a warm project (second vote)
    function test_gas_processVoteUnchecked_warm() public {
        // Warm up project 1
        qf.exposed_processVoteUnchecked(1, ALIGNED_CONTRIBUTION, ALIGNED_WEIGHT);
        // Measure second vote (warm SLOAD + SSTORE)
        qf.exposed_processVoteUnchecked(1, ALIGNED_CONTRIBUTION, ALIGNED_WEIGHT);
    }

    // ── _processVote (with sqrt validation) ──────────────────────────────

    /// @notice Gas cost of processVote on a cold project
    function test_gas_processVote_cold() public {
        qf.exposed_processVote(1, ALIGNED_CONTRIBUTION, ALIGNED_WEIGHT);
    }

    /// @notice Gas cost of processVote on a warm project
    function test_gas_processVote_warm() public {
        qf.exposed_processVote(1, ALIGNED_CONTRIBUTION, ALIGNED_WEIGHT);
        qf.exposed_processVote(1, ALIGNED_CONTRIBUTION, ALIGNED_WEIGHT);
    }

    // ── Read operations ──────────────────────────────────────────────────

    /// @notice Gas cost of reading project tally (packed storage decode)
    function test_gas_getTally() public {
        // Write data first
        qf.exposed_processVoteUnchecked(1, ALIGNED_CONTRIBUTION, ALIGNED_WEIGHT);
        // Measure read
        qf.getTally(1);
    }

    /// @notice Gas cost of reading projects() view (packed storage decode)
    function test_gas_projects() public {
        qf.exposed_processVoteUnchecked(1, ALIGNED_CONTRIBUTION, ALIGNED_WEIGHT);
        qf.projects(1);
    }

    /// @notice Gas cost of reading totalFunding
    function test_gas_totalFunding() public {
        qf.exposed_processVoteUnchecked(1, ALIGNED_CONTRIBUTION, ALIGNED_WEIGHT);
        qf.totalFunding();
    }

    // ── Alpha operations ─────────────────────────────────────────────────

    /// @notice Gas cost of setAlpha
    function test_gas_setAlpha() public {
        qf.exposed_setAlpha(6000, 10000);
    }

    // ── Multi-project scenario ───────────────────────────────────────────

    /// @notice Gas cost of voting across 5 different projects (all cold)
    function test_gas_vote_5_projects_cold() public {
        for (uint256 i = 1; i <= 5; i++) {
            qf.exposed_processVoteUnchecked(i, ALIGNED_CONTRIBUTION, ALIGNED_WEIGHT);
        }
    }

    /// @notice Gas cost of voting across 5 different projects (all warm)
    function test_gas_vote_5_projects_warm() public {
        // Warm all 5
        for (uint256 i = 1; i <= 5; i++) {
            qf.exposed_processVoteUnchecked(i, ALIGNED_CONTRIBUTION, ALIGNED_WEIGHT);
        }
        // Measure warm votes
        for (uint256 i = 1; i <= 5; i++) {
            qf.exposed_processVoteUnchecked(i, ALIGNED_CONTRIBUTION, ALIGNED_WEIGHT);
        }
    }
}
