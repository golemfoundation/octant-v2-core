// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { AccessMode } from "src/constants.sol";
import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";

import { MockERC20Staking } from "test/mocks/MockERC20Staking.sol";

import { Staker } from "staker/Staker.sol";
import { IERC20Staking } from "staker/interfaces/IERC20Staking.sol";
import { IEarningPowerCalculator } from "staker/interfaces/IEarningPowerCalculator.sol";

/// @dev Minimal allocation mechanism stub expected by contribute()
contract MockAllocationMechanism {
    IERC20 public immutable asset;

    constructor(IERC20 _asset) {
        asset = _asset;
    }

    function canSignup(address) external pure returns (bool) {
        return true; // No access control
    }

    function signupOnBehalfWithSignature(address, uint256 amount, uint256, uint8, bytes32, bytes32) external {
        // Transfer tokens from the staker contract to consume the allowance
        if (amount > 0) {
            asset.transferFrom(msg.sender, address(this), amount);
        }
    }
}

/// @dev Harness exposing helper for seeding unclaimed rewards.
contract RegenStakerDustHarness is RegenStaker {
    constructor(
        IERC20 rewardToken,
        IERC20Staking stakeToken,
        IEarningPowerCalculator calculator,
        uint256 maxBumpTip,
        address admin,
        uint128 rewardDuration,
        uint128 minimumStakeAmount,
        IAddressSet stakerAllowset,
        IAddressSet stakerBlockset,
        AccessMode stakerAccessMode,
        IAddressSet allocationAllowset
    )
        RegenStaker(
            rewardToken,
            stakeToken,
            calculator,
            maxBumpTip,
            admin,
            rewardDuration,
            minimumStakeAmount,
            stakerAllowset,
            stakerBlockset,
            stakerAccessMode,
            allocationAllowset
        )
    {}

    function seedUnclaimedRewards(Staker.DepositIdentifier depositId, uint256 amount) external {
        deposits[depositId].scaledUnclaimedRewardCheckpoint = amount * SCALE_FACTOR;
    }
}

/// @title Cantina Competition September 2025 – Finding 564 Fix
/// @notice Verifies that small rewards (≤ fee) are swept to the fee collector.
contract Cantina564Fix is Test {
    MockERC20Staking internal stakeAndRewardToken;
    RegenStakerDustHarness internal regenStaker;
    MockAllocationMechanism internal allocation;
    AddressSet internal allocationAllowset;
    RegenEarningPowerCalculator internal earningPowerCalculator;

    address internal immutable user = makeAddr("user");
    address internal immutable feeCollector = makeAddr("feeCollector");

    uint256 internal constant STAKE_AMOUNT = 1 ether;
    uint256 internal constant FEE_AMOUNT = 10 ether;
    uint256 internal constant DUST = 5 ether;

    function setUp() public {
        stakeAndRewardToken = new MockERC20Staking(18);
        allocationAllowset = new AddressSet();
        earningPowerCalculator = new RegenEarningPowerCalculator(
            address(this),
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE
        );

        regenStaker = new RegenStakerDustHarness(
            IERC20(address(stakeAndRewardToken)),
            IERC20Staking(address(stakeAndRewardToken)),
            IEarningPowerCalculator(address(earningPowerCalculator)),
            1e18,
            address(this),
            uint128(30 days),
            0,
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            allocationAllowset
        );

        allocation = new MockAllocationMechanism(IERC20(address(stakeAndRewardToken)));
        allocationAllowset.add(address(allocation));

        // Note: Fee collection has been eliminated, so no setClaimFeeParameters call needed
    }

    /// @notice Test that dust rewards can now be claimed directly (no fee collection)
    function testClaimRewardAllowsDustClaim() public {
        Staker.DepositIdentifier depositId = _createDepositWithDust();

        vm.prank(user);
        uint256 claimed = regenStaker.claimReward(depositId);

        assertEq(claimed, DUST, "claimer receives full dust amount");
        assertEq(stakeAndRewardToken.balanceOf(user), DUST, "user receives dust tokens");
        assertEq(regenStaker.unclaimedReward(depositId), 0, "deposit cleared");
    }

    /// @notice Test that dust rewards can be contributed (no fee collection)
    function testContributeAllowsDustContribution() public {
        Staker.DepositIdentifier depositId = _createDepositWithDust();

        vm.prank(user);
        uint256 contributed = regenStaker.contribute(
            depositId,
            address(allocation),
            DUST,
            block.timestamp + 1 days,
            0,
            bytes32(0),
            bytes32(0)
        );

        assertEq(contributed, DUST, "full dust amount contributed");
        assertEq(regenStaker.unclaimedReward(depositId), 0, "deposit cleared");
    }

    /// @notice Test that dust rewards can be compounded (no fee collection)
    function testCompoundAllowsDustCompound() public {
        Staker.DepositIdentifier depositId = _createDepositWithDust();

        vm.prank(user);
        uint256 compounded = regenStaker.compoundRewards(depositId);

        assertEq(compounded, DUST, "full dust amount compounded");
        assertEq(regenStaker.unclaimedReward(depositId), 0, "deposit cleared");
    }

    function _createDepositWithDust() internal returns (Staker.DepositIdentifier depositId) {
        stakeAndRewardToken.mint(user, STAKE_AMOUNT);
        vm.startPrank(user);
        stakeAndRewardToken.approve(address(regenStaker), STAKE_AMOUNT);
        depositId = regenStaker.stake(STAKE_AMOUNT, user, user);
        vm.stopPrank();

        stakeAndRewardToken.mint(address(regenStaker), DUST);
        regenStaker.seedUnclaimedRewards(depositId, DUST);
    }
}
