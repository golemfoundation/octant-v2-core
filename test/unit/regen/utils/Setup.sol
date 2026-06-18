// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";

import { AccessMode } from "src/constants.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerWithoutDelegateSurrogateVotes } from "src/regen/RegenStakerWithoutDelegateSurrogateVotes.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";

import { TokenizedAllocationMechanism } from "src/mechanisms/TokenizedAllocationMechanism.sol";
import { OctantQFMechanism } from "src/mechanisms/mechanism/OctantQFMechanism.sol";
import { AllocationConfig } from "src/mechanisms/BaseAllocationMechanism.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Staking } from "staker/interfaces/IERC20Staking.sol";
import { IEarningPowerCalculator } from "staker/interfaces/IEarningPowerCalculator.sol";

/// @title Shared scaffolding for RegenStaker unit tests
/// @notice Centralises the RegenStaker / RegenStakerWithoutDelegateSurrogateVotes deployment,
///         the earning-power calculator and allocation-mechanism wiring, and the common
///         stake/notify actions that every concern-specific test file repeats.
/// @dev Helpers are stateless and parameterised: each concern file keeps its own `setUp()`
///      describing the scenario it exercises, but builds the deployment through these helpers
///      instead of re-spelling the 11-argument constructor by hand. Named-field deployment
///      (`RegenCfg`) removes the positional-argument hazard inherent to the raw constructor.
abstract contract Setup is Test {
    /// @notice Named-field configuration for deploying either RegenStaker variant.
    /// @dev `stakeToken` is typed as IERC20 to fit both variants; `_deployRegenStaker` casts to
    ///      IERC20Staking. Field names mirror the constructor parameters one-to-one.
    struct RegenCfg {
        IERC20 rewardsToken;
        IERC20 stakeToken;
        IEarningPowerCalculator earningPowerCalculator;
        uint256 maxBumpTip;
        address admin;
        uint128 rewardDuration;
        uint128 minimumStakeAmount;
        IAddressSet stakerAllowset;
        IAddressSet stakerBlockset;
        AccessMode stakerAccessMode;
        IAddressSet allocationMechanismAllowset;
    }

    // --------------------------------------------------------------------------------------------
    // Deployment helpers
    // --------------------------------------------------------------------------------------------

    /// @notice Deploy a RegenStaker (delegation-surrogate variant) from a named-field config.
    function _deployRegenStaker(RegenCfg memory c) internal returns (RegenStaker) {
        return
            new RegenStaker(
                c.rewardsToken,
                IERC20Staking(address(c.stakeToken)),
                c.earningPowerCalculator,
                c.maxBumpTip,
                c.admin,
                c.rewardDuration,
                c.minimumStakeAmount,
                c.stakerAllowset,
                c.stakerBlockset,
                c.stakerAccessMode,
                c.allocationMechanismAllowset
            );
    }

    /// @notice Deploy a RegenStakerWithoutDelegateSurrogateVotes from a named-field config.
    function _deployRegenStakerWithoutDelegation(
        RegenCfg memory c
    ) internal returns (RegenStakerWithoutDelegateSurrogateVotes) {
        return
            new RegenStakerWithoutDelegateSurrogateVotes(
                c.rewardsToken,
                c.stakeToken,
                c.earningPowerCalculator,
                c.maxBumpTip,
                c.admin,
                c.rewardDuration,
                c.minimumStakeAmount,
                c.stakerAllowset,
                c.stakerBlockset,
                c.stakerAccessMode,
                c.allocationMechanismAllowset
            );
    }

    /// @notice Deploy a RegenEarningPowerCalculator with the given allow/block sets and mode.
    function _deployCalculator(
        address admin,
        IAddressSet allowset,
        IAddressSet blockset,
        AccessMode mode
    ) internal returns (RegenEarningPowerCalculator) {
        return new RegenEarningPowerCalculator(admin, allowset, blockset, mode);
    }

    /// @notice Deploy an OctantQFMechanism (with a fresh TokenizedAllocationMechanism implementation)
    ///         using the parameters that the RegenStaker tests rely on.
    /// @dev Mirrors the verbatim block previously duplicated across the claimer-permissions and
    ///      voting-power assignment suites.
    function _deployOctantQFMechanism(
        IERC20 asset,
        address owner,
        IAddressSet contributionAllowset,
        IAddressSet contributionBlockset,
        AccessMode contributionAccessMode
    ) internal returns (OctantQFMechanism) {
        TokenizedAllocationMechanism impl = new TokenizedAllocationMechanism();
        AllocationConfig memory cfg = AllocationConfig({
            asset: asset,
            name: "TestAlloc",
            symbol: "TA",
            votingDelay: 1,
            votingPeriod: 30 days,
            quorumShares: 1,
            timelockDelay: 1,
            gracePeriod: 100,
            owner: owner
        });
        return
            new OctantQFMechanism(
                address(impl),
                cfg,
                1,
                1,
                contributionAllowset,
                contributionBlockset,
                contributionAccessMode
            );
    }
}
