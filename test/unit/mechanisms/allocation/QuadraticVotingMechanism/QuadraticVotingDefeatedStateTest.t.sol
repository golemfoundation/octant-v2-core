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

contract QuadraticVotingDefeatedStateTest is Test {
    AllocationMechanismFactory factory;
    ERC20Mock token;
    QuadraticVotingMechanism mechanism;

    address alice = address(0x1);
    address frank = address(0x6);

    uint256 constant LARGE_DEPOSIT = 1000 ether;
    uint256 constant QUORUM_REQUIREMENT = 200 ether;
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;

    function _tokenized(address _mechanism) internal pure returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(_mechanism);
    }

    function setUp() public {
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();
        token.mint(alice, 2000 ether);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Debug Defeated",
            symbol: "DEBUG",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: QUORUM_REQUIREMENT,
            timelockDelay: 1 days,
            gracePeriod: 7 days,
            owner: address(0)
        });

        address mechanismAddr = factory.deployQuadraticVotingMechanism(config, 50, 100); // 50% alpha
        mechanism = QuadraticVotingMechanism(payable(mechanismAddr));
        _tokenized(address(mechanism)).setKeeper(alice);
    }

    function testDebugDefeatedState() public {
        // Fetch actual timeline values from the contract
        // The mechanism sets startTime = block.timestamp during initialization
        // We can calculate the timeline from the deployment time and configuration
        uint256 deploymentTime = block.timestamp; // Time when mechanism was deployed in setUp()
        uint256 votingDelay = _tokenized(address(mechanism)).votingDelay();
        uint256 votingPeriod = _tokenized(address(mechanism)).votingPeriod();

        // Calculate absolute timeline timestamps
        uint256 startTime = deploymentTime; // Contract sets this during initialization
        uint256 votingStartTime = startTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        console.log("Timeline - Start:", startTime);
        console.log("Timeline - Voting Start:", votingStartTime);
        console.log("Timeline - Voting End:", votingEndTime);

        // Setup voter
        vm.startPrank(alice);
        token.approve(address(mechanism), LARGE_DEPOSIT);
        _tokenized(address(mechanism)).signup(LARGE_DEPOSIT);
        vm.stopPrank();

        console.log("Alice voting power:", _tokenized(address(mechanism)).votingPower(alice));
        console.log("Quorum requirement:", _tokenized(address(mechanism)).quorumShares());

        // Create proposal that should be defeated
        vm.prank(alice);
        uint256 pid = _tokenized(address(mechanism)).propose(frank, "Frank's Low Vote Proposal");

        // Warp to absolute voting start time (not relative)
        vm.warp(votingStartTime + 1);
        console.log("Warped to voting time:", block.timestamp);

        // Vote with insufficient amount for quorum - QuadraticFunding calculation needed
        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, 10, frank);

        console.log("Vote weight: 10, quadratic cost: 100 voting power");

        // Check vote tally before finalization using getTally() from ProperQF
        (, , uint256 quadraticFunding, uint256 linearFunding) = mechanism.getTally(pid);
        uint256 forVotes = quadraticFunding + linearFunding;
        uint256 againstVotes = 0; // QuadraticVoting only supports For votes
        uint256 abstainVotes = 0; // QuadraticVoting only supports For votes
        console.log("For votes (QuadraticFunding):", forVotes / 1e18);
        console.log("Against votes (always 0 in QuadraticVoting):", againstVotes / 1e18);
        console.log("Abstain votes (always 0 in QuadraticVoting):", abstainVotes / 1e18);

        // Warp to absolute voting end time for finalization (not relative)
        vm.warp(votingEndTime + 1);
        console.log("Warped to finalization time:", block.timestamp);
        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        // Check if proposal has quorum
        (bool success2, ) = address(mechanism).call(abi.encodeWithSignature("hasQuorumHook(uint256)", pid));
        console.log("hasQuorumHook call success:", success2);

        // Check QuadraticFunding weighted total for quorum
        console.log("Weighted funding for quorum check (forVotes):", forVotes / 1e18);
        console.log("Quorum requirement:", QUORUM_REQUIREMENT / 1e18);
        console.log("Has quorum:", forVotes >= QUORUM_REQUIREMENT);

        // Check actual state
        uint256 actualState = uint(_tokenized(address(mechanism)).state(pid));
        console.log("Actual state:", actualState);
        console.log("Expected Defeated state:", uint(TokenizedAllocationMechanism.ProposalState.Defeated));

        if (actualState == uint(TokenizedAllocationMechanism.ProposalState.Defeated)) {
            console.log("SUCCESS: Proposal is correctly DEFEATED");
        } else {
            console.log("FAILURE: Proposal should be DEFEATED but has different state");

            if (actualState == uint(TokenizedAllocationMechanism.ProposalState.Active)) {
                console.log("State is ACTIVE");
            } else if (actualState == uint(TokenizedAllocationMechanism.ProposalState.Succeeded)) {
                console.log("State is SUCCEEDED");
            } else if (actualState == uint(TokenizedAllocationMechanism.ProposalState.Pending)) {
                console.log("State is PENDING");
            }
        }
    }
}
