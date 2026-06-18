// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { AccessMode } from "src/constants.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Staker } from "staker/Staker.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { TokenizedAllocationMechanism } from "src/mechanisms/TokenizedAllocationMechanism.sol";
import { OctantQFMechanism } from "src/mechanisms/mechanism/OctantQFMechanism.sol";
// import { SimpleVotingMechanism } from "test/mocks/SimpleVotingMechanism.sol"; // SimpleVotingMechanism removed
import { AllocationConfig } from "src/mechanisms/BaseAllocationMechanism.sol";
import { NotInAllowset } from "src/errors.sol";

import { RegenIntegrationBase } from "./base/RegenIntegrationBase.sol";

/**
 * @notice Contribute integration tests for RegenStaker.
 * forge-config: default.fuzz.runs = 16384
 * forge-config: default.fuzz.max_test_rejects = 1048576
 */
contract RegenIntegrationContributeTest is RegenIntegrationBase {
    function test_Contribute_WithSignature_Success() public {
        _clearTestContext();

        // Setup
        currentTestCtx.stakeAmount = getStakeAmount(1000);
        currentTestCtx.rewardAmount = getRewardAmount(10000);
        currentTestCtx.contributeAmount = getRewardAmount(1); // Much smaller amount to match partial voting period accumulation

        // ✅ CORRECT: Fetch absolute timeline from contract
        uint256 deploymentTime = block.timestamp; // When mechanism will be deployed
        currentTestCtx.allocationMechanism = _deployAllocationMechanism();
        uint256 votingDelay = TokenizedAllocationMechanism(currentTestCtx.allocationMechanism).votingDelay();
        uint256 votingPeriod = TokenizedAllocationMechanism(currentTestCtx.allocationMechanism).votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        // Advance to allow signup (startBlock + votingDelay period)
        vm.roll(block.number + 5);

        authorizeUser(alice, true, true, true);

        // Fund and stake
        stakeToken.mint(alice, currentTestCtx.stakeAmount);
        rewardToken.mint(address(regenStaker), currentTestCtx.rewardAmount);

        vm.startPrank(alice);
        stakeToken.approve(address(regenStaker), currentTestCtx.stakeAmount);
        currentTestCtx.depositId = regenStaker.stake(currentTestCtx.stakeAmount, alice);
        vm.stopPrank();

        // Notify rewards
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(currentTestCtx.rewardAmount);

        // Warp to voting period and ensure sufficient rewards have accrued
        // Warp to near end of voting period to accumulate maximum rewards
        uint256 timeInVotingPeriod = votingEndTime - (votingPeriod / 10); // 90% through voting period
        vm.warp(timeInVotingPeriod);

        console.log("Voting start:", votingStartTime);
        console.log("Voting end:", votingEndTime);
        console.log("Current time:", block.timestamp);
        console.log("Time in voting period?", block.timestamp >= votingStartTime && block.timestamp <= votingEndTime);

        // Verify alice has unclaimed rewards
        currentTestCtx.unclaimedBefore = regenStaker.unclaimedReward(currentTestCtx.depositId);
        assertGt(
            currentTestCtx.unclaimedBefore,
            currentTestCtx.contributeAmount,
            "Alice should have sufficient unclaimed rewards"
        );

        // Create EIP-2612 signature for TokenizedAllocationMechanism
        currentTestCtx.nonce = TokenizedAllocationMechanism(currentTestCtx.allocationMechanism).nonces(alice);
        currentTestCtx.deadline = block.timestamp + 1 hours;
        currentTestCtx.netContribution = currentTestCtx.contributeAmount; // No fees in this test

        currentTestCtx.digest = _getSignupDigest(
            currentTestCtx.allocationMechanism,
            alice,
            address(regenStaker),
            currentTestCtx.netContribution,
            currentTestCtx.nonce,
            currentTestCtx.deadline
        );
        (currentTestCtx.v, currentTestCtx.r, currentTestCtx.s) = _signDigest(currentTestCtx.digest, ALICE_PRIVATE_KEY);

        // Give Alice tokens and approve for the expected flow
        rewardToken.mint(alice, currentTestCtx.netContribution);
        vm.startPrank(alice);
        rewardToken.approve(currentTestCtx.allocationMechanism, currentTestCtx.netContribution);

        // Call contribute function
        currentTestCtx.actualContribution = regenStaker.contribute(
            currentTestCtx.depositId,
            currentTestCtx.allocationMechanism,
            currentTestCtx.contributeAmount,
            currentTestCtx.deadline,
            currentTestCtx.v,
            currentTestCtx.r,
            currentTestCtx.s
        );
        vm.stopPrank();

        // Verify results
        assertEq(
            currentTestCtx.actualContribution,
            currentTestCtx.contributeAmount,
            "Contribution amount should match"
        );

        uint256 unclaimedAfter = regenStaker.unclaimedReward(currentTestCtx.depositId);
        assertEq(
            unclaimedAfter,
            currentTestCtx.unclaimedBefore - currentTestCtx.contributeAmount,
            "Unclaimed rewards should be reduced"
        );

        // Verify the allocation mechanism received the contribution
        assertEq(
            rewardToken.balanceOf(currentTestCtx.allocationMechanism),
            currentTestCtx.contributeAmount,
            "Allocation mechanism should receive tokens"
        );

        // Verify alice has voting power in the allocation mechanism
        // SimpleVotingMechanism scales voting power to 18 decimals
        uint256 expectedVotingPower = currentTestCtx.netContribution * (10 ** (18 - rewardTokenDecimals));
        assertEq(
            TokenizedAllocationMechanism(currentTestCtx.allocationMechanism).votingPower(alice),
            expectedVotingPower,
            "Alice should have voting power"
        );
    }

    function test_Contribute_WithZeroAmount_AllowsSignup() public {
        _clearTestContext();

        currentTestCtx.stakeAmount = getStakeAmount(1000);
        currentTestCtx.rewardAmount = getRewardAmount(10000);
        currentTestCtx.contributeAmount = 0;

        uint256 deploymentTime = block.timestamp;
        currentTestCtx.allocationMechanism = _deployAllocationMechanism();
        uint256 votingDelay = TokenizedAllocationMechanism(currentTestCtx.allocationMechanism).votingDelay();
        uint256 votingPeriod = TokenizedAllocationMechanism(currentTestCtx.allocationMechanism).votingPeriod();
        uint256 votingStartTime = deploymentTime + votingDelay;
        uint256 votingEndTime = votingStartTime + votingPeriod;

        vm.roll(block.number + 5);

        authorizeUser(alice, true, true, true);

        stakeToken.mint(alice, currentTestCtx.stakeAmount);
        rewardToken.mint(address(regenStaker), currentTestCtx.rewardAmount);

        vm.startPrank(alice);
        stakeToken.approve(address(regenStaker), currentTestCtx.stakeAmount);
        currentTestCtx.depositId = regenStaker.stake(currentTestCtx.stakeAmount, alice);
        vm.stopPrank();

        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(currentTestCtx.rewardAmount);

        uint256 timeInVotingPeriod = votingEndTime - (votingPeriod / 10);
        vm.warp(timeInVotingPeriod);
        assertTrue(block.timestamp >= votingStartTime && block.timestamp <= votingEndTime);

        currentTestCtx.unclaimedBefore = regenStaker.unclaimedReward(currentTestCtx.depositId);

        currentTestCtx.nonce = TokenizedAllocationMechanism(currentTestCtx.allocationMechanism).nonces(alice);
        currentTestCtx.deadline = block.timestamp + 1 hours;
        currentTestCtx.netContribution = 0;

        currentTestCtx.digest = _getSignupDigest(
            currentTestCtx.allocationMechanism,
            alice,
            address(regenStaker),
            currentTestCtx.netContribution,
            currentTestCtx.nonce,
            currentTestCtx.deadline
        );
        (currentTestCtx.v, currentTestCtx.r, currentTestCtx.s) = _signDigest(currentTestCtx.digest, ALICE_PRIVATE_KEY);

        vm.prank(alice);
        currentTestCtx.actualContribution = regenStaker.contribute(
            currentTestCtx.depositId,
            currentTestCtx.allocationMechanism,
            0,
            currentTestCtx.deadline,
            currentTestCtx.v,
            currentTestCtx.r,
            currentTestCtx.s
        );

        assertEq(currentTestCtx.actualContribution, 0);
        assertEq(
            regenStaker.unclaimedReward(currentTestCtx.depositId),
            currentTestCtx.unclaimedBefore,
            "Unclaimed rewards should remain unchanged"
        );
        assertEq(
            TokenizedAllocationMechanism(currentTestCtx.allocationMechanism).nonces(alice),
            currentTestCtx.nonce + 1,
            "Mechanism nonce should increment"
        );
        assertEq(
            TokenizedAllocationMechanism(currentTestCtx.allocationMechanism).votingPower(alice),
            0,
            "Voting power should remain zero"
        );
        assertEq(
            rewardToken.balanceOf(currentTestCtx.allocationMechanism),
            0,
            "Allocation mechanism should not receive tokens"
        );
    }

    function test_Contribute_WithSignature_RevertIfInsufficientRewards() public {
        uint256 stakeAmount = getStakeAmount(1000);
        uint256 rewardAmount = getRewardAmount(1000); // Larger reward amount to avoid InvalidRewardRate
        uint256 contributeAmount = getRewardAmount(2000); // Try to contribute more than available

        address allocationMechanism = _deployAllocationMechanism();

        // Advance to allow signup (startBlock + votingDelay period)
        vm.roll(block.number + 5);

        authorizeUser(alice, true, true, true);

        // Fund and stake
        stakeToken.mint(alice, stakeAmount);
        rewardToken.mint(address(regenStaker), rewardAmount);

        vm.startPrank(alice);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, alice);
        vm.stopPrank();

        // Notify rewards
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);
        vm.warp(block.timestamp + regenStaker.rewardDuration());

        uint256 unclaimedAmount = regenStaker.unclaimedReward(depositId);

        // Create signature
        uint256 nonce = TokenizedAllocationMechanism(allocationMechanism).nonces(alice);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = _getSignupDigest(
            allocationMechanism,
            alice,
            address(regenStaker),
            contributeAmount,
            nonce,
            deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = _signDigest(digest, ALICE_PRIVATE_KEY);

        // Give Alice tokens and approve for the expected flow
        rewardToken.mint(alice, contributeAmount);
        vm.startPrank(alice);
        rewardToken.approve(allocationMechanism, contributeAmount);

        // Should revert with CantAfford
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.CantAfford.selector, contributeAmount, unclaimedAmount));
        regenStaker.contribute(depositId, allocationMechanism, contributeAmount, deadline, v, r, s);
        vm.stopPrank();
    }

    function test_Contribute_WithSignature_RevertIfNotAllowseted() public {
        uint256 stakeAmount = getStakeAmount(1000);
        uint256 rewardAmount = getRewardAmount(10000);
        uint256 contributeAmount = getRewardAmount(100);

        // Deploy OctantQFMechanism directly to test contribution access control
        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(rewardToken)),
            name: "Test Allocation",
            symbol: "TEST",
            votingDelay: 1,
            votingPeriod: 8 days,
            quorumShares: 1e18,
            timelockDelay: 1 days,
            gracePeriod: 7 days,
            owner: address(this)
        });

        OctantQFMechanism octantQF = new OctantQFMechanism(
            allocationFactory.tokenizedAllocationImplementation(),
            config,
            50, // alphaNumerator
            100, // alphaDenominator
            contributorAllowset, // contributionAllowset
            IAddressSet(address(0)), // contributionBlockset
            AccessMode.ALLOWSET
        );
        address allocationMechanism = address(octantQF);

        approveMechanism(allocationMechanism);

        // Advance to allow signup (startBlock + votingDelay period)
        vm.roll(block.number + 5);

        // Don't allowset alice for contribution (only for staking)
        authorizeUser(alice, true, false, true);

        // Fund and stake
        stakeToken.mint(alice, stakeAmount);
        rewardToken.mint(address(regenStaker), rewardAmount);

        vm.startPrank(alice);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, alice);
        vm.stopPrank();

        // Notify rewards
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);
        vm.warp(block.timestamp + regenStaker.rewardDuration());

        // Create signature
        uint256 nonce = TokenizedAllocationMechanism(allocationMechanism).nonces(alice);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = _getSignupDigest(
            allocationMechanism,
            alice,
            address(regenStaker),
            contributeAmount,
            nonce,
            deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = _signDigest(digest, ALICE_PRIVATE_KEY);

        // Alice is not allowseted for contribution, defense-in-depth check rejects
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                RegenStakerBase.DepositOwnerNotEligibleForMechanism.selector,
                allocationMechanism,
                alice
            )
        );
        regenStaker.contribute(depositId, allocationMechanism, contributeAmount, deadline, v, r, s);
    }

    function test_Contribute_WithSignature_RevertWhenPaused() public {
        uint256 stakeAmount = getStakeAmount(1000);
        uint256 rewardAmount = getRewardAmount(10000);
        uint256 contributeAmount = getRewardAmount(100);

        address allocationMechanism = _deployAllocationMechanism();

        // Advance to allow signup (startBlock + votingDelay period)
        vm.roll(block.number + 5);

        authorizeUser(alice, true, true, true);

        // Fund and stake
        stakeToken.mint(alice, stakeAmount);
        rewardToken.mint(address(regenStaker), rewardAmount);

        vm.startPrank(alice);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, alice);
        vm.stopPrank();

        // Notify rewards
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);
        vm.warp(block.timestamp + regenStaker.rewardDuration());

        // Pause the contract
        vm.prank(ADMIN);
        regenStaker.pause();

        // Create signature
        uint256 nonce = TokenizedAllocationMechanism(allocationMechanism).nonces(alice);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = _getSignupDigest(
            allocationMechanism,
            alice,
            address(regenStaker),
            contributeAmount,
            nonce,
            deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = _signDigest(digest, ALICE_PRIVATE_KEY);

        // Give Alice tokens and approve for the expected flow
        rewardToken.mint(alice, contributeAmount);
        vm.startPrank(alice);
        rewardToken.approve(allocationMechanism, contributeAmount);

        // Should revert with EnforcedPause
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        regenStaker.contribute(depositId, allocationMechanism, contributeAmount, deadline, v, r, s);
        vm.stopPrank();
    }

    function test_Contribute_WithSignature_ExpiredDeadline() public {
        uint256 stakeAmount = getStakeAmount(1000);
        uint256 rewardAmount = getRewardAmount(10000);
        uint256 contributeAmount = getRewardAmount(100);

        address allocationMechanism = _deployAllocationMechanism();

        // Advance to allow signup (startBlock + votingDelay period)
        vm.roll(block.number + 5);

        authorizeUser(alice, true, true, true);

        // Fund and stake
        stakeToken.mint(alice, stakeAmount);
        rewardToken.mint(address(regenStaker), rewardAmount);

        vm.startPrank(alice);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, alice);
        vm.stopPrank();

        // Notify rewards
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);
        vm.warp(block.timestamp + regenStaker.rewardDuration());

        // Create signature with expired deadline
        uint256 nonce = TokenizedAllocationMechanism(allocationMechanism).nonces(alice);
        uint256 deadline = block.timestamp - 1; // Expired

        bytes32 digest = _getSignupDigest(
            allocationMechanism,
            alice,
            address(regenStaker),
            contributeAmount,
            nonce,
            deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = _signDigest(digest, ALICE_PRIVATE_KEY);

        // Give Alice tokens and approve for the expected flow
        rewardToken.mint(alice, contributeAmount);
        vm.startPrank(alice);
        rewardToken.approve(allocationMechanism, contributeAmount);

        // Should revert with ExpiredSignature from TokenizedAllocationMechanism
        vm.expectRevert(); // The exact error will be from TokenizedAllocationMechanism
        regenStaker.contribute(depositId, allocationMechanism, contributeAmount, deadline, v, r, s);
        vm.stopPrank();
    }

    function test_Contribute_WithSignature_RevertIfAllocationMechanismNotAllowseted() public {
        uint256 stakeAmount = getStakeAmount(1000);
        uint256 rewardAmount = getRewardAmount(10000);
        uint256 contributeAmount = getRewardAmount(100);

        // Deploy allocation mechanism but don't allowset it
        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(rewardToken)),
            name: "Test Allocation",
            symbol: "TEST",
            votingDelay: 1,
            votingPeriod: 1000,
            quorumShares: 1e18,
            timelockDelay: 1 days,
            gracePeriod: 7 days,
            owner: address(0)
        });
        // Deploy QuadraticVotingMechanism instead of SimpleVotingMechanism
        address allocationMechanism = allocationFactory.deployQuadraticVotingMechanism(config, 50, 100);

        // Advance to allow signup (startBlock + votingDelay period)
        vm.roll(block.number + 5);

        authorizeUser(alice, true, true, true);

        // Fund and stake
        stakeToken.mint(alice, stakeAmount);
        rewardToken.mint(address(regenStaker), rewardAmount);

        vm.startPrank(alice);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, alice);
        vm.stopPrank();

        // Notify rewards
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);
        vm.warp(block.timestamp + regenStaker.rewardDuration());

        // Create signature
        uint256 nonce = TokenizedAllocationMechanism(allocationMechanism).nonces(alice);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = _getSignupDigest(
            allocationMechanism,
            alice,
            address(regenStaker),
            contributeAmount,
            nonce,
            deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = _signDigest(digest, ALICE_PRIVATE_KEY);

        // Give Alice tokens and approve for the expected flow
        rewardToken.mint(alice, contributeAmount);
        vm.startPrank(alice);
        rewardToken.approve(allocationMechanism, contributeAmount);

        // Should revert with NotAllowseted for allocation mechanism
        vm.expectRevert(abi.encodeWithSelector(NotInAllowset.selector, allocationMechanism));
        regenStaker.contribute(depositId, allocationMechanism, contributeAmount, deadline, v, r, s);
        vm.stopPrank();
    }

    function testFuzz_RevertIf_Contribute_GrantRoundAddressZero(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase,
        uint256 contributionAmountBase
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        rewardAmountBase = bound(rewardAmountBase, regenStaker.rewardDuration(), MAX_REWARD_DURATION + 1_000_000_000);
        contributionAmountBase = bound(contributionAmountBase, 1, 1_000);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        uint256 rewardAmount = getRewardAmount(rewardAmountBase);
        uint256 contributionAmount = getRewardAmount(contributionAmountBase);

        uint256 contributorPrivateKey = uint256(keccak256(abi.encodePacked("contributor")));
        address contributor = vm.addr(contributorPrivateKey);

        authorizeUser(contributor, true, true, true);

        stakeToken.mint(contributor, stakeAmount);
        rewardToken.mint(address(regenStaker), rewardAmount);

        vm.startPrank(contributor);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, contributor);
        vm.stopPrank();

        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);
        vm.warp(block.timestamp + regenStaker.rewardDuration());

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = keccak256("mock");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(contributorPrivateKey, digest);

        vm.startPrank(contributor);
        vm.expectRevert(abi.encodeWithSelector(Staker.Staker__InvalidAddress.selector));
        regenStaker.contribute(depositId, address(0), contributionAmount, deadline, v, r, s);
        vm.stopPrank();
    }
}
