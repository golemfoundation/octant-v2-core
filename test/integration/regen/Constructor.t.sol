// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { AccessMode } from "src/constants.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Staking } from "staker/interfaces/IERC20Staking.sol";
import { IAccessControlledEarningPowerCalculator } from "src/regen/interfaces/IAccessControlledEarningPowerCalculator.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
// import { SimpleVotingMechanism } from "test/mocks/SimpleVotingMechanism.sol"; // SimpleVotingMechanism removed

import { RegenIntegrationBase } from "./base/RegenIntegrationBase.sol";

/**
 * @notice Constructor integration tests for RegenStaker.
 * forge-config: default.fuzz.runs = 16384
 * forge-config: default.fuzz.max_test_rejects = 1048576
 */
contract RegenIntegrationConstructorTest is RegenIntegrationBase {
    function testFuzz_Constructor_InitializesAllParametersCorrectly(
        uint256 tipAmount,
        uint256 feeAmount,
        uint256 minimumStakeAmount
    ) public {
        tipAmount = bound(tipAmount, 0, MAX_BUMP_TIP);
        feeAmount = bound(feeAmount, 0, MAX_CLAIM_FEE);
        minimumStakeAmount = bound(uint128(minimumStakeAmount), 0, getStakeAmount(1000));

        vm.startPrank(ADMIN);
        RegenStaker localRegenStaker = new RegenStaker(
            IERC20(address(rewardToken)),
            IERC20Staking(address(stakeToken)),
            calculator,
            tipAmount,
            ADMIN,
            uint128(MIN_REWARD_DURATION),
            uint128(minimumStakeAmount),
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            allocationMechanismAllowset
        );

        assertEq(address(localRegenStaker.REWARD_TOKEN()), address(rewardToken));
        assertEq(address(localRegenStaker.STAKE_TOKEN()), address(stakeToken));
        assertEq(localRegenStaker.admin(), ADMIN);
        assertEq(address(localRegenStaker.earningPowerCalculator()), address(calculator));
        assertEq(localRegenStaker.maxBumpTip(), tipAmount);
        assertEq(localRegenStaker.minimumStakeAmount(), minimumStakeAmount);

        assertEq(address(localRegenStaker.stakerAllowset()), address(0));

        (uint96 initialFeeAmount, address initialFeeCollector) = localRegenStaker.claimFeeParameters();
        assertEq(initialFeeAmount, 0);
        assertEq(initialFeeCollector, address(0));

        assertEq(localRegenStaker.totalStaked(), 0);
        assertEq(localRegenStaker.totalEarningPower(), 0);
        assertEq(localRegenStaker.rewardDuration(), MIN_REWARD_DURATION);
        vm.stopPrank();
    }

    function testFuzz_Constructor_InitializesAllParametersWithProvidedAllowsets(
        uint256 tipAmount,
        uint256 feeAmount,
        uint256 minimumStakeAmount
    ) public {
        tipAmount = bound(tipAmount, 0, MAX_BUMP_TIP);
        feeAmount = bound(feeAmount, 0, MAX_CLAIM_FEE);
        minimumStakeAmount = bound(uint128(minimumStakeAmount), 0, getStakeAmount(1000));

        vm.startPrank(ADMIN);
        AddressSet providedStakerAllowset = new AddressSet();
        AddressSet providedContributorAllowset = new AddressSet();

        providedStakerAllowset.transferOwnership(ADMIN);
        providedContributorAllowset.transferOwnership(ADMIN);

        RegenStaker localRegenStaker = new RegenStaker(
            IERC20(address(rewardToken)),
            IERC20Staking(address(stakeToken)),
            calculator,
            tipAmount,
            ADMIN,
            uint128(MIN_REWARD_DURATION),
            uint128(minimumStakeAmount),
            providedStakerAllowset,
            IAddressSet(address(0)),
            AccessMode.NONE,
            allocationMechanismAllowset
        );

        assertEq(address(localRegenStaker.REWARD_TOKEN()), address(rewardToken));
        assertEq(address(localRegenStaker.STAKE_TOKEN()), address(stakeToken));
        assertEq(localRegenStaker.admin(), ADMIN);
        assertEq(address(localRegenStaker.earningPowerCalculator()), address(calculator));
        assertEq(localRegenStaker.maxBumpTip(), tipAmount);
        assertEq(localRegenStaker.minimumStakeAmount(), minimumStakeAmount);

        assertEq(address(localRegenStaker.stakerAllowset()), address(providedStakerAllowset));

        assertEq(Ownable(address(localRegenStaker.stakerAllowset())).owner(), ADMIN);

        (uint96 initialFeeAmount, address initialFeeCollector) = localRegenStaker.claimFeeParameters();
        assertEq(initialFeeAmount, 0);
        assertEq(initialFeeCollector, address(0));

        assertEq(localRegenStaker.totalStaked(), 0);
        assertEq(localRegenStaker.totalEarningPower(), 0);
        assertEq(localRegenStaker.rewardDuration(), MIN_REWARD_DURATION);
        vm.stopPrank();
    }

    function test_StakerAllowsetIsSet() public view {
        assertEq(address(regenStaker.stakerAllowset()), address(stakerAllowset));
    }

    function test_EarningPowerAllowsetIsSet() public view {
        assertEq(
            address(IAccessControlledEarningPowerCalculator(address(regenStaker.earningPowerCalculator())).allowset()),
            address(earningPowerAllowset)
        );
    }

    function test_EarningPowerCalculatorIsSet() public view {
        assertEq(address(regenStaker.earningPowerCalculator()), address(calculator));
    }

    function test_AllocationMechanismAllowsetIsSet() public view {
        assertEq(address(regenStaker.allocationMechanismAllowset()), address(allocationMechanismAllowset));
    }
}
