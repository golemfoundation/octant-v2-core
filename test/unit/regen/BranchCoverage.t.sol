// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { AccessMode } from "src/constants.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IEarningPowerCalculator } from "staker/interfaces/IEarningPowerCalculator.sol";
import { Staker } from "staker/Staker.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockERC20Staking } from "test/mocks/MockERC20Staking.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

import { Setup } from "./utils/Setup.sol";

/// @title RegenStakerBase Branch Coverage
/// @notice Tests untested branches in RegenStakerBase: BLOCKSET access, compound, stakeMore, bumpEarningPower, etc.
contract RegenStakerBaseBranchCoverageTest is Setup {
    RegenStaker regenStaker;
    RegenEarningPowerCalculator calculator;
    AddressSet stakerAllowset;
    AddressSet stakerBlockset;
    AddressSet allocationMechanismAllowset;
    MockERC20Staking stakeToken;

    address public constant ADMIN = address(0xAD);
    address public staker1;
    address public staker2;
    address public blockedStaker;

    function setUp() public {
        staker1 = makeAddr("staker1");
        staker2 = makeAddr("staker2");
        blockedStaker = makeAddr("blockedStaker");

        vm.startPrank(ADMIN);

        stakeToken = new MockERC20Staking(18);
        stakerAllowset = new AddressSet();
        stakerBlockset = new AddressSet();
        allocationMechanismAllowset = new AddressSet();

        calculator = _deployCalculator(
            ADMIN,
            IAddressSet(address(stakerAllowset)),
            IAddressSet(address(stakerBlockset)),
            AccessMode.NONE
        );

        // reward = stake for compound tests
        regenStaker = _deployRegenStaker(
            RegenCfg({
                rewardsToken: IERC20(address(stakeToken)),
                stakeToken: IERC20(address(stakeToken)),
                earningPowerCalculator: calculator,
                maxBumpTip: 1e18,
                admin: ADMIN,
                rewardDuration: uint128(7 days),
                minimumStakeAmount: 0,
                stakerAllowset: IAddressSet(address(stakerAllowset)),
                stakerBlockset: IAddressSet(address(stakerBlockset)),
                stakerAccessMode: AccessMode.NONE,
                allocationMechanismAllowset: IAddressSet(address(allocationMechanismAllowset))
            })
        );

        regenStaker.setRewardNotifier(ADMIN, true);
        vm.stopPrank();
    }

    // === Helper: stake tokens ===
    function _stakeFor(address user, uint256 amount) internal returns (Staker.DepositIdentifier depositId) {
        stakeToken.mint(user, amount);
        vm.startPrank(user);
        stakeToken.approve(address(regenStaker), amount);
        depositId = regenStaker.stake(amount, user, user);
        vm.stopPrank();
    }

    // === Helper: notify rewards ===
    function _notifyReward(uint256 amount) internal {
        stakeToken.mint(address(regenStaker), amount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(amount);
    }

    // ===== BLOCKSET mode: _checkStakerAccess reverts when blocked =====

    function test_blocksetMode_stakeReverts_whenBlocked() public {
        vm.startPrank(ADMIN);
        regenStaker.setAccessMode(AccessMode.BLOCKSET);
        stakerBlockset.add(blockedStaker);
        vm.stopPrank();

        stakeToken.mint(blockedStaker, 1000e18);
        vm.startPrank(blockedStaker);
        stakeToken.approve(address(regenStaker), 1000e18);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.StakerBlocked.selector, blockedStaker));
        regenStaker.stake(1000e18, blockedStaker, blockedStaker);
        vm.stopPrank();
    }

    function test_blocksetMode_stakeSucceeds_whenNotBlocked() public {
        vm.startPrank(ADMIN);
        regenStaker.setAccessMode(AccessMode.BLOCKSET);
        vm.stopPrank();

        // staker1 not in blockset, should succeed
        _stakeFor(staker1, 1000e18);
    }

    // ===== ALLOWSET mode: _checkStakerAccess reverts when not in allowset =====

    function test_allowsetMode_stakeReverts_whenNotAllowed() public {
        vm.startPrank(ADMIN);
        regenStaker.setAccessMode(AccessMode.ALLOWSET);
        vm.stopPrank();

        stakeToken.mint(staker1, 1000e18);
        vm.startPrank(staker1);
        stakeToken.approve(address(regenStaker), 1000e18);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.StakerNotAllowed.selector, staker1));
        regenStaker.stake(1000e18, staker1, staker1);
        vm.stopPrank();
    }

    function test_allowsetMode_stakeSucceeds_whenAllowed() public {
        vm.startPrank(ADMIN);
        regenStaker.setAccessMode(AccessMode.ALLOWSET);
        stakerAllowset.add(staker1);
        vm.stopPrank();

        _stakeFor(staker1, 1000e18);
    }

    // ===== _stakeMore: BLOCKSET check on deposit.owner =====

    function test_stakeMore_blocksetMode_revertsWhenOwnerBlocked() public {
        // Stake first in NONE mode
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);

        // Switch to BLOCKSET and block staker1
        vm.startPrank(ADMIN);
        regenStaker.setAccessMode(AccessMode.BLOCKSET);
        stakerBlockset.add(staker1);
        vm.stopPrank();

        stakeToken.mint(staker1, 500e18);
        vm.startPrank(staker1);
        stakeToken.approve(address(regenStaker), 500e18);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.StakerBlocked.selector, staker1));
        regenStaker.stakeMore(depositId, 500e18);
        vm.stopPrank();
    }

    // ===== _stake: zero amount reverts =====

    function test_stake_zeroAmount_reverts() public {
        stakeToken.mint(staker1, 1000e18);
        vm.startPrank(staker1);
        stakeToken.approve(address(regenStaker), 1000e18);
        vm.expectRevert(RegenStakerBase.ZeroOperation.selector);
        regenStaker.stake(0, staker1, staker1);
        vm.stopPrank();
    }

    // ===== _stakeMore: zero amount reverts =====

    function test_stakeMore_zeroAmount_reverts() public {
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);

        vm.prank(staker1);
        vm.expectRevert(RegenStakerBase.ZeroOperation.selector);
        regenStaker.stakeMore(depositId, 0);
    }

    // ===== _withdraw: zero amount reverts =====

    function test_withdraw_zeroAmount_reverts() public {
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);

        vm.prank(staker1);
        vm.expectRevert(RegenStakerBase.ZeroOperation.selector);
        regenStaker.withdraw(depositId, 0);
    }

    // ===== Minimum stake amount boundary =====

    function test_minimumStake_exactBoundary_succeeds() public {
        vm.prank(ADMIN);
        regenStaker.setMinimumStakeAmount(100e18);

        // Stake exactly the minimum
        _stakeFor(staker1, 100e18);
    }

    function test_minimumStake_belowBoundary_reverts() public {
        vm.prank(ADMIN);
        regenStaker.setMinimumStakeAmount(100e18);

        stakeToken.mint(staker1, 99e18);
        vm.startPrank(staker1);
        stakeToken.approve(address(regenStaker), 99e18);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.MinimumStakeAmountNotMet.selector, 100e18, 99e18));
        regenStaker.stake(99e18, staker1, staker1);
        vm.stopPrank();
    }

    function test_minimumStake_withdrawToZero_succeeds() public {
        vm.prank(ADMIN);
        regenStaker.setMinimumStakeAmount(100e18);

        Staker.DepositIdentifier depositId = _stakeFor(staker1, 100e18);

        // Withdraw all - should succeed (zero balance exception)
        vm.prank(staker1);
        regenStaker.withdraw(depositId, 100e18);
    }

    function test_minimumStake_withdrawBelowMinimum_reverts() public {
        vm.prank(ADMIN);
        regenStaker.setMinimumStakeAmount(100e18);

        Staker.DepositIdentifier depositId = _stakeFor(staker1, 200e18);

        // Withdraw to 50 (below minimum, not zero) - should revert
        vm.prank(staker1);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.MinimumStakeAmountNotMet.selector, 100e18, 50e18));
        regenStaker.withdraw(depositId, 150e18);
    }

    // ===== compoundRewards: zero unclaimed returns 0 =====

    function test_compound_zeroUnclaimed_returnsZero() public {
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);

        // No rewards notified, so unclaimed = 0
        vm.prank(staker1);
        uint256 compounded = regenStaker.compoundRewards(depositId);
        assertEq(compounded, 0, "Should return 0 when no unclaimed rewards");
    }

    // ===== compoundRewards: not claimer or owner reverts =====

    function test_compound_notClaimerOrOwner_reverts() public {
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);

        vm.prank(staker2);
        vm.expectRevert(
            abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not claimer or owner"), staker2)
        );
        regenStaker.compoundRewards(depositId);
    }

    // ===== compoundRewards: BLOCKSET check on deposit owner =====

    function test_compound_blocksetMode_revertsWhenOwnerBlocked() public {
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);
        _notifyReward(10000e18);

        // Advance time to accrue rewards
        vm.warp(block.timestamp + 1 days);

        // Block staker1
        vm.startPrank(ADMIN);
        regenStaker.setAccessMode(AccessMode.BLOCKSET);
        stakerBlockset.add(staker1);
        vm.stopPrank();

        vm.prank(staker1);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.StakerBlocked.selector, staker1));
        regenStaker.compoundRewards(depositId);
    }

    // ===== compoundRewards: ALLOWSET check on deposit owner =====

    function test_compound_allowsetMode_revertsWhenOwnerNotAllowed() public {
        // Must stake in NONE mode first since staker1 won't be in allowset
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);
        _notifyReward(10000e18);
        vm.warp(block.timestamp + 1 days);

        // Switch to ALLOWSET mode without adding staker1
        vm.prank(ADMIN);
        regenStaker.setAccessMode(AccessMode.ALLOWSET);

        vm.prank(staker1);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.StakerNotAllowed.selector, staker1));
        regenStaker.compoundRewards(depositId);
    }

    // ===== Paused: stake reverts =====

    function test_paused_stakeReverts() public {
        vm.prank(ADMIN);
        regenStaker.pause();

        stakeToken.mint(staker1, 1000e18);
        vm.startPrank(staker1);
        stakeToken.approve(address(regenStaker), 1000e18);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        regenStaker.stake(1000e18, staker1, staker1);
        vm.stopPrank();
    }

    // ===== Paused: withdraw still works =====

    function test_paused_withdrawStillWorks() public {
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);

        vm.prank(ADMIN);
        regenStaker.pause();

        vm.prank(staker1);
        regenStaker.withdraw(depositId, 1000e18);
    }

    // ===== Paused: compound reverts =====

    function test_paused_compoundReverts() public {
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);

        vm.prank(ADMIN);
        regenStaker.pause();

        vm.prank(staker1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        regenStaker.compoundRewards(depositId);
    }

    // ===== setRewardDuration: during active reward reverts =====

    function test_setRewardDuration_duringActiveReward_reverts() public {
        _stakeFor(staker1, 1000e18);
        _notifyReward(10000e18);

        vm.prank(ADMIN);
        vm.expectRevert(RegenStakerBase.CannotChangeRewardDurationDuringActiveReward.selector);
        regenStaker.setRewardDuration(uint128(14 days));
    }

    // ===== setRewardDuration: invalid duration reverts =====

    function test_setRewardDuration_tooShort_reverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.InvalidRewardDuration.selector, 1 days));
        regenStaker.setRewardDuration(uint128(1 days));
    }

    function test_setRewardDuration_tooLong_reverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.InvalidRewardDuration.selector, 3001 days));
        regenStaker.setRewardDuration(uint128(3001 days));
    }

    // ===== setRewardDuration: same value NoOperation =====

    function test_setRewardDuration_sameValue_reverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(RegenStakerBase.NoOperation.selector);
        regenStaker.setRewardDuration(uint128(7 days));
    }

    // ===== setMinimumStakeAmount: raise during active reward reverts =====

    function test_setMinimumStake_raiseDuringActiveReward_reverts() public {
        _stakeFor(staker1, 1000e18);
        _notifyReward(10000e18);

        vm.prank(ADMIN);
        vm.expectRevert(RegenStakerBase.CannotRaiseMinimumStakeAmountDuringActiveReward.selector);
        regenStaker.setMinimumStakeAmount(100e18);
    }

    // ===== setMinimumStakeAmount: lower during active reward succeeds =====

    function test_setMinimumStake_lowerDuringActiveReward_succeeds() public {
        vm.prank(ADMIN);
        regenStaker.setMinimumStakeAmount(100e18);

        _stakeFor(staker1, 1000e18);
        _notifyReward(10000e18);

        // Lowering is allowed during active reward
        vm.prank(ADMIN);
        regenStaker.setMinimumStakeAmount(50e18);
        assertEq(regenStaker.minimumStakeAmount(), 50e18);
    }

    // ===== setMaxBumpTip: raise during active reward reverts =====

    function test_setMaxBumpTip_raiseDuringActiveReward_reverts() public {
        _stakeFor(staker1, 1000e18);
        _notifyReward(10000e18);

        vm.prank(ADMIN);
        vm.expectRevert(RegenStakerBase.CannotRaiseMaxBumpTipDuringActiveReward.selector);
        regenStaker.setMaxBumpTip(2e18);
    }

    // ===== setMaxBumpTip: lower during active reward succeeds =====

    function test_setMaxBumpTip_lowerDuringActiveReward_succeeds() public {
        _stakeFor(staker1, 1000e18);
        _notifyReward(10000e18);

        vm.prank(ADMIN);
        regenStaker.setMaxBumpTip(0.5e18);
    }

    // ===== setStakerAllowset: same value NoOperation =====

    function test_setStakerAllowset_sameValue_reverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(RegenStakerBase.NoOperation.selector);
        regenStaker.setStakerAllowset(IAddressSet(address(stakerAllowset)));
    }

    // ===== setStakerAllowset: same as mechanism allowset reverts =====

    function test_setStakerAllowset_sameAsMechanism_reverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(Staker.Staker__InvalidAddress.selector);
        regenStaker.setStakerAllowset(IAddressSet(address(allocationMechanismAllowset)));
    }

    // ===== setStakerBlockset: same value NoOperation =====

    function test_setStakerBlockset_sameValue_reverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(RegenStakerBase.NoOperation.selector);
        regenStaker.setStakerBlockset(IAddressSet(address(stakerBlockset)));
    }

    // ===== setStakerBlockset: same as mechanism allowset reverts =====

    function test_setStakerBlockset_sameAsMechanism_reverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(Staker.Staker__InvalidAddress.selector);
        regenStaker.setStakerBlockset(IAddressSet(address(allocationMechanismAllowset)));
    }

    // ===== setAccessMode: same mode NoOperation =====

    function test_setAccessMode_sameMode_reverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(RegenStakerBase.NoOperation.selector);
        regenStaker.setAccessMode(AccessMode.NONE);
    }

    // ===== setAllocationMechanismAllowset: same value NoOperation =====

    function test_setAllocationMechanismAllowset_sameValue_reverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(RegenStakerBase.NoOperation.selector);
        regenStaker.setAllocationMechanismAllowset(IAddressSet(address(allocationMechanismAllowset)));
    }

    // ===== setAllocationMechanismAllowset: address(0) reverts =====

    function test_setAllocationMechanismAllowset_zero_reverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(RegenStakerBase.DisablingAllocationMechanismAllowsetNotAllowed.selector);
        regenStaker.setAllocationMechanismAllowset(IAddressSet(address(0)));
    }

    // ===== setAllocationMechanismAllowset: same as staker allowset reverts =====

    function test_setAllocationMechanismAllowset_sameAsStaker_reverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(Staker.Staker__InvalidAddress.selector);
        regenStaker.setAllocationMechanismAllowset(IAddressSet(address(stakerAllowset)));
    }

    // ===== setAllocationMechanismAllowset: same as staker blockset reverts =====

    function test_setAllocationMechanismAllowset_sameAsBlockset_reverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(Staker.Staker__InvalidAddress.selector);
        regenStaker.setAllocationMechanismAllowset(IAddressSet(address(stakerBlockset)));
    }

    // ===== pause/unpause =====

    function test_pause_notAdmin_reverts() public {
        vm.prank(staker1);
        vm.expectRevert();
        regenStaker.pause();
    }

    function test_unpause_notAdmin_reverts() public {
        vm.prank(ADMIN);
        regenStaker.pause();

        vm.prank(staker1);
        vm.expectRevert();
        regenStaker.unpause();
    }

    function test_unpause_succeeds() public {
        vm.prank(ADMIN);
        regenStaker.pause();

        vm.prank(ADMIN);
        regenStaker.unpause();

        // Can now stake
        _stakeFor(staker1, 1000e18);
    }

    // ===== notifyRewardAmount during existing reward (carry-over path) =====

    function test_notifyReward_carryOver_path() public {
        _stakeFor(staker1, 1000e18);
        _notifyReward(10000e18);

        // Advance halfway
        vm.warp(block.timestamp + 3.5 days);

        // Notify more rewards (should carry over remaining)
        _notifyReward(5000e18);

        // Verify cumulative rewards include the carry-over path update
        assertEq(regenStaker.totalRewards(), 15000e18);
    }

    // ===== _checkpointGlobalReward: totalEarningPower == 0 extends rewardEndTime =====

    function test_checkpointGlobalReward_zeroEarningPower_extendsEndTime() public {
        // Notify reward with no stakers (totalEarningPower = 0)
        stakeToken.mint(address(regenStaker), 10000e18);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(10000e18);

        uint256 endTimeBefore = regenStaker.rewardEndTime();

        // Advance time - since no earning power, end time should extend
        vm.warp(block.timestamp + 1 days);

        // Trigger checkpoint via a stake
        _stakeFor(staker1, 1000e18);

        uint256 endTimeAfter = regenStaker.rewardEndTime();
        assertGt(endTimeAfter, endTimeBefore, "End time should have extended with zero earning power");
    }

    // ===== RegenStaker: predictSurrogateAddress =====

    function test_predictSurrogateAddress_returnsConsistentAddress() public view {
        address predicted = regenStaker.predictSurrogateAddress(staker1);
        assertTrue(predicted != address(0), "Predicted address should not be zero");

        // Calling again should give same result
        address predicted2 = regenStaker.predictSurrogateAddress(staker1);
        assertEq(predicted, predicted2, "Should be deterministic");
    }

    // ===== RegenStaker: getDelegateeFromSurrogate =====

    function test_getDelegateeFromSurrogate_returnsCorrectDelegatee() public {
        // Stake to create a surrogate for staker1
        _stakeFor(staker1, 1000e18);

        // The surrogate should delegate to staker1
        address surrogate = address(regenStaker.surrogates(staker1));
        assertTrue(surrogate != address(0), "Surrogate should exist after staking");

        address delegatee = regenStaker.getDelegateeFromSurrogate(surrogate);
        assertEq(delegatee, staker1, "Surrogate should delegate to staker1");
    }

    // ===== RegenStaker: predictSurrogateAddress matches actual =====

    function test_predictSurrogateAddress_matchesDeployed() public {
        address predicted = regenStaker.predictSurrogateAddress(staker1);

        // Stake to deploy surrogate
        _stakeFor(staker1, 1000e18);

        address actual = address(regenStaker.surrogates(staker1));
        assertEq(predicted, actual, "Predicted address should match deployed surrogate");
    }

    // ===== InsufficientRewardBalance =====

    function test_notifyReward_insufficientBalance_reverts() public {
        // Don't mint any tokens - contract has no balance
        vm.prank(ADMIN);
        vm.expectRevert();
        regenStaker.notifyRewardAmount(10000e18);
    }

    // ===== _validateAndGetRequiredBalance carry-over =====

    function test_notifyReward_carryOverValidation() public {
        _stakeFor(staker1, 1000e18);
        _notifyReward(10000e18);

        // Claim some rewards
        vm.warp(block.timestamp + 3 days);
        Staker.DepositIdentifier depositId = Staker.DepositIdentifier.wrap(0);
        vm.prank(staker1);
        regenStaker.claimReward(depositId);

        // Now notify more - should account for carry-over
        stakeToken.mint(address(regenStaker), 5000e18);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(5000e18);
    }

    // =====================================================================
    // Phase 2: Additional branch coverage for RegenStakerBase
    // Targets: bumpEarningPower, _alterDelegatee, _checkpointGlobalReward,
    //          _notifyRewardAmountWithCustomDuration edge cases,
    //          contribute zero-amount, _consumeRewards zero path
    // =====================================================================

    // ===== _alterDelegatee: covers the uncovered function =====

    function test_alterDelegatee_succeeds() public {
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);

        // staker1 changes delegatee to staker2
        vm.prank(staker1);
        regenStaker.alterDelegatee(depositId, staker2);

        // Verify delegatee changed
        (, , , address delegatee, , , ) = regenStaker.deposits(depositId);
        assertEq(delegatee, staker2, "Delegatee should be staker2");
    }

    function test_alterDelegatee_whenPaused_reverts() public {
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);

        vm.prank(ADMIN);
        regenStaker.pause();

        vm.prank(staker1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        regenStaker.alterDelegatee(depositId, staker2);
    }

    // ===== bumpEarningPower: covers the uncovered function and all its branches =====

    function test_bumpEarningPower_invalidTip_reverts() public {
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);

        // maxBumpTip is 1e18, so requesting more reverts
        vm.prank(staker2);
        vm.expectRevert(Staker.Staker__InvalidTip.selector);
        regenStaker.bumpEarningPower(depositId, staker2, 2e18);
    }

    function test_bumpEarningPower_unqualified_reverts() public {
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);

        // The RegenEarningPowerCalculator returns (balance, balance != oldEP).
        // After staking, deposit.earningPower == balance, so getNewEarningPower returns
        // (balance, false) since newEP == oldEP. This means !_isQualifiedForBump = true.
        vm.prank(staker2);
        vm.expectRevert(abi.encodeWithSelector(Staker.Staker__Unqualified.selector, 1000e18));
        regenStaker.bumpEarningPower(depositId, staker2, 0);
    }

    function test_bumpEarningPower_downward_withTip_succeeds() public {
        // Setup: stake in NONE mode, notify rewards, accrue
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);
        _notifyReward(10000e18);
        vm.warp(block.timestamp + 3 days);

        // Block staker1 so earning power drops to 0
        vm.startPrank(ADMIN);
        regenStaker.setAccessMode(AccessMode.BLOCKSET);
        calculator.setAccessMode(AccessMode.BLOCKSET);
        stakerBlockset.add(staker1);

        // The blockset used by calculator is a different one, we need to add staker1 there
        vm.stopPrank();

        // We need the calculator's blockset - let's just use vm.mockCall
        // Mock getNewEarningPower to return (0, true) for staker1
        vm.mockCall(
            address(calculator),
            abi.encodeWithSelector(
                IEarningPowerCalculator.getNewEarningPower.selector,
                uint256(1000e18), // balance
                staker1, // owner
                staker1, // delegatee
                uint256(1000e18) // old earning power
            ),
            abi.encode(uint256(0), true)
        );

        // Also mock getEarningPower for checkpoint calls
        vm.mockCall(
            address(calculator),
            abi.encodeWithSelector(
                IEarningPowerCalculator.getEarningPower.selector,
                uint256(1000e18), // balance
                staker1, // owner
                staker1 // delegatee
            ),
            abi.encode(uint256(0))
        );

        // Bump earning power down - tip should be capped to unclaimed rewards
        // L991: _requestedTip > _unclaimedRewards path (tip capped)
        // L1012: tipToPay > 0 path
        address tipReceiver = makeAddr("tipReceiver");
        vm.prank(staker2);
        regenStaker.bumpEarningPower(depositId, tipReceiver, 0.5e18);

        vm.clearMockedCalls();

        // Verify earning power was updated
        (, , uint96 earningPower, , , , ) = regenStaker.deposits(depositId);
        assertEq(earningPower, 0, "Earning power should be 0 after block");
    }

    function test_bumpEarningPower_upward_insufficientRewards_reverts() public {
        // Stake but don't notify rewards - no unclaimed rewards
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);

        // Mock getNewEarningPower to return higher EP and qualified
        vm.mockCall(
            address(calculator),
            abi.encodeWithSelector(
                IEarningPowerCalculator.getNewEarningPower.selector,
                uint256(1000e18),
                staker1,
                staker1,
                uint256(1000e18)
            ),
            abi.encode(uint256(2000e18), true)
        );

        // L986: _newEarningPower > deposit.earningPower && _unclaimedRewards < _requestedTip
        vm.prank(staker2);
        vm.expectRevert(Staker.Staker__InsufficientUnclaimedRewards.selector);
        regenStaker.bumpEarningPower(depositId, staker2, 0.5e18);

        vm.clearMockedCalls();
    }

    function test_bumpEarningPower_zeroTip_succeeds() public {
        // Stake and get some rewards
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);
        _notifyReward(10000e18);
        vm.warp(block.timestamp + 3 days);

        // Mock getNewEarningPower to return lower EP (simulating block)
        vm.mockCall(
            address(calculator),
            abi.encodeWithSelector(
                IEarningPowerCalculator.getNewEarningPower.selector,
                uint256(1000e18),
                staker1,
                staker1,
                uint256(1000e18)
            ),
            abi.encode(uint256(500e18), true)
        );

        vm.mockCall(
            address(calculator),
            abi.encodeWithSelector(
                IEarningPowerCalculator.getEarningPower.selector,
                uint256(1000e18),
                staker1,
                staker1
            ),
            abi.encode(uint256(500e18))
        );

        // L1012: tipToPay == 0 path (false branch)
        // L807: _consumeRewards with amount=0 (false branch)
        vm.prank(staker2);
        regenStaker.bumpEarningPower(depositId, staker2, 0);

        vm.clearMockedCalls();

        (, , uint96 earningPower, , , , ) = regenStaker.deposits(depositId);
        assertEq(earningPower, 500e18, "Earning power should be updated to 500e18");
    }

    function test_bumpEarningPower_whenPaused_reverts() public {
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);

        vm.prank(ADMIN);
        regenStaker.pause();

        vm.prank(staker2);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        regenStaker.bumpEarningPower(depositId, staker2, 0);
    }

    // ===== _checkpointGlobalReward: elapsed == 0 path (false branch of outer if) =====

    function test_checkpointGlobalReward_noElapsed_noop() public {
        _stakeFor(staker1, 1000e18);
        _notifyReward(10000e18);

        // Do two operations in the same block (elapsed=0 on second)
        // The first stake triggers checkpoint. Staking more in the same block
        // triggers another checkpoint with elapsed=0.
        stakeToken.mint(staker1, 500e18);
        vm.startPrank(staker1);
        stakeToken.approve(address(regenStaker), 500e18);
        Staker.DepositIdentifier depositId = Staker.DepositIdentifier.wrap(0);
        regenStaker.stakeMore(depositId, 500e18);
        vm.stopPrank();

        // If we got here without revert, the false branch of elapsed>0 was hit
    }

    // ===== _checkpointGlobalReward: scaledRewardRate == 0 path =====

    function test_checkpointGlobalReward_zeroRewardRate_noop() public {
        // Stake without notifying rewards (scaledRewardRate = 0)
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);

        vm.warp(block.timestamp + 1 days);

        // Staking more triggers checkpoint with scaledRewardRate=0
        stakeToken.mint(staker1, 500e18);
        vm.startPrank(staker1);
        stakeToken.approve(address(regenStaker), 500e18);
        regenStaker.stakeMore(depositId, 500e18);
        vm.stopPrank();
    }

    // ===== _notifyRewardAmountWithCustomDuration: scaledRewardRate < SCALE_FACTOR =====

    function test_notifyReward_tooSmallAmount_reverts() public {
        _stakeFor(staker1, 1000e18);

        // Notify a tiny amount that would result in scaledRewardRate < SCALE_FACTOR
        // scaledRewardRate = (amount * 1e36) / rewardDuration
        // For 7 days = 604800 seconds, we need amount * 1e36 / 604800 < 1e36
        // So amount < 604800 (about 604800 wei)
        uint256 tinyAmount = 1; // 1 wei
        stakeToken.mint(address(regenStaker), tinyAmount);
        vm.prank(ADMIN);
        vm.expectRevert(Staker.Staker__InvalidRewardRate.selector);
        regenStaker.notifyRewardAmount(tinyAmount);
    }

    // ===== _notifyRewardAmountWithCustomDuration: not reward notifier =====

    function test_notifyReward_notNotifier_reverts() public {
        stakeToken.mint(address(regenStaker), 10000e18);

        vm.prank(staker1);
        vm.expectRevert(abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not notifier"), staker1));
        regenStaker.notifyRewardAmount(10000e18);
    }

    // ===== _stakeMore: ALLOWSET check on deposit.owner =====

    function test_stakeMore_allowsetMode_revertsWhenOwnerNotAllowed() public {
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);

        vm.prank(ADMIN);
        regenStaker.setAccessMode(AccessMode.ALLOWSET);

        stakeToken.mint(staker1, 500e18);
        vm.startPrank(staker1);
        stakeToken.approve(address(regenStaker), 500e18);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.StakerNotAllowed.selector, staker1));
        regenStaker.stakeMore(depositId, 500e18);
        vm.stopPrank();
    }

    // ===== Paused: stakeMore reverts =====

    function test_paused_stakeMoreReverts() public {
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);

        vm.prank(ADMIN);
        regenStaker.pause();

        stakeToken.mint(staker1, 500e18);
        vm.startPrank(staker1);
        stakeToken.approve(address(regenStaker), 500e18);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        regenStaker.stakeMore(depositId, 500e18);
        vm.stopPrank();
    }

    // ===== Paused: claimReward reverts =====

    function test_paused_claimRewardReverts() public {
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);
        _notifyReward(10000e18);
        vm.warp(block.timestamp + 1 days);

        vm.prank(ADMIN);
        regenStaker.pause();

        vm.prank(staker1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        regenStaker.claimReward(depositId);
    }

    // ===== Paused: alterClaimer reverts =====

    function test_paused_alterClaimerReverts() public {
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);

        vm.prank(ADMIN);
        regenStaker.pause();

        vm.prank(staker1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        regenStaker.alterClaimer(depositId, staker2);
    }

    // ===== setRewardDuration: not admin reverts =====

    function test_setRewardDuration_notAdmin_reverts() public {
        vm.prank(staker1);
        vm.expectRevert(abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not admin"), staker1));
        regenStaker.setRewardDuration(uint128(14 days));
    }

    // ===== _stakeMore: minimumStake check after stakeMore =====

    function test_stakeMore_resultBelowMinimum_reverts() public {
        // Stake 200e18 with no minimum
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 200e18);

        // Set minimum to 500e18 (after staking, so existing deposit is grandfathered)
        vm.prank(ADMIN);
        regenStaker.setMinimumStakeAmount(500e18);

        // StakeMore 50e18 => balance 250e18 < 500e18 minimum => should revert
        stakeToken.mint(staker1, 50e18);
        vm.startPrank(staker1);
        stakeToken.approve(address(regenStaker), 50e18);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.MinimumStakeAmountNotMet.selector, 500e18, 250e18));
        regenStaker.stakeMore(depositId, 50e18);
        vm.stopPrank();
    }

    // ===== Constructor: REWARD_TOKEN != STAKE_TOKEN branch =====
    // (This tests the false branch of L301 in the constructor)

    function test_constructor_differentRewardAndStakeToken() public {
        MockERC20 rewardToken = new MockERC20(18);

        vm.prank(ADMIN);
        RegenStaker differentTokenStaker = new RegenStaker(
            IERC20(address(rewardToken)), // different reward token
            stakeToken,
            calculator,
            1e18,
            ADMIN,
            uint128(7 days),
            0,
            IAddressSet(address(stakerAllowset)),
            IAddressSet(address(stakerBlockset)),
            AccessMode.NONE,
            IAddressSet(address(allocationMechanismAllowset))
        );

        // Verify compounding not supported with different tokens
        stakeToken.mint(staker1, 1000e18);
        vm.startPrank(staker1);
        stakeToken.approve(address(differentTokenStaker), 1000e18);
        Staker.DepositIdentifier depositId = differentTokenStaker.stake(1000e18, staker1, staker1);
        vm.stopPrank();

        vm.prank(staker1);
        vm.expectRevert(RegenStakerBase.CompoundingNotSupported.selector);
        differentTokenStaker.compoundRewards(depositId);
    }

    // ===== View getter function coverage =====

    function test_viewGetters_stakerBlockset() public view {
        IAddressSet result = regenStaker.stakerBlockset();
        assertEq(address(result), address(stakerBlockset));
    }

    function test_viewGetters_stakerAccessMode() public view {
        AccessMode mode = regenStaker.stakerAccessMode();
        assertEq(uint8(mode), uint8(AccessMode.NONE));
    }

    // ===== Constructor: _initializeSharedState validation branches =====

    function test_constructor_invalidRewardDuration_tooShort_reverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.InvalidRewardDuration.selector, uint256(1 days)));
        new RegenStaker(
            IERC20(address(stakeToken)),
            stakeToken,
            calculator,
            1e18,
            ADMIN,
            uint128(1 days), // too short
            0,
            IAddressSet(address(stakerAllowset)),
            IAddressSet(address(stakerBlockset)),
            AccessMode.NONE,
            IAddressSet(address(allocationMechanismAllowset))
        );
    }

    function test_constructor_invalidRewardDuration_tooLong_reverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.InvalidRewardDuration.selector, uint256(3001 days)));
        new RegenStaker(
            IERC20(address(stakeToken)),
            stakeToken,
            calculator,
            1e18,
            ADMIN,
            uint128(3001 days), // too long
            0,
            IAddressSet(address(stakerAllowset)),
            IAddressSet(address(stakerBlockset)),
            AccessMode.NONE,
            IAddressSet(address(allocationMechanismAllowset))
        );
    }

    function test_constructor_zeroAllocationMechanismAllowset_reverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(RegenStakerBase.DisablingAllocationMechanismAllowsetNotAllowed.selector);
        new RegenStaker(
            IERC20(address(stakeToken)),
            stakeToken,
            calculator,
            1e18,
            ADMIN,
            uint128(7 days),
            0,
            IAddressSet(address(stakerAllowset)),
            IAddressSet(address(stakerBlockset)),
            AccessMode.NONE,
            IAddressSet(address(0)) // zero address
        );
    }

    function test_constructor_allocationMechSameAsStakerAllowset_reverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(Staker.Staker__InvalidAddress.selector);
        new RegenStaker(
            IERC20(address(stakeToken)),
            stakeToken,
            calculator,
            1e18,
            ADMIN,
            uint128(7 days),
            0,
            IAddressSet(address(stakerAllowset)),
            IAddressSet(address(stakerBlockset)),
            AccessMode.NONE,
            IAddressSet(address(stakerAllowset)) // same as staker allowset
        );
    }

    function test_constructor_allocationMechSameAsStakerBlockset_reverts() public {
        vm.prank(ADMIN);
        vm.expectRevert(Staker.Staker__InvalidAddress.selector);
        new RegenStaker(
            IERC20(address(stakeToken)),
            stakeToken,
            calculator,
            1e18,
            ADMIN,
            uint128(7 days),
            0,
            IAddressSet(address(stakerAllowset)),
            IAddressSet(address(stakerBlockset)),
            AccessMode.NONE,
            IAddressSet(address(stakerBlockset)) // same as staker blockset
        );
    }

    // ===== bumpEarningPower: upward bump with tip that succeeds =====

    function test_bumpEarningPower_upward_withTip_succeeds() public {
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);
        _notifyReward(10000e18);
        vm.warp(block.timestamp + 3 days);

        // Mock getNewEarningPower to return higher EP and qualified
        vm.mockCall(
            address(calculator),
            abi.encodeWithSelector(
                IEarningPowerCalculator.getNewEarningPower.selector,
                uint256(1000e18),
                staker1,
                staker1,
                uint256(1000e18)
            ),
            abi.encode(uint256(2000e18), true)
        );

        vm.mockCall(
            address(calculator),
            abi.encodeWithSelector(
                IEarningPowerCalculator.getEarningPower.selector,
                uint256(1000e18),
                staker1,
                staker1
            ),
            abi.encode(uint256(2000e18))
        );

        // Upward bump with small tip (L986 false branch: newEP > oldEP but unclaimed >= tip)
        // L1012 true branch: tipToPay > 0
        address tipReceiver = makeAddr("tipReceiver2");
        vm.prank(staker2);
        regenStaker.bumpEarningPower(depositId, tipReceiver, 0.1e18);

        vm.clearMockedCalls();

        uint256 tipBalance = stakeToken.balanceOf(tipReceiver);
        assertEq(tipBalance, 0.1e18, "Tip receiver should have received tip");

        (, , uint96 earningPower, , , , ) = regenStaker.deposits(depositId);
        assertEq(earningPower, 2000e18, "Earning power should be updated to 2000e18");
    }

    // ===== bumpEarningPower: downward bump with tip capped to unclaimed =====

    function test_bumpEarningPower_downward_tipCapped() public {
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);
        _notifyReward(10000e18);
        // Small time passage to accrue very few rewards
        vm.warp(block.timestamp + 100);

        // Mock getNewEarningPower to return lower EP (downward bump)
        vm.mockCall(
            address(calculator),
            abi.encodeWithSelector(
                IEarningPowerCalculator.getNewEarningPower.selector,
                uint256(1000e18),
                staker1,
                staker1,
                uint256(1000e18)
            ),
            abi.encode(uint256(500e18), true)
        );

        vm.mockCall(
            address(calculator),
            abi.encodeWithSelector(
                IEarningPowerCalculator.getEarningPower.selector,
                uint256(1000e18),
                staker1,
                staker1
            ),
            abi.encode(uint256(500e18))
        );

        // Request tip of 1e18, but unclaimed might be less
        // L991: _requestedTip > _unclaimedRewards => tipToPay = _unclaimedRewards
        address tipReceiver = makeAddr("tipReceiver3");
        vm.prank(staker2);
        regenStaker.bumpEarningPower(depositId, tipReceiver, 1e18);

        vm.clearMockedCalls();
    }

    // ===== setRewardDuration: valid change after reward ends =====

    function test_setRewardDuration_validChange_succeeds() public {
        _stakeFor(staker1, 1000e18);
        _notifyReward(10000e18);

        // Warp past reward end
        vm.warp(block.timestamp + 8 days);

        vm.prank(ADMIN);
        regenStaker.setRewardDuration(uint128(14 days));
        assertEq(regenStaker.rewardDuration(), 14 days);
    }

    // ===== contribute: address(0) mechanism reverts =====

    function test_contribute_addressZeroMechanism_reverts() public {
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);

        vm.prank(staker1);
        vm.expectRevert();
        regenStaker.contribute(depositId, address(0), 1e18, block.timestamp + 1 days, 0, bytes32(0), bytes32(0));
    }

    // ===== contribute: mechanism not in allowset reverts =====

    function test_contribute_mechanismNotInAllowset_reverts() public {
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);
        address fakeMechanism = makeAddr("fakeMechanism");

        vm.prank(staker1);
        vm.expectRevert();
        regenStaker.contribute(depositId, fakeMechanism, 1e18, block.timestamp + 1 days, 0, bytes32(0), bytes32(0));
    }

    // ===== contribute: not claimer or owner reverts =====

    function test_contribute_notClaimerOrOwner_reverts() public {
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);

        // Deploy a mock mechanism that returns the right asset
        address fakeMechanism = makeAddr("validMechanism");
        vm.mockCall(
            fakeMechanism,
            abi.encodeWithSelector(bytes4(keccak256("asset()"))),
            abi.encode(address(stakeToken))
        );
        vm.mockCall(
            address(allocationMechanismAllowset),
            abi.encodeWithSelector(IAddressSet.contains.selector, fakeMechanism),
            abi.encode(true)
        );

        vm.prank(staker2);
        vm.expectRevert(
            abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not claimer or owner"), staker2)
        );
        regenStaker.contribute(depositId, fakeMechanism, 1e18, block.timestamp + 1 days, 0, bytes32(0), bytes32(0));

        vm.clearMockedCalls();
    }

    // ===== contribute: CantAfford reverts =====

    function test_contribute_cantAfford_reverts() public {
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);
        // No rewards notified - unclaimed = 0

        address fakeMechanism = makeAddr("validMech2");
        vm.mockCall(
            fakeMechanism,
            abi.encodeWithSelector(bytes4(keccak256("asset()"))),
            abi.encode(address(stakeToken))
        );
        vm.mockCall(
            address(allocationMechanismAllowset),
            abi.encodeWithSelector(IAddressSet.contains.selector, fakeMechanism),
            abi.encode(true)
        );
        vm.mockCall(fakeMechanism, abi.encodeWithSelector(bytes4(keccak256("canSignup(address)"))), abi.encode(true));

        vm.prank(staker1);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.CantAfford.selector, 1e18, 0));
        regenStaker.contribute(depositId, fakeMechanism, 1e18, block.timestamp + 1 days, 0, bytes32(0), bytes32(0));

        vm.clearMockedCalls();
    }

    // ===== contribute: zero amount (voting registration) =====

    function test_contribute_zeroAmount_votingRegistration() public {
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);

        address fakeMechanism = makeAddr("validMech3");
        vm.mockCall(
            fakeMechanism,
            abi.encodeWithSelector(bytes4(keccak256("asset()"))),
            abi.encode(address(stakeToken))
        );
        vm.mockCall(
            address(allocationMechanismAllowset),
            abi.encodeWithSelector(IAddressSet.contains.selector, fakeMechanism),
            abi.encode(true)
        );
        vm.mockCall(fakeMechanism, abi.encodeWithSelector(bytes4(keccak256("canSignup(address)"))), abi.encode(true));
        // Mock signupOnBehalfWithSignature to succeed
        vm.mockCall(
            fakeMechanism,
            abi.encodeWithSelector(
                bytes4(keccak256("signupOnBehalfWithSignature(address,uint256,uint256,uint8,bytes32,bytes32)"))
            ),
            abi.encode()
        );

        vm.prank(staker1);
        uint256 contributed = regenStaker.contribute(
            depositId,
            fakeMechanism,
            0, // zero amount for voting registration
            block.timestamp + 1 days,
            0,
            bytes32(0),
            bytes32(0)
        );

        vm.clearMockedCalls();
        assertEq(contributed, 0, "Zero amount contribution should return 0");
    }

    // ===== contribute: owner not eligible for mechanism =====

    function test_contribute_ownerNotEligible_reverts() public {
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);
        _notifyReward(10e18);
        vm.warp(block.timestamp + 7 days);

        address fakeMechanism = makeAddr("validMech4");
        vm.mockCall(
            fakeMechanism,
            abi.encodeWithSelector(bytes4(keccak256("asset()"))),
            abi.encode(address(stakeToken))
        );
        vm.mockCall(
            address(allocationMechanismAllowset),
            abi.encodeWithSelector(IAddressSet.contains.selector, fakeMechanism),
            abi.encode(true)
        );
        // Mock canSignup to return false for the owner
        vm.mockCall(
            fakeMechanism,
            abi.encodeWithSelector(bytes4(keccak256("canSignup(address)")), staker1),
            abi.encode(false)
        );

        vm.prank(staker1);
        vm.expectRevert(
            abi.encodeWithSelector(RegenStakerBase.DepositOwnerNotEligibleForMechanism.selector, fakeMechanism, staker1)
        );
        regenStaker.contribute(depositId, fakeMechanism, 1e18, block.timestamp + 1 days, 0, bytes32(0), bytes32(0));

        vm.clearMockedCalls();
    }

    // =====================================================================
    // Phase 4: Additional branch coverage targeting uncovered BRDA entries
    // Targets: line 460 (successful setStakerBlockset), line 991 (tip capped
    // to unclaimed during downward bump), line 692 (contribute allowance check)
    // =====================================================================

    // ===== setStakerBlockset: successful change (line 460 branch 13,1) =====

    function test_setStakerBlockset_validChange_succeeds() public {
        AddressSet newBlockset = new AddressSet();

        vm.prank(ADMIN);
        regenStaker.setStakerBlockset(IAddressSet(address(newBlockset)));

        assertEq(address(regenStaker.stakerBlockset()), address(newBlockset));
    }

    // ===== bumpEarningPower: downward bump where requestedTip > unclaimedRewards (line 991) =====
    // The key: earningPower goes DOWN so the L986 check is skipped.
    // But _requestedTip > _unclaimedRewards must be true, so tipToPay = _unclaimedRewards.

    function test_bumpEarningPower_downward_tipExceedsUnclaimed() public {
        // Stake and accrue a tiny amount of rewards
        Staker.DepositIdentifier depositId = _stakeFor(staker1, 1000e18);
        _notifyReward(10000e18);
        // Very short time to accrue minimal rewards
        vm.warp(block.timestamp + 10);

        // Mock: downward bump (newEP < oldEP)
        vm.mockCall(
            address(calculator),
            abi.encodeWithSelector(
                IEarningPowerCalculator.getNewEarningPower.selector,
                uint256(1000e18),
                staker1,
                staker1,
                uint256(1000e18)
            ),
            abi.encode(uint256(100e18), true)
        );
        vm.mockCall(
            address(calculator),
            abi.encodeWithSelector(
                IEarningPowerCalculator.getEarningPower.selector,
                uint256(1000e18),
                staker1,
                staker1
            ),
            abi.encode(uint256(100e18))
        );

        // Request maxBumpTip (1e18) which is almost certainly > unclaimed after only 10 seconds
        // 10000e18 over 7 days = ~16.5e15/sec, so after 10s unclaimed ~ 0.165e18 < 1e18
        // This triggers: _requestedTip(1e18) > _unclaimedRewards(~0.165e18)
        // tipToPay is capped to _unclaimedRewards
        address tipReceiver = makeAddr("tipReceiverCapped");
        vm.prank(staker2);
        regenStaker.bumpEarningPower(depositId, tipReceiver, 1e18);

        vm.clearMockedCalls();

        // Verify tip was paid (capped amount)
        uint256 tipBalance = stakeToken.balanceOf(tipReceiver);
        assertGt(tipBalance, 0, "Tip receiver should have received capped tip");
        assertLt(tipBalance, 1e18, "Tip should be less than requested");
    }

    // ===== setAllocationMechanismAllowset: successful change =====
    // Provides a new valid address that is different from current, non-zero,
    // and different from both stakerAllowset and stakerBlockset.
    // This helps cover the success path of the AND condition at line 491.

    function test_setAllocationMechanismAllowset_validChange_succeeds() public {
        AddressSet newAllowset = new AddressSet();

        vm.prank(ADMIN);
        regenStaker.setAllocationMechanismAllowset(IAddressSet(address(newAllowset)));

        assertEq(address(regenStaker.allocationMechanismAllowset()), address(newAllowset));
    }

    // ===== setStakerAllowset: successful change (covers line 446 success path) =====

    function test_setStakerAllowset_validChange_succeeds() public {
        AddressSet newAllowset = new AddressSet();

        vm.prank(ADMIN);
        regenStaker.setStakerAllowset(IAddressSet(address(newAllowset)));

        assertEq(address(regenStaker.stakerAllowset()), address(newAllowset));
    }
}
