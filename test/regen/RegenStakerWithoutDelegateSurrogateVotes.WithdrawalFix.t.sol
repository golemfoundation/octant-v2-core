// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.23;

import { AccessMode } from "src/constants.sol";
import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { RegenStakerWithoutDelegateSurrogateVotes } from "src/regen/RegenStakerWithoutDelegateSurrogateVotes.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { Staker } from "staker/Staker.sol";
import { StakerOnBehalf } from "staker/extensions/StakerOnBehalf.sol";

/// @title Tests for REG-007 Withdrawal Lockup Fix
/// @notice Validates that the withdrawal lockup vulnerability is properly fixed
/// @dev Addresses REG-007 (OSU-918) - Contract using address(this) as surrogate causes withdrawal failures
contract RegenStakerWithoutDelegateSurrogateVotesWithdrawalFixTest is Test {
    RegenStakerWithoutDelegateSurrogateVotes public staker;
    MockERC20 public stakeToken;
    MockERC20 public rewardToken;
    RegenEarningPowerCalculator public earningPowerCalculator;
    AddressSet public allowset;
    AddressSet public allocationAllowset;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public notifier = makeAddr("notifier");

    uint256 constant INITIAL_BALANCE = 10_000e18;
    uint128 constant MIN_STAKE = 100e18;
    uint256 constant STAKE_AMOUNT = 1000e18;
    uint256 constant REWARD_AMOUNT = 500e18;

    function setUp() public {
        // Deploy tokens
        stakeToken = new MockERC20(18);
        rewardToken = new MockERC20(18);

        // Deploy allowsets
        allowset = new AddressSet();
        allowset.add(alice);
        allowset.add(bob);

        allocationAllowset = new AddressSet();

        // Deploy earning power calculator
        earningPowerCalculator = new RegenEarningPowerCalculator(
            admin,
            IAddressSet(address(allowset)),
            IAddressSet(address(0)),
            AccessMode.ALLOWSET
        );

        // Deploy staker
        staker = new RegenStakerWithoutDelegateSurrogateVotes(
            IERC20(address(rewardToken)),
            IERC20(address(stakeToken)),
            earningPowerCalculator,
            0, // maxBumpTip
            admin,
            30 days, // rewardDuration
            MIN_STAKE, // minimumStakeAmount
            IAddressSet(address(allowset)), // stakerAllowset
            IAddressSet(address(0)), // stakerBlockset
            AccessMode.NONE,
            allocationAllowset // allocationMechanismAllowset
        );

        // Setup notifier
        vm.prank(admin);
        staker.setRewardNotifier(notifier, true);

        // Fund users
        stakeToken.mint(alice, INITIAL_BALANCE);
        stakeToken.mint(bob, INITIAL_BALANCE);
        rewardToken.mint(notifier, INITIAL_BALANCE);
    }

    /// @notice Test basic withdrawal succeeds after fix
    function test_basicWithdrawal() public {
        // Alice stakes
        vm.startPrank(alice);
        stakeToken.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = staker.stake(STAKE_AMOUNT, alice, alice);
        vm.stopPrank();

        // Verify stake
        assertEq(staker.totalStaked(), STAKE_AMOUNT);
        assertEq(stakeToken.balanceOf(address(staker)), STAKE_AMOUNT);
        assertEq(stakeToken.balanceOf(alice), INITIAL_BALANCE - STAKE_AMOUNT);

        // Alice withdraws
        vm.prank(alice);
        staker.withdraw(depositId, STAKE_AMOUNT);

        // Verify withdrawal
        assertEq(staker.totalStaked(), 0);
        assertEq(stakeToken.balanceOf(address(staker)), 0);
        assertEq(stakeToken.balanceOf(alice), INITIAL_BALANCE);
    }

    /// @notice Test partial withdrawal
    function test_partialWithdrawal() public {
        // Alice stakes
        vm.startPrank(alice);
        stakeToken.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = staker.stake(STAKE_AMOUNT, alice, alice);
        vm.stopPrank();

        uint256 withdrawAmount = STAKE_AMOUNT - MIN_STAKE;

        // Alice partially withdraws
        vm.prank(alice);
        staker.withdraw(depositId, withdrawAmount);

        // Verify partial withdrawal
        assertEq(staker.totalStaked(), MIN_STAKE);
        assertEq(stakeToken.balanceOf(address(staker)), MIN_STAKE);
        assertEq(stakeToken.balanceOf(alice), INITIAL_BALANCE - MIN_STAKE);
    }

    /// @notice Test multiple users can withdraw
    function test_multipleUsersWithdraw() public {
        // Alice stakes
        vm.startPrank(alice);
        stakeToken.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier aliceDepositId = staker.stake(STAKE_AMOUNT, alice, alice);
        vm.stopPrank();

        // Bob stakes
        vm.startPrank(bob);
        stakeToken.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier bobDepositId = staker.stake(STAKE_AMOUNT, bob, bob);
        vm.stopPrank();

        // Verify total stakes
        assertEq(staker.totalStaked(), STAKE_AMOUNT * 2);

        // Alice withdraws
        vm.prank(alice);
        staker.withdraw(aliceDepositId, STAKE_AMOUNT);

        // Verify Alice's withdrawal
        assertEq(staker.totalStaked(), STAKE_AMOUNT);
        assertEq(stakeToken.balanceOf(alice), INITIAL_BALANCE);

        // Bob withdraws
        vm.prank(bob);
        staker.withdraw(bobDepositId, STAKE_AMOUNT);

        // Verify Bob's withdrawal
        assertEq(staker.totalStaked(), 0);
        assertEq(stakeToken.balanceOf(bob), INITIAL_BALANCE);
    }

    /// @notice Test withdrawal after earning rewards
    function test_withdrawalAfterEarningRewards() public {
        // Alice stakes
        vm.startPrank(alice);
        stakeToken.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = staker.stake(STAKE_AMOUNT, alice, alice);
        vm.stopPrank();

        // Add rewards
        vm.startPrank(notifier);
        rewardToken.transfer(address(staker), REWARD_AMOUNT);
        staker.notifyRewardAmount(REWARD_AMOUNT);
        vm.stopPrank();

        // Advance time to earn rewards
        vm.warp(block.timestamp + 15 days);

        // Alice withdraws stake (not rewards)
        vm.prank(alice);
        staker.withdraw(depositId, STAKE_AMOUNT);

        // Verify withdrawal
        assertEq(staker.totalStaked(), 0);
        assertEq(stakeToken.balanceOf(alice), INITIAL_BALANCE);

        // Alice can still claim rewards after withdrawal
        uint256 aliceRewardBalanceBefore = rewardToken.balanceOf(alice);
        vm.prank(alice);
        uint256 rewardsClaimed = staker.claimReward(depositId);
        assertGt(rewardsClaimed, 0, "Should have claimed rewards");
        assertEq(rewardToken.balanceOf(alice), aliceRewardBalanceBefore + rewardsClaimed);
    }

    /// @notice Test withdrawal with compounded rewards
    function test_withdrawalWithCompoundedRewards() public {
        // Setup same token for staking and rewards
        RegenStakerWithoutDelegateSurrogateVotes sameTokenStaker = new RegenStakerWithoutDelegateSurrogateVotes(
            IERC20(address(stakeToken)), // Same token for rewards
            IERC20(address(stakeToken)), // Same token for staking
            earningPowerCalculator,
            0,
            admin,
            30 days,
            MIN_STAKE,
            IAddressSet(address(allowset)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            allocationAllowset
        );

        vm.prank(admin);
        sameTokenStaker.setRewardNotifier(notifier, true);

        // Alice stakes
        vm.startPrank(alice);
        stakeToken.approve(address(sameTokenStaker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = sameTokenStaker.stake(STAKE_AMOUNT, alice, alice);
        vm.stopPrank();

        // Add rewards
        stakeToken.mint(notifier, REWARD_AMOUNT);
        vm.startPrank(notifier);
        stakeToken.transfer(address(sameTokenStaker), REWARD_AMOUNT);
        sameTokenStaker.notifyRewardAmount(REWARD_AMOUNT);
        vm.stopPrank();

        // Advance time
        vm.warp(block.timestamp + 15 days);

        // Compound rewards
        vm.prank(alice);
        sameTokenStaker.compoundRewards(depositId);

        (uint96 newStakeAmount, , , , , , ) = sameTokenStaker.deposits(depositId);
        assertGt(newStakeAmount, STAKE_AMOUNT, "Stake should have increased");

        // Withdraw everything
        vm.prank(alice);
        sameTokenStaker.withdraw(depositId, newStakeAmount);

        // Verify withdrawal
        assertEq(sameTokenStaker.totalStaked(), 0);
        assertGt(stakeToken.balanceOf(alice), INITIAL_BALANCE, "Should have withdrawn compounded amount");
    }

    /// @notice Test multiple sequential withdrawals
    function test_multipleSequentialWithdrawals() public {
        // Alice makes multiple deposits
        vm.startPrank(alice);
        stakeToken.approve(address(staker), STAKE_AMOUNT * 3);

        Staker.DepositIdentifier deposit1 = staker.stake(STAKE_AMOUNT, alice, alice);
        Staker.DepositIdentifier deposit2 = staker.stake(STAKE_AMOUNT, alice, alice);
        Staker.DepositIdentifier deposit3 = staker.stake(STAKE_AMOUNT, alice, alice);
        vm.stopPrank();

        assertEq(staker.totalStaked(), STAKE_AMOUNT * 3);

        // Withdraw in different order
        vm.startPrank(alice);
        staker.withdraw(deposit2, STAKE_AMOUNT);
        assertEq(staker.totalStaked(), STAKE_AMOUNT * 2);

        staker.withdraw(deposit1, STAKE_AMOUNT);
        assertEq(staker.totalStaked(), STAKE_AMOUNT);

        staker.withdraw(deposit3, STAKE_AMOUNT);
        assertEq(staker.totalStaked(), 0);
        vm.stopPrank();

        // Verify final balance
        assertEq(stakeToken.balanceOf(alice), INITIAL_BALANCE);
    }

    /// @notice Test gas cost of withdrawal
    function test_withdrawalGasCost() public {
        // Alice stakes
        vm.startPrank(alice);
        stakeToken.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = staker.stake(STAKE_AMOUNT, alice, alice);
        vm.stopPrank();

        // Measure withdrawal gas
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        staker.withdraw(depositId, STAKE_AMOUNT);
        uint256 gasUsed = gasBefore - gasleft();

        // Log gas usage
        emit log_named_uint("Withdrawal gas used", gasUsed);

        // Verify gas is reasonable (less than 100k)
        assertLt(gasUsed, 100_000, "Withdrawal should be gas efficient");
    }

    /// @notice Fuzz test withdrawal amounts
    function testFuzz_withdrawalAmounts(uint256 stakeAmount, uint256 withdrawAmount) public {
        // Bound inputs
        stakeAmount = bound(stakeAmount, MIN_STAKE, INITIAL_BALANCE);
        withdrawAmount = bound(withdrawAmount, 1, stakeAmount);

        // Adjust withdrawal to respect minimum stake
        if (withdrawAmount < stakeAmount && stakeAmount - withdrawAmount < MIN_STAKE) {
            withdrawAmount = stakeAmount; // Full withdrawal if remainder would be below minimum
        }

        // Alice stakes
        vm.startPrank(alice);
        stakeToken.approve(address(staker), stakeAmount);
        Staker.DepositIdentifier depositId = staker.stake(stakeAmount, alice, alice);
        vm.stopPrank();

        uint256 expectedBalance = INITIAL_BALANCE - stakeAmount + withdrawAmount;
        uint256 expectedStaked = stakeAmount - withdrawAmount;

        // Alice withdraws
        vm.prank(alice);
        staker.withdraw(depositId, withdrawAmount);

        // Verify
        assertEq(staker.totalStaked(), expectedStaked);
        assertEq(stakeToken.balanceOf(alice), expectedBalance);
    }

    /// @notice Test that alterDelegatee reverts since delegation is not supported
    function test_alterDelegateeReverts() public {
        // Alice stakes
        vm.startPrank(alice);
        stakeToken.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = staker.stake(STAKE_AMOUNT, alice, alice);
        vm.stopPrank();

        // Attempt to alter delegatee should revert
        vm.prank(alice);
        vm.expectRevert(RegenStakerWithoutDelegateSurrogateVotes.DelegationNotSupported.selector);
        staker.alterDelegatee(depositId, bob);
    }

    /// @notice Fuzz test that alterDelegatee always reverts regardless of inputs
    function testFuzz_alterDelegateeAlwaysReverts(address newDelegatee) public {
        // Alice stakes
        vm.startPrank(alice);
        stakeToken.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = staker.stake(STAKE_AMOUNT, alice, alice);
        vm.stopPrank();

        // Any attempt to alter delegatee should revert
        vm.prank(alice);
        vm.expectRevert(RegenStakerWithoutDelegateSurrogateVotes.DelegationNotSupported.selector);
        staker.alterDelegatee(depositId, newDelegatee);
    }

    /// @notice Test that alterDelegateeOnBehalf reverts since delegation is not supported
    function test_alterDelegateeOnBehalfReverts() public {
        // Alice stakes
        vm.startPrank(alice);
        stakeToken.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = staker.stake(STAKE_AMOUNT, alice, alice);
        vm.stopPrank();

        // With invalid signature, reverts during signature validation (before reaching _alterDelegatee)
        vm.expectRevert(StakerOnBehalf.StakerOnBehalf__InvalidSignature.selector);
        staker.alterDelegateeOnBehalf(depositId, bob, alice, block.timestamp + 1000, "");
    }

    /// @notice Fuzz test that alterDelegateeOnBehalf always reverts regardless of inputs
    function testFuzz_alterDelegateeOnBehalfAlwaysReverts(address newDelegatee, uint256 deadline) public {
        vm.assume(deadline > block.timestamp);

        // Alice stakes
        vm.startPrank(alice);
        stakeToken.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = staker.stake(STAKE_AMOUNT, alice, alice);
        vm.stopPrank();

        // With invalid signature, reverts during signature validation (before reaching _alterDelegatee)
        vm.expectRevert(StakerOnBehalf.StakerOnBehalf__InvalidSignature.selector);
        staker.alterDelegateeOnBehalf(depositId, newDelegatee, alice, deadline, "");
    }
}
