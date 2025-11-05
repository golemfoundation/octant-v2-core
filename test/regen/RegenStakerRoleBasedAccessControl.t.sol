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
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title RegenStakerRoleBasedAccessControlTest
 * @dev Tests role-based access control implementation (OSU-1348)
 *
 * COVERAGE:
 * - DEFAULT_ADMIN_ROLE can perform all admin operations
 * - REWARD_MANAGER_ROLE can only manage reward notifiers
 * - DEFAULT_ADMIN_ROLE can grant/revoke roles
 * - setAdmin() is disabled in favor of AccessControl
 * - Role initialization in constructor
 * - Separation of governance (DEFAULT_ADMIN) from operations (REWARD_MANAGER)
 */
contract RegenStakerRoleBasedAccessControlTest is Test {
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

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public REWARD_MANAGER_ROLE;

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

        // Cache role identifiers
        REWARD_MANAGER_ROLE = regenStaker.REWARD_MANAGER_ROLE();

        vm.stopPrank();
    }

    // === Role Initialization Tests ===

    function test_constructor_grantsDefaultAdminRole() public view {
        assertTrue(regenStaker.hasRole(DEFAULT_ADMIN_ROLE, admin), "Admin should have DEFAULT_ADMIN_ROLE");
    }

    function test_constructor_doesNotGrantRewardManagerRole() public view {
        assertFalse(
            regenStaker.hasRole(REWARD_MANAGER_ROLE, admin),
            "Admin should not have REWARD_MANAGER_ROLE by default"
        );
    }

    function test_roleAdmin_configuration() public view {
        // Verify DEFAULT_ADMIN_ROLE manages REWARD_MANAGER_ROLE
        assertEq(
            regenStaker.getRoleAdmin(REWARD_MANAGER_ROLE),
            DEFAULT_ADMIN_ROLE,
            "DEFAULT_ADMIN_ROLE should manage REWARD_MANAGER_ROLE"
        );
    }

    // === DEFAULT_ADMIN_ROLE Permission Tests ===

    function test_defaultAdminRole_canSetRewardNotifier() public {
        vm.prank(admin);
        regenStaker.setRewardNotifier(rewardNotifier, true);
        assertTrue(regenStaker.isRewardNotifier(rewardNotifier), "Admin should be able to set reward notifier");
    }

    function test_defaultAdminRole_canSetRewardDuration() public {
        vm.prank(admin);
        regenStaker.setRewardDuration(uint128(60 days));
        assertEq(regenStaker.rewardDuration(), 60 days, "Admin should be able to set reward duration");
    }

    function test_defaultAdminRole_canSetMinimumStakeAmount() public {
        vm.prank(admin);
        regenStaker.setMinimumStakeAmount(200);
        assertEq(regenStaker.minimumStakeAmount(), 200, "Admin should be able to set minimum stake amount");
    }

    function test_defaultAdminRole_canSetMaxBumpTip() public {
        vm.prank(admin);
        regenStaker.setMaxBumpTip(2000);
        assertEq(regenStaker.maxBumpTip(), 2000, "Admin should be able to set max bump tip");
    }

    function test_defaultAdminRole_canSetStakerAllowset() public {
        AddressSet newAllowset = new AddressSet();
        vm.prank(admin);
        regenStaker.setStakerAllowset(newAllowset);
        assertEq(
            address(regenStaker.stakerAllowset()),
            address(newAllowset),
            "Admin should be able to set staker allowset"
        );
    }

    function test_defaultAdminRole_canSetStakerBlockset() public {
        AddressSet newBlockset = new AddressSet();
        vm.prank(admin);
        regenStaker.setStakerBlockset(newBlockset);
        assertEq(
            address(regenStaker.stakerBlockset()),
            address(newBlockset),
            "Admin should be able to set staker blockset"
        );
    }

    function test_defaultAdminRole_canSetAccessMode() public {
        vm.prank(admin);
        regenStaker.setAccessMode(AccessMode.ALLOWSET);
        assertEq(
            uint8(regenStaker.stakerAccessMode()),
            uint8(AccessMode.ALLOWSET),
            "Admin should be able to set access mode"
        );
    }

    function test_defaultAdminRole_canSetAllocationMechanismAllowset() public {
        AddressSet newAllowset = new AddressSet();
        vm.prank(admin);
        regenStaker.setAllocationMechanismAllowset(newAllowset);
        assertEq(
            address(regenStaker.allocationMechanismAllowset()),
            address(newAllowset),
            "Admin should be able to set allocation mechanism allowset"
        );
    }

    function test_defaultAdminRole_canPause() public {
        vm.prank(admin);
        regenStaker.pause();
        assertTrue(regenStaker.paused(), "Admin should be able to pause");
    }

    function test_defaultAdminRole_canUnpause() public {
        vm.startPrank(admin);
        regenStaker.pause();
        regenStaker.unpause();
        vm.stopPrank();
        assertFalse(regenStaker.paused(), "Admin should be able to unpause");
    }

    // === REWARD_MANAGER_ROLE Permission Tests ===

    function test_rewardManagerRole_canSetRewardNotifier() public {
        // Grant REWARD_MANAGER_ROLE
        vm.prank(admin);
        regenStaker.grantRole(REWARD_MANAGER_ROLE, rewardManager);

        // Reward manager should be able to set notifier
        vm.prank(rewardManager);
        regenStaker.setRewardNotifier(rewardNotifier, true);
        assertTrue(
            regenStaker.isRewardNotifier(rewardNotifier),
            "Reward manager should be able to set reward notifier"
        );
    }

    function test_rewardManagerRole_cannotSetRewardDuration() public {
        // Grant REWARD_MANAGER_ROLE
        vm.prank(admin);
        regenStaker.grantRole(REWARD_MANAGER_ROLE, rewardManager);

        // Reward manager should NOT be able to set reward duration
        vm.prank(rewardManager);
        vm.expectRevert(
            abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not admin"), rewardManager)
        );
        regenStaker.setRewardDuration(uint128(60 days));
    }

    function test_rewardManagerRole_cannotSetMinimumStakeAmount() public {
        vm.prank(admin);
        regenStaker.grantRole(REWARD_MANAGER_ROLE, rewardManager);

        vm.prank(rewardManager);
        vm.expectRevert(
            abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not admin"), rewardManager)
        );
        regenStaker.setMinimumStakeAmount(200);
    }

    function test_rewardManagerRole_cannotSetMaxBumpTip() public {
        vm.prank(admin);
        regenStaker.grantRole(REWARD_MANAGER_ROLE, rewardManager);

        vm.prank(rewardManager);
        vm.expectRevert(
            abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not admin"), rewardManager)
        );
        regenStaker.setMaxBumpTip(2000);
    }

    function test_rewardManagerRole_cannotSetStakerAllowset() public {
        vm.prank(admin);
        regenStaker.grantRole(REWARD_MANAGER_ROLE, rewardManager);

        AddressSet newAllowset = new AddressSet();
        vm.prank(rewardManager);
        vm.expectRevert(
            abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not admin"), rewardManager)
        );
        regenStaker.setStakerAllowset(newAllowset);
    }

    function test_rewardManagerRole_cannotSetAccessMode() public {
        vm.prank(admin);
        regenStaker.grantRole(REWARD_MANAGER_ROLE, rewardManager);

        vm.prank(rewardManager);
        vm.expectRevert(
            abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not admin"), rewardManager)
        );
        regenStaker.setAccessMode(AccessMode.ALLOWSET);
    }

    function test_rewardManagerRole_cannotPause() public {
        vm.prank(admin);
        regenStaker.grantRole(REWARD_MANAGER_ROLE, rewardManager);

        vm.prank(rewardManager);
        vm.expectRevert(
            abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not admin"), rewardManager)
        );
        regenStaker.pause();
    }

    // === Unauthorized Access Tests ===

    function test_unauthorized_cannotSetRewardNotifier() public {
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(
                Staker.Staker__Unauthorized.selector,
                bytes32("not admin or reward manager"),
                unauthorized
            )
        );
        regenStaker.setRewardNotifier(rewardNotifier, true);
    }

    function test_unauthorized_cannotSetRewardDuration() public {
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not admin"), unauthorized)
        );
        regenStaker.setRewardDuration(uint128(60 days));
    }

    function test_unauthorized_cannotPause() public {
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not admin"), unauthorized)
        );
        regenStaker.pause();
    }

    // === setAdmin() Transfer Tests ===

    function test_setAdmin_transfersRoleSuccessfully() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        regenStaker.setAdmin(newAdmin);

        assertTrue(regenStaker.hasRole(DEFAULT_ADMIN_ROLE, newAdmin), "New admin should have DEFAULT_ADMIN_ROLE");
        assertFalse(regenStaker.hasRole(DEFAULT_ADMIN_ROLE, admin), "Old admin should not have DEFAULT_ADMIN_ROLE");
    }

    function test_setAdmin_oldAdminLosesPermissions() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        regenStaker.setAdmin(newAdmin);

        // Old admin should not be able to perform admin actions
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not admin"), admin));
        regenStaker.pause();
    }

    function test_setAdmin_newAdminGainsPermissions() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        regenStaker.setAdmin(newAdmin);

        // New admin should be able to perform admin actions
        vm.prank(newAdmin);
        regenStaker.pause();

        assertTrue(regenStaker.paused(), "New admin should be able to pause");
    }

    function test_setAdmin_nonAdminCannotCall() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not admin"), unauthorized)
        );
        regenStaker.setAdmin(newAdmin);
    }

    function test_setAdmin_cannotTransferToZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                Staker.Staker__Unauthorized.selector,
                bytes32("admin cannot be zero address"),
                address(0)
            )
        );
        regenStaker.setAdmin(address(0));
    }

    function test_setAdmin_otherAdminsUnaffected() public {
        address newAdmin = makeAddr("newAdmin");
        address anotherAdmin = makeAddr("anotherAdmin");

        // Grant DEFAULT_ADMIN_ROLE to another admin first
        vm.prank(admin);
        regenStaker.grantRole(DEFAULT_ADMIN_ROLE, anotherAdmin);

        // Transfer from original admin to newAdmin
        vm.prank(admin);
        regenStaker.setAdmin(newAdmin);

        // Original admin should have lost role
        assertFalse(regenStaker.hasRole(DEFAULT_ADMIN_ROLE, admin), "Original admin should not have role");

        // New admin should have role
        assertTrue(regenStaker.hasRole(DEFAULT_ADMIN_ROLE, newAdmin), "New admin should have role");

        // Another admin should still have role
        assertTrue(regenStaker.hasRole(DEFAULT_ADMIN_ROLE, anotherAdmin), "Another admin should still have role");

        // Another admin should still be able to perform admin actions
        vm.prank(anotherAdmin);
        regenStaker.pause();
        assertTrue(regenStaker.paused(), "Another admin should still be able to pause");
    }

    // === Role Management Tests ===

    function test_defaultAdmin_canGrantDefaultAdminRole() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(admin);
        regenStaker.grantRole(DEFAULT_ADMIN_ROLE, newAdmin);

        assertTrue(regenStaker.hasRole(DEFAULT_ADMIN_ROLE, newAdmin), "New admin should have DEFAULT_ADMIN_ROLE");
    }

    function test_defaultAdmin_canRevokeDefaultAdminRole() public {
        address tempAdmin = makeAddr("tempAdmin");

        vm.startPrank(admin);
        regenStaker.grantRole(DEFAULT_ADMIN_ROLE, tempAdmin);
        regenStaker.revokeRole(DEFAULT_ADMIN_ROLE, tempAdmin);
        vm.stopPrank();

        assertFalse(
            regenStaker.hasRole(DEFAULT_ADMIN_ROLE, tempAdmin),
            "Temp admin should not have DEFAULT_ADMIN_ROLE after revocation"
        );
    }

    function test_defaultAdmin_canGrantRewardManagerRole() public {
        vm.prank(admin);
        regenStaker.grantRole(REWARD_MANAGER_ROLE, rewardManager);

        assertTrue(
            regenStaker.hasRole(REWARD_MANAGER_ROLE, rewardManager),
            "Reward manager should have REWARD_MANAGER_ROLE"
        );
    }

    function test_defaultAdmin_canRevokeRewardManagerRole() public {
        vm.startPrank(admin);
        regenStaker.grantRole(REWARD_MANAGER_ROLE, rewardManager);
        regenStaker.revokeRole(REWARD_MANAGER_ROLE, rewardManager);
        vm.stopPrank();

        assertFalse(
            regenStaker.hasRole(REWARD_MANAGER_ROLE, rewardManager),
            "Reward manager should not have role after revocation"
        );
    }

    function test_nonDefaultAdmin_cannotGrantRoles() public {
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        vm.expectRevert();
        regenStaker.grantRole(DEFAULT_ADMIN_ROLE, attacker);
    }

    function test_nonDefaultAdmin_cannotRevokeRoles() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        regenStaker.revokeRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // === Integration Tests ===

    function test_multipleRewardManagers_canBothSetNotifiers() public {
        address rewardManager2 = makeAddr("rewardManager2");

        vm.startPrank(admin);
        regenStaker.grantRole(REWARD_MANAGER_ROLE, rewardManager);
        regenStaker.grantRole(REWARD_MANAGER_ROLE, rewardManager2);
        vm.stopPrank();

        address notifier1 = makeAddr("notifier1");
        address notifier2 = makeAddr("notifier2");

        vm.prank(rewardManager);
        regenStaker.setRewardNotifier(notifier1, true);

        vm.prank(rewardManager2);
        regenStaker.setRewardNotifier(notifier2, true);

        assertTrue(regenStaker.isRewardNotifier(notifier1), "Notifier1 should be enabled");
        assertTrue(regenStaker.isRewardNotifier(notifier2), "Notifier2 should be enabled");
    }

    function test_adminCanAlsoSetRewardNotifier_whenRewardManagerExists() public {
        // Grant REWARD_MANAGER_ROLE to rewardManager
        vm.prank(admin);
        regenStaker.grantRole(REWARD_MANAGER_ROLE, rewardManager);

        // Admin (who has DEFAULT_ADMIN_ROLE) should still be able to set notifier
        vm.prank(admin);
        regenStaker.setRewardNotifier(rewardNotifier, true);

        assertTrue(
            regenStaker.isRewardNotifier(rewardNotifier),
            "Admin should be able to set notifier even with reward manager role granted to others"
        );
    }

    function test_revokedRewardManager_cannotSetNotifier() public {
        vm.startPrank(admin);
        regenStaker.grantRole(REWARD_MANAGER_ROLE, rewardManager);
        regenStaker.revokeRole(REWARD_MANAGER_ROLE, rewardManager);
        vm.stopPrank();

        vm.prank(rewardManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                Staker.Staker__Unauthorized.selector,
                bytes32("not admin or reward manager"),
                rewardManager
            )
        );
        regenStaker.setRewardNotifier(rewardNotifier, true);
    }

    // === Governance Protection Still Works ===

    function test_governanceProtection_stillWorksWithRoleBasedAccessControl() public {
        // Setup: notify rewards to start active period
        rewardToken.mint(rewardNotifier, 100 ether);
        vm.prank(admin);
        regenStaker.setRewardNotifier(rewardNotifier, true);

        vm.startPrank(rewardNotifier);
        rewardToken.transfer(address(regenStaker), 100 ether);
        regenStaker.notifyRewardAmount(100 ether);
        vm.stopPrank();

        // Verify in active reward period
        assertGt(regenStaker.rewardEndTime(), block.timestamp, "Should be in active reward period");

        // Admin should NOT be able to increase maxBumpTip during active rewards (governance protection)
        vm.prank(admin);
        vm.expectRevert(RegenStakerBase.CannotRaiseMaxBumpTipDuringActiveReward.selector);
        regenStaker.setMaxBumpTip(5000);

        // After reward period ends, it should work
        vm.warp(regenStaker.rewardEndTime() + 1);
        vm.prank(admin);
        regenStaker.setMaxBumpTip(5000);
        assertEq(regenStaker.maxBumpTip(), 5000, "Should be able to set after reward period");
    }
}
