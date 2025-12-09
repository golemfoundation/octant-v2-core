// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { AccessMode } from "src/constants.sol";
import { Test } from "forge-std/Test.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { MockERC20Staking } from "test/mocks/MockERC20Staking.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { Staker } from "staker/Staker.sol";

/**
 * @title REG-008 Compound AddressSet Bypass Demo
 * @dev Demonstrates access control bypass in compoundRewards function
 *
 * VULNERABILITY: Non-inAllowset depositors can increase stake via inAllowset claimers
 * ROOT CAUSE: Missing depositor allowset check when claimer calls compoundRewards
 * IMPACT: Bypasses access control for previously delisted users
 * SEVERITY: High
 */
contract REG008CompoundAllowsetBypassDemoTest is Test {
    RegenStaker public regenStaker;
    MockERC20Staking public stakeToken;
    AddressSet public stakerAllowset;

    address public admin = makeAddr("admin");
    address public rewardNotifier = makeAddr("rewardNotifier");
    address public depositor = makeAddr("depositor");
    address public allowlistedClaimer = makeAddr("allowlistedClaimer");

    uint256 public constant STAKE_AMOUNT = 100 ether;
    uint256 public constant REWARD_AMOUNT = 50 ether;

    function setUp() public {
        vm.startPrank(admin);

        stakeToken = new MockERC20Staking(18);
        stakerAllowset = new AddressSet();
        AddressSet earningPowerAllowset = new AddressSet();
        RegenEarningPowerCalculator calc = new RegenEarningPowerCalculator(
            address(this),
            earningPowerAllowset,
            IAddressSet(address(0)),
            AccessMode.ALLOWSET
        );

        regenStaker = new RegenStaker(
            stakeToken,
            stakeToken,
            calc,
            1000,
            admin,
            30 days,
            0,
            stakerAllowset,
            IAddressSet(address(0)),
            AccessMode.ALLOWSET,
            new AddressSet()
        );

        regenStaker.setRewardNotifier(rewardNotifier, true);

        // Initially allowset both users
        stakerAllowset.add(depositor);
        stakerAllowset.add(allowlistedClaimer);
        earningPowerAllowset.add(depositor);
        earningPowerAllowset.add(allowlistedClaimer);

        stakeToken.mint(depositor, STAKE_AMOUNT);
        stakeToken.mint(rewardNotifier, REWARD_AMOUNT);

        vm.stopPrank();
    }

    function testREG008_AllowsetBypassViaCompound() public {
        // NOTE: This vulnerability has been fixed - the test now verifies proper behavior
        // Step 1: Depositor stakes with inAllowset claimer
        vm.startPrank(depositor);
        stakeToken.approve(address(regenStaker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = regenStaker.stake(STAKE_AMOUNT, makeAddr("delegatee"), allowlistedClaimer);
        vm.stopPrank();

        // Step 2: Start rewards and accumulate some
        vm.startPrank(rewardNotifier);
        stakeToken.approve(address(regenStaker), REWARD_AMOUNT);
        stakeToken.transfer(address(regenStaker), REWARD_AMOUNT);
        regenStaker.notifyRewardAmount(REWARD_AMOUNT);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Step 3: Admin removes depositor from allowset (e.g., compliance issue)
        vm.prank(admin);
        stakerAllowset.remove(depositor);

        // Verify depositor is no longer inAllowset
        assertFalse(stakerAllowset.contains(depositor));
        assertTrue(stakerAllowset.contains(allowlistedClaimer));

        // Step 4: Vulnerability FIXED - Allowseted claimer cannot compound for delisted depositor
        vm.prank(allowlistedClaimer);
        // The compound now properly checks depositor allowset status and reverts
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.StakerNotAllowed.selector, depositor));
        regenStaker.compoundRewards(depositId);
    }

    function testREG008_DirectDepositBlockedButCompoundAllowed() public {
        // NOTE: This vulnerability has been fixed - the test now verifies proper behavior
        // Setup deposit and rewards
        vm.startPrank(depositor);
        stakeToken.approve(address(regenStaker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = regenStaker.stake(STAKE_AMOUNT, makeAddr("delegatee"), allowlistedClaimer);
        vm.stopPrank();

        vm.startPrank(rewardNotifier);
        stakeToken.approve(address(regenStaker), REWARD_AMOUNT);
        stakeToken.transfer(address(regenStaker), REWARD_AMOUNT);
        regenStaker.notifyRewardAmount(REWARD_AMOUNT);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        // Remove depositor from allowset
        vm.prank(admin);
        stakerAllowset.remove(depositor);

        // Direct staking is correctly blocked
        vm.startPrank(depositor);
        stakeToken.mint(depositor, STAKE_AMOUNT);
        stakeToken.approve(address(regenStaker), STAKE_AMOUNT);

        vm.expectRevert(); // Should revert due to allowset check
        regenStaker.stake(STAKE_AMOUNT, makeAddr("delegatee"), depositor);
        vm.stopPrank();

        // Compound is now also blocked - vulnerability has been fixed
        vm.prank(allowlistedClaimer);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.StakerNotAllowed.selector, depositor));
        regenStaker.compoundRewards(depositId);
    }
}
