// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.23;

import { AccessMode } from "src/constants.sol";
import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { MockERC20Staking } from "test/mocks/MockERC20Staking.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { AddressSet } from "src/utils/AddressSet.sol";

/// @title Tests for Same-Token Behavior in RegenStaker
/// @notice Tests that RegenStaker with surrogates relies on base Staker protection
/// @dev Addresses REG-023 (OSU-956) - Surrogate variant doesn't need custom protection
contract RegenStakerSameTokenProtectionTest is Test {
    RegenStaker public staker;
    MockERC20Staking public token;
    RegenEarningPowerCalculator public earningPowerCalculator;
    AddressSet public allowset;

    address public admin = address(0x1);
    address public notifier = address(0x2);
    address public user1 = address(0x3);
    address public delegatee = address(0x4);

    uint256 constant INITIAL_BALANCE = 1_000_000e18;
    uint256 constant STAKE_AMOUNT = 1000e18;
    uint256 constant REWARD_AMOUNT = 500e18;

    function setUp() public {
        // Deploy token with delegation support
        token = new MockERC20Staking(18);

        // Deploy allowset
        allowset = new AddressSet();
        allowset.add(user1);

        // Deploy earning power calculator
        earningPowerCalculator = new RegenEarningPowerCalculator(
            admin,
            IAddressSet(address(allowset)),
            IAddressSet(address(0)),
            AccessMode.ALLOWSET
        );

        // Deploy staker with SAME token for staking and rewards
        staker = new RegenStaker(
            IERC20(address(token)), // rewards token (SAME)
            token, // stake token (SAME)
            earningPowerCalculator,
            0, // maxBumpTip
            admin,
            30 days, // rewardDuration
            0, // minimumStakeAmount
            IAddressSet(address(0)), // no staker allowset
            IAddressSet(address(0)),
            AccessMode.NONE,
            allowset // allocation mechanism allowset
        );

        // Setup admin and notifier
        vm.startPrank(admin);
        staker.setRewardNotifier(notifier, true);
        vm.stopPrank();

        // Fund users
        token.mint(user1, INITIAL_BALANCE);
        token.mint(notifier, INITIAL_BALANCE);
    }

    /// @notice Test that RegenStaker relies on base Staker check (reward balance >= amount)
    function test_baseStakerCheckSufficientForSurrogates() public {
        // User stakes tokens (goes to surrogate)
        vm.startPrank(user1);
        token.approve(address(staker), STAKE_AMOUNT);
        staker.stake(STAKE_AMOUNT, delegatee, user1);
        vm.stopPrank();

        // Verify tokens are in surrogate, not main contract
        assertEq(token.balanceOf(address(staker)), 0, "Main contract should have no stake tokens");
        address surrogate = address(staker.surrogates(delegatee));
        assertEq(token.balanceOf(surrogate), STAKE_AMOUNT, "Surrogate should hold stake tokens");

        // Base Staker requires reward balance >= notified amount
        vm.startPrank(notifier);

        // Should revert - new balance validation: no rewards transferred yet
        vm.expectRevert(
            abi.encodeWithSelector(
                RegenStakerBase.InsufficientRewardBalance.selector,
                0, // currentBalance = 0 (no tokens transferred yet)
                REWARD_AMOUNT // required = totalRewards - totalClaimedRewards + amount = 0 - 0 + 500e18
            )
        );
        staker.notifyRewardAmount(REWARD_AMOUNT);

        // Transfer LESS than reward amount - should still fail balance check
        token.transfer(address(staker), REWARD_AMOUNT - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                RegenStakerBase.InsufficientRewardBalance.selector,
                REWARD_AMOUNT - 1, // currentBalance = 499e18 (transferred amount)
                REWARD_AMOUNT // required = 0 - 0 + 500e18 = 500e18
            )
        );
        staker.notifyRewardAmount(REWARD_AMOUNT);

        // Transfer exactly reward amount - should succeed
        // Note: Does NOT need totalStaked since stakes are segregated in surrogates
        token.transfer(address(staker), 1); // Add the missing 1 wei to reach REWARD_AMOUNT
        staker.notifyRewardAmount(REWARD_AMOUNT);
        vm.stopPrank();

        // This demonstrates that surrogate segregation makes the same-token scenario safe
        // without needing the additional protection that WithoutDelegate variant requires
    }

    /// @notice Test that different token scenario still works normally
    function test_differentTokensNoProtectionNeeded() public {
        // Deploy a variant with different reward token
        MockERC20Staking rewardToken = new MockERC20Staking(18);
        RegenStaker differentTokenStaker = new RegenStaker(
            IERC20(address(rewardToken)), // different reward token
            token, // stake token
            earningPowerCalculator,
            0,
            admin,
            30 days,
            0,
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            allowset
        );

        vm.startPrank(admin);
        differentTokenStaker.setRewardNotifier(notifier, true);
        vm.stopPrank();

        // Fund and notify - protection check is skipped for different tokens
        rewardToken.mint(notifier, REWARD_AMOUNT);
        vm.startPrank(notifier);
        rewardToken.transfer(address(differentTokenStaker), REWARD_AMOUNT);
        differentTokenStaker.notifyRewardAmount(REWARD_AMOUNT);
        vm.stopPrank();
    }
}
