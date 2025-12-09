// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { AccessMode } from "src/constants.sol";
import "forge-std/Test.sol";
import { OctantQFMechanism } from "src/mechanisms/mechanism/OctantQFMechanism.sol";
import { TokenizedAllocationMechanism } from "src/mechanisms/TokenizedAllocationMechanism.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { AllocationConfig } from "src/mechanisms/BaseAllocationMechanism.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { NotInAllowset } from "src/errors.sol";

contract OctantQFMechanismTest is Test {
    OctantQFMechanism public mechanism;
    TokenizedAllocationMechanism public implementation;
    AddressSet public allowset;
    ERC20Mock public token;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public keeper = makeAddr("keeper");
    address public management = makeAddr("management");

    // Helper to access TokenizedAllocationMechanism functions
    function tam() internal view returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(address(mechanism));
    }

    uint256 constant INITIAL_SUPPLY = 1_000_000e18;
    uint256 constant SIGNUP_AMOUNT = 10_000e18; // Increased to allow bigger votes
    uint256 constant VOTING_DELAY = 1;
    uint256 constant VOTING_PERIOD = 100;
    uint256 constant QUORUM_SHARES = 10_000e18; // 10k shares quorum (realistic value)
    uint256 constant TIMELOCK_DELAY = 50;
    uint256 constant GRACE_PERIOD = 100;

    event AllowsetUpdated(address indexed oldAllowset, address indexed newAllowset);

    function setUp() public {
        vm.startPrank(owner);

        // Deploy token
        token = new ERC20Mock();
        token.mint(owner, INITIAL_SUPPLY);

        // Deploy allowset
        allowset = new AddressSet();

        // Deploy TokenizedAllocationMechanism implementation
        implementation = new TokenizedAllocationMechanism();

        // Create config
        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Octant QF Shares",
            symbol: "OQF",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: QUORUM_SHARES,
            timelockDelay: TIMELOCK_DELAY,
            gracePeriod: GRACE_PERIOD,
            owner: owner
        });

        // Deploy OctantQFMechanism with NONE mode initially
        mechanism = new OctantQFMechanism(
            address(implementation),
            config,
            10000, // alphaNumerator (1.0)
            10000, // alphaDenominator
            IAddressSet(address(allowset)), // contributionAllowset
            IAddressSet(address(0)), // contributionBlockset
            AccessMode.NONE
        );

        // Setup roles
        tam().setKeeper(keeper);
        tam().setManagement(management);

        // Fund mechanism with matching pool
        token.transfer(address(mechanism), 100_000e18);

        // Fund test users
        token.transfer(alice, SIGNUP_AMOUNT * 2);
        token.transfer(bob, SIGNUP_AMOUNT * 2);
        token.transfer(charlie, SIGNUP_AMOUNT * 2);

        vm.stopPrank();
    }

    // ===== AddressSet Integration Tests =====

    function test_AllowsetUserCanSignup() public {
        // Configure allowset mode
        vm.startPrank(owner);
        mechanism.setContributionAllowset(IAddressSet(address(allowset)));
        mechanism.setAccessMode(AccessMode.ALLOWSET);

        // Add alice to allowset
        allowset.add(alice);
        vm.stopPrank();

        // Alice approves and signs up
        vm.startPrank(alice);
        token.approve(address(mechanism), SIGNUP_AMOUNT);
        tam().signup(SIGNUP_AMOUNT);
        vm.stopPrank();

        // Verify signup successful
        assertEq(tam().votingPower(alice), SIGNUP_AMOUNT);
    }

    function test_NonAllowsetUserCannotSignup() public {
        // Configure allowset mode with only alice allowed
        vm.startPrank(owner);
        mechanism.setContributionAllowset(IAddressSet(address(allowset)));
        mechanism.setAccessMode(AccessMode.ALLOWSET);
        allowset.add(alice); // Only alice in allowset, not bob
        vm.stopPrank();

        // Bob is not in allowset
        vm.startPrank(bob);
        token.approve(address(mechanism), SIGNUP_AMOUNT);

        // Signup should fail
        vm.expectRevert(abi.encodeWithSelector(NotInAllowset.selector, bob));
        tam().signup(SIGNUP_AMOUNT);
        vm.stopPrank();

        // Verify no voting power
        assertEq(tam().votingPower(bob), 0);
    }

    function test_UsersCanSignupWhenAccessModeNone() public {
        // Ensure mode is NONE (default from constructor)
        // vm.prank(owner);

        // Anyone can signup now
        vm.startPrank(charlie);
        token.approve(address(mechanism), SIGNUP_AMOUNT);
        tam().signup(SIGNUP_AMOUNT);
        vm.stopPrank();

        assertEq(tam().votingPower(charlie), SIGNUP_AMOUNT);
    }

    function test_SignupFailsWithInvalidAllowset() public {
        // Set allowset to an EOA (not a contract) and enable ALLOWSET mode
        vm.startPrank(owner);
        mechanism.setContributionAllowset(IAddressSet(makeAddr("notAContract")));
        mechanism.setAccessMode(AccessMode.ALLOWSET);
        vm.stopPrank();

        // Signup should fail gracefully
        vm.startPrank(alice);
        token.approve(address(mechanism), SIGNUP_AMOUNT);
        vm.expectRevert();
        tam().signup(SIGNUP_AMOUNT);
        vm.stopPrank();
    }

    // ===== Access Control Tests =====

    // ===== State Transition Tests =====

    function test_AddingToAllowsetAllowsSignup() public {
        // Configure ALLOWSET mode
        vm.startPrank(owner);
        mechanism.setContributionAllowset(IAddressSet(address(allowset)));
        mechanism.setAccessMode(AccessMode.ALLOWSET);
        vm.stopPrank();

        // Initially bob cannot signup
        assertFalse(mechanism.canSignup(bob));

        // Add bob to allowset
        vm.prank(owner);
        allowset.add(bob);

        // Now bob can signup
        assertTrue(mechanism.canSignup(bob));

        vm.startPrank(bob);
        token.approve(address(mechanism), SIGNUP_AMOUNT);
        tam().signup(SIGNUP_AMOUNT);
        vm.stopPrank();

        assertEq(tam().votingPower(bob), SIGNUP_AMOUNT);
    }

    function test_RemovingFromAllowsetPreventsSignup() public {
        // Configure ALLOWSET mode
        vm.startPrank(owner);
        mechanism.setContributionAllowset(IAddressSet(address(allowset)));
        mechanism.setAccessMode(AccessMode.ALLOWSET);

        // Add and then remove alice
        allowset.add(alice);
        assertTrue(mechanism.canSignup(alice));

        allowset.remove(alice);
        assertFalse(mechanism.canSignup(alice));
        vm.stopPrank();

        // Alice cannot signup
        vm.startPrank(alice);
        token.approve(address(mechanism), SIGNUP_AMOUNT);
        vm.expectRevert();
        tam().signup(SIGNUP_AMOUNT);
        vm.stopPrank();
    }

    function test_ChangingAllowsetAffectsAccess() public {
        // Setup two allowsets
        vm.startPrank(owner);
        AddressSet allowset2 = new AddressSet();

        // Add alice to first allowset, bob to second
        allowset.add(alice);
        allowset2.add(bob);

        mechanism.setContributionAllowset(IAddressSet(address(allowset)));
        mechanism.setAccessMode(AccessMode.ALLOWSET);
        vm.stopPrank();

        // Alice can signup with first allowset
        assertTrue(mechanism.canSignup(alice));
        assertFalse(mechanism.canSignup(bob));

        // Switch to second allowset
        vm.prank(owner);
        mechanism.setContributionAllowset(IAddressSet(address(allowset2)));

        // Now bob can signup but not alice
        assertFalse(mechanism.canSignup(alice));
        assertTrue(mechanism.canSignup(bob));
    }

    // ===== Integration Tests =====

    function test_FullVoterJourneyForAllowsetUser() public {
        // Add alice, bob, and charlie to allowset
        vm.startPrank(owner);
        address[] memory voters = new address[](3);
        voters[0] = alice;
        voters[1] = bob;
        voters[2] = charlie;
        allowset.add(voters);
        vm.stopPrank();

        // All three users signup
        address[3] memory users = [alice, bob, charlie];
        for (uint i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            token.approve(address(mechanism), SIGNUP_AMOUNT);
            tam().signup(SIGNUP_AMOUNT);
            vm.stopPrank();
        }

        // Keeper creates proposal
        vm.prank(keeper);
        uint256 pid = tam().propose(alice, "Test proposal");

        // Wait for voting delay
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        // All users vote with substantial weight
        // Each has 10,000e18 voting power, so they can vote with weight 60e9
        // Cost per vote = (60e9)^2 = 3,600e18
        // Total quadratic funding = (60e9 * 3)^2 = (180e9)^2 = 32,400e18
        // This exceeds quorum of 10,000e18
        for (uint i = 0; i < users.length; i++) {
            vm.prank(users[i]);
            tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 60e9, alice);
        }

        // Wait for voting period
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        // Finalize and queue
        vm.prank(owner);
        tam().finalizeVoteTally();
        tam().queueProposal(pid);

        // Verify proposal queued successfully
        assertEq(uint8(tam().state(pid)), uint8(TokenizedAllocationMechanism.ProposalState.Queued));
    }

    function test_ProposalCreationStillRestrictedToKeeperManagement() public {
        // Add alice to allowset
        vm.prank(owner);
        allowset.add(alice);

        // Alice signs up
        vm.startPrank(alice);
        token.approve(address(mechanism), SIGNUP_AMOUNT);
        tam().signup(SIGNUP_AMOUNT);

        // Alice cannot propose (not keeper/management)
        vm.expectRevert();
        tam().propose(alice, "Test proposal");
        vm.stopPrank();

        // Keeper can propose
        vm.prank(keeper);
        uint256 pid = tam().propose(alice, "Test proposal");
        assertGt(pid, 0);

        // Verify alice still has voting power after failed propose attempt
        assertEq(tam().votingPower(alice), SIGNUP_AMOUNT);
    }

    // ===== Edge Cases =====

    function test_AllowsetWithNoUsersBlocksAllSignups() public {
        // Configure ALLOWSET mode
        vm.startPrank(owner);
        mechanism.setContributionAllowset(IAddressSet(address(allowset)));
        mechanism.setAccessMode(AccessMode.ALLOWSET);
        vm.stopPrank();

        // AddressSet has no users
        assertFalse(allowset.contains(alice));
        assertFalse(allowset.contains(bob));
        assertFalse(allowset.contains(charlie));

        // No one can signup
        address[] memory users = new address[](3);
        users[0] = alice;
        users[1] = bob;
        users[2] = charlie;

        for (uint i = 0; i < users.length; i++) {
            assertFalse(mechanism.canSignup(users[i]));

            vm.startPrank(users[i]);
            token.approve(address(mechanism), SIGNUP_AMOUNT);
            vm.expectRevert();
            tam().signup(SIGNUP_AMOUNT);
            vm.stopPrank();
        }
    }

    function test_BatchAllowsetOperations() public {
        // Configure ALLOWSET mode
        vm.startPrank(owner);
        mechanism.setContributionAllowset(IAddressSet(address(allowset)));
        mechanism.setAccessMode(AccessMode.ALLOWSET);

        // Add multiple users at once
        address[] memory usersToAdd = new address[](3);
        usersToAdd[0] = alice;
        usersToAdd[1] = bob;
        usersToAdd[2] = charlie;

        for (uint i = 0; i < usersToAdd.length; i++) {
            allowset.add(usersToAdd[i]);
        }

        // All can signup
        for (uint i = 0; i < usersToAdd.length; i++) {
            assertTrue(mechanism.canSignup(usersToAdd[i]));
        }

        // Remove multiple users
        address[] memory usersToRemove = new address[](2);
        usersToRemove[0] = alice;
        usersToRemove[1] = bob;

        for (uint i = 0; i < usersToRemove.length; i++) {
            allowset.remove(usersToRemove[i]);
        }

        // Removed users cannot signup
        assertFalse(mechanism.canSignup(alice));
        assertFalse(mechanism.canSignup(bob));
        // Charlie still can
        assertTrue(mechanism.canSignup(charlie));

        vm.stopPrank();
    }
}
