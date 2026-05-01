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

/// @title Admin Journey Integration Tests
/// @notice Comprehensive tests for admin user journey covering deployment, monitoring, and execution
contract QuadraticVotingAdminJourneyTest is Test {
    AllocationMechanismFactory factory;
    ERC20Mock token;
    QuadraticVotingMechanism mechanism;

    address alice = address(0x1);
    address bob = address(0x2);
    address charlie = address(0x3);
    address dave = address(0x4);
    address newOwner = address(0xa);

    uint256 constant LARGE_DEPOSIT = 1000 ether;
    uint256 constant MEDIUM_DEPOSIT = 500 ether;
    uint256 constant QUORUM_REQUIREMENT = 500; // Adjusted for quadratic funding
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;
    uint256 constant TIMELOCK_DELAY = 1 days;

    function _tokenized(address _mechanism) internal pure returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(_mechanism);
    }

    /// @notice Helper function to sign up a user with specified deposit
    /// @param user Address of user to sign up
    /// @param depositAmount Amount of tokens to deposit
    function _signupUser(address user, uint256 depositAmount) internal {
        vm.startPrank(user);
        token.approve(address(mechanism), depositAmount);
        _tokenized(address(mechanism)).signup(depositAmount);
        vm.stopPrank();
    }

    /// @notice Helper function to create a proposal
    /// @param proposer Address creating the proposal
    /// @param recipient Address that will receive funds if proposal passes
    /// @param description Description of the proposal
    /// @return pid The proposal ID
    function _createProposal(
        address proposer,
        address recipient,
        string memory description
    ) internal returns (uint256 pid) {
        vm.prank(proposer);
        pid = _tokenized(address(mechanism)).propose(recipient, description);
    }

    /// @notice Helper function to cast a vote on a proposal
    /// @param voter Address casting the vote
    /// @param pid Proposal ID to vote on
    /// @param weight Vote weight (quadratic cost = weight^2)
    /// @param recipient Expected recipient address for the proposal
    function _castVote(address voter, uint256 pid, uint256 weight, address recipient) internal {
        vm.prank(voter);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, weight, recipient);
    }

    function setUp() public {
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();

        token.mint(alice, 2000 ether);
        token.mint(bob, 1500 ether);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Admin Journey Test",
            symbol: "AJTEST",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: QUORUM_REQUIREMENT,
            timelockDelay: TIMELOCK_DELAY,
            gracePeriod: 7 days,
            owner: address(0)
        });

        address mechanismAddr = factory.deployQuadraticVotingMechanism(config, 50, 100); // 50% alpha
        mechanism = QuadraticVotingMechanism(payable(mechanismAddr));

        // Set alice as keeper and bob as management so they can create proposals
        _tokenized(address(mechanism)).setKeeper(alice);
        _tokenized(address(mechanism)).setManagement(bob);
    }

    /// @notice Test admin deployment and configuration verification
    function testAdminDeployment_ConfigurationVerification() public {
        // Verify factory deployment state
        assertEq(factory.getDeployedCount(), 1);
        assertTrue(factory.isMechanism(address(mechanism)));
        assertNotEq(factory.tokenizedAllocationImplementation(), address(0));

        // Verify mechanism configuration
        assertEq(_tokenized(address(mechanism)).name(), "Admin Journey Test");
        assertEq(_tokenized(address(mechanism)).symbol(), "AJTEST");
        assertEq(address(_tokenized(address(mechanism)).asset()), address(token));
        assertEq(_tokenized(address(mechanism)).votingDelay(), VOTING_DELAY);
        assertEq(_tokenized(address(mechanism)).votingPeriod(), VOTING_PERIOD);
        assertEq(_tokenized(address(mechanism)).quorumShares(), QUORUM_REQUIREMENT);
        assertEq(_tokenized(address(mechanism)).timelockDelay(), TIMELOCK_DELAY);

        // Verify owner context (deployer becomes owner)
        assertEq(_tokenized(address(mechanism)).owner(), address(this));

        // Deploy second mechanism to test isolation
        AllocationConfig memory config2 = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Second Mechanism",
            symbol: "SECOND",
            votingDelay: 50,
            votingPeriod: 500,
            quorumShares: 300,
            timelockDelay: 2 days,
            gracePeriod: 14 days,
            owner: address(0)
        });

        address mechanism2Addr = factory.deployQuadraticVotingMechanism(config2, 50, 100);

        // Verify isolation between mechanisms
        assertEq(factory.getDeployedCount(), 2);
        assertEq(_tokenized(address(mechanism)).name(), "Admin Journey Test");
        assertEq(_tokenized(mechanism2Addr).name(), "Second Mechanism");
        assertEq(_tokenized(address(mechanism)).votingDelay(), VOTING_DELAY);
        assertEq(_tokenized(mechanism2Addr).votingDelay(), 50);
    }

    /// @notice Test admin monitoring during voting process
    function testAdminMonitoring_VotingProcess() public {
        // Setup realistic voting scenario
        _signupUser(alice, LARGE_DEPOSIT);
        _signupUser(bob, MEDIUM_DEPOSIT);

        // Admin monitors proposal creation
        uint256 pid1 = _createProposal(alice, charlie, "Infrastructure Project");
        uint256 pid2 = _createProposal(bob, dave, "Community Initiative");

        assertEq(_tokenized(address(mechanism)).getProposalCount(), 2);

        // Admin monitors voting progress - advance to voting period
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        _castVote(alice, pid1, 22, charlie);
        _castVote(bob, pid1, 8, charlie);
        _castVote(alice, pid2, 18, dave);
        _castVote(bob, pid2, 18, dave);

        // Admin checks real-time vote tallies using getTally() from ProperQF
        (, , uint256 p1QuadraticFunding, uint256 p1LinearFunding) = mechanism.getTally(pid1);
        uint256 p1For = p1QuadraticFunding + p1LinearFunding;
        assertEq(p1For, 724); // QuadraticFunding: (22+8)² × 0.5 + linear portion = 724

        (, , uint256 p2QuadraticFunding, uint256 p2LinearFunding) = mechanism.getTally(pid2);
        uint256 p2For = p2QuadraticFunding + p2LinearFunding;
        assertEq(p2For, 972); // QuadraticFunding: (18+18)² × 0.5 + linear portion = 972

        // Admin monitors proposal states during voting
        assertEq(
            uint256(_tokenized(address(mechanism)).state(pid1)),
            uint256(TokenizedAllocationMechanism.ProposalState.Active)
        );
        assertEq(
            uint256(_tokenized(address(mechanism)).state(pid2)),
            uint256(TokenizedAllocationMechanism.ProposalState.Active)
        );
    }

    /// @notice Test admin finalization process
    function testAdminFinalization_Process() public {
        // Setup voting
        _signupUser(alice, LARGE_DEPOSIT);
        uint256 pid = _createProposal(alice, charlie, "Test Proposal");

        // Advance to voting period
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        _castVote(alice, pid, 20, charlie);

        // Cannot finalize before voting period ends
        vm.expectRevert();
        _tokenized(address(mechanism)).finalizeVoteTally();

        // Successful finalization after voting period
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        assertFalse(_tokenized(address(mechanism)).tallyFinalized());

        _tokenized(address(mechanism)).finalizeVoteTally();
        assertTrue(_tokenized(address(mechanism)).tallyFinalized());

        // Cannot finalize twice
        vm.expectRevert(TokenizedAllocationMechanism.TallyAlreadyFinalized.selector);
        _tokenized(address(mechanism)).finalizeVoteTally();
    }

    /// @notice Test admin proposal queuing and execution
    function testAdminExecution_ProposalQueuing() public {
        // Setup successful and failed proposals
        _signupUser(alice, LARGE_DEPOSIT);
        _signupUser(bob, MEDIUM_DEPOSIT);

        uint256 pidSuccessful = _createProposal(alice, charlie, "Successful Project");
        uint256 pidFailed = _createProposal(bob, dave, "Failed Project");

        // Advance to voting period
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        // Create outcomes: one success, one failure
        _castVote(alice, pidSuccessful, 25, charlie);
        _castVote(bob, pidSuccessful, 15, charlie);

        // Failed proposal gets insufficient votes
        _castVote(bob, pidFailed, 8, dave);

        // Advance past voting period
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        // Queue successful proposal
        assertEq(
            uint256(_tokenized(address(mechanism)).state(pidSuccessful)),
            uint256(TokenizedAllocationMechanism.ProposalState.Succeeded)
        );

        uint256 timestampBefore = block.timestamp;
        (bool success2, ) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pidSuccessful));
        require(success2, "Queue successful proposal failed");

        // Verify queuing effects
        assertEq(
            uint256(_tokenized(address(mechanism)).state(pidSuccessful)),
            uint256(TokenizedAllocationMechanism.ProposalState.Queued)
        );
        // QuadraticFunding calculation: pidSuccessful gets proportional shares based on weighted funding
        // Alice(25) + Bob(15) = (40)² × 0.5 + contributions × 0.5 = approx 1225 weighted funding
        // Exact shares depend on total funding across all proposals
        uint256 actualShares = _tokenized(address(mechanism)).proposalShares(pidSuccessful);
        assertTrue(actualShares > 0, "Successful proposal should receive shares");
        assertEq(_tokenized(address(mechanism)).balanceOf(charlie), actualShares);
        assertEq(_tokenized(address(mechanism)).globalRedemptionStart(), timestampBefore + TIMELOCK_DELAY);

        // Cannot queue failed proposal
        assertEq(
            uint256(_tokenized(address(mechanism)).state(pidFailed)),
            uint256(TokenizedAllocationMechanism.ProposalState.Defeated)
        );

        vm.expectRevert(); // Should revert with NoQuorum or similar for defeated proposal
        _tokenized(address(mechanism)).queueProposal(pidFailed);

        // Cannot queue already queued proposal
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.AlreadyQueued.selector, pidSuccessful));
        _tokenized(address(mechanism)).queueProposal(pidSuccessful);
    }

    /// @notice Test admin emergency functions
    function testAdminEmergency_Functions() public {
        // Test pause mechanism
        assertFalse(_tokenized(address(mechanism)).paused());

        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("pause()"));
        require(success, "Pause failed");
        assertTrue(_tokenized(address(mechanism)).paused());

        // Paused mechanism blocks operations
        vm.expectRevert(TokenizedAllocationMechanism.PausedError.selector);
        vm.prank(alice);
        _tokenized(address(mechanism)).signup(100 ether);

        // Unpause mechanism
        (bool success2, ) = address(mechanism).call(abi.encodeWithSignature("unpause()"));
        require(success2, "Unpause failed");
        assertFalse(_tokenized(address(mechanism)).paused());

        // Transfer ownership
        (bool success3, ) = address(mechanism).call(abi.encodeWithSignature("transferOwnership(address)", newOwner));
        require(success3, "Transfer ownership failed");

        // New owner accepts ownership
        vm.prank(newOwner);
        (bool success3b, ) = address(mechanism).call(abi.encodeWithSignature("acceptOwnership()"));
        require(success3b, "Accept ownership failed");
        assertEq(_tokenized(address(mechanism)).owner(), newOwner);

        // Old owner cannot perform owner functions
        vm.expectRevert(TokenizedAllocationMechanism.Unauthorized.selector);
        _tokenized(address(mechanism)).pause();

        // New owner can perform owner functions
        vm.startPrank(newOwner);
        (bool success5, ) = address(mechanism).call(abi.encodeWithSignature("pause()"));
        require(success5, "New owner pause failed");
        assertTrue(_tokenized(address(mechanism)).paused());
        vm.stopPrank();
    }

    /// @notice Test admin crisis management and recovery
    function testAdminCrisis_ManagementRecovery() public {
        // Setup scenario with potential failures
        _signupUser(alice, LARGE_DEPOSIT);
        _signupUser(bob, MEDIUM_DEPOSIT);

        uint256 pid = _createProposal(alice, charlie, "Test proposal");

        // Advance to voting period
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        _castVote(alice, pid, 20, charlie);

        // Emergency pause during voting
        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("pause()"));
        require(success, "Pause failed");

        // All operations blocked
        vm.expectRevert(TokenizedAllocationMechanism.PausedError.selector);
        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, 8, charlie);

        // Resume operations
        (bool success2, ) = address(mechanism).call(abi.encodeWithSignature("unpause()"));
        require(success2, "Unpause failed");

        // Operations work again - use bob since alice already voted
        _castVote(bob, pid, 8, charlie);

        // Ownership transfer during crisis
        address emergencyAdmin = newOwner;
        (bool success3, ) = address(mechanism).call(
            abi.encodeWithSignature("transferOwnership(address)", emergencyAdmin)
        );
        require(success3, "Transfer ownership failed");

        // New owner accepts ownership
        vm.prank(emergencyAdmin);
        (bool success3b, ) = address(mechanism).call(abi.encodeWithSignature("acceptOwnership()"));
        require(success3b, "Accept ownership failed");

        // New owner manages crisis
        vm.startPrank(emergencyAdmin);
        (bool success4, ) = address(mechanism).call(abi.encodeWithSignature("pause()"));
        require(success4, "Emergency admin pause failed");
        vm.stopPrank();

        // System recovery after crisis
        vm.startPrank(emergencyAdmin);
        (bool success5, ) = address(mechanism).call(abi.encodeWithSignature("unpause()"));
        require(success5, "Recovery unpause failed");
        vm.stopPrank();

        // Complete voting cycle to verify system integrity
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        vm.startPrank(emergencyAdmin);
        (bool success6, ) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success6, "Emergency finalization failed");

        (bool success7, ) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pid));
        require(success7, "Emergency queuing failed");
        vm.stopPrank();

        // System functions normally - alice (20) + bob (8) votes in QuadraticFunding
        // Total weighted funding = quadratic + linear components, shares allocated proportionally
        uint256 actualShares = _tokenized(address(mechanism)).balanceOf(charlie);
        assertTrue(actualShares > 0, "Successful proposal should receive shares after crisis recovery");
        assertEq(
            uint256(_tokenized(address(mechanism)).state(pid)),
            uint256(TokenizedAllocationMechanism.ProposalState.Queued)
        );
    }
}
