// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AccessMode } from "src/constants.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { Staker } from "staker/Staker.sol";
import { MockERC20Staking } from "test/mocks/MockERC20Staking.sol";
import { MockEarningPowerCalculator } from "test/mocks/MockEarningPowerCalculator.sol";
import { TokenizedAllocationMechanism } from "src/mechanisms/TokenizedAllocationMechanism.sol";
import { OctantQFMechanism } from "src/mechanisms/mechanism/OctantQFMechanism.sol";
import { AllocationConfig } from "src/mechanisms/BaseAllocationMechanism.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";

/// @title RegenStaker Advance Rewards Tests
/// @notice Tests for stakeWithAdvanceReward() and contribution split flow through contribute()
contract RegenStakerWithAdvanceRewardsTest is Test {
    RegenStaker public regenStaker;
    MockERC20Staking public token;
    MockEarningPowerCalculator public earningPowerCalculator;
    OctantQFMechanism public allocationMechanism;
    AddressSet public allocationAllowset;

    address public admin = makeAddr("admin");
    address public owner;
    uint256 private ownerPk;
    address public claimer;
    address public delegatee = makeAddr("delegatee");
    address public stranger = makeAddr("stranger");

    uint256 public constant STAKE_AMOUNT = 1000e18;
    uint256 public constant REWARD_AMOUNT = 10_000e18;
    uint128 public constant REWARD_DURATION = 30 days;

    Staker.DepositIdentifier public depositId;

    function setUp() public {
        (owner, ownerPk) = makeAddrAndKey("owner");
        claimer = makeAddr("claimer");

        token = new MockERC20Staking(18);
        earningPowerCalculator = new MockEarningPowerCalculator();

        // Deploy a real OctantQFMechanism (same token for stake/reward)
        TokenizedAllocationMechanism impl = new TokenizedAllocationMechanism();
        AllocationConfig memory cfg = AllocationConfig({
            asset: IERC20(address(token)),
            name: "AdvanceTest",
            symbol: "ST",
            votingDelay: 1,
            votingPeriod: 30 days,
            quorumShares: 1,
            timelockDelay: 1,
            gracePeriod: 100,
            owner: admin
        });
        allocationMechanism = new OctantQFMechanism(
            address(impl),
            cfg,
            1,
            1,
            IAddressSet(address(0)), // contributionAllowset (open)
            IAddressSet(address(0)), // contributionBlockset (none)
            AccessMode.NONE
        );

        vm.startPrank(admin);
        allocationAllowset = new AddressSet();
        allocationAllowset.add(address(allocationMechanism));
        vm.stopPrank();

        vm.prank(admin);
        regenStaker = new RegenStaker(
            IERC20(address(token)), // rewardsToken (same as stake token)
            token,
            earningPowerCalculator,
            0, // maxBumpTip
            admin,
            REWARD_DURATION,
            1e18, // minimumStakeAmount
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            IAddressSet(address(allocationAllowset))
        );

        // Fund owner and stake
        token.mint(owner, STAKE_AMOUNT);
        token.mint(address(regenStaker), REWARD_AMOUNT);

        vm.startPrank(owner);
        token.approve(address(regenStaker), STAKE_AMOUNT);
        depositId = regenStaker.stake(STAKE_AMOUNT, delegatee, claimer);
        vm.stopPrank();

        // Schedule rewards
        vm.startPrank(admin);
        regenStaker.setRewardNotifier(admin, true);
        regenStaker.notifyRewardAmount(REWARD_AMOUNT);
        vm.stopPrank();
    }

    // =========================================================
    // Helpers
    // =========================================================

    /// @dev Returns deposit balance from the public tuple getter
    function _depositBalance(Staker.DepositIdentifier _depositId) internal view returns (uint96 bal) {
        (bal, , , , , , ) = regenStaker.deposits(_depositId);
    }

    /// @dev Returns deposit earning power from the public tuple getter
    function _depositEarningPower(Staker.DepositIdentifier _depositId) internal view returns (uint96 ep) {
        (, , ep, , , , ) = regenStaker.deposits(_depositId);
    }

    function _contributeSignatureFor(
        address _contributor,
        uint256 _contributorPk,
        uint256 _amount
    ) internal returns (uint256 deadline, uint8 v, bytes32 r, bytes32 s) {
        bytes32 domainSeparator = TokenizedAllocationMechanism(address(allocationMechanism)).DOMAIN_SEPARATOR();
        uint256 nonce = TokenizedAllocationMechanism(address(allocationMechanism)).nonces(_contributor);
        deadline = block.timestamp + 1 days;

        bytes32 typeHash = keccak256(
            bytes("Signup(address user,address payer,uint256 deposit,uint256 nonce,uint256 deadline)")
        );
        bytes32 structHash = keccak256(
            abi.encode(typeHash, _contributor, address(regenStaker), _amount, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (v, r, s) = vm.sign(_contributorPk, digest);
    }

    // =========================================================
    // stakeWithAdvanceReward
    // =========================================================

    function test_stakeWithAdvanceReward_stakesAndEarmarksInOneCall() public {
        address bob = makeAddr("bob");
        uint256 bobStakeAmount = 200e18;
        uint256 advanceAmount = (bobStakeAmount * 5) / 100;

        token.mint(bob, bobStakeAmount);

        vm.startPrank(bob);
        token.approve(address(regenStaker), bobStakeAmount);
        Staker.DepositIdentifier bobDepositId = regenStaker.stakeWithAdvanceReward(
            bobStakeAmount,
            delegatee,
            bob,
            advanceAmount,
            advanceAmount
        );
        vm.stopPrank();

        (uint96 balance, address ownerAddr, , address delegateeAddr, address claimerAddr, , ) = regenStaker.deposits(
            bobDepositId
        );
        assertEq(ownerAddr, bob, "owner mismatch");
        assertEq(delegateeAddr, delegatee, "delegatee mismatch");
        assertEq(claimerAddr, bob, "claimer mismatch");
        assertEq(balance, bobStakeAmount - advanceAmount, "deposit balance should be reduced by earmark");

        uint64 lockEnd = regenStaker.advanceRewardLockEnd(bobDepositId);
        assertEq(lockEnd, block.timestamp + 5 * 30 days, "lock end mismatch");
        assertEq(token.balanceOf(bob), advanceAmount, "owner should receive immediate reward payout");
    }

    function test_stakeWithAdvanceReward_withExplicitClaimer() public {
        address bob = makeAddr("bob2");
        uint256 bobStakeAmount = 120e18;

        token.mint(bob, bobStakeAmount);

        vm.startPrank(bob);
        token.approve(address(regenStaker), bobStakeAmount);
        uint256 advanceAmount = (bobStakeAmount * 2) / 100;
        Staker.DepositIdentifier bobDepositId = regenStaker.stakeWithAdvanceReward(
            bobStakeAmount,
            delegatee,
            claimer,
            advanceAmount,
            advanceAmount
        );
        vm.stopPrank();

        (, address ownerAddr, , , address claimerAddr, , ) = regenStaker.deposits(bobDepositId);
        assertEq(ownerAddr, bob, "owner mismatch");
        assertEq(claimerAddr, claimer, "explicit claimer mismatch");
    }

    function test_stakeWithAdvanceReward_usesCeilDivisionForTinyAdvanceLock() public {
        uint256 smallStakeAmount = 20e18;
        uint256 tinyAdvance = 1;
        uint256 lockDurationPerPercent = 30 days;
        token.mint(owner, smallStakeAmount);

        uint256 expectedDuration = ((tinyAdvance * lockDurationPerPercent * 100) - 1) / smallStakeAmount + 1;
        assertEq(expectedDuration, 1, "expected tiny advance lock duration should be 1 second");

        vm.startPrank(owner);
        token.approve(address(regenStaker), smallStakeAmount);
        Staker.DepositIdentifier tinyDepositId = regenStaker.stakeWithAdvanceReward(
            smallStakeAmount,
            delegatee,
            owner,
            tinyAdvance,
            tinyAdvance
        );
        vm.stopPrank();

        uint64 lockEnd = regenStaker.advanceRewardLockEnd(tinyDepositId);
        assertEq(lockEnd, block.timestamp + expectedDuration, "lock end should use ceil division");
    }

    function test_stakeWithAdvanceReward_revertsInvalidAdvanceAmount() public {
        address bob = makeAddr("bob3");
        uint256 bobStakeAmount = 120e18;
        token.mint(bob, bobStakeAmount);

        vm.startPrank(bob);
        token.approve(address(regenStaker), bobStakeAmount);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.ZeroOperation.selector));
        regenStaker.stakeWithAdvanceReward(bobStakeAmount, delegatee, claimer, 0, 0);
        uint256 tooLargeAdvance = (bobStakeAmount * 5) / 100 + 1;
        vm.expectRevert(
            abi.encodeWithSelector(RegenStakerBase.CantAfford.selector, tooLargeAdvance, bobStakeAmount / 20)
        );
        regenStaker.stakeWithAdvanceReward(bobStakeAmount, delegatee, claimer, tooLargeAdvance, 0);
        vm.stopPrank();
    }

    function test_stakeWithAdvanceReward_sameTokenRevertsWhenMinOutTooHigh() public {
        address bob = makeAddr("bob4");
        uint256 bobStakeAmount = 120e18;
        uint256 advanceAmount = (bobStakeAmount * 2) / 100;
        token.mint(bob, bobStakeAmount);

        vm.startPrank(bob);
        token.approve(address(regenStaker), bobStakeAmount);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.CantAfford.selector, advanceAmount + 1, advanceAmount));
        regenStaker.stakeWithAdvanceReward(bobStakeAmount, delegatee, claimer, advanceAmount, advanceAmount + 1);
        vm.stopPrank();
    }

    function test_setAdvanceSwapConfig_adminOnlyAndStores() public {
        address router = makeAddr("router");
        uint24 fee = 500;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not admin"), owner));
        regenStaker.setAdvanceSwapConfig(router, fee);

        vm.prank(admin);
        regenStaker.setAdvanceSwapConfig(router, fee);
    }

    function test_withdraw_revertsDuringLock_andAllowedAfterExpiry() public {
        address bob = makeAddr("bob5");
        uint256 bobStakeAmount = 200e18;
        uint256 advanceAmount = (bobStakeAmount * 5) / 100;
        token.mint(bob, bobStakeAmount);

        vm.startPrank(bob);
        token.approve(address(regenStaker), bobStakeAmount);
        Staker.DepositIdentifier bobDepositId = regenStaker.stakeWithAdvanceReward(
            bobStakeAmount,
            delegatee,
            bob,
            advanceAmount,
            advanceAmount
        );
        (uint96 balance, , , , , , ) = regenStaker.deposits(bobDepositId);
        uint64 lockEnd = regenStaker.advanceRewardLockEnd(bobDepositId);

        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.CommitmentLockActive.selector, bobDepositId, lockEnd));
        regenStaker.withdraw(bobDepositId, balance);

        vm.warp(lockEnd + 1);
        regenStaker.withdraw(bobDepositId, balance);
        vm.stopPrank();

        (uint96 remainingBalance, , , , , , ) = regenStaker.deposits(bobDepositId);
        assertEq(remainingBalance, 0, "full withdraw should clear balance");
        uint64 currentLockEnd = regenStaker.advanceRewardLockEnd(bobDepositId);
        assertEq(currentLockEnd, 0, "lock should clear after lock expiry and withdraw");
    }

    // =========================================================
    // contribute (reward-only, REWARD_TOKEN path)
    // =========================================================

    function test_contribute_usesRewardsOnly_whenAvailable() public {
        vm.warp(block.timestamp + REWARD_DURATION / 4);

        uint256 rewardAvailable = regenStaker.unclaimedReward(depositId);
        uint256 rewardToContribute = rewardAvailable / 2;
        require(rewardToContribute > 0, "reward-to-contribute should be > 0");

        (uint256 deadline, uint8 v, bytes32 r, bytes32 s) = _contributeSignatureFor(owner, ownerPk, rewardToContribute);

        uint256 mechanismBalanceBefore = token.balanceOf(address(allocationMechanism));
        uint96 balanceBefore = _depositBalance(depositId);
        uint256 totalStakedBefore = regenStaker.totalStaked();

        vm.prank(owner);
        uint256 contributed = regenStaker.contribute(
            depositId,
            address(allocationMechanism),
            rewardToContribute,
            deadline,
            v,
            r,
            s
        );

        assertEq(contributed, rewardToContribute, "contributed amount mismatch");
        assertEq(
            token.balanceOf(address(allocationMechanism)) - mechanismBalanceBefore,
            rewardToContribute,
            "all contribution should hit mechanism"
        );
        assertEq(_depositBalance(depositId), balanceBefore, "deposit balance should not reduce");
        assertEq(regenStaker.totalStaked(), totalStakedBefore, "total staked should not change");
    }

    function test_contribute_rewardOnlyLegStillWorksDuringActiveLock() public {
        uint256 ownerStakeAmount = 200e18;
        token.mint(owner, ownerStakeAmount);

        vm.startPrank(owner);
        token.approve(address(regenStaker), ownerStakeAmount);
        Staker.DepositIdentifier lockedDepositId = regenStaker.stakeWithAdvanceReward(
            ownerStakeAmount,
            delegatee,
            owner,
            (ownerStakeAmount * 5) / 100,
            (ownerStakeAmount * 5) / 100
        );
        vm.stopPrank();

        vm.warp(block.timestamp + REWARD_DURATION / 4);

        uint64 lockEnd = regenStaker.advanceRewardLockEnd(lockedDepositId);

        uint256 rewardAvailable = regenStaker.unclaimedReward(lockedDepositId);
        uint256 rewardToContribute = rewardAvailable / 2;
        require(rewardToContribute > 0, "reward-to-contribute should be > 0");

        (uint256 deadline, uint8 v, bytes32 r, bytes32 s) = _contributeSignatureFor(owner, ownerPk, rewardToContribute);

        uint256 mechanismBalanceBefore = token.balanceOf(address(allocationMechanism));
        vm.prank(owner);
        uint256 contributed = regenStaker.contribute(
            lockedDepositId,
            address(allocationMechanism),
            rewardToContribute,
            deadline,
            v,
            r,
            s
        );

        assertEq(contributed, rewardToContribute);
        assertEq(token.balanceOf(address(allocationMechanism)) - mechanismBalanceBefore, rewardToContribute);
        // contribute() does not touch lock metadata
        uint64 currentLockEnd = regenStaker.advanceRewardLockEnd(lockedDepositId);
        assertEq(currentLockEnd, lockEnd);
    }

    function test_contribute_zeroAmountStillAllowedForContributionSignup() public {
        vm.warp(block.timestamp + REWARD_DURATION / 4);
        uint256 rewardAvailable = regenStaker.unclaimedReward(depositId);
        require(rewardAvailable > 0, "reward should be available");

        (uint256 deadline, uint8 v, bytes32 r, bytes32 s) = _contributeSignatureFor(owner, ownerPk, 0);

        vm.prank(owner);
        uint256 contributed = regenStaker.contribute(depositId, address(allocationMechanism), 0, deadline, v, r, s);
        assertEq(contributed, 0, "zero amount should still be a valid signup path");
    }
}
