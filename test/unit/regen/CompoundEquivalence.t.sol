// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.23;

import { AccessMode } from "src/constants.sol";
import { Test } from "forge-std/Test.sol";

import { RegenStakerWithoutDelegateSurrogateVotes } from "src/regen/RegenStakerWithoutDelegateSurrogateVotes.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { Staker } from "staker/Staker.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { MockERC20Permit } from "test/mocks/MockERC20Permit.sol";

contract CompoundEquivalenceTest is Test {
    address internal constant ADMIN = address(0xA11CE);
    address internal constant USER = address(0xBEEF);
    address internal constant DELEGATEE = address(0xD1E6A7);
    address internal constant NOTIFIER = address(0xFEE);

    uint256 internal constant INITIAL_USER_BAL = 1_000_000e18;
    uint256 internal constant STAKE_AMOUNT = 1_000e18;
    uint256 internal constant REWARD_AMOUNT = 10_000e18;
    uint256 internal constant MAX_BUMP_TIP = 0;
    uint128 internal constant REWARD_DURATION = 30 days; // business as usual
    uint256 internal constant MAX_CLAIM_FEE = 0; // simplify equivalence
    uint128 internal constant MIN_STAKE = 0;

    MockERC20Permit internal token;
    RegenEarningPowerCalculator internal calculator;
    RegenStakerWithoutDelegateSurrogateVotes internal stakerA; // compound path
    RegenStakerWithoutDelegateSurrogateVotes internal stakerB; // claim+stakeMore path
    AddressSet internal allocationAllowset;

    function setUp() public {
        token = new MockERC20Permit(18);
        calculator = new RegenEarningPowerCalculator(
            ADMIN,
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE
        );
        allocationAllowset = new AddressSet();

        stakerA = new RegenStakerWithoutDelegateSurrogateVotes(
            token,
            token,
            calculator,
            MAX_BUMP_TIP,
            ADMIN,
            REWARD_DURATION,
            MIN_STAKE,
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            IAddressSet(address(allocationAllowset))
        );

        stakerB = new RegenStakerWithoutDelegateSurrogateVotes(
            token,
            token,
            calculator,
            MAX_BUMP_TIP,
            ADMIN,
            REWARD_DURATION,
            MIN_STAKE,
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            IAddressSet(address(allocationAllowset))
        );

        // fund user and stakers for rewards
        token.mint(USER, INITIAL_USER_BAL);
        token.mint(address(this), REWARD_AMOUNT * 2);

        // enable notifier
        vm.prank(ADMIN);
        stakerA.setRewardNotifier(NOTIFIER, true);
        vm.prank(ADMIN);
        stakerB.setRewardNotifier(NOTIFIER, true);

        // user approves both stakers for stake and future stakeMore
        vm.startPrank(USER);
        token.approve(address(stakerA), type(uint256).max);
        token.approve(address(stakerB), type(uint256).max);
        vm.stopPrank();

        // initial stake on both instances
        vm.prank(USER);
        stakerA.stake(STAKE_AMOUNT, DELEGATEE);
        vm.prank(USER);
        stakerB.stake(STAKE_AMOUNT, DELEGATEE);

        // transfer rewards and notify on both instances
        token.transfer(address(stakerA), REWARD_AMOUNT);
        vm.prank(NOTIFIER);
        stakerA.notifyRewardAmount(REWARD_AMOUNT);

        token.transfer(address(stakerB), REWARD_AMOUNT);
        vm.prank(NOTIFIER);
        stakerB.notifyRewardAmount(REWARD_AMOUNT);

        // advance time to accrue rewards partially
        vm.warp(block.timestamp + 7 days);
    }

    function test_CompoundEqualsClaimPlusStakeMore() public {
        // deposit ids are 0 on both fresh contracts
        Staker.DepositIdentifier depositId = Staker.DepositIdentifier.wrap(0);

        // Path A: compound
        vm.prank(USER);
        uint256 compounded = stakerA.compoundRewards(depositId);

        // Path B: claim then stakeMore
        vm.prank(USER);
        uint256 claimed = stakerB.claimReward(depositId);
        assertGt(claimed, 0, "expected positive claim");
        vm.prank(USER);
        stakerB.stakeMore(depositId, claimed);

        // Assert amounts match
        assertEq(compounded, claimed, "compounded vs claimed mismatch");

        // Compare live unclaimed rewards (sub-wei behavior aligned with claim semantics)
        uint256 unclaimedA = stakerA.unclaimedReward(depositId);
        uint256 unclaimedB = stakerB.unclaimedReward(depositId);
        assertEq(unclaimedA, unclaimedB, "unclaimedReward");

        // Compare globals
        assertEq(stakerA.totalStaked(), stakerB.totalStaked(), "totalStaked");
        assertEq(stakerA.totalEarningPower(), stakerB.totalEarningPower(), "totalEP");
        assertEq(stakerA.depositorTotalStaked(USER), stakerB.depositorTotalStaked(USER), "user total staked");
        assertEq(stakerA.depositorTotalEarningPower(USER), stakerB.depositorTotalEarningPower(USER), "user total EP");
    }

    function testFuzz_CompoundEqualsClaimPlusStakeMore(
        uint128 stakeAmt,
        uint128 rewardAmt,
        uint32 secondsElapsed
    ) public {
        // bounds to avoid pathological overflows and zero cases (values are token units before scaling)
        stakeAmt = uint128(bound(uint256(stakeAmt), 1e6, 1_000_000));
        rewardAmt = uint128(bound(uint256(rewardAmt), 3_000_000, 10_000_000)); // ensure amount/duration >= 1 in wei after scaling
        secondsElapsed = uint32(bound(uint256(secondsElapsed), 1 minutes, 25 days));

        uint256 stakeWei = uint256(stakeAmt) * 1e18;
        uint256 rewardWei = uint256(rewardAmt) * 1e18;

        // fresh instances for each fuzz case
        MockERC20Permit tkn = new MockERC20Permit(18);
        RegenStakerWithoutDelegateSurrogateVotes A = new RegenStakerWithoutDelegateSurrogateVotes(
            tkn,
            tkn,
            calculator,
            MAX_BUMP_TIP,
            ADMIN,
            REWARD_DURATION,
            MIN_STAKE,
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            IAddressSet(address(allocationAllowset))
        );
        RegenStakerWithoutDelegateSurrogateVotes B = new RegenStakerWithoutDelegateSurrogateVotes(
            tkn,
            tkn,
            calculator,
            MAX_BUMP_TIP,
            ADMIN,
            REWARD_DURATION,
            MIN_STAKE,
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            IAddressSet(address(allocationAllowset))
        );

        // fund
        tkn.mint(USER, stakeWei * 2);
        tkn.mint(address(this), rewardWei * 2);

        // enable notifier
        vm.prank(ADMIN);
        A.setRewardNotifier(NOTIFIER, true);
        vm.prank(ADMIN);
        B.setRewardNotifier(NOTIFIER, true);

        // user approves
        vm.startPrank(USER);
        tkn.approve(address(A), type(uint256).max);
        tkn.approve(address(B), type(uint256).max);
        vm.stopPrank();

        // stake
        vm.prank(USER);
        A.stake(stakeWei, DELEGATEE);
        vm.prank(USER);
        B.stake(stakeWei, DELEGATEE);

        // rewards and notify
        tkn.transfer(address(A), rewardWei);
        vm.prank(NOTIFIER);
        A.notifyRewardAmount(rewardWei);

        tkn.transfer(address(B), rewardWei);
        vm.prank(NOTIFIER);
        B.notifyRewardAmount(rewardWei);

        // time passes
        vm.warp(block.timestamp + secondsElapsed);

        // act
        Staker.DepositIdentifier id = Staker.DepositIdentifier.wrap(0);
        vm.prank(USER);
        uint256 compounded = A.compoundRewards(id);

        vm.prank(USER);
        uint256 claimed = B.claimReward(id);
        vm.prank(USER);
        B.stakeMore(id, claimed);

        // assert equivalence
        assertEq(compounded, claimed, "amount");
        assertEq(A.totalStaked(), B.totalStaked(), "totalStaked");
        assertEq(A.totalEarningPower(), B.totalEarningPower(), "totalEP");
        assertEq(A.depositorTotalStaked(USER), B.depositorTotalStaked(USER), "user total staked");
        assertEq(A.depositorTotalEarningPower(USER), B.depositorTotalEarningPower(USER), "user total EP");
        assertEq(A.rewardPerTokenAccumulatedCheckpoint(), B.rewardPerTokenAccumulatedCheckpoint(), "rPT");
        assertEq(A.lastCheckpointTime(), B.lastCheckpointTime(), "last time");
        assertEq(A.scaledRewardRate(), B.scaledRewardRate(), "scaled rate");
        assertEq(A.rewardEndTime(), B.rewardEndTime(), "end time");
        // token balances at contracts equal
        assertEq(tkn.balanceOf(address(A)), tkn.balanceOf(address(B)), "token balance");
        // live unclaimed equal
        assertEq(A.unclaimedReward(id), B.unclaimedReward(id), "unclaimed");
    }
}
