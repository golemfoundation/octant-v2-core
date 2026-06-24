// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {QuadraticVotingTestBase} from "../utils/QuadraticVotingTestBase.sol";

contract QuadraticVotingBasicTimelockTest is QuadraticVotingTestBase {
    function setUp() public {
        _setUpQuadraticVoting("Basic Test", "BASIC", 10, 100, 500, 1000, 5000, 50, 100);
        token.mint(alice, 2000 ether);
        _tokenized().setKeeper(alice);
    }

    function testBasicTimelock() public {
        // Get the voting delay and period from the mechanism
        uint256 votingDelay = _tokenized().votingDelay();
        uint256 votingPeriod = _tokenized().votingPeriod();

        // Calculate timeline based on deployment time (setUp runs at timestamp 1)
        uint256 deploymentTime = 1; // Default foundry timestamp
        uint256 votingStartTime = deploymentTime + votingDelay; // 1 + 10 = 11
        uint256 votingEndTime = votingStartTime + votingPeriod; // 11 + 100 = 111

        // Setup - register and create proposal (before voting starts)
        _signup(alice, 1000 ether);
        uint256 pid = _propose(alice, charlie, "Test");

        // Vote - advance to voting period
        vm.warp(votingStartTime);
        _vote(alice, pid, 31, charlie); // 31^2 = 961 > 500 quorum

        // Finalize - advance past voting period
        vm.warp(votingEndTime + 1);
        uint256 finalizeTime = block.timestamp; // Should be 112
        (bool success,) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        // Check that global redemption start was set during finalization
        uint256 timelockDelay = _tokenized().timelockDelay();
        assertEq(
            _tokenized().globalRedemptionStart(),
            finalizeTime + timelockDelay,
            "Should have globalRedemptionStart set after finalize"
        );
        assertEq(_tokenized().balanceOf(charlie), 0, "Should have no shares before queue");

        // Queue proposal
        assertEq(block.timestamp, finalizeTime, "Should be at finalize timestamp");
        (bool success2,) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pid));
        require(success2, "Queue failed");

        // Verify shares were minted
        assertGt(_tokenized().balanceOf(charlie), 0, "Should have shares after queue");
        // Global redemption start remains the same (set during finalize)
        assertEq(
            _tokenized().globalRedemptionStart(),
            finalizeTime + timelockDelay,
            "globalRedemptionStart should not change after queue"
        );

        // Should be blocked immediately at queue time
        assertEq(_tokenized().maxRedeem(charlie), 0, "Should be blocked at queue time");

        // Should be blocked during timelock period (1 second before expiry)
        vm.warp(finalizeTime + timelockDelay - 1);
        assertEq(_tokenized().maxRedeem(charlie), 0, "Should be blocked 1 second before expiry");

        // Should be allowed at timelock expiry
        vm.warp(finalizeTime + timelockDelay);
        assertGt(_tokenized().maxRedeem(charlie), 0, "Should be allowed at timelock expiry");

        // Should still be allowed after timelock expiry
        vm.warp(finalizeTime + timelockDelay + 1);
        assertGt(_tokenized().maxRedeem(charlie), 0, "Should be allowed after timelock expiry");

        // Should be blocked after grace period expires
        uint256 gracePeriod = _tokenized().gracePeriod();
        vm.warp(finalizeTime + timelockDelay + gracePeriod + 1);
        assertEq(_tokenized().maxRedeem(charlie), 0, "Should be blocked after grace period");
    }
}
