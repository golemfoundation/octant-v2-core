// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { TokenizedAllocationMechanism } from "src/mechanisms/TokenizedAllocationMechanism.sol";
import { QuadraticVotingMechanism } from "src/mechanisms/mechanism/QuadraticVotingMechanism.sol";
import { AllocationMechanismFactory } from "src/mechanisms/AllocationMechanismFactory.sol";
import { AllocationConfig } from "src/mechanisms/BaseAllocationMechanism.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract QuadraticVotingBasicTimelockTest is Test {
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
            name: "Basic Test",
            symbol: "BASIC",
            votingDelay: 10,
            votingPeriod: 100,
            quorumShares: 500, // Adjusted for quadratic funding
            timelockDelay: 1000, // 1000 seconds
            gracePeriod: 5000, // 5000 seconds
            owner: address(0)
        });

        address mechanismAddr = factory.deployQuadraticVotingMechanism(config, 50, 100); // 50% alpha
        mechanism = QuadraticVotingMechanism(payable(mechanismAddr));
        _tokenized(address(mechanism)).setKeeper(alice);
    }

    function testBasicTimelock() public {
        // Get the voting delay and period from the mechanism
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingPeriod = _tokenized(address(mechanism)).votingPeriod();

        // Calculate timeline based on deployment time (setUp runs at timestamp 1)
        uint256 deploymentTime = 1; // Default foundry timestamp
        uint256 votingStartTime = deploymentTime + votingDelay; // 1 + 10 = 11
        uint256 votingEndTime = votingStartTime + votingPeriod; // 11 + 100 = 111

        // Setup - register and create proposal (before voting starts)
        vm.startPrank(alice);
        token.approve(address(mechanism), 1000 ether);
        _tokenized(address(mechanism)).signup(1000 ether);
        uint256 pid = _tokenized(address(mechanism)).propose(charlie, "Test");
        vm.stopPrank();

        // Vote - advance to voting period
        vm.warp(votingStartTime);
        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, 31, charlie); // 31^2 = 961 > 500 quorum

        // Finalize - advance past voting period
        vm.warp(votingEndTime + 1);
        uint256 finalizeTime = block.timestamp; // Should be 112
        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        // Check that global redemption start was set during finalization
        uint256 timelockDelay = _tokenized(address(mechanism)).timelockDelay();
        assertEq(
            _tokenized(address(mechanism)).globalRedemptionStart(),
            finalizeTime + timelockDelay,
            "Should have globalRedemptionStart set after finalize"
        );
        assertEq(_tokenized(address(mechanism)).balanceOf(charlie), 0, "Should have no shares before queue");

        // Queue proposal
        assertEq(block.timestamp, finalizeTime, "Should be at finalize timestamp");
        (bool success2, ) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pid));
        require(success2, "Queue failed");

        // Verify shares were minted
        assertGt(_tokenized(address(mechanism)).balanceOf(charlie), 0, "Should have shares after queue");
        // Global redemption start remains the same (set during finalize)
        assertEq(
            _tokenized(address(mechanism)).globalRedemptionStart(),
            finalizeTime + timelockDelay,
            "globalRedemptionStart should not change after queue"
        );

        // Should be blocked immediately at queue time
        assertEq(_tokenized(address(mechanism)).maxRedeem(charlie), 0, "Should be blocked at queue time");

        // Should be blocked during timelock period (1 second before expiry)
        vm.warp(finalizeTime + timelockDelay - 1);
        assertEq(_tokenized(address(mechanism)).maxRedeem(charlie), 0, "Should be blocked 1 second before expiry");

        // Should be allowed at timelock expiry
        vm.warp(finalizeTime + timelockDelay);
        assertGt(_tokenized(address(mechanism)).maxRedeem(charlie), 0, "Should be allowed at timelock expiry");

        // Should still be allowed after timelock expiry
        vm.warp(finalizeTime + timelockDelay + 1);
        assertGt(_tokenized(address(mechanism)).maxRedeem(charlie), 0, "Should be allowed after timelock expiry");

        // Should be blocked after grace period expires
        uint256 gracePeriod = _tokenized(address(mechanism)).gracePeriod();
        vm.warp(finalizeTime + timelockDelay + gracePeriod + 1);
        assertEq(_tokenized(address(mechanism)).maxRedeem(charlie), 0, "Should be blocked after grace period");
    }
}
