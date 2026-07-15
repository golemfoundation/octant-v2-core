// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { AccessMode } from "src/constants.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { Staker } from "staker/Staker.sol";
// import { SimpleVotingMechanism } from "test/mocks/SimpleVotingMechanism.sol"; // SimpleVotingMechanism removed

import { RegenIntegrationBase } from "./base/RegenIntegrationBase.sol";

/**
 * @notice Allowsets integration tests for RegenStaker.
 * forge-config: default.fuzz.runs = 16384
 * forge-config: default.fuzz.max_test_rejects = 1048576
 */
contract RegenIntegrationAllowsetsTest is RegenIntegrationBase {
    function testFuzz_RevertIf_NonAdminCannotSetStakerAddressSet(address nonAdmin) public {
        vm.assume(nonAdmin != ADMIN);
        vm.startPrank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not admin"), nonAdmin));
        regenStaker.setStakerAllowset(AddressSet(address(0)));
        vm.stopPrank();
    }

    function testFuzz_StakerAllowset_DisableAllowsStaking(uint256 stakeAmountBase) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        uint256 partialStakeAmount = stakeAmount / 2;

        address user = makeAddr("unauthorizedUser");
        stakeToken.mint(user, stakeAmount);

        // Enable ALLOWSET mode first
        vm.prank(ADMIN);
        regenStaker.setAccessMode(AccessMode.ALLOWSET);

        vm.startPrank(user);
        stakeToken.approve(address(regenStaker), stakeAmount);

        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.StakerNotAllowed.selector, user));
        regenStaker.stake(partialStakeAmount, user);
        vm.stopPrank();

        // Disable access control by setting mode to NONE
        vm.prank(ADMIN);
        regenStaker.setAccessMode(AccessMode.NONE);

        vm.startPrank(user);
        regenStaker.stake(partialStakeAmount, user);
        vm.stopPrank();

        assertEq(stakeToken.balanceOf(user), stakeAmount - partialStakeAmount);
    }

    function testFuzz_EarningPowerAllowset_DisableGrantsEarningPower(uint256 stakeAmountBase) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        uint256 stakeAmount = getStakeAmount(stakeAmountBase);

        address authorizedUser = makeAddr("authorizedUser");
        address unauthorizedUser = makeAddr("unauthorizedUser");

        stakeToken.mint(authorizedUser, stakeAmount);
        stakeToken.mint(unauthorizedUser, stakeAmount);

        // Staker access control is already NONE from setUp, no need to set it again

        authorizeUser(authorizedUser, true, false, true);
        authorizeUser(unauthorizedUser, true, false, false);

        vm.startPrank(authorizedUser);
        stakeToken.approve(address(regenStaker), stakeAmount);
        regenStaker.stake(stakeAmount, authorizedUser);
        vm.stopPrank();

        vm.startPrank(unauthorizedUser);
        stakeToken.approve(address(regenStaker), stakeAmount);
        regenStaker.stake(stakeAmount, unauthorizedUser);
        vm.stopPrank();

        assertEq(regenStaker.depositorTotalEarningPower(authorizedUser), stakeAmount);
        assertEq(regenStaker.depositorTotalEarningPower(unauthorizedUser), 0);

        vm.prank(ADMIN);
        calculator.setAccessMode(AccessMode.NONE);

        assertEq(regenStaker.depositorTotalEarningPower(unauthorizedUser), 0);

        Staker.DepositIdentifier depositId = Staker.DepositIdentifier.wrap(1);

        vm.prank(ADMIN);
        regenStaker.bumpEarningPower(depositId, ADMIN, 0);

        assertEq(regenStaker.depositorTotalEarningPower(unauthorizedUser), stakeAmount);

        address newUser = makeAddr("newUser");
        stakeToken.mint(newUser, stakeAmount);

        authorizeUser(newUser, true, false, false);

        vm.startPrank(newUser);
        stakeToken.approve(address(regenStaker), stakeAmount);
        regenStaker.stake(stakeAmount, newUser);
        vm.stopPrank();

        assertEq(regenStaker.depositorTotalEarningPower(newUser), stakeAmount);
    }
}
