// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/console.sol";
import { QuadraticVotingTestBase } from "../utils/QuadraticVotingTestBase.sol";

contract DebugQuorum is QuadraticVotingTestBase {
    function setUp() public {
        _setUpQuadraticVoting("Debug Test", "DEBUG", 10, 100, 500, 1000, 5000, 50, 100);
        token.mint(alice, 2000 ether);
        _tokenized().setKeeper(alice);
    }

    function testDebugQuorum() public {
        // Get absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized().votingDelay();
        uint256 votingPeriod = _tokenized().votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Setup
        _signup(alice, 1000 ether);
        uint256 pid = _propose(alice, charlie, "Test");

        console.log("=== SETUP COMPLETE ===");
        console.log("Alice voting power:", _tokenized().votingPower(alice));
        console.log("Quorum requirement:", _tokenized().quorumShares());

        // Try different vote weights to find minimum for quorum
        vm.warp(votingStartTime + 1);
        _vote(alice, pid, 31, charlie); // 31^2 = 961 > 200 ether quorum

        console.log("=== AFTER VOTING ===");
        console.log("Vote weight used: 31");
        console.log("Quadratic cost: 961");

        // Get funding breakdown
        uint256 sumContributions;
        uint256 sumSquareRoots;
        uint256 quadraticFunding;
        uint256 linearFunding;

        try mechanism.getProposalFunding(pid) returns (
            uint256 _sumContributions,
            uint256 _sumSquareRoots,
            uint256 _quadraticFunding,
            uint256 _linearFunding
        ) {
            sumContributions = _sumContributions;
            sumSquareRoots = _sumSquareRoots;
            quadraticFunding = _quadraticFunding;
            linearFunding = _linearFunding;
            console.log("sumContributions:", sumContributions);
            console.log("sumSquareRoots:", sumSquareRoots);
            console.log("quadraticFunding:", quadraticFunding);
            console.log("linearFunding:", linearFunding);
        } catch {
            console.log("getProposalFunding FAILED");
        }

        // Calculate weighted funding (what quorum check uses - WRONG VERSION)
        uint256 alphaNumerator = 50;
        uint256 alphaDenominator = 100;
        uint256 projectWeightedFunding = (quadraticFunding * alphaNumerator) /
            alphaDenominator +
            (linearFunding * (alphaDenominator - alphaNumerator)) /
            alphaDenominator;
        console.log("Project weighted funding (WRONG - double alpha):", projectWeightedFunding);
        console.log("Meets quorum (wrong calc)?", projectWeightedFunding >= 200 ether);

        // Correct calculation: getTally already returns alpha-weighted quadratic
        uint256 correctWeightedFunding = quadraticFunding +
            (linearFunding * (alphaDenominator - alphaNumerator)) /
            alphaDenominator;
        console.log("Project weighted funding (CORRECT):", correctWeightedFunding);
        console.log("Meets quorum (correct calc)?", correctWeightedFunding >= 200 ether);

        // Try to finalize
        vm.warp(votingEndTime + 1);
        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        // Check if we can queue
        console.log("=== FINALIZATION COMPLETE ===");
        console.log("Proposal state:", uint256(_tokenized().state(pid)));
        // 0=Pending, 1=Active, 2=Canceled, 3=Defeated, 4=Succeeded, 5=Queued, 6=Expired, 7=Executed

        try this.tryQueue(pid) {
            console.log("Queue SUCCESS");
        } catch {
            console.log("Queue FAILED - insufficient quorum");
        }
    }

    function tryQueue(uint256 pid) external {
        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pid));
        require(success, "Queue failed");
    }
}
