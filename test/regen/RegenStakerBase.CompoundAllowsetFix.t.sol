// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.23;

import { AccessMode } from "src/constants.sol";
import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { MockERC20Staking } from "test/mocks/MockERC20Staking.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { Staker } from "staker/Staker.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";

/// @title Tests for REG-008 Compound Rewards AddressSet Fix
/// @notice Validates that the allowset bypass vulnerability in compoundRewards is properly fixed
/// @dev Addresses REG-008 (OSU-919) - Missing depositor allowset check when claimer calls compoundRewards
contract RegenStakerBaseCompoundAllowsetFixTest is Test {
    RegenStaker public staker;
    MockERC20Staking public stakeToken;
    RegenEarningPowerCalculator public earningPowerCalculator;
    AddressSet public stakerAllowset;
    AddressSet public earningPowerAllowset;
    AddressSet public allocationAllowset;

    address public admin = makeAddr("admin");
    address public notifier = makeAddr("notifier");
    address public depositor = makeAddr("depositor");
    address public allowlistedClaimer = makeAddr("allowlistedClaimer");
    address public nonAllowsetedClaimer = makeAddr("nonAllowsetedClaimer");
    address public delegatee = makeAddr("delegatee");

    uint256 constant INITIAL_BALANCE = 10_000e18;
    uint256 constant STAKE_AMOUNT = 1000e18;
    uint256 constant REWARD_AMOUNT = 500e18;

    event StakeDeposited(
        address indexed depositor,
        Staker.DepositIdentifier indexed depositId,
        uint256 amount,
        uint256 earningPower
    );

    function setUp() public {
        // Deploy tokens
        stakeToken = new MockERC20Staking(18);

        // Deploy allowsets
        stakerAllowset = new AddressSet();
        earningPowerAllowset = new AddressSet();
        allocationAllowset = new AddressSet();

        // Deploy earning power calculator
        earningPowerCalculator = new RegenEarningPowerCalculator(
            admin,
            IAddressSet(address(earningPowerAllowset)),
            IAddressSet(address(0)),
            AccessMode.ALLOWSET
        );

        // Deploy staker with same token for staking and rewards (to enable compounding)
        staker = new RegenStaker(
            IERC20(address(stakeToken)), // rewards token (same as stake)
            stakeToken, // stake token
            earningPowerCalculator,
            0, // maxBumpTip
            admin,
            30 days, // rewardDuration
            0, // minimumStakeAmount
            IAddressSet(address(stakerAllowset)),
            IAddressSet(address(0)),
            AccessMode.ALLOWSET,
            allocationAllowset
        );

        // Setup notifier
        vm.prank(admin);
        staker.setRewardNotifier(notifier, true);

        // Fund users
        stakeToken.mint(depositor, INITIAL_BALANCE);
        stakeToken.mint(allowlistedClaimer, INITIAL_BALANCE);
        stakeToken.mint(nonAllowsetedClaimer, INITIAL_BALANCE);
        stakeToken.mint(notifier, INITIAL_BALANCE);
    }

    /// @notice Test inAllowset owner + inAllowset claimer (should work)
    function test_allowlistedOwnerAllowsetedClaimer() public {
        // AddressSet both depositor and claimer
        stakerAllowset.add(depositor);
        stakerAllowset.add(allowlistedClaimer);
        earningPowerAllowset.add(depositor);

        // Depositor stakes with inAllowset claimer
        vm.startPrank(depositor);
        stakeToken.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = staker.stake(STAKE_AMOUNT, delegatee, allowlistedClaimer);
        vm.stopPrank();

        // Add rewards
        _addRewards();

        // Advance time to earn rewards
        vm.warp(block.timestamp + 15 days);

        // Allowseted claimer can compound for inAllowset depositor
        vm.prank(allowlistedClaimer);
        uint256 compounded = staker.compoundRewards(depositId);

        assertGt(compounded, 0, "Should have compounded rewards");
    }

    /// @notice Test non-inAllowset owner + inAllowset claimer (should fail - the fix)
    function test_nonAllowsetedOwnerAllowsetedClaimer() public {
        // Initially allowset depositor to create deposit
        stakerAllowset.add(depositor);
        stakerAllowset.add(allowlistedClaimer);
        earningPowerAllowset.add(depositor);

        // Depositor stakes with inAllowset claimer
        vm.startPrank(depositor);
        stakeToken.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = staker.stake(STAKE_AMOUNT, delegatee, allowlistedClaimer);
        vm.stopPrank();

        // Add rewards
        _addRewards();
        vm.warp(block.timestamp + 15 days);

        // Remove depositor from allowset (e.g., compliance issue)
        stakerAllowset.remove(depositor);
        assertFalse(stakerAllowset.contains(depositor));
        assertTrue(stakerAllowset.contains(allowlistedClaimer));

        // Allowseted claimer CANNOT compound for non-inAllowset depositor (the fix)
        vm.prank(allowlistedClaimer);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.StakerNotAllowed.selector, depositor));
        staker.compoundRewards(depositId);
    }

    /// @notice Test inAllowset owner calling their own compound (should work)
    function test_allowlistedOwnerSelfCompound() public {
        // AddressSet depositor
        stakerAllowset.add(depositor);
        earningPowerAllowset.add(depositor);

        // Depositor stakes with themselves as claimer
        vm.startPrank(depositor);
        stakeToken.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = staker.stake(STAKE_AMOUNT, delegatee, depositor);
        vm.stopPrank();

        // Add rewards
        _addRewards();
        vm.warp(block.timestamp + 15 days);

        // Depositor can compound their own rewards
        vm.prank(depositor);
        uint256 compounded = staker.compoundRewards(depositId);

        assertGt(compounded, 0, "Should have compounded rewards");
    }

    /// @notice Test non-inAllowset owner calling their own compound (should fail)
    function test_nonAllowsetedOwnerSelfCompound() public {
        // Initially allowset to create deposit
        stakerAllowset.add(depositor);
        earningPowerAllowset.add(depositor);

        // Depositor stakes
        vm.startPrank(depositor);
        stakeToken.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = staker.stake(STAKE_AMOUNT, delegatee, depositor);
        vm.stopPrank();

        // Add rewards
        _addRewards();
        vm.warp(block.timestamp + 15 days);

        // Remove depositor from allowset
        stakerAllowset.remove(depositor);

        // Non-inAllowset depositor cannot compound their own rewards
        vm.prank(depositor);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.StakerNotAllowed.selector, depositor));
        staker.compoundRewards(depositId);
    }

    /// @notice Test inAllowset owner + non-inAllowset claimer (should work)
    function test_allowlistedOwnerNonAllowsetedClaimer() public {
        // AddressSet only depositor, not the claimer
        stakerAllowset.add(depositor);
        earningPowerAllowset.add(depositor);
        assertFalse(stakerAllowset.contains(nonAllowsetedClaimer));

        // Depositor stakes with non-inAllowset claimer
        vm.startPrank(depositor);
        stakeToken.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = staker.stake(STAKE_AMOUNT, delegatee, nonAllowsetedClaimer);
        vm.stopPrank();

        // Add rewards
        _addRewards();
        vm.warp(block.timestamp + 15 days);

        // Non-inAllowset claimer CAN compound for inAllowset depositor
        // The implementation only checks that the deposit owner is inAllowset
        vm.prank(nonAllowsetedClaimer);
        uint256 compounded = staker.compoundRewards(depositId);
        assertGt(compounded, 0, "Should have compounded rewards");
    }

    /// @notice Test that legitimate compound operations still work after fix
    function test_legitimateCompoundStillWorks() public {
        // Setup multiple inAllowset users
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        stakeToken.mint(alice, INITIAL_BALANCE);
        stakeToken.mint(bob, INITIAL_BALANCE);

        stakerAllowset.add(alice);
        stakerAllowset.add(bob);
        earningPowerAllowset.add(alice);
        earningPowerAllowset.add(bob);

        // Alice stakes with Bob as claimer
        vm.startPrank(alice);
        stakeToken.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier aliceDeposit = staker.stake(STAKE_AMOUNT, delegatee, bob);
        vm.stopPrank();

        // Bob stakes with Alice as claimer
        vm.startPrank(bob);
        stakeToken.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier bobDeposit = staker.stake(STAKE_AMOUNT, delegatee, alice);
        vm.stopPrank();

        // Add rewards
        _addRewards();
        vm.warp(block.timestamp + 15 days);

        // Bob can compound Alice's deposit
        vm.prank(bob);
        uint256 aliceCompounded = staker.compoundRewards(aliceDeposit);
        assertGt(aliceCompounded, 0, "Bob should compound Alice's rewards");

        // Alice can compound Bob's deposit
        vm.prank(alice);
        uint256 bobCompounded = staker.compoundRewards(bobDeposit);
        assertGt(bobCompounded, 0, "Alice should compound Bob's rewards");
    }

    /// @notice Test unauthorized claimer cannot compound
    function test_unauthorizedClaimerCannotCompound() public {
        address unauthorizedUser = makeAddr("unauthorized");

        // AddressSet depositor
        stakerAllowset.add(depositor);
        stakerAllowset.add(unauthorizedUser);
        earningPowerAllowset.add(depositor);

        // Depositor stakes with allowlistedClaimer (not unauthorizedUser)
        stakerAllowset.add(allowlistedClaimer);
        vm.startPrank(depositor);
        stakeToken.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = staker.stake(STAKE_AMOUNT, delegatee, allowlistedClaimer);
        vm.stopPrank();

        // Add rewards
        _addRewards();
        vm.warp(block.timestamp + 15 days);

        // Unauthorized user (not owner, not claimer) cannot compound
        vm.prank(unauthorizedUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                Staker.Staker__Unauthorized.selector,
                bytes32("not claimer or owner"),
                unauthorizedUser
            )
        );
        staker.compoundRewards(depositId);
    }

    /// @notice Test scenario where depositor is removed then re-added to allowset
    function test_depositorRemovedThenReaddedToAddressSet() public {
        // AddressSet both
        stakerAllowset.add(depositor);
        stakerAllowset.add(allowlistedClaimer);
        earningPowerAllowset.add(depositor);

        // Create deposit
        vm.startPrank(depositor);
        stakeToken.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = staker.stake(STAKE_AMOUNT, delegatee, allowlistedClaimer);
        vm.stopPrank();

        // Add rewards
        _addRewards();
        vm.warp(block.timestamp + 10 days);

        // Remove depositor from allowset
        stakerAllowset.remove(depositor);

        // Claimer cannot compound while depositor is not inAllowset
        vm.prank(allowlistedClaimer);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.StakerNotAllowed.selector, depositor));
        staker.compoundRewards(depositId);

        // Re-add depositor to allowset
        stakerAllowset.add(depositor);

        // Now claimer can compound again
        vm.prank(allowlistedClaimer);
        uint256 compounded = staker.compoundRewards(depositId);
        assertGt(compounded, 0, "Should compound after re-adding to allowset");
    }

    /// @notice Fuzz test various scenarios
    function testFuzz_compoundAllowsetChecks(bool ownerAllowseted, bool claimerAllowseted, bool callerIsOwner) public {
        // Setup based on fuzz inputs
        if (ownerAllowseted) {
            stakerAllowset.add(depositor);
            earningPowerAllowset.add(depositor);
        }
        if (claimerAllowseted) {
            stakerAllowset.add(allowlistedClaimer);
        }

        // Skip if neither is inAllowset (can't create deposit)
        if (!ownerAllowseted) return;

        // Create deposit
        vm.startPrank(depositor);
        stakeToken.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = staker.stake(
            STAKE_AMOUNT,
            delegatee,
            callerIsOwner ? depositor : allowlistedClaimer
        );
        vm.stopPrank();

        // Add rewards
        _addRewards();
        vm.warp(block.timestamp + 15 days);

        // Remove owner from allowset for testing
        if (!ownerAllowseted) {
            stakerAllowset.remove(depositor);
        }

        // Determine who is calling and expected result
        address caller = callerIsOwner ? depositor : allowlistedClaimer;

        // The implementation only checks that the deposit owner is inAllowset
        // It doesn't matter if the claimer is inAllowset or not
        bool shouldSucceed = ownerAllowseted;

        // Execute compound
        if (shouldSucceed) {
            vm.prank(caller);
            uint256 compounded = staker.compoundRewards(depositId);
            assertGt(compounded, 0, "Should compound successfully");
        } else {
            vm.prank(caller);
            vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.StakerNotAllowed.selector, depositor));
            staker.compoundRewards(depositId);
        }
    }

    // ============ Helper Functions ============

    function _addRewards() internal {
        vm.startPrank(notifier);
        stakeToken.transfer(address(staker), REWARD_AMOUNT);
        staker.notifyRewardAmount(REWARD_AMOUNT);
        vm.stopPrank();
    }
}
