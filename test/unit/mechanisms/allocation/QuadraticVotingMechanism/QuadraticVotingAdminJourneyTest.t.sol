// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/console.sol";
import {TokenizedAllocationMechanism} from "src/mechanisms/TokenizedAllocationMechanism.sol";
import {QuadraticVotingTestBase} from "../utils/QuadraticVotingTestBase.sol";

/// @title Admin Journey Integration Tests
/// @notice Comprehensive tests for admin user journey covering deployment, monitoring, and execution
contract QuadraticVotingAdminJourneyTest is QuadraticVotingTestBase {
    address newOwner = address(0xa);

    uint256 constant LARGE_DEPOSIT = 1000 ether;
    uint256 constant MEDIUM_DEPOSIT = 500 ether;
    uint256 constant QUORUM_REQUIREMENT = 500; // Adjusted for quadratic funding
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;
    uint256 constant TIMELOCK_DELAY = 1 days;

    function setUp() public {
        _setUpQuadraticVoting(
            "Admin Journey Test",
            "AJTEST",
            VOTING_DELAY,
            VOTING_PERIOD,
            QUORUM_REQUIREMENT,
            TIMELOCK_DELAY,
            7 days,
            50,
            100
        );

        token.mint(alice, 2000 ether);
        token.mint(bob, 1500 ether);
        _setRoles(alice, bob);
    }

    /// @notice Test admin deployment and configuration verification
    function testAdminDeployment_ConfigurationVerification() public {
        // Verify factory deployment state
        assertEq(factory.getDeployedCount(), 1);
        assertTrue(factory.isMechanism(address(mechanism)));
        assertNotEq(factory.tokenizedAllocationImplementation(), address(0));

        // Verify mechanism configuration
        assertEq(_tokenized().name(), "Admin Journey Test");
        assertEq(_tokenized().symbol(), "AJTEST");
        assertEq(address(_tokenized().asset()), address(token));
        assertEq(_tokenized().votingDelay(), VOTING_DELAY);
        assertEq(_tokenized().votingPeriod(), VOTING_PERIOD);
        assertEq(_tokenized().quorumShares(), QUORUM_REQUIREMENT);
        assertEq(_tokenized().timelockDelay(), TIMELOCK_DELAY);

        // Verify owner context (deployer becomes owner)
        assertEq(_tokenized().owner(), address(this));

        // Deploy second mechanism to test isolation
        address mechanism2Addr = address(
            _deployQuadraticVoting(
                factory,
                _config({
                    asset: token,
                    name: "Second Mechanism",
                    symbol: "SECOND",
                    votingDelay: 50,
                    votingPeriod: 500,
                    quorumShares: 300,
                    timelockDelay: 2 days,
                    gracePeriod: 14 days,
                    owner: address(0)
                }),
                50,
                100
            )
        );

        // Verify isolation between mechanisms
        assertEq(factory.getDeployedCount(), 2);
        assertEq(_tokenized().name(), "Admin Journey Test");
        assertEq(_tokenized(mechanism2Addr).name(), "Second Mechanism");
        assertEq(_tokenized().votingDelay(), VOTING_DELAY);
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

        assertEq(_tokenized().getProposalCount(), 2);

        // Admin monitors voting progress - advance to voting period
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        _castVote(alice, pid1, 22, charlie);
        _castVote(bob, pid1, 8, charlie);
        _castVote(alice, pid2, 18, dave);
        _castVote(bob, pid2, 18, dave);

        // Admin checks real-time vote tallies using getTally() from ProperQF
        (,, uint256 p1QuadraticFunding, uint256 p1LinearFunding) = mechanism.getTally(pid1);
        uint256 p1For = p1QuadraticFunding + p1LinearFunding;
        assertEq(p1For, 724); // QuadraticFunding: (22+8)² × 0.5 + linear portion = 724

        (,, uint256 p2QuadraticFunding, uint256 p2LinearFunding) = mechanism.getTally(pid2);
        uint256 p2For = p2QuadraticFunding + p2LinearFunding;
        assertEq(p2For, 972); // QuadraticFunding: (18+18)² × 0.5 + linear portion = 972

        // Admin monitors proposal states during voting
        assertEq(uint256(_tokenized().state(pid1)), uint256(TokenizedAllocationMechanism.ProposalState.Active));
        assertEq(uint256(_tokenized().state(pid2)), uint256(TokenizedAllocationMechanism.ProposalState.Active));
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
        _tokenized().finalizeVoteTally();

        // Successful finalization after voting period
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        assertFalse(_tokenized().tallyFinalized());

        _tokenized().finalizeVoteTally();
        assertTrue(_tokenized().tallyFinalized());

        // Cannot finalize twice
        vm.expectRevert(TokenizedAllocationMechanism.TallyAlreadyFinalized.selector);
        _tokenized().finalizeVoteTally();
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
        (bool success,) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        // Queue successful proposal
        assertEq(
            uint256(_tokenized().state(pidSuccessful)), uint256(TokenizedAllocationMechanism.ProposalState.Succeeded)
        );

        uint256 timestampBefore = block.timestamp;
        (bool success2,) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pidSuccessful));
        require(success2, "Queue successful proposal failed");

        // Verify queuing effects
        assertEq(uint256(_tokenized().state(pidSuccessful)), uint256(TokenizedAllocationMechanism.ProposalState.Queued));
        // QuadraticFunding calculation: pidSuccessful gets proportional shares based on weighted funding
        // Alice(25) + Bob(15) = (40)² × 0.5 + contributions × 0.5 = approx 1225 weighted funding
        // Exact shares depend on total funding across all proposals
        uint256 actualShares = _tokenized().proposalShares(pidSuccessful);
        assertTrue(actualShares > 0, "Successful proposal should receive shares");
        assertEq(_tokenized().balanceOf(charlie), actualShares);
        assertEq(_tokenized().globalRedemptionStart(), timestampBefore + TIMELOCK_DELAY);

        // Cannot queue failed proposal
        assertEq(uint256(_tokenized().state(pidFailed)), uint256(TokenizedAllocationMechanism.ProposalState.Defeated));

        vm.expectRevert(); // Should revert with NoQuorum or similar for defeated proposal
        _tokenized().queueProposal(pidFailed);

        // Cannot queue already queued proposal
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.AlreadyQueued.selector, pidSuccessful));
        _tokenized().queueProposal(pidSuccessful);
    }

    /// @notice Test admin emergency functions
    function testAdminEmergency_Functions() public {
        // Test pause mechanism
        assertFalse(_tokenized().paused());

        (bool success,) = address(mechanism).call(abi.encodeWithSignature("pause()"));
        require(success, "Pause failed");
        assertTrue(_tokenized().paused());

        // Paused mechanism blocks operations
        vm.expectRevert(TokenizedAllocationMechanism.PausedError.selector);
        vm.prank(alice);
        _tokenized().signup(100 ether);

        // Unpause mechanism
        (bool success2,) = address(mechanism).call(abi.encodeWithSignature("unpause()"));
        require(success2, "Unpause failed");
        assertFalse(_tokenized().paused());

        // Transfer ownership
        (bool success3,) = address(mechanism).call(abi.encodeWithSignature("transferOwnership(address)", newOwner));
        require(success3, "Transfer ownership failed");

        // New owner accepts ownership
        vm.prank(newOwner);
        (bool success3b,) = address(mechanism).call(abi.encodeWithSignature("acceptOwnership()"));
        require(success3b, "Accept ownership failed");
        assertEq(_tokenized().owner(), newOwner);

        // Old owner cannot perform owner functions
        vm.expectRevert(TokenizedAllocationMechanism.Unauthorized.selector);
        _tokenized().pause();

        // New owner can perform owner functions
        vm.startPrank(newOwner);
        (bool success5,) = address(mechanism).call(abi.encodeWithSignature("pause()"));
        require(success5, "New owner pause failed");
        assertTrue(_tokenized().paused());
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
        (bool success,) = address(mechanism).call(abi.encodeWithSignature("pause()"));
        require(success, "Pause failed");

        // All operations blocked
        vm.expectRevert(TokenizedAllocationMechanism.PausedError.selector);
        vm.prank(alice);
        _tokenized().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 8, charlie);

        // Resume operations
        (bool success2,) = address(mechanism).call(abi.encodeWithSignature("unpause()"));
        require(success2, "Unpause failed");

        // Operations work again - use bob since alice already voted
        _castVote(bob, pid, 8, charlie);

        // Ownership transfer during crisis
        address emergencyAdmin = newOwner;
        (bool success3,) =
            address(mechanism).call(abi.encodeWithSignature("transferOwnership(address)", emergencyAdmin));
        require(success3, "Transfer ownership failed");

        // New owner accepts ownership
        vm.prank(emergencyAdmin);
        (bool success3b,) = address(mechanism).call(abi.encodeWithSignature("acceptOwnership()"));
        require(success3b, "Accept ownership failed");

        // New owner manages crisis
        vm.startPrank(emergencyAdmin);
        (bool success4,) = address(mechanism).call(abi.encodeWithSignature("pause()"));
        require(success4, "Emergency admin pause failed");
        vm.stopPrank();

        // System recovery after crisis
        vm.startPrank(emergencyAdmin);
        (bool success5,) = address(mechanism).call(abi.encodeWithSignature("unpause()"));
        require(success5, "Recovery unpause failed");
        vm.stopPrank();

        // Complete voting cycle to verify system integrity
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        vm.startPrank(emergencyAdmin);
        (bool success6,) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success6, "Emergency finalization failed");

        (bool success7,) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pid));
        require(success7, "Emergency queuing failed");
        vm.stopPrank();

        // System functions normally - alice (20) + bob (8) votes in QuadraticFunding
        // Total weighted funding = quadratic + linear components, shares allocated proportionally
        uint256 actualShares = _tokenized().balanceOf(charlie);
        assertTrue(actualShares > 0, "Successful proposal should receive shares after crisis recovery");
        assertEq(uint256(_tokenized().state(pid)), uint256(TokenizedAllocationMechanism.ProposalState.Queued));
    }
}
