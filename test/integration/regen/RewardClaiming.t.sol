// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { Staker } from "staker/Staker.sol";
// import { SimpleVotingMechanism } from "test/mocks/SimpleVotingMechanism.sol"; // SimpleVotingMechanism removed

import { RegenIntegrationBase } from "./base/RegenIntegrationBase.sol";

/**
 * @notice RewardClaiming integration tests for RegenStaker.
 * forge-config: default.fuzz.runs = 16384
 * forge-config: default.fuzz.max_test_rejects = 1048576
 */
contract RegenIntegrationRewardClaimingTest is RegenIntegrationBase {
    function testFuzz_RewardClaiming_ClaimByDesignatedClaimer_Succeeds(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase,
        uint256 firstClaimTimePercent
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        rewardAmountBase = bound(rewardAmountBase, regenStaker.rewardDuration(), MAX_REWARD_DURATION + 1_000_000_000);
        uint256 minClaimTime = 10;
        uint256 maxClaimTime = 90;
        firstClaimTimePercent = bound(firstClaimTimePercent, minClaimTime, maxClaimTime);

        address owner = makeAddr("owner");
        address designatedClaimer = makeAddr("claimer");

        authorizeUser(owner, true, false, true);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        stakeToken.mint(owner, stakeAmount);
        vm.startPrank(owner);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, owner);
        regenStaker.alterClaimer(depositId, designatedClaimer);
        vm.stopPrank();

        (, , , , address retrievedClaimer, , ) = regenStaker.deposits(depositId);
        assertEq(retrievedClaimer, designatedClaimer);

        uint256 rewardAmount = getRewardAmount(rewardAmountBase);
        rewardToken.mint(address(regenStaker), rewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);

        uint256 firstClaimTime = (regenStaker.rewardDuration() * firstClaimTimePercent) / 100;
        vm.warp(block.timestamp + firstClaimTime);

        uint256 initialClaimerBalance = rewardToken.balanceOf(designatedClaimer);
        vm.startPrank(designatedClaimer);
        uint256 claimedAmount1 = regenStaker.claimReward(depositId);
        vm.stopPrank();

        uint256 expectedFirst = (rewardAmount * firstClaimTimePercent) / 100;
        assertApproxEqRel(claimedAmount1, expectedFirst, ONE_MICRO);
        assertEq(rewardToken.balanceOf(designatedClaimer), initialClaimerBalance + claimedAmount1);

        uint256 remainingTime = regenStaker.rewardDuration() - firstClaimTime;
        vm.warp(block.timestamp + remainingTime);

        initialClaimerBalance = rewardToken.balanceOf(designatedClaimer);
        vm.startPrank(designatedClaimer);
        uint256 claimedAmount2 = regenStaker.claimReward(depositId);
        vm.stopPrank();

        uint256 remainingTimePercent = 100 - firstClaimTimePercent;
        uint256 expectedSecond = (rewardAmount * remainingTimePercent) / 100;
        assertApproxEqRel(claimedAmount2, expectedSecond, ONE_MICRO);
        assertEq(rewardToken.balanceOf(designatedClaimer), initialClaimerBalance + claimedAmount2);

        assertApproxEqRel(claimedAmount1 + claimedAmount2, rewardAmount, ONE_MICRO);
    }

    function testFuzz_RewardClaiming_RevertIf_ClaimByNonOwnerNonClaimer(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase,
        uint256 seedForAddresses
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        rewardAmountBase = bound(rewardAmountBase, regenStaker.rewardDuration(), MAX_REWARD_DURATION + 1_000_000_000);

        address owner = makeAddr(string(abi.encodePacked("owner", seedForAddresses)));
        address designatedClaimer = makeAddr(string(abi.encodePacked("claimer", seedForAddresses)));
        address unrelatedUser = makeAddr(string(abi.encodePacked("unrelated", seedForAddresses)));

        vm.assume(owner != designatedClaimer);
        vm.assume(owner != unrelatedUser);
        vm.assume(designatedClaimer != unrelatedUser);

        authorizeUser(owner, true, false, true);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        stakeToken.mint(owner, stakeAmount);
        vm.startPrank(owner);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, owner);
        regenStaker.alterClaimer(depositId, designatedClaimer);
        vm.stopPrank();

        uint256 rewardAmount = getRewardAmount(rewardAmountBase);
        rewardToken.mint(address(regenStaker), rewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);
        vm.warp(block.timestamp + regenStaker.rewardDuration());

        vm.startPrank(unrelatedUser);
        vm.expectRevert(
            abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not claimer or owner"), unrelatedUser)
        );
        regenStaker.claimReward(depositId);
        vm.stopPrank();
    }

    function testFuzz_RewardClaiming_OwnerCanStillClaimAfterDesignatingNewClaimer(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase,
        uint256 seedForAddresses
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        rewardAmountBase = bound(rewardAmountBase, regenStaker.rewardDuration(), MAX_REWARD_DURATION + 1_000_000_000);

        address ownerAddr = makeAddr(string(abi.encodePacked("owner", seedForAddresses)));
        address newClaimer = makeAddr(string(abi.encodePacked("claimer", seedForAddresses)));

        vm.assume(ownerAddr != newClaimer);

        authorizeUser(ownerAddr, true, false, true);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        stakeToken.mint(ownerAddr, stakeAmount);
        vm.startPrank(ownerAddr);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, ownerAddr);
        regenStaker.alterClaimer(depositId, newClaimer);
        vm.stopPrank();

        uint256 rewardAmount = getRewardAmount(rewardAmountBase);
        rewardToken.mint(address(regenStaker), rewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);
        vm.warp(block.timestamp + regenStaker.rewardDuration());

        vm.startPrank(ownerAddr);
        uint256 claimedByOwner = regenStaker.claimReward(depositId);
        vm.stopPrank();

        assertApproxEqRel(claimedByOwner, rewardAmount, ONE_MICRO);
    }
}
