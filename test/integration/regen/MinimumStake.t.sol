// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { Staker } from "staker/Staker.sol";
// import { SimpleVotingMechanism } from "test/mocks/SimpleVotingMechanism.sol"; // SimpleVotingMechanism removed

import { RegenIntegrationBase } from "./base/RegenIntegrationBase.sol";

/**
 * @notice MinimumStake integration tests for RegenStaker.
 * forge-config: default.fuzz.runs = 16384
 * forge-config: default.fuzz.max_test_rejects = 1048576
 */
contract RegenIntegrationMinimumStakeTest is RegenIntegrationBase {
    function testFuzz_SetMinimumStakeAmount(uint256 newMinimum) public {
        newMinimum = bound(newMinimum, 0, getStakeAmount(10000));

        vm.prank(ADMIN);
        regenStaker.setMinimumStakeAmount(uint128(newMinimum));

        assertEq(regenStaker.minimumStakeAmount(), newMinimum);
    }

    function testFuzz_RevertIf_NonAdminCannotSetMinimumStakeAmount(address nonAdmin, uint256 newMinimum) public {
        vm.assume(nonAdmin != ADMIN);
        newMinimum = bound(newMinimum, 0, getStakeAmount(10000));

        vm.startPrank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not admin"), nonAdmin));
        regenStaker.setMinimumStakeAmount(uint128(newMinimum));
        vm.stopPrank();
    }

    function testFuzz_RevertIf_StakeBelowMinimum(uint256 minimumAmount, uint256 stakeAmount) public {
        minimumAmount = bound(minimumAmount, getStakeAmount(1), getStakeAmount(1000));
        stakeAmount = bound(stakeAmount, 1, minimumAmount - 1);

        vm.prank(ADMIN);
        regenStaker.setMinimumStakeAmount(uint128(minimumAmount));

        address user = makeAddr("user");
        authorizeUser(user, true, false, true);

        stakeToken.mint(user, stakeAmount);
        vm.startPrank(user);
        stakeToken.approve(address(regenStaker), stakeAmount);
        vm.expectRevert(
            abi.encodeWithSelector(RegenStakerBase.MinimumStakeAmountNotMet.selector, minimumAmount, stakeAmount)
        );
        regenStaker.stake(stakeAmount, user, user);
        vm.stopPrank();
    }

    function testFuzz_StakeAtOrAboveMinimumSucceeds(uint256 minimumAmountBase, uint256 additionalAmountBase) public {
        minimumAmountBase = bound(minimumAmountBase, 1, 100);
        additionalAmountBase = bound(additionalAmountBase, 0, 100);

        uint256 minimumAmount = getStakeAmount(minimumAmountBase);
        uint256 additionalAmount = getStakeAmount(additionalAmountBase);
        uint256 stakeAmount = minimumAmount + additionalAmount;

        vm.assume(stakeAmount >= minimumAmount);

        vm.prank(ADMIN);
        regenStaker.setMinimumStakeAmount(uint128(minimumAmount));

        address user = makeAddr("user");
        authorizeUser(user, true, false, true);

        stakeToken.mint(user, stakeAmount);
        vm.startPrank(user);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, user, user);
        vm.stopPrank();

        assertEq(regenStaker.depositorTotalStaked(user), stakeAmount);
        (uint96 depositBalance, , , , , , ) = regenStaker.deposits(depositId);
        assertEq(uint256(depositBalance), stakeAmount);
    }

    function testFuzz_RevertIf_StakeMoreResultsBelowMinimum(
        uint256 minimumAmountBase,
        uint256 withdrawPercent,
        uint256 additionalAmountBase
    ) public {
        minimumAmountBase = bound(minimumAmountBase, 10, 50);
        withdrawPercent = bound(withdrawPercent, 30, 70);
        additionalAmountBase = bound(additionalAmountBase, 1, minimumAmountBase - 1);

        uint256 minimumAmount = getStakeAmount(minimumAmountBase);
        uint256 initialStake = minimumAmount + getStakeAmount(10);
        uint256 withdrawAmount = (initialStake * withdrawPercent) / 100;
        uint256 additionalStake = getStakeAmount(additionalAmountBase);

        uint256 remainingAfterWithdraw = initialStake - withdrawAmount;
        vm.assume(remainingAfterWithdraw < minimumAmount);
        vm.assume(remainingAfterWithdraw + additionalStake < minimumAmount);

        vm.prank(ADMIN);
        regenStaker.setMinimumStakeAmount(uint128(minimumAmount));

        address user = makeAddr("user");
        authorizeUser(user, true, false, true);

        stakeToken.mint(user, initialStake + additionalStake);
        vm.startPrank(user);
        stakeToken.approve(address(regenStaker), initialStake + additionalStake);
        Staker.DepositIdentifier depositId = regenStaker.stake(initialStake, user, user);

        vm.expectRevert(
            abi.encodeWithSelector(
                RegenStakerBase.MinimumStakeAmountNotMet.selector,
                minimumAmount,
                remainingAfterWithdraw
            )
        );
        regenStaker.withdraw(depositId, withdrawAmount);
        vm.stopPrank();
    }
}
