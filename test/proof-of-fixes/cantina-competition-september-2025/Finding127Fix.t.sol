// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { AccessMode } from "src/constants.sol";
import { Test } from "forge-std/Test.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { Staker } from "staker/Staker.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { MockERC20Staking } from "test/mocks/MockERC20Staking.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { TokenizedAllocationMechanism } from "src/mechanisms/TokenizedAllocationMechanism.sol";
import { OctantQFMechanism } from "src/mechanisms/mechanism/OctantQFMechanism.sol";
import { AllocationMechanismFactory } from "src/mechanisms/AllocationMechanismFactory.sol";
import { AllocationConfig } from "src/mechanisms/BaseAllocationMechanism.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { NotInAllowset } from "src/errors.sol";

/// @title Cantina Competition September 2025 – Finding 127 Fix
/// @notice Proves the PROPER architectural fix: contribution allowset at TAM signup, not RegenStaker
/// @dev This is where voting power is CREATED, so this is where access control belongs
contract Cantina127Fix is Test {
    // Contracts
    RegenStaker public regenStaker;
    MockERC20Staking public stakeToken;
    MockERC20 public rewardToken;
    AddressSet public stakerAllowset;
    AddressSet public regenContributionAllowset; // RegenStaker's (defense-in-depth)
    AddressSet public tamContributionAllowset; // TAM's (the RIGHT place)
    AddressSet public allocationAllowset;
    AddressSet public earningPowerAllowset;
    OctantQFMechanism public allocationMechanism;
    AllocationMechanismFactory public allocationFactory;

    // Actors
    address public admin = makeAddr("admin");
    address public alice; // The delisted depositor
    uint256 public alicePk;
    address public bob; // The inAllowset claimer
    uint256 public bobPk;
    address public rewardNotifier = makeAddr("rewardNotifier");

    // Constants
    uint256 internal constant STAKE_AMOUNT = 100 ether;
    uint256 internal constant REWARD_AMOUNT = 50 ether;
    uint256 internal constant CONTRIBUTION_AMOUNT = 10 ether;

    function setUp() public {
        (alice, alicePk) = makeAddrAndKey("alice");
        (bob, bobPk) = makeAddrAndKey("bob");

        vm.startPrank(admin);
        // Deploy tokens and allowsets
        stakeToken = new MockERC20Staking(18);
        rewardToken = new MockERC20(18);
        stakerAllowset = new AddressSet();
        regenContributionAllowset = new AddressSet(); // RegenStaker's
        tamContributionAllowset = new AddressSet();
        allocationAllowset = new AddressSet();
        earningPowerAllowset = new AddressSet();

        // Deploy Allocation Mechanism
        allocationFactory = new AllocationMechanismFactory();
        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(rewardToken)),
            name: "Test QF",
            symbol: "TQF",
            votingDelay: 1,
            votingPeriod: 30 days,
            quorumShares: 1,
            timelockDelay: 1,
            gracePeriod: 7 days,
            owner: admin
        });
        TokenizedAllocationMechanism impl = new TokenizedAllocationMechanism();
        allocationMechanism = new OctantQFMechanism(
            address(impl),
            config,
            1,
            1,
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE
        );

        // THE FIX: Set contribution allowset on OctantQF (where voting power is created)
        allocationMechanism.setContributionAllowset(tamContributionAllowset);
        allocationMechanism.setAccessMode(AccessMode.ALLOWSET);

        allocationAllowset.add(address(allocationMechanism));

        // Deploy RegenStaker
        RegenEarningPowerCalculator calc = new RegenEarningPowerCalculator(
            admin,
            earningPowerAllowset,
            IAddressSet(address(0)), // No blockset for earning power
            AccessMode.ALLOWSET
        );
        regenStaker = new RegenStaker(
            rewardToken,
            stakeToken,
            calc,
            0, // maxBumpTip
            admin,
            30 days, // reward duration
            0, // minimumStakeAmount
            stakerAllowset,
            IAddressSet(address(0)), // No staker blockset
            AccessMode.NONE, // No staker restrictions (contribution control is in TAM)
            allocationAllowset
        );
        regenStaker.setRewardNotifier(rewardNotifier, true);
        vm.stopPrank();

        // Fund accounts
        stakeToken.mint(alice, STAKE_AMOUNT);
        rewardToken.mint(rewardNotifier, REWARD_AMOUNT);
    }

    /// @notice Test that TAM-level allowset blocks delisted users via ALL paths
    /// @dev This is the PROPER fix - control at the point of power creation
    function testFix_TAMAllowsetBlocksAllPaths() public {
        // Setup: Alice inAllowset everywhere initially
        vm.startPrank(admin);
        stakerAllowset.add(alice);
        regenContributionAllowset.add(alice); // RegenStaker's (still checked by contribute())
        regenContributionAllowset.add(bob); // Bob too for contribute() path
        tamContributionAllowset.add(alice); // TAM's (the REAL enforcement)
        tamContributionAllowset.add(bob);
        earningPowerAllowset.add(alice);
        vm.stopPrank();

        // Alice stakes
        vm.startPrank(alice);
        stakeToken.approve(address(regenStaker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = regenStaker.stake(STAKE_AMOUNT, alice, bob);
        vm.stopPrank();

        // Rewards accrue
        vm.startPrank(rewardNotifier);
        rewardToken.transfer(address(regenStaker), REWARD_AMOUNT);
        regenStaker.notifyRewardAmount(REWARD_AMOUNT);
        vm.stopPrank();
        vm.warp(block.timestamp + 15 days);

        uint256 aliceRewards = regenStaker.unclaimedReward(depositId);
        assertGe(aliceRewards, CONTRIBUTION_AMOUNT);

        // Admin delists Alice from BOTH allowsets (layered defense)
        vm.startPrank(admin);
        regenContributionAllowset.remove(alice); // RegenStaker check (fund source)
        tamContributionAllowset.remove(alice); // TAM check (for claim->signup path)
        vm.stopPrank();

        // PATH 1: Try contribute() via Bob (in the allowset claimer)
        // Bob provides HIS signature (claimer autonomy) but should FAIL because Alice (fund source) is not eligible
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _getSignupDigest(bob, address(regenStaker), CONTRIBUTION_AMOUNT, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPk, digest);

        vm.prank(bob);
        // Expect error indicating alice (deposit owner) is not eligible for the mechanism
        vm.expectRevert(
            abi.encodeWithSelector(
                RegenStakerBase.DepositOwnerNotEligibleForMechanism.selector,
                address(allocationMechanism),
                alice
            )
        );
        regenStaker.contribute(depositId, address(allocationMechanism), CONTRIBUTION_AMOUNT, deadline, v, r, s);

        // PATH 2: Try claim → direct signup (the bypass path)
        // Should ALSO FAIL because Alice is not on TAM allowset
        vm.prank(alice);
        uint256 claimed = regenStaker.claimReward(depositId);
        assertGt(claimed, 0);

        // Alice now has tokens, tries to signup directly
        vm.startPrank(alice);
        rewardToken.approve(address(allocationMechanism), claimed);
        vm.expectRevert(abi.encodeWithSelector(NotInAllowset.selector, alice));
        TokenizedAllocationMechanism(address(allocationMechanism)).signup(claimed);
        vm.stopPrank();
    }

    function _getSignupDigest(
        address user,
        address payer,
        uint256 deposit,
        uint256 nonce,
        uint256 deadline
    ) internal returns (bytes32) {
        bytes32 domainSeparator = TokenizedAllocationMechanism(address(allocationMechanism)).DOMAIN_SEPARATOR();
        bytes32 typeHash = keccak256(
            "Signup(address user,address payer,uint256 deposit,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(abi.encode(typeHash, user, payer, deposit, nonce, deadline));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
