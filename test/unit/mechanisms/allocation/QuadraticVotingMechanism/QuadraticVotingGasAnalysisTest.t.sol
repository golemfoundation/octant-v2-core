// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import { QuadraticVotingMechanism } from "src/mechanisms/mechanism/QuadraticVotingMechanism.sol";
import { AllocationMechanismFactory } from "src/mechanisms/AllocationMechanismFactory.sol";
import { TokenizedAllocationMechanism } from "src/mechanisms/TokenizedAllocationMechanism.sol";
import { AllocationConfig } from "src/mechanisms/BaseAllocationMechanism.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Gas Analysis Test for Cold vs Warm Storage Operations
/// @notice Analyzes gas costs for voting on new projects (cold storage) vs existing projects (warm storage)
contract QuadraticVotingGasAnalysisTest is Test {
    // Events for gas measurement logging
    event GasMeasurement(string operation, uint256 gasUsed);
    event GasComparison(string comparison, uint256 gasA, uint256 gasB, uint256 difference, uint256 percentSavings);

    AllocationMechanismFactory factory;
    QuadraticVotingMechanism mechanism;
    ERC20Mock token;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");
    address david = makeAddr("david");

    address recipient1 = makeAddr("recipient1");
    address recipient2 = makeAddr("recipient2");
    address recipient3 = makeAddr("recipient3");

    function setUp() public {
        // Deploy factory and token
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();

        // Deploy mechanism with alpha = 1.0 (pure quadratic)
        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Gas Analysis Test",
            symbol: "GAT",
            votingDelay: 5, // voting delay blocks
            votingPeriod: 100, // voting period blocks
            quorumShares: 1000 ether,
            timelockDelay: 10, // timelock blocks
            gracePeriod: 50, // grace period blocks
            owner: address(this) // will be set by factory
        });

        address mechanismAddr = factory.deployQuadraticVotingMechanism(
            config,
            10000, // alpha numerator (1.0)
            10000 // alpha denominator (1.0)
        );

        mechanism = QuadraticVotingMechanism(payable(mechanismAddr));
        TokenizedAllocationMechanism(address(mechanism)).setKeeper(alice);
        TokenizedAllocationMechanism(address(mechanism)).setManagement(david);

        console.log("=== GAS ANALYSIS TEST SETUP COMPLETE ===");
        console.log("Mechanism deployed at:", address(mechanism));
        console.log("Test token deployed at:", address(token));
    }

    /// @notice Test gas costs for cold storage operations (first votes on new projects)
    function testColdStorageVoting() public {
        console.log("\n=== COLD STORAGE VOTING ANALYSIS ===");

        // Setup users with voting power
        _setupUsers();

        // Get absolute timeline from contract
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized().votingDelay();
        uint256 votingStartTime = deploymentTime + votingDelay;

        // Create proposals for cold storage testing
        vm.prank(alice);
        uint256 pid1 = _tokenized().propose(recipient1, "First Project");

        vm.prank(david);
        uint256 pid2 = _tokenized().propose(recipient2, "Second Project");

        vm.prank(alice);
        uint256 pid3 = _tokenized().propose(recipient3, "Third Project");

        console.log("Created 3 proposals for cold storage testing");

        // Advance to voting period
        vm.warp(votingStartTime + 1);

        // Test cold storage voting (first votes on each project)
        console.log("\n--- COLD STORAGE OPERATIONS ---");

        // Alice votes on project 1 (cold storage - first vote on this project)
        console.log("Testing Alice vote on project 1 (COLD STORAGE - first vote on project):");
        uint256 gasStart1 = gasleft();
        vm.prank(alice);
        _tokenized().castVote(pid1, TokenizedAllocationMechanism.VoteType.For, 20, recipient1); // 400 voting power cost
        uint256 gasCold1 = gasStart1 - gasleft();
        console.log("Alice COLD vote gas:", gasCold1);
        emit GasMeasurement("Alice_ColdStorage_Vote", gasCold1);

        // Bob votes on project 2 (cold storage - first vote on this project)
        console.log("Testing Bob vote on project 2 (COLD STORAGE - first vote on project):");
        uint256 gasStart2 = gasleft();
        vm.prank(bob);
        _tokenized().castVote(pid2, TokenizedAllocationMechanism.VoteType.For, 15, recipient2); // 225 voting power cost
        uint256 gasCold2 = gasStart2 - gasleft();
        console.log("Bob COLD vote gas:", gasCold2);
        emit GasMeasurement("Bob_ColdStorage_Vote", gasCold2);

        // Charlie votes on project 3 (cold storage - first vote on this project)
        console.log("Testing Charlie vote on project 3 (COLD STORAGE - first vote on project):");
        uint256 gasStart3 = gasleft();
        vm.prank(charlie);
        _tokenized().castVote(pid3, TokenizedAllocationMechanism.VoteType.For, 10, recipient3); // 100 voting power cost
        uint256 gasCold3 = gasStart3 - gasleft();
        console.log("Charlie COLD vote gas:", gasCold3);
        emit GasMeasurement("Charlie_ColdStorage_Vote", gasCold3);

        uint256 avgColdGas = (gasCold1 + gasCold2 + gasCold3) / 3;
        console.log("Average COLD storage voting gas:", avgColdGas);
        emit GasMeasurement("Average_ColdStorage_Vote", avgColdGas);
        console.log("COLD storage pattern: First votes initialize new project storage slots");
    }

    /// @notice Test gas costs for warm storage operations (subsequent votes on existing projects)
    function testWarmStorageVoting() public {
        console.log("\n=== WARM STORAGE VOTING ANALYSIS ===");

        // Setup users with voting power (using fresh addresses to avoid conflicts)
        address alice2 = makeAddr("alice2");
        address bob2 = makeAddr("bob2");
        address charlie2 = makeAddr("charlie2");
        address david2 = makeAddr("david2");

        address[] memory users = new address[](4);
        users[0] = alice2;
        users[1] = bob2;
        users[2] = charlie2;
        users[3] = david2;

        for (uint256 i = 0; i < users.length; i++) {
            token.mint(users[i], 1000 ether);
            vm.prank(users[i]);
            token.approve(address(mechanism), 1000 ether);
            vm.prank(users[i]);
            _tokenized().signup(1000 ether);
        }
        console.log("Setup complete: 4 fresh users with 1000 ether voting power each");

        // Create proposals and set up initial votes (cold storage operations)
        vm.prank(alice);
        uint256 pid1 = _tokenized().propose(recipient1, "First Project");

        vm.prank(david);
        uint256 pid2 = _tokenized().propose(recipient2, "Second Project");

        vm.prank(alice);
        uint256 pid3 = _tokenized().propose(recipient3, "Third Project");

        console.log("Created 3 proposals for warm storage testing");

        // Get absolute timeline from contract
        uint256 deploymentTime2 = block.timestamp;
        uint256 votingDelay2 = _tokenized().votingDelay();
        uint256 votingStartTime2 = deploymentTime2 + votingDelay2;

        // Advance to voting period
        vm.warp(votingStartTime2 + 1);

        // First create some votes to "warm up" the storage
        vm.prank(alice2);
        _tokenized().castVote(pid1, TokenizedAllocationMechanism.VoteType.For, 5, recipient1); // Initial vote to warm storage

        vm.prank(bob2);
        _tokenized().castVote(pid2, TokenizedAllocationMechanism.VoteType.For, 5, recipient2); // Initial vote to warm storage

        vm.prank(charlie2);
        _tokenized().castVote(pid3, TokenizedAllocationMechanism.VoteType.For, 5, recipient3); // Initial vote to warm storage

        console.log("\n--- WARM STORAGE OPERATIONS ---");

        // Test warm storage voting (different users voting on projects that already have votes)
        // Bob2 votes on project 3 (Charlie2 already voted on it in warmup)
        console.log("Testing Bob2 vote on project 3 (WARM STORAGE - project already has votes):");
        uint256 gasStartWarm1 = gasleft();
        vm.prank(bob2);
        _tokenized().castVote(pid3, TokenizedAllocationMechanism.VoteType.For, 10, recipient3); // 100 voting power cost
        uint256 gasWarm1 = gasStartWarm1 - gasleft();
        console.log("Bob2 WARM vote gas:", gasWarm1);
        emit GasMeasurement("Bob2_WarmStorage_Vote", gasWarm1);

        // Charlie2 votes on project 1 (Alice2 already voted on it in warmup)
        console.log("Testing Charlie2 vote on project 1 (WARM STORAGE - project already has votes):");
        uint256 gasStartWarm2 = gasleft();
        vm.prank(charlie2);
        _tokenized().castVote(pid1, TokenizedAllocationMechanism.VoteType.For, 8, recipient1); // 64 voting power cost
        uint256 gasWarm2 = gasStartWarm2 - gasleft();
        console.log("Charlie2 WARM vote gas:", gasWarm2);
        emit GasMeasurement("Charlie2_WarmStorage_Vote", gasWarm2);

        // David2 votes on project 2 (Bob2 already voted on it in warmup)
        console.log("Testing David2 vote on project 2 (WARM STORAGE - project already has votes):");
        uint256 gasStartWarm3 = gasleft();
        vm.prank(david2);
        _tokenized().castVote(pid2, TokenizedAllocationMechanism.VoteType.For, 12, recipient2); // 144 voting power cost
        uint256 gasWarm3 = gasStartWarm3 - gasleft();
        console.log("David2 WARM vote gas:", gasWarm3);
        emit GasMeasurement("David2_WarmStorage_Vote", gasWarm3);

        uint256 avgWarmGas = (gasWarm1 + gasWarm2 + gasWarm3) / 3;
        console.log("Average WARM storage voting gas:", avgWarmGas);
        emit GasMeasurement("Average_WarmStorage_Vote", avgWarmGas);

        console.log("\n--- WARM STORAGE ANALYSIS COMPLETE ---");
        console.log("WARM storage votes update existing project storage slots");
        console.log("WARM storage benefits from pre-initialized storage (SSTORE warm vs cold)");
    }

    /// @notice Test gas costs for multiple votes on the same project by the same user
    function testRepeatedVotingOnSameProject() public {
        console.log("\n=== REPEATED VOTING ON SAME PROJECT ANALYSIS ===");

        // Setup users
        _setupUsers();

        // Create one proposal
        vm.prank(alice);
        uint256 pid = _tokenized().propose(recipient1, "Repeated Voting Project");

        // Get absolute timeline from contract
        uint256 deploymentTime3 = block.timestamp;
        uint256 votingDelay3 = _tokenized().votingDelay();
        uint256 votingStartTime3 = deploymentTime3 + votingDelay3;

        // Advance to voting period
        vm.warp(votingStartTime3 + 1);

        console.log("Testing multiple votes from Alice on same project...");

        // In our system, users can only vote once per proposal, but they can update their vote weight
        // We'll test different users voting on the same project instead

        // Alice's vote (cold storage - first vote on project)
        console.log("Alice voting on project (COLD - first vote on project):");
        uint256 gasStartFirst = gasleft();
        vm.prank(alice);
        _tokenized().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 10, recipient1); // 100 voting power cost
        uint256 gasFirst = gasStartFirst - gasleft();
        console.log("Alice FIRST vote gas:", gasFirst);
        emit GasMeasurement("Alice_FirstVote_OnProject", gasFirst);

        // Bob's vote (warm storage - project already has votes)
        console.log("Bob voting on same project (WARM - project has existing votes):");
        uint256 gasStartSecond = gasleft();
        vm.prank(bob);
        _tokenized().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 15, recipient1); // 225 voting power cost
        uint256 gasSecond = gasStartSecond - gasleft();
        console.log("Bob SECOND vote gas:", gasSecond);
        emit GasMeasurement("Bob_SecondVote_OnProject", gasSecond);

        // Charlie's vote (warm storage - project already has votes from 2 users)
        console.log("Charlie voting on same project (WARM - project has existing votes from 2 users):");
        uint256 gasStartThird = gasleft();
        vm.prank(charlie);
        _tokenized().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20, recipient1); // 400 voting power cost
        uint256 gasThird = gasStartThird - gasleft();
        console.log("Charlie THIRD vote gas:", gasThird);
        emit GasMeasurement("Charlie_ThirdVote_OnProject", gasThird);

        console.log("\n--- REPEATED VOTING ANALYSIS ---");
        console.log("First vote (Alice):", gasFirst, "gas - COLD storage initialization");
        console.log("Second vote (Bob):", gasSecond, "gas - WARM storage update");
        console.log("Third vote (Charlie):", gasThird, "gas - WARM storage update");

        if (gasFirst > gasSecond) {
            uint256 savings = gasFirst - gasSecond;
            uint256 savingsPercent = (savings * 100) / gasFirst;
            console.log("WARM storage saves:", savings, "gas");
            emit GasComparison("WARM_vs_COLD_Storage", gasFirst, gasSecond, savings, savingsPercent);
        }
    }

    /// @notice Test gas costs for voting with different weight magnitudes
    function testVotingWeightImpactOnGas() public {
        console.log("\n=== VOTING WEIGHT IMPACT ON GAS ANALYSIS ===");

        // Setup users
        _setupUsers();

        // Create multiple proposals for testing different weights
        vm.prank(alice);
        uint256 pid1 = _tokenized().propose(recipient1, "Small Weight Project");

        vm.prank(alice);
        uint256 pid2 = _tokenized().propose(recipient2, "Medium Weight Project");

        vm.prank(alice);
        uint256 pid3 = _tokenized().propose(recipient3, "Large Weight Project");

        // Get absolute timeline from contract
        uint256 deploymentTime4 = block.timestamp;
        uint256 votingDelay4 = _tokenized().votingDelay();
        uint256 votingStartTime4 = deploymentTime4 + votingDelay4;

        // Advance to voting period
        vm.warp(votingStartTime4 + 1);

        console.log("Testing different vote weights on new projects...");

        // Small weight vote (weight=5, cost=25)
        uint256 gasStartSmall = gasleft();
        vm.prank(alice);
        _tokenized().castVote(pid1, TokenizedAllocationMechanism.VoteType.For, 5, recipient1);
        uint256 gasSmallWeight = gasStartSmall - gasleft();
        console.log("Small weight vote (5, cost=25):", gasSmallWeight, "gas");
        emit GasMeasurement("Small_Weight_Vote", gasSmallWeight);

        // Medium weight vote (weight=20, cost=400)
        uint256 gasStartMedium = gasleft();
        vm.prank(alice);
        _tokenized().castVote(pid2, TokenizedAllocationMechanism.VoteType.For, 20, recipient2);
        uint256 gasMediumWeight = gasStartMedium - gasleft();
        console.log("Medium weight vote (20, cost=400):", gasMediumWeight, "gas");
        emit GasMeasurement("Medium_Weight_Vote", gasMediumWeight);

        // Large weight vote (weight=31, cost=961)
        uint256 gasStartLarge = gasleft();
        vm.prank(alice);
        _tokenized().castVote(pid3, TokenizedAllocationMechanism.VoteType.For, 31, recipient3);
        uint256 gasLargeWeight = gasStartLarge - gasleft();
        console.log("Large weight vote (31, cost=961):", gasLargeWeight, "gas");
        emit GasMeasurement("Large_Weight_Vote", gasLargeWeight);

        console.log("\n--- WEIGHT IMPACT ANALYSIS ---");
        uint256 mediumSmallDiff = gasMediumWeight > gasSmallWeight ? gasMediumWeight - gasSmallWeight : 0;
        uint256 largeMediumDiff = gasLargeWeight > gasMediumWeight ? gasLargeWeight - gasMediumWeight : 0;
        uint256 largeSmallDiff = gasLargeWeight > gasSmallWeight ? gasLargeWeight - gasSmallWeight : 0;

        console.log("Gas difference (medium - small):", mediumSmallDiff);
        console.log("Gas difference (large - medium):", largeMediumDiff);
        console.log("Gas difference (large - small):", largeSmallDiff);

        emit GasComparison(
            "Medium_vs_Small_Weight",
            gasMediumWeight,
            gasSmallWeight,
            mediumSmallDiff,
            mediumSmallDiff > 0 ? (mediumSmallDiff * 100) / gasSmallWeight : 0
        );
        emit GasComparison(
            "Large_vs_Medium_Weight",
            gasLargeWeight,
            gasMediumWeight,
            largeMediumDiff,
            largeMediumDiff > 0 ? (largeMediumDiff * 100) / gasMediumWeight : 0
        );
        emit GasComparison(
            "Large_vs_Small_Weight",
            gasLargeWeight,
            gasSmallWeight,
            largeSmallDiff,
            largeSmallDiff > 0 ? (largeSmallDiff * 100) / gasSmallWeight : 0
        );

        if (gasSmallWeight == gasMediumWeight && gasMediumWeight == gasLargeWeight) {
            console.log("RESULT: Vote weight has NO impact on gas cost");
        } else {
            console.log("RESULT: Vote weight AFFECTS gas cost");
        }
    }

    /// @notice Test gas costs for sequential votes on different projects
    function testSequentialVotingAcrossProjects() public {
        console.log("\n=== SEQUENTIAL VOTING ACROSS PROJECTS ANALYSIS ===");

        // Setup users
        _setupUsers();

        // Create 5 proposals
        vm.prank(alice);
        uint256 pid1 = _tokenized().propose(recipient1, "Project 1");
        vm.prank(alice);
        uint256 pid2 = _tokenized().propose(recipient2, "Project 2");
        vm.prank(alice);
        uint256 pid3 = _tokenized().propose(recipient3, "Project 3");
        vm.prank(david);
        uint256 pid4 = _tokenized().propose(makeAddr("recipient4"), "Project 4");
        vm.prank(david);
        uint256 pid5 = _tokenized().propose(makeAddr("recipient5"), "Project 5");

        // Get absolute timeline from contract
        uint256 deploymentTime5 = block.timestamp;
        uint256 votingDelay5 = _tokenized().votingDelay();
        uint256 votingStartTime5 = deploymentTime5 + votingDelay5;

        // Advance to voting period
        vm.warp(votingStartTime5 + 1);

        console.log("Testing Alice voting sequentially across 5 projects...");

        uint256[] memory gasUsed = new uint256[](5);
        uint256[] memory pids = new uint256[](5);
        pids[0] = pid1;
        pids[1] = pid2;
        pids[2] = pid3;
        pids[3] = pid4;
        pids[4] = pid5;

        address[] memory recipients = new address[](5);
        recipients[0] = recipient1;
        recipients[1] = recipient2;
        recipients[2] = recipient3;
        recipients[3] = makeAddr("recipient4");
        recipients[4] = makeAddr("recipient5");

        // Alice votes on each project sequentially
        for (uint256 i = 0; i < 5; i++) {
            uint256 gasStart = gasleft();
            vm.prank(alice);
            _tokenized().castVote(pids[i], TokenizedAllocationMechanism.VoteType.For, 10, recipients[i]);
            gasUsed[i] = gasStart - gasleft();
            console.log("Vote %d (project %d): %d gas", i + 1, pids[i], gasUsed[i]);
            emit GasMeasurement(string(abi.encodePacked("Sequential_Vote_", vm.toString(i + 1))), gasUsed[i]);
        }

        console.log("\n--- SEQUENTIAL VOTING PATTERNS ---");
        console.log("First vote (cold global state):", gasUsed[0], "gas");

        uint256 totalSubsequent = 0;
        for (uint256 i = 1; i < 5; i++) {
            totalSubsequent += gasUsed[i];
        }
        uint256 avgSubsequent = totalSubsequent / 4;
        console.log("Average subsequent votes:", avgSubsequent, "gas");

        if (gasUsed[0] > avgSubsequent) {
            uint256 firstVotePenalty = gasUsed[0] - avgSubsequent;
            uint256 penaltyPercent = (firstVotePenalty * 100) / gasUsed[0];
            console.log("First vote penalty:", firstVotePenalty, "gas");
            emit GasComparison(
                "First_vs_Avg_Subsequent_Votes",
                gasUsed[0],
                avgSubsequent,
                firstVotePenalty,
                penaltyPercent
            );
        }

        // Check if there's a pattern in gas reduction
        bool decreasingPattern = true;
        for (uint256 i = 1; i < 5; i++) {
            if (gasUsed[i] >= gasUsed[i - 1]) {
                decreasingPattern = false;
                break;
            }
        }

        if (decreasingPattern) {
            console.log("PATTERN: Gas costs decrease with each vote");
        } else {
            console.log("PATTERN: Gas costs stabilize after first vote");
        }
    }

    /// @notice Helper function to get the tokenized allocation mechanism
    function _tokenized() internal view returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(address(mechanism));
    }

    /// @notice Setup users with voting power
    function _setupUsers() internal {
        // Give users tokens and voting power
        address[] memory users = new address[](4);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;
        users[3] = david;

        for (uint256 i = 0; i < users.length; i++) {
            token.mint(users[i], 1000 ether);
            vm.prank(users[i]);
            token.approve(address(mechanism), 1000 ether);
            vm.prank(users[i]);
            _tokenized().signup(1000 ether);
        }

        console.log("Setup complete: 4 users with 1000 ether voting power each");
    }
}
