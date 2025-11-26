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

/// @title RegenStakerGovernanceProtectionTest
/// @dev Tests setEarningPowerCalculator governance protection during active reward periods
contract RegenStakerGovernanceProtectionTest is Test {
    RegenStaker public regenStaker;
    RegenEarningPowerCalculator public earningPowerCalculator;
    MockERC20 public rewardToken;
    MockERC20Staking public stakeToken;
    AddressSet public allowset;
    AddressSet public allocationAllowset;

    address public admin = makeAddr("admin");
    address public rewardNotifier = makeAddr("rewardNotifier");
    address public user = makeAddr("user");

    uint256 public constant INITIAL_REWARD_AMOUNT = 100 ether;
    uint256 public constant REWARD_DURATION = 30 days;

    function setUp() public {
        rewardToken = new MockERC20(18);
        stakeToken = new MockERC20Staking(18);

        vm.startPrank(admin);
        allowset = new AddressSet();
        allocationAllowset = new AddressSet();
        earningPowerCalculator = new RegenEarningPowerCalculator(
            admin,
            allowset,
            IAddressSet(address(0)),
            AccessMode.ALLOWSET
        );
        regenStaker = new RegenStaker(
            rewardToken,
            stakeToken,
            earningPowerCalculator,
            1000,
            admin,
            uint128(REWARD_DURATION),
            100,
            allowset,
            IAddressSet(address(0)),
            AccessMode.NONE,
            allocationAllowset
        );
        regenStaker.setRewardNotifier(rewardNotifier, true);
        allowset.add(user);
        vm.stopPrank();

        rewardToken.mint(rewardNotifier, INITIAL_REWARD_AMOUNT);
        stakeToken.mint(user, 10 ether);

        vm.startPrank(user);
        stakeToken.approve(address(regenStaker), 10 ether);
        regenStaker.stake(10 ether, user);
        vm.stopPrank();
    }

    function _deployNewCalculator() internal returns (RegenEarningPowerCalculator) {
        return new RegenEarningPowerCalculator(admin, allowset, IAddressSet(address(0)), AccessMode.ALLOWSET);
    }

    function _startRewards() internal {
        vm.startPrank(rewardNotifier);
        rewardToken.transfer(address(regenStaker), INITIAL_REWARD_AMOUNT);
        regenStaker.notifyRewardAmount(INITIAL_REWARD_AMOUNT);
        vm.stopPrank();
    }

    function test_RevertWhen_SetEarningPowerCalculatorDuringActiveReward() public {
        RegenEarningPowerCalculator newCalculator = _deployNewCalculator();
        _startRewards();

        vm.prank(admin);
        vm.expectRevert(RegenStakerBase.CannotChangeEarningPowerCalculatorDuringActiveReward.selector);
        regenStaker.setEarningPowerCalculator(address(newCalculator));
    }

    function test_SetEarningPowerCalculatorAfterRewardPeriod() public {
        RegenEarningPowerCalculator newCalculator = _deployNewCalculator();
        _startRewards();
        vm.warp(regenStaker.rewardEndTime() + 1);

        vm.prank(admin);
        regenStaker.setEarningPowerCalculator(address(newCalculator));

        assertEq(address(regenStaker.earningPowerCalculator()), address(newCalculator));
    }

    function test_SetEarningPowerCalculatorBeforeFirstReward() public {
        RegenEarningPowerCalculator newCalculator = _deployNewCalculator();

        vm.prank(admin);
        regenStaker.setEarningPowerCalculator(address(newCalculator));

        assertEq(address(regenStaker.earningPowerCalculator()), address(newCalculator));
    }

    function test_RevertWhen_NonAdminSetsEarningPowerCalculator() public {
        RegenEarningPowerCalculator newCalculator = _deployNewCalculator();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not admin"), user));
        regenStaker.setEarningPowerCalculator(address(newCalculator));
    }

    function test_RevertWhen_SetEarningPowerCalculatorExactlyAtRewardEndTime() public {
        RegenEarningPowerCalculator newCalculator = _deployNewCalculator();
        _startRewards();
        uint256 rewardEndTime = regenStaker.rewardEndTime();

        vm.warp(rewardEndTime);
        vm.prank(admin);
        vm.expectRevert(RegenStakerBase.CannotChangeEarningPowerCalculatorDuringActiveReward.selector);
        regenStaker.setEarningPowerCalculator(address(newCalculator));

        vm.warp(rewardEndTime + 1);
        vm.prank(admin);
        regenStaker.setEarningPowerCalculator(address(newCalculator));
        assertEq(address(regenStaker.earningPowerCalculator()), address(newCalculator));
    }

    function testFuzz_SetEarningPowerCalculatorProtectionTiming(uint256 timeOffset) public {
        RegenEarningPowerCalculator newCalculator = _deployNewCalculator();
        _startRewards();
        uint256 rewardEndTime = regenStaker.rewardEndTime();
        timeOffset = bound(timeOffset, 0, REWARD_DURATION + 1 days);
        vm.warp(block.timestamp + timeOffset);

        vm.prank(admin);
        if (block.timestamp <= rewardEndTime) {
            vm.expectRevert(RegenStakerBase.CannotChangeEarningPowerCalculatorDuringActiveReward.selector);
            regenStaker.setEarningPowerCalculator(address(newCalculator));
        } else {
            regenStaker.setEarningPowerCalculator(address(newCalculator));
            assertEq(address(regenStaker.earningPowerCalculator()), address(newCalculator));
        }
    }

    function test_AdminCanAssignRewardNotifierToArbitraryAddress() public {
        address newNotifier = makeAddr("newNotifier");
        uint256 rewardAmount = 50 ether;
        rewardToken.mint(newNotifier, rewardAmount);

        vm.prank(admin);
        regenStaker.setRewardNotifier(newNotifier, true);

        assertTrue(regenStaker.isRewardNotifier(newNotifier));

        vm.startPrank(newNotifier);
        rewardToken.transfer(address(regenStaker), rewardAmount);
        regenStaker.notifyRewardAmount(rewardAmount);
        vm.stopPrank();

        assertGt(regenStaker.rewardEndTime(), block.timestamp);
    }
}
