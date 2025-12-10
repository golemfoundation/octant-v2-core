// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import { ShutterDAOIntegrationTest } from "test/integration/shutter/ShutterDAOIntegration.t.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { Staker } from "staker/Staker.sol";

/**
 * @title ShutterDAODelegationTest
 * @notice Extended delegation testing for Shutter DAO integration.
 * @dev Inherits from ShutterDAOIntegrationTest to reuse setup and infrastructure.
 */
contract ShutterDAODelegationTest is ShutterDAOIntegrationTest {
    function test_DelegationPersistsAfterAdditionalStake() public {
        uint256 initialStake = 10_000e18;
        uint256 additionalStake = 5_000e18;
        address delegatee = makeAddr("Delegatee");
        address surrogate = regenStaker.predictSurrogateAddress(delegatee);

        // 1. Initial Stake
        vm.startPrank(shuHolder1);
        IERC20(SHU_TOKEN).approve(address(regenStaker), initialStake + additionalStake);
        regenStaker.stake(initialStake, delegatee);
        vm.stopPrank();

        // Verify initial delegation
        address actualDelegatee = _getDelegatee(surrogate);
        assertEq(actualDelegatee, delegatee, "Initial delegation failed");
        assertEq(regenStaker.depositorTotalStaked(shuHolder1), initialStake);

        // 2. Additional Stake (same delegatee)
        vm.prank(shuHolder1);
        regenStaker.stake(additionalStake, delegatee);

        // Verify delegation persists and amount increases
        actualDelegatee = _getDelegatee(surrogate);
        assertEq(actualDelegatee, delegatee, "Delegation lost after additional stake");
        assertEq(regenStaker.depositorTotalStaked(shuHolder1), initialStake + additionalStake);
    }

    function test_DelegationChangeable() public {
        uint256 stakeAmount = 10_000e18;
        address delegatee1 = makeAddr("Delegatee1");
        address delegatee2 = makeAddr("Delegatee2");
        address surrogate1 = regenStaker.predictSurrogateAddress(delegatee1);
        address surrogate2 = regenStaker.predictSurrogateAddress(delegatee2);

        // 1. Stake to Delegatee 1
        vm.startPrank(shuHolder1);
        IERC20(SHU_TOKEN).approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, delegatee1);

        // Verify initial state
        assertEq(_getDelegatee(surrogate1), delegatee1);

        // 2. Change Delegatee to Delegatee 2
        // To change delegatee, we withdraw and restake or use alterDelegatee if supported.
        // RegenStakerBase supports alterDelegatee.
        regenStaker.alterDelegatee(depositId, delegatee2);
        vm.stopPrank();

        // Verify new state
        assertEq(_getDelegatee(surrogate2), delegatee2);

        // Verify tokens moved
        assertEq(IERC20(SHU_TOKEN).balanceOf(surrogate1), 0);
        assertEq(IERC20(SHU_TOKEN).balanceOf(surrogate2), stakeAmount);
    }

    function test_DelegationClearedOnFullWithdrawal() public {
        uint256 stakeAmount = 10_000e18;
        address delegatee = makeAddr("Delegatee");
        address surrogate = regenStaker.predictSurrogateAddress(delegatee);

        vm.startPrank(shuHolder1);
        IERC20(SHU_TOKEN).approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, delegatee);

        // Verify staked
        assertEq(IERC20(SHU_TOKEN).balanceOf(surrogate), stakeAmount);

        // Withdraw full amount
        regenStaker.withdraw(depositId, stakeAmount);
        vm.stopPrank();

        // Verify surrogate balance is zero (voting power removed)
        assertEq(IERC20(SHU_TOKEN).balanceOf(surrogate), 0);
    }

    function test_SurrogateAddressUniqueness() public {
        address delegatee1 = makeAddr("Delegatee1");
        address delegatee2 = makeAddr("Delegatee2");

        address surrogate1 = regenStaker.predictSurrogateAddress(delegatee1);
        address surrogate2 = regenStaker.predictSurrogateAddress(delegatee2);

        assertFalse(surrogate1 == surrogate2, "Surrogate addresses must be unique per delegatee");
        assertFalse(surrogate1 == address(0), "Surrogate address cannot be zero");
        assertFalse(surrogate2 == address(0), "Surrogate address cannot be zero");
    }

    function test_CannotStealDelegationOfAnotherStaker() public {
        uint256 stake1 = 10_000e18;
        uint256 stake2 = 5_000e18;
        address delegatee = makeAddr("SharedDelegatee");
        address surrogate = regenStaker.predictSurrogateAddress(delegatee);

        // User 1 stakes
        vm.startPrank(shuHolder1);
        IERC20(SHU_TOKEN).approve(address(regenStaker), stake1);
        regenStaker.stake(stake1, delegatee);
        vm.stopPrank();

        // User 2 stakes to SAME delegatee
        vm.startPrank(shuHolder2);
        IERC20(SHU_TOKEN).approve(address(regenStaker), stake2);
        Staker.DepositIdentifier depositId2 = regenStaker.stake(stake2, delegatee);

        // Try to withdraw more than staked (attack)
        vm.expectRevert(); // Should revert with over/underflow or insufficient balance error
        regenStaker.withdraw(depositId2, stake2 + 1);

        // Withdraw correct amount
        regenStaker.withdraw(depositId2, stake2);
        vm.stopPrank();

        // Verify User 1's stake remains untouched in surrogate
        assertEq(IERC20(SHU_TOKEN).balanceOf(surrogate), stake1);
    }

    // Helper to check delegatee on real SHU token
    function _getDelegatee(address surrogate) internal view returns (address) {
        (bool success, bytes memory data) = SHU_TOKEN.staticcall(
            abi.encodeWithSignature("delegates(address)", surrogate)
        );
        require(success, "Delegates call failed");
        return abi.decode(data, (address));
    }
}
