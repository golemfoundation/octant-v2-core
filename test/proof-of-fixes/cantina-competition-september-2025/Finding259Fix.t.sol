// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { AccessMode } from "src/constants.sol";
import { Test } from "forge-std/Test.sol";
import { RegenStakerWithoutDelegateSurrogateVotes } from "src/regen/RegenStakerWithoutDelegateSurrogateVotes.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { MockERC20Staking } from "test/mocks/MockERC20Staking.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Staker } from "staker/Staker.sol";
import { StakerOnBehalf } from "staker/extensions/StakerOnBehalf.sol";

/// @title Cantina Competition September 2025 – Finding 259 Fix
/// @notice Proves that delegation functions are properly disabled in RegenStakerWithoutDelegateSurrogateVotes
/// @dev This variant uses address(this) as surrogate and doesn't support delegation
contract Cantina259Fix is Test {
    RegenStakerWithoutDelegateSurrogateVotes public stakerNoDelegation;
    RegenStaker public stakerWithDelegation;
    RegenEarningPowerCalculator public calculator;
    AddressSet public stakerAllowset;
    AddressSet public earningPowerAllowset;
    AddressSet public allocationMechanismAllowset;
    MockERC20Staking public stakeToken;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    uint256 internal constant STAKE_AMOUNT = 1000 ether;
    uint256 internal constant REWARD_DURATION = 30 days;

    function setUp() public {
        // Deploy tokens
        stakeToken = new MockERC20Staking(18);

        // Deploy allowsets
        stakerAllowset = new AddressSet();
        earningPowerAllowset = new AddressSet();
        allocationMechanismAllowset = new AddressSet();

        // AddressSet all users
        stakerAllowset.add(alice);
        stakerAllowset.add(bob);
        stakerAllowset.add(charlie);

        earningPowerAllowset.add(alice);
        earningPowerAllowset.add(bob);
        earningPowerAllowset.add(charlie);

        // Deploy calculator
        calculator = new RegenEarningPowerCalculator(
            admin,
            earningPowerAllowset,
            IAddressSet(address(0)),
            AccessMode.ALLOWSET
        );

        // Deploy stakers
        stakerNoDelegation = new RegenStakerWithoutDelegateSurrogateVotes(
            IERC20(address(stakeToken)),
            IERC20(address(stakeToken)),
            calculator,
            0, // maxBumpTip
            admin,
            uint128(REWARD_DURATION),
            0, // minimumStakeAmount
            IAddressSet(stakerAllowset),
            IAddressSet(address(0)), // stakerBlockset
            AccessMode.NONE,
            IAddressSet(allocationMechanismAllowset) // allocation mechanism allowset CANNOT be address(0)
        );

        stakerWithDelegation = new RegenStaker(
            IERC20(address(stakeToken)),
            stakeToken,
            calculator,
            0, // maxBumpTip
            admin,
            uint128(REWARD_DURATION),
            0, // minimumStakeAmount
            IAddressSet(stakerAllowset),
            IAddressSet(address(0)), // stakerBlockset
            AccessMode.NONE,
            IAddressSet(allocationMechanismAllowset) // allocation mechanism allowset CANNOT be address(0)
        );

        // AddressSet the staker contracts (test contract is the owner of earningPowerAllowset)
        earningPowerAllowset.add(address(stakerNoDelegation));
        earningPowerAllowset.add(address(stakerWithDelegation));
    }

    function testFix_AlterDelegateeReverts() public {
        // Alice stakes in non-delegation variant
        stakeToken.mint(alice, STAKE_AMOUNT);
        vm.startPrank(alice);
        stakeToken.approve(address(stakerNoDelegation), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = stakerNoDelegation.stake(STAKE_AMOUNT, alice);
        vm.stopPrank();

        // Verify that alterDelegatee reverts with DelegationNotSupported
        vm.prank(alice);
        vm.expectRevert(RegenStakerWithoutDelegateSurrogateVotes.DelegationNotSupported.selector);
        stakerNoDelegation.alterDelegatee(depositId, bob);
    }

    function testFix_AlterDelegateeOnBehalfReverts() public {
        // Alice stakes in non-delegation variant
        stakeToken.mint(alice, STAKE_AMOUNT);
        vm.startPrank(alice);
        stakeToken.approve(address(stakerNoDelegation), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = stakerNoDelegation.stake(STAKE_AMOUNT, alice);
        vm.stopPrank();

        // With invalid signature, reverts during signature validation (before reaching _alterDelegatee)
        vm.expectRevert(StakerOnBehalf.StakerOnBehalf__InvalidSignature.selector);
        stakerNoDelegation.alterDelegateeOnBehalf(depositId, bob, alice, block.timestamp + 1000, "");
    }

    function testFix_ContrastWithDelegationVariant() public {
        // Part 1: Show delegation variant ALLOWS alterDelegatee
        stakeToken.mint(alice, STAKE_AMOUNT);
        vm.startPrank(alice);
        stakeToken.approve(address(stakerWithDelegation), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId1 = stakerWithDelegation.stake(STAKE_AMOUNT, bob);

        // Verify we can alter delegatee in the delegation variant
        address newDelegatee = makeAddr("newDelegatee");
        stakerWithDelegation.alterDelegatee(depositId1, newDelegatee); // Should succeed
        vm.stopPrank();

        // Part 2: Show non-delegation variant BLOCKS alterDelegatee
        stakeToken.mint(charlie, STAKE_AMOUNT);
        vm.startPrank(charlie);
        stakeToken.approve(address(stakerNoDelegation), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId2 = stakerNoDelegation.stake(STAKE_AMOUNT, charlie);

        // Verify that alterDelegatee FAILS in non-delegation variant
        vm.expectRevert(RegenStakerWithoutDelegateSurrogateVotes.DelegationNotSupported.selector);
        stakerNoDelegation.alterDelegatee(depositId2, newDelegatee);
        vm.stopPrank();
    }
}
