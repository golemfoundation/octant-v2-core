// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import { AccessMode } from "src/constants.sol";
import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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

/// @title RegenStakerBase Claimer Permissions Demonstration
/// @notice Demonstrates that claimers have intended staking permissions through compounding
/// @dev This test suite validates the documented behavior that claimers can:
///      1. Claim rewards on behalf of the owner
///      2. Compound rewards (increasing stake) when REWARD_TOKEN == STAKE_TOKEN
///      This is INTENDED BEHAVIOR as documented in REG-019
contract RegenStakerBaseClaimerPermissionsDemoTest is Test {
    RegenStaker public regenStaker;
    MockERC20Staking public token; // Same token for stake and reward
    MockEarningPowerCalculator public earningPowerCalculator;
    OctantQFMechanism public allocationMechanism;
    AddressSet public stakerAllowset;
    AddressSet public allocationAllowset;

    address public admin = makeAddr("admin");
    address public owner;
    uint256 private ownerPk;
    address public claimer;
    uint256 private claimerPk;
    address public delegatee = makeAddr("delegatee");

    uint256 public constant STAKE_AMOUNT = 100e18;
    uint256 public constant REWARD_AMOUNT = 1000e18;
    uint128 public constant REWARD_DURATION = 30 days;

    Staker.DepositIdentifier public depositId;

    function setUp() public {
        // Deploy infrastructure
        token = new MockERC20Staking(18);
        earningPowerCalculator = new MockEarningPowerCalculator();

        // Deploy real allocation mechanism (OctantQFMechanism) using shared implementation
        TokenizedAllocationMechanism impl = new TokenizedAllocationMechanism();
        AllocationConfig memory cfg = AllocationConfig({
            asset: IERC20(address(token)),
            name: "TestAlloc",
            symbol: "TA",
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
            IAddressSet(address(0)), // contributionAllowset
            IAddressSet(address(0)), // contributionBlockset
            AccessMode.NONE
        );

        // Deploy allowsets
        vm.startPrank(admin);
        stakerAllowset = new AddressSet();
        allocationAllowset = new AddressSet();

        // Setup allowsets
        (owner, ownerPk) = makeAddrAndKey("owner");
        stakerAllowset.add(owner);
        (claimer, claimerPk) = makeAddrAndKey("claimer");
        stakerAllowset.add(claimer);
        allocationAllowset.add(address(allocationMechanism));
        vm.stopPrank();

        // Deploy RegenStaker with same token for stake/reward (enables compounding)
        vm.prank(admin);
        regenStaker = new RegenStaker(
            IERC20(address(token)), // rewardsToken
            token, // stakeToken
            earningPowerCalculator,
            0, // maxBumpTip
            admin,
            REWARD_DURATION,
            1e18, // minimumStakeAmount
            IAddressSet(address(stakerAllowset)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            IAddressSet(address(allocationAllowset))
        );

        // Fund and create deposit with claimer designation
        token.mint(owner, STAKE_AMOUNT);
        token.mint(address(regenStaker), REWARD_AMOUNT);

        vm.startPrank(owner);
        token.approve(address(regenStaker), STAKE_AMOUNT);
        depositId = regenStaker.stake(STAKE_AMOUNT, delegatee, claimer);
        vm.stopPrank();

        // Setup rewards
        vm.startPrank(admin);
        regenStaker.setRewardNotifier(admin, true);
        regenStaker.notifyRewardAmount(REWARD_AMOUNT);
        vm.stopPrank();

        // Accumulate rewards
        vm.warp(block.timestamp + REWARD_DURATION / 2);
    }

    /// @notice Demonstrates that claimers CAN claim rewards - INTENDED BEHAVIOR
    function testDemonstrate_ClaimerCanClaimRewards() public {
        // Claimer successfully claims rewards
        vm.prank(claimer);
        uint256 claimedAmount = regenStaker.claimReward(depositId);

        // Verify rewards were claimed
        assertGt(claimedAmount, 0, "claims rewards");
        assertEq(token.balanceOf(claimer), claimedAmount, "Rewards sent to claimer");
    }

    /// @notice Demonstrates that claimers CAN compound rewards - INTENDED BEHAVIOR
    /// @dev This increases the deposit's stake amount, which is the documented behavior
    function testDemonstrate_ClaimerCanCompoundRewards() public {
        (uint96 stakeBefore, , , , , , ) = regenStaker.deposits(depositId);

        // Claimer compounds rewards (claims + restakes in one operation)
        vm.prank(claimer);
        uint256 compoundedAmount = regenStaker.compoundRewards(depositId);

        (uint96 stakeAfter, , , , , , ) = regenStaker.deposits(depositId);

        // Verify stake increased through compounding
        assertGt(compoundedAmount, 0, "compounded");
        assertEq(stakeAfter - stakeBefore, compoundedAmount);
    }

    /// @notice Demonstrates the permission boundaries - claimers CANNOT withdraw
    function testDemonstrate_ClaimerCannotWithdraw() public {
        vm.prank(claimer);
        vm.expectRevert(); // Claimer lacks withdrawal permission
        regenStaker.withdraw(depositId, 10e18);
    }

    /// @notice Demonstrates that claimers CAN contribute when on contribution allowset
    function testDemonstrate_ClaimerCanContributeIfAllowseted() public {
        // Progress time to accrue rewards
        vm.warp(block.timestamp + REWARD_DURATION / 4);

        // Prepare EIP-712 signature for signupOnBehalfWithSignature(user=claimer, payer=regenStaker)
        // Claimer receives voting power and provides signature (claimer autonomy)
        bytes32 domainSeparator = TokenizedAllocationMechanism(address(allocationMechanism)).DOMAIN_SEPARATOR();
        uint256 nonce = TokenizedAllocationMechanism(address(allocationMechanism)).nonces(claimer);
        uint256 amount = 1e18;
        uint256 deadline = block.timestamp + 1 days;
        bytes32 typeHash = keccak256(
            bytes("Signup(address user,address payer,uint256 deposit,uint256 nonce,uint256 deadline)")
        );
        bytes32 structHash = keccak256(abi.encode(typeHash, claimer, address(regenStaker), amount, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(claimerPk, digest);

        uint256 mechanismBalanceBefore = token.balanceOf(address(allocationMechanism));

        // Claimer contributes unclaimed rewards to the real allocation mechanism
        vm.prank(claimer);
        uint256 contributed = regenStaker.contribute(
            depositId,
            address(allocationMechanism),
            amount,
            deadline,
            v,
            r,
            s
        );

        // Verify contribution succeeded
        assertEq(contributed, amount);
        assertEq(token.balanceOf(address(allocationMechanism)) - mechanismBalanceBefore, amount);
    }

    /// @notice Demonstrates owner control - can revoke claimer at any time
    function testDemonstrate_OwnerCanRevokeClaimer() public {
        address newClaimer = makeAddr("newClaimer");

        // Owner changes claimer
        vm.prank(admin);
        stakerAllowset.add(newClaimer);

        vm.prank(owner);
        regenStaker.alterClaimer(depositId, newClaimer);

        // Old claimer no longer has access
        vm.prank(claimer);
        vm.expectRevert(); // No longer authorized
        regenStaker.claimReward(depositId);

        // New claimer has access
        vm.prank(newClaimer);
        uint256 claimed = regenStaker.claimReward(depositId);
        assertGt(claimed, 0, "New claimer can claim");
    }
}
