// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { Staker } from "staker/Staker.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { TokenizedAllocationMechanism } from "src/mechanisms/TokenizedAllocationMechanism.sol";
// import { SimpleVotingMechanism } from "test/mocks/SimpleVotingMechanism.sol"; // SimpleVotingMechanism removed

import { RegenIntegrationBase } from "./base/RegenIntegrationBase.sol";

/**
 * @notice Pause integration tests for RegenStaker.
 * forge-config: default.fuzz.runs = 16384
 * forge-config: default.fuzz.max_test_rejects = 1048576
 */
contract RegenIntegrationPauseTest is RegenIntegrationBase {
    function testFuzz_RevertIf_PauseCalledByNonAdmin(address nonAdmin) public {
        vm.assume(nonAdmin != ADMIN);

        vm.startPrank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not admin"), nonAdmin));
        regenStaker.pause();
        vm.stopPrank();

        vm.startPrank(ADMIN);
        regenStaker.pause();
        assertTrue(regenStaker.paused());
        regenStaker.unpause();
        vm.stopPrank();
    }

    function testFuzz_RevertIf_StakeWhenPaused(uint256 stakeAmountBase) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        uint256 stakeAmount = getStakeAmount(stakeAmountBase);

        address user = makeAddr("user");
        authorizeUser(user, true, false, false);

        stakeToken.mint(user, stakeAmount);
        vm.startPrank(user);
        stakeToken.approve(address(regenStaker), stakeAmount);
        vm.stopPrank();

        vm.prank(ADMIN);
        regenStaker.pause();
        assertTrue(regenStaker.paused());

        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        regenStaker.stake(stakeAmount / 2, user);
        vm.stopPrank();

        vm.prank(ADMIN);
        regenStaker.unpause();
        assertFalse(regenStaker.paused());
    }

    function testFuzz_RevertIf_ContributeWhenPaused(uint256 stakeAmountBase, uint256 rewardAmountBase) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        rewardAmountBase = bound(rewardAmountBase, regenStaker.rewardDuration(), MAX_REWARD_DURATION + 1_000_000_000);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        uint256 rewardAmount = getRewardAmount(rewardAmountBase);
        uint256 contributeAmount = getRewardAmount(100);

        uint256 contributorPrivateKey = uint256(keccak256(abi.encodePacked("contributor")));
        address contributor = vm.addr(contributorPrivateKey);
        address allocationMechanism = _deployAllocationMechanism();

        authorizeUser(contributor, true, true, true);

        stakeToken.mint(contributor, stakeAmount);
        rewardToken.mint(address(regenStaker), rewardAmount);

        vm.startPrank(contributor);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, contributor);
        vm.stopPrank();

        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);
        vm.warp(block.timestamp + regenStaker.rewardDuration());

        vm.prank(ADMIN);
        regenStaker.pause();
        assertTrue(regenStaker.paused());

        uint256 nonce = TokenizedAllocationMechanism(allocationMechanism).nonces(contributor);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = _getSignupDigest(
            allocationMechanism,
            contributor,
            address(regenStaker),
            contributeAmount,
            nonce,
            deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = _signDigest(digest, contributorPrivateKey);

        vm.startPrank(contributor);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        regenStaker.contribute(depositId, allocationMechanism, contributeAmount, deadline, v, r, s);
        vm.stopPrank();

        vm.prank(ADMIN);
        regenStaker.unpause();
        assertFalse(regenStaker.paused());
    }

    function testFuzz_WithdrawSucceedsWhenPaused(uint256 stakeAmountBase, uint256 withdrawAmountRatio) public {
        uint256 minStake = 100;
        uint256 maxStake = 10_000;
        stakeAmountBase = bound(stakeAmountBase, minStake, maxStake);
        uint256 minWithdrawRatio = 1;
        uint256 maxWithdrawRatio = 90;
        withdrawAmountRatio = bound(withdrawAmountRatio, minWithdrawRatio, maxWithdrawRatio);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        uint256 withdrawAmount = (stakeAmount * withdrawAmountRatio) / 100;
        vm.assume(withdrawAmount > 0);

        address user = makeAddr("user");
        authorizeUser(user, true, false, true);

        stakeToken.mint(user, stakeAmount);
        vm.startPrank(user);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, user);
        vm.stopPrank();

        vm.prank(ADMIN);
        regenStaker.pause();
        assertTrue(regenStaker.paused());

        // Withdrawal should succeed even when paused (user protection)
        uint256 balanceBefore = stakeToken.balanceOf(user);
        vm.prank(user);
        regenStaker.withdraw(depositId, withdrawAmount);

        uint256 balanceAfter = stakeToken.balanceOf(user);
        assertEq(balanceAfter - balanceBefore, withdrawAmount, "Withdrawal should succeed when paused");

        // Verify deposit balance was reduced
        (uint96 balance, , , , , , ) = regenStaker.deposits(depositId);
        assertEq(balance, stakeAmount - withdrawAmount, "Deposit balance should be reduced");

        vm.prank(ADMIN);
        regenStaker.unpause();
        assertFalse(regenStaker.paused());
    }

    /// @notice Test that withdrawals remain enabled when paused for user protection
    function test_WithdrawalsEnabledWhenPaused() public {
        uint256 stakeAmount = getStakeAmount(1000);
        address user = makeAddr("user");
        authorizeUser(user, true, false, true);

        stakeToken.mint(user, stakeAmount);
        vm.startPrank(user);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, user);
        vm.stopPrank();

        // Pause the contract
        vm.prank(ADMIN);
        regenStaker.pause();
        assertTrue(regenStaker.paused());

        // Verify other operations are blocked
        vm.startPrank(user);

        // Staking should fail
        stakeToken.mint(user, stakeAmount);
        stakeToken.approve(address(regenStaker), stakeAmount);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        regenStaker.stake(stakeAmount, user);

        // Claiming should fail
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        regenStaker.claimReward(depositId);

        // But withdrawal should succeed (MICA compliance)
        uint256 withdrawAmount = stakeAmount / 2;
        uint256 balanceBefore = stakeToken.balanceOf(user);
        regenStaker.withdraw(depositId, withdrawAmount);
        uint256 balanceAfter = stakeToken.balanceOf(user);

        assertEq(
            balanceAfter - balanceBefore,
            withdrawAmount,
            "Withdrawal should succeed when paused for user protection"
        );

        vm.stopPrank();

        // Unpause
        vm.prank(ADMIN);
        regenStaker.unpause();
        assertFalse(regenStaker.paused());
    }

    function testFuzz_RevertIf_ClaimRewardWhenPaused(uint256 stakeAmountBase, uint256 rewardAmountBase) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        rewardAmountBase = bound(rewardAmountBase, regenStaker.rewardDuration(), MAX_REWARD_DURATION + 1_000_000_000);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        uint256 rewardAmount = getRewardAmount(rewardAmountBase);

        address user = makeAddr("user");
        authorizeUser(user, true, false, true);

        stakeToken.mint(user, stakeAmount);
        vm.startPrank(user);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, user);
        vm.stopPrank();

        rewardToken.mint(address(regenStaker), rewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);
        uint256 halfDuration = regenStaker.rewardDuration() / 2;
        vm.warp(block.timestamp + halfDuration);

        vm.prank(ADMIN);
        regenStaker.pause();
        assertTrue(regenStaker.paused());

        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        regenStaker.claimReward(depositId);
        vm.stopPrank();

        vm.prank(ADMIN);
        regenStaker.unpause();
        assertFalse(regenStaker.paused());
    }
}
