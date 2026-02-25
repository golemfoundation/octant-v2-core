// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AccessMode } from "src/constants.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { RegenStakerWithoutDelegateSurrogateVotes } from "src/regen/RegenStakerWithoutDelegateSurrogateVotes.sol";
import { Staker } from "staker/Staker.sol";
import { MockERC20Staking } from "test/mocks/MockERC20Staking.sol";
import { MockEarningPowerCalculator } from "test/mocks/MockEarningPowerCalculator.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { MockAdvanceRewardsSwapRouter } from "test/mocks/MockAdvanceRewardsSwapRouter.sol";

contract RegenStakerAdvanceRewardSwapTest is Test {
    RegenStaker public regenStaker;
    MockERC20Staking public stakeToken;
    MockERC20Staking public rewardToken;
    MockEarningPowerCalculator public earningPowerCalculator;
    AddressSet public allocationAllowset;
    MockAdvanceRewardsSwapRouter public swapRouter;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public delegatee = makeAddr("delegatee");
    address public claimer = makeAddr("claimer");

    uint256 public constant STAKE_AMOUNT = 200e18;
    uint256 public constant ADVANCE_AMOUNT = 10e18;
    uint128 public constant REWARD_DURATION = 30 days;

    function setUp() public {
        stakeToken = new MockERC20Staking(18);
        rewardToken = new MockERC20Staking(18);
        earningPowerCalculator = new MockEarningPowerCalculator();
        swapRouter = new MockAdvanceRewardsSwapRouter();

        vm.startPrank(admin);
        allocationAllowset = new AddressSet();
        vm.stopPrank();

        vm.prank(admin);
        regenStaker = new RegenStaker(
            IERC20(address(rewardToken)),
            stakeToken,
            earningPowerCalculator,
            0,
            admin,
            REWARD_DURATION,
            1e18,
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            IAddressSet(address(allocationAllowset))
        );

        stakeToken.mint(alice, STAKE_AMOUNT);
    }

    function test_stakeWithAdvanceReward_swapsAndPaysOut_whenDifferentToken() public {
        vm.prank(admin);
        regenStaker.setAdvanceSwapConfig(address(swapRouter), 3000);

        vm.startPrank(alice);
        stakeToken.approve(address(regenStaker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = regenStaker.stakeWithAdvanceReward(
            STAKE_AMOUNT,
            delegatee,
            claimer,
            ADVANCE_AMOUNT,
            ADVANCE_AMOUNT
        );
        vm.stopPrank();

        (uint96 balance, address ownerAddr, , address delegateeAddr, address claimerAddr, , ) = regenStaker.deposits(
            depositId
        );
        assertEq(balance, STAKE_AMOUNT - ADVANCE_AMOUNT, "net stake balance mismatch");
        assertEq(ownerAddr, alice, "owner mismatch");
        assertEq(delegateeAddr, delegatee, "delegatee mismatch");
        assertEq(claimerAddr, claimer, "claimer mismatch");
        assertEq(rewardToken.balanceOf(alice), ADVANCE_AMOUNT, "reward payout mismatch");
        assertEq(stakeToken.balanceOf(address(swapRouter)), ADVANCE_AMOUNT, "router should receive surrendered stake");
        assertEq(stakeToken.allowance(address(regenStaker), address(swapRouter)), 0, "router allowance should clear");

        uint64 lockEnd = regenStaker.advanceRewardLockEnd(depositId);
        assertEq(lockEnd, block.timestamp + (ADVANCE_AMOUNT * 3000 days) / STAKE_AMOUNT, "lock end mismatch");
    }

    function test_stakeWithAdvanceReward_revertsWhenRouterNotSet_forDifferentToken() public {
        vm.startPrank(alice);
        stakeToken.approve(address(regenStaker), STAKE_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(Staker.Staker__InvalidAddress.selector));
        regenStaker.stakeWithAdvanceReward(STAKE_AMOUNT, delegatee, claimer, ADVANCE_AMOUNT, ADVANCE_AMOUNT);
        vm.stopPrank();
    }

    function test_stakeWithAdvanceReward_revertsWhenSwapOutputBelowMinOut() public {
        vm.prank(admin);
        regenStaker.setAdvanceSwapConfig(address(swapRouter), 3000);
        swapRouter.setOutputBps(9000);

        vm.startPrank(alice);
        stakeToken.approve(address(regenStaker), STAKE_AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockAdvanceRewardsSwapRouter.MockInsufficientOutput.selector,
                (ADVANCE_AMOUNT * 9000) / 10_000,
                ADVANCE_AMOUNT
            )
        );
        regenStaker.stakeWithAdvanceReward(STAKE_AMOUNT, delegatee, claimer, ADVANCE_AMOUNT, ADVANCE_AMOUNT);
        vm.stopPrank();
    }
}

contract RegenStakerWithoutDelegateAdvanceRewardSwapTest is Test {
    RegenStakerWithoutDelegateSurrogateVotes public regenStaker;
    MockERC20Staking public stakeToken;
    MockERC20Staking public rewardToken;
    MockEarningPowerCalculator public earningPowerCalculator;
    AddressSet public allocationAllowset;
    MockAdvanceRewardsSwapRouter public swapRouter;

    address public admin = makeAddr("admin-no-delegation");
    address public alice = makeAddr("alice-no-delegation");
    address public delegatee = makeAddr("delegatee-no-delegation");

    uint256 public constant STAKE_AMOUNT = 200e18;
    uint256 public constant ADVANCE_AMOUNT = 10e18;
    uint128 public constant REWARD_DURATION = 30 days;

    function setUp() public {
        stakeToken = new MockERC20Staking(18);
        rewardToken = new MockERC20Staking(18);
        earningPowerCalculator = new MockEarningPowerCalculator();
        swapRouter = new MockAdvanceRewardsSwapRouter();

        vm.startPrank(admin);
        allocationAllowset = new AddressSet();
        vm.stopPrank();

        vm.prank(admin);
        regenStaker = new RegenStakerWithoutDelegateSurrogateVotes(
            IERC20(address(rewardToken)),
            IERC20(address(stakeToken)),
            earningPowerCalculator,
            0,
            admin,
            REWARD_DURATION,
            1e18,
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            IAddressSet(address(allocationAllowset))
        );

        vm.prank(admin);
        regenStaker.setAdvanceSwapConfig(address(swapRouter), 3000);
        stakeToken.mint(alice, STAKE_AMOUNT);
    }

    function test_stakeWithAdvanceReward_noDelegationVariant_usesSameExchangeSemantics() public {
        vm.startPrank(alice);
        stakeToken.approve(address(regenStaker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = regenStaker.stakeWithAdvanceReward(
            STAKE_AMOUNT,
            delegatee,
            alice,
            ADVANCE_AMOUNT,
            ADVANCE_AMOUNT
        );
        vm.stopPrank();

        (uint96 balance, address ownerAddr, , address delegateeAddr, address claimerAddr, , ) = regenStaker.deposits(
            depositId
        );
        assertEq(balance, STAKE_AMOUNT - ADVANCE_AMOUNT, "net stake balance mismatch");
        assertEq(ownerAddr, alice, "owner mismatch");
        assertEq(delegateeAddr, delegatee, "delegatee mismatch");
        assertEq(claimerAddr, alice, "claimer mismatch");
        assertEq(rewardToken.balanceOf(alice), ADVANCE_AMOUNT, "reward payout mismatch");
        assertEq(stakeToken.balanceOf(address(swapRouter)), ADVANCE_AMOUNT, "router should receive surrendered stake");

        uint64 lockEnd = regenStaker.advanceRewardLockEnd(depositId);
        assertEq(lockEnd, block.timestamp + (ADVANCE_AMOUNT * 3000 days) / STAKE_AMOUNT, "lock end mismatch");
    }
}
