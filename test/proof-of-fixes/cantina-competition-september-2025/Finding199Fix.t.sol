// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { OctantTestBase } from "test/proof-of-concepts/OctantTestBase.t.sol";
import { Staker } from "staker/Staker.sol";

/// @title Cantina Competition September 2025 – Finding 199 Fix
/// @notice Ensures the fix for competition finding #199 prevents earning-power griefing attacks.
contract Cantina199Fix is Test, OctantTestBase {
    Staker.DepositIdentifier internal aliceDepositId;
    Staker.DepositIdentifier internal bobDepositId;
    Staker.DepositIdentifier internal charlieDepositId;

    uint256 internal constant ALICE_STAKE = 1_000 ether;
    uint256 internal constant BOB_STAKE = 100 ether;
    uint256 internal constant CHARLIE_STAKE = 50 ether;
    uint256 internal constant REWARD_AMOUNT = 100 ether;

    function testFix_AllowsZeroTipDowngrade() public {
        // Recreate initial staking/reward distribution and prep the attack.
        _seedBaseScenario();

        // Admin removes Alice from the allowset as in the PoC.
        vm.prank(admin);
        earningPowerAllowset.remove(alice);

        // Keeper (Charlie) now bumps earning power with zero tip. This must succeed post-fix.
        vm.prank(charlie);
        regenStaker.bumpEarningPower(aliceDepositId, charlie, 0);

        // Alice should have zero earning power, and subsequent bumps are no-ops with zero tip.
        (, , uint96 earningPowerAfter, , , , ) = regenStaker.deposits(aliceDepositId);
        assertEq(earningPowerAfter, 0, "earning power should be cleared after downgrade");

        // No tip should be paid out when the keeper requests zero.
        assertEq(rewardToken.balanceOf(charlie), 0, "zero-tip downgrade must not transfer rewards");
    }

    /// @dev Recreates the base setup, staking, reward notification and attack prep.
    function _seedBaseScenario() internal {
        // Fund actors
        stakeToken.mint(alice, ALICE_STAKE);
        stakeToken.mint(bob, BOB_STAKE);
        stakeToken.mint(charlie, CHARLIE_STAKE);
        rewardToken.mint(rewardNotifier, REWARD_AMOUNT);

        // AddressSet bump keeper for staking/earning power
        vm.prank(admin);
        stakerAllowset.add(charlie);
        vm.prank(admin);
        earningPowerAllowset.add(charlie);

        vm.startPrank(alice);
        stakeToken.approve(address(regenStaker), ALICE_STAKE);
        aliceDepositId = regenStaker.stake(ALICE_STAKE, alice, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        stakeToken.approve(address(regenStaker), BOB_STAKE);
        bobDepositId = regenStaker.stake(BOB_STAKE, bob, bob);
        vm.stopPrank();

        vm.startPrank(charlie);
        stakeToken.approve(address(regenStaker), CHARLIE_STAKE);
        charlieDepositId = regenStaker.stake(CHARLIE_STAKE, charlie, charlie);
        vm.stopPrank();

        vm.prank(rewardNotifier);
        rewardToken.approve(address(regenStaker), REWARD_AMOUNT);
        vm.prank(rewardNotifier);
        rewardToken.transfer(address(regenStaker), REWARD_AMOUNT);
        vm.prank(rewardNotifier);
        regenStaker.notifyRewardAmount(REWARD_AMOUNT);

        vm.warp(block.timestamp + REWARD_DURATION / 2);

        vm.prank(alice);
        regenStaker.claimReward(aliceDepositId);
    }
}
