// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { AccessMode } from "src/constants.sol";
import "forge-std/Test.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockERC20Staking } from "test/mocks/MockERC20Staking.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { Staker } from "staker/Staker.sol";

/**
 * @title RegenStakerRewardManagerTest
 * @dev Tests reward manager access control implementation (simplified from AccessControl)
 *
 * COVERAGE:
 * - Admin can perform all admin operations
 * - Admin can set reward manager
 * - Reward manager can only manage reward notifiers
 * - Both admin and reward manager can manage notifiers
 * - Unauthorized users cannot perform privileged operations
 * - Separation of governance (admin) from operations (reward manager)
 */
contract RegenStakerRewardManagerTest is Test {
    RegenStaker public regenStaker;
    RegenEarningPowerCalculator public earningPowerCalculator;
    MockERC20 public rewardToken;
    MockERC20Staking public stakeToken;
    AddressSet public stakerAllowset;
    AddressSet public stakerBlockset;
    AddressSet public allocationAllowset;

    address public admin = makeAddr("admin");
    address public rewardManager = makeAddr("rewardManager");
    address public rewardNotifier = makeAddr("rewardNotifier");
    address public unauthorized = makeAddr("unauthorized");
    address public user = makeAddr("user");

    event RewardManagerSet(address indexed newRewardManager);

    function setUp() public {
        // Deploy tokens
        rewardToken = new MockERC20(18);
        stakeToken = new MockERC20Staking(18);

        // Deploy allowsets
        vm.startPrank(admin);
        stakerAllowset = new AddressSet();
        stakerBlockset = new AddressSet();
        allocationAllowset = new AddressSet();
        earningPowerCalculator = new RegenEarningPowerCalculator(
            admin,
            stakerAllowset,
            IAddressSet(address(0)),
            AccessMode.NONE
        );

        // Deploy RegenStaker
        regenStaker = new RegenStaker(
            rewardToken,
            stakeToken,
            earningPowerCalculator,
            1000, // maxBumpTip
            admin,
            uint128(30 days), // rewardDuration
            100, // minimumStakeAmount
            stakerAllowset,
            stakerBlockset,
            AccessMode.NONE,
            allocationAllowset
        );

        vm.stopPrank();
    }

    // === Reward Manager Management Tests ===

    function test_constructor_rewardManagerIsZero() public view {
        assertEq(regenStaker.rewardManager(), address(0), "Reward manager should be zero initially");
    }

    function test_setRewardManager_adminCanSet() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit RewardManagerSet(rewardManager);
        regenStaker.setRewardManager(rewardManager);

        assertEq(regenStaker.rewardManager(), rewardManager, "Reward manager should be set");
    }

    function test_setRewardManager_unauthorizedCannotSet() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        regenStaker.setRewardManager(rewardManager);
    }

    function test_setRewardManager_rewardManagerCannotSetSelf() public {
        // First, admin sets reward manager
        vm.prank(admin);
        regenStaker.setRewardManager(rewardManager);

        // Reward manager tries to change to someone else
        vm.prank(rewardManager);
        vm.expectRevert();
        regenStaker.setRewardManager(makeAddr("newManager"));
    }

    // === Reward Notifier Management Tests ===

    function test_setRewardNotifier_adminCanSet() public {
        vm.prank(admin);
        regenStaker.setRewardNotifier(rewardNotifier, true);

        assertTrue(regenStaker.isRewardNotifier(rewardNotifier), "Notifier should be enabled");
    }

    function test_setRewardNotifier_rewardManagerCanSet() public {
        // Admin sets reward manager
        vm.prank(admin);
        regenStaker.setRewardManager(rewardManager);

        // Reward manager sets notifier
        vm.prank(rewardManager);
        regenStaker.setRewardNotifier(rewardNotifier, true);

        assertTrue(regenStaker.isRewardNotifier(rewardNotifier), "Notifier should be enabled");
    }

    function test_setRewardNotifier_unauthorizedCannotSet() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        regenStaker.setRewardNotifier(rewardNotifier, true);
    }

    function test_setRewardNotifier_rewardManagerCanDisable() public {
        // Admin sets notifier
        vm.prank(admin);
        regenStaker.setRewardNotifier(rewardNotifier, true);

        // Admin sets reward manager
        vm.prank(admin);
        regenStaker.setRewardManager(rewardManager);

        // Reward manager disables notifier
        vm.prank(rewardManager);
        regenStaker.setRewardNotifier(rewardNotifier, false);

        assertFalse(regenStaker.isRewardNotifier(rewardNotifier), "Notifier should be disabled");
    }

    // === Reward Manager Cannot Do Admin Operations ===

    function test_rewardManager_cannotPause() public {
        vm.prank(admin);
        regenStaker.setRewardManager(rewardManager);

        vm.prank(rewardManager);
        vm.expectRevert();
        regenStaker.pause();
    }

    function test_rewardManager_cannotSetRewardDuration() public {
        vm.prank(admin);
        regenStaker.setRewardManager(rewardManager);

        // Skip past any active reward period
        vm.warp(block.timestamp + 31 days);

        vm.prank(rewardManager);
        vm.expectRevert();
        regenStaker.setRewardDuration(uint128(60 days));
    }

    function test_rewardManager_cannotSetMinimumStakeAmount() public {
        vm.prank(admin);
        regenStaker.setRewardManager(rewardManager);

        vm.prank(rewardManager);
        vm.expectRevert();
        regenStaker.setMinimumStakeAmount(200);
    }

    function test_rewardManager_cannotSetMaxBumpTip() public {
        vm.prank(admin);
        regenStaker.setRewardManager(rewardManager);

        // Skip past any active reward period
        vm.warp(block.timestamp + 31 days);

        vm.prank(rewardManager);
        vm.expectRevert();
        regenStaker.setMaxBumpTip(2000);
    }

    function test_rewardManager_cannotSetAdmin() public {
        vm.prank(admin);
        regenStaker.setRewardManager(rewardManager);

        vm.prank(rewardManager);
        vm.expectRevert();
        regenStaker.setAdmin(makeAddr("newAdmin"));
    }

    // === Admin Can Still Do Everything ===

    function test_admin_canPause() public {
        vm.prank(admin);
        regenStaker.pause();
        assertTrue(regenStaker.paused(), "Contract should be paused");
    }

    function test_admin_canUnpause() public {
        vm.prank(admin);
        regenStaker.pause();

        vm.prank(admin);
        regenStaker.unpause();
        assertFalse(regenStaker.paused(), "Contract should be unpaused");
    }

    function test_admin_canSetRewardDuration() public {
        // Skip past any active reward period
        vm.warp(block.timestamp + 31 days);

        vm.prank(admin);
        regenStaker.setRewardDuration(uint128(60 days));
        assertEq(regenStaker.rewardDuration(), 60 days, "Reward duration should be updated");
    }

    function test_admin_canSetMinimumStakeAmount() public {
        vm.prank(admin);
        regenStaker.setMinimumStakeAmount(200);
        assertEq(regenStaker.minimumStakeAmount(), 200, "Minimum stake amount should be updated");
    }

    function test_admin_canSetMaxBumpTip() public {
        // Skip past any active reward period
        vm.warp(block.timestamp + 31 days);

        vm.prank(admin);
        regenStaker.setMaxBumpTip(2000);
        assertEq(regenStaker.maxBumpTip(), 2000, "Max bump tip should be updated");
    }

    // === Multiple Reward Managers Scenario ===

    function test_adminCanChangeRewardManager() public {
        address firstManager = makeAddr("firstManager");
        address secondManager = makeAddr("secondManager");

        // Set first manager
        vm.prank(admin);
        regenStaker.setRewardManager(firstManager);
        assertEq(regenStaker.rewardManager(), firstManager);

        // Change to second manager
        vm.prank(admin);
        regenStaker.setRewardManager(secondManager);
        assertEq(regenStaker.rewardManager(), secondManager);

        // First manager can no longer manage notifiers
        vm.prank(firstManager);
        vm.expectRevert();
        regenStaker.setRewardNotifier(rewardNotifier, true);

        // Second manager can manage notifiers
        vm.prank(secondManager);
        regenStaker.setRewardNotifier(rewardNotifier, true);
        assertTrue(regenStaker.isRewardNotifier(rewardNotifier));
    }

    function test_adminCanRemoveRewardManager() public {
        // Set reward manager
        vm.prank(admin);
        regenStaker.setRewardManager(rewardManager);

        // Manager can set notifier
        vm.prank(rewardManager);
        regenStaker.setRewardNotifier(rewardNotifier, true);
        assertTrue(regenStaker.isRewardNotifier(rewardNotifier));

        // Admin removes reward manager
        vm.prank(admin);
        regenStaker.setRewardManager(address(0));
        assertEq(regenStaker.rewardManager(), address(0));

        // Old manager can no longer set notifier
        vm.prank(rewardManager);
        vm.expectRevert();
        regenStaker.setRewardNotifier(makeAddr("newNotifier"), true);
    }

    // === Governance Protection Still Works ===

    function test_governanceProtection_stillWorksWithRewardManager() public {
        // Setup: Add reward manager
        vm.prank(admin);
        regenStaker.setRewardManager(rewardManager);

        // Fund the contract and notify rewards
        rewardToken.mint(address(regenStaker), 10000e18);
        vm.prank(admin);
        regenStaker.setRewardNotifier(admin, true);

        vm.prank(admin);
        regenStaker.notifyRewardAmount(1000e18);

        // Try to change earning power calculator during active reward (should fail for admin)
        address newCalculator = makeAddr("newCalculator");
        vm.prank(admin);
        vm.expectRevert(RegenStakerBase.CannotChangeEarningPowerCalculatorDuringActiveReward.selector);
        regenStaker.setEarningPowerCalculator(newCalculator);

        // Skip past reward period
        vm.warp(block.timestamp + 31 days);

        // Now admin can change calculator
        vm.prank(admin);
        regenStaker.setEarningPowerCalculator(newCalculator);
        assertEq(address(regenStaker.earningPowerCalculator()), newCalculator);
    }
}
