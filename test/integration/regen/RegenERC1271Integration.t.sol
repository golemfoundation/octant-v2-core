// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { AccessMode } from "src/constants.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Staking } from "staker/interfaces/IERC20Staking.sol";
import { IAccessControlledEarningPowerCalculator } from "src/regen/interfaces/IAccessControlledEarningPowerCalculator.sol";
import { Staker } from "staker/Staker.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockERC20Staking } from "test/mocks/MockERC20Staking.sol";
import { MockERC1271Signer } from "test/mocks/MockERC1271Signer.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { TokenizedAllocationMechanism } from "src/mechanisms/TokenizedAllocationMechanism.sol";
import { QuadraticVotingMechanism } from "src/mechanisms/mechanism/QuadraticVotingMechanism.sol";
import { OctantQFMechanism } from "src/mechanisms/mechanism/OctantQFMechanism.sol";
import { AllocationMechanismFactory } from "src/mechanisms/AllocationMechanismFactory.sol";
import { AllocationConfig } from "src/mechanisms/BaseAllocationMechanism.sol";

/**
 * @title RegenERC1271IntegrationTest
 * @notice Integration tests for ERC1271 signature support in RegenStaker + TokenizedAllocationMechanism
 */
contract RegenERC1271IntegrationTest is Test {
    // Main contracts
    RegenStaker regenStaker;
    QuadraticVotingMechanism allocationMechanism;
    MockERC1271Signer contractSigner;

    // Supporting contracts
    RegenEarningPowerCalculator calculator;
    AddressSet stakerAllowset;
    AddressSet contributorAllowset;
    AddressSet allocationMechanismAllowset;
    AddressSet earningPowerAllowset;
    MockERC20 rewardToken;
    MockERC20Staking stakeToken;
    AllocationMechanismFactory allocationFactory;

    // Test accounts
    address admin = address(0x1);
    address notifier = address(0x2);
    uint256 userPk = 0x59c6995e998f97436e00f7f96b1d3bb48d6c5ab2edb3b96e1f1e6da7c6c1a0e9; // Standard test private key 2
    address user = 0x1Fcd3D37EeD451c27b45d4Fc7A2746608ef28036; // Matches userPk private key
    uint256 contractSignerOwnerPk = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; // Standard test private key
    address contractSignerOwner = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; // Matches contractSignerOwnerPk private key
    address proposer = address(0x5);
    address recipient = address(0x6);

    // Constants
    uint256 constant REWARD_DURATION = 30 days;
    uint256 constant MIN_STAKE = 100e18;
    uint256 constant REWARD_AMOUNT = 1000e18;
    uint256 constant STAKE_AMOUNT = 1000e18;
    uint256 constant VOTING_DELAY = 1 days;
    uint256 constant VOTING_PERIOD = 7 days;
    uint256 constant QUORUM_SHARES = 10e18;
    uint256 constant TIMELOCK_DELAY = 2 days;
    uint256 constant GRACE_PERIOD = 7 days;

    // EIP712 Domain
    bytes32 private constant TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant SIGNUP_TYPEHASH =
        keccak256("Signup(address user,address payer,uint256 deposit,uint256 nonce,uint256 deadline)");
    string private constant EIP712_VERSION = "1";

    function setUp() public {
        vm.startPrank(admin);

        // Deploy tokens
        rewardToken = new MockERC20(18);
        stakeToken = new MockERC20Staking(18);

        // Deploy allowsets
        stakerAllowset = new AddressSet();
        contributorAllowset = new AddressSet();
        allocationMechanismAllowset = new AddressSet();
        earningPowerAllowset = new AddressSet();

        // Deploy earning power calculator
        calculator = new RegenEarningPowerCalculator(
            admin,
            earningPowerAllowset,
            IAddressSet(address(0)),
            AccessMode.ALLOWSET
        );

        // Deploy RegenStaker
        regenStaker = new RegenStaker(
            rewardToken,
            stakeToken,
            calculator,
            10, // maxBumpTip (0.001%)
            admin,
            uint128(REWARD_DURATION),
            uint128(MIN_STAKE),
            IAddressSet(stakerAllowset),
            IAddressSet(address(0)),
            AccessMode.NONE,
            IAddressSet(allocationMechanismAllowset)
        );

        // Deploy allocation mechanism factory
        allocationFactory = new AllocationMechanismFactory();

        // Deploy QuadraticVotingMechanism with proper config
        AllocationConfig memory config = AllocationConfig({
            asset: rewardToken,
            name: "Test QV Mechanism",
            symbol: "TQV",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: QUORUM_SHARES,
            timelockDelay: TIMELOCK_DELAY,
            gracePeriod: GRACE_PERIOD,
            owner: admin
        });

        // Deploy OctantQFMechanism with no access control (AccessMode.NONE)
        uint256 alphaNumerator = 1; // Default alpha = 1/1 = 1
        uint256 alphaDenominator = 1;

        OctantQFMechanism octantQF = new OctantQFMechanism(
            allocationFactory.tokenizedAllocationImplementation(),
            config,
            alphaNumerator,
            alphaDenominator,
            IAddressSet(address(0)), // contributionAllowset
            IAddressSet(address(0)), // contributionBlockset
            AccessMode.NONE // no access control
        );

        allocationMechanism = QuadraticVotingMechanism(payable(address(octantQF)));

        // Deploy contract signer before allowseting
        contractSigner = new MockERC1271Signer(contractSignerOwner);

        // Setup allowsets
        stakerAllowset.add(user);
        stakerAllowset.add(address(contractSigner)); // Contract signer needs to be allowseted as staker
        contributorAllowset.add(user);
        contributorAllowset.add(address(contractSigner)); // Contract signer needs to be allowseted as contributor
        allocationMechanismAllowset.add(address(allocationMechanism));
        earningPowerAllowset.add(address(regenStaker));
        earningPowerAllowset.add(user); // User needs earning power
        earningPowerAllowset.add(address(contractSigner)); // Contract signer needs earning power

        // Setup reward notifier
        regenStaker.setRewardNotifier(notifier, true);

        // Fund accounts
        rewardToken.mint(notifier, REWARD_AMOUNT * 10);
        stakeToken.mint(user, STAKE_AMOUNT);
        stakeToken.mint(address(contractSigner), STAKE_AMOUNT);

        vm.stopPrank();
    }

    function testContractSignerCanContributeWithERC1271() public {
        // First, contract signer needs to stake
        vm.startPrank(address(contractSigner));
        stakeToken.approve(address(regenStaker), STAKE_AMOUNT);
        RegenStakerBase.DepositIdentifier depositId = regenStaker.stake(STAKE_AMOUNT, address(contractSigner));
        vm.stopPrank();

        // Add rewards
        vm.startPrank(notifier);
        rewardToken.transfer(address(regenStaker), REWARD_AMOUNT);
        regenStaker.notifyRewardAmount(REWARD_AMOUNT);
        vm.stopPrank();

        // Wait for some rewards to accrue (but not too long to exceed voting period)
        vm.warp(block.timestamp + 1 days); // Just 1 day instead of 15 days

        // Check unclaimed rewards
        uint256 unclaimedRewards = regenStaker.unclaimedReward(depositId);
        assertGt(unclaimedRewards, 0, "Should have accrued rewards");

        // Contract signer approves allocation mechanism to pull tokens
        vm.prank(address(contractSigner));
        rewardToken.approve(address(allocationMechanism), unclaimedRewards);

        // Prepare signature from contract signer's owner
        uint256 contributionAmount = unclaimedRewards / 2; // Contribute half of rewards
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = TokenizedAllocationMechanism(address(allocationMechanism)).nonces(address(contractSigner));

        // Get the actual domain separator from the contract
        bytes32 domainSeparator = TokenizedAllocationMechanism(address(allocationMechanism)).DOMAIN_SEPARATOR();

        // Create struct hash - msg.sender in signupOnBehalfWithSignature context is the RegenStaker!
        bytes32 structHash = keccak256(
            abi.encode(
                SIGNUP_TYPEHASH,
                address(contractSigner), // user
                address(regenStaker), // msg.sender (payer)
                contributionAmount, // deposit
                nonce,
                deadline
            )
        );

        // Create digest
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Sign with contract signer's owner
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(contractSignerOwnerPk, digest);

        // Contract signer contributes to allocation mechanism
        vm.startPrank(address(contractSigner));
        uint256 contributedAmount = regenStaker.contribute(
            depositId,
            address(allocationMechanism),
            contributionAmount,
            deadline,
            v,
            r,
            s
        );
        vm.stopPrank();

        // Verify contribution was successful
        assertEq(contributedAmount, contributionAmount, "Should have contributed requested amount");

        // Verify contract signer received voting power
        uint256 votingPower = TokenizedAllocationMechanism(address(allocationMechanism)).votingPower(
            address(contractSigner)
        );
        assertGt(votingPower, 0, "Contract signer should have voting power");

        // Verify contract signer can vote
        // First create a proposal (admin can propose as they are management)
        vm.prank(admin);
        uint256 proposalId = TokenizedAllocationMechanism(address(allocationMechanism)).propose(
            recipient,
            "Test proposal for contract signer"
        );

        // Move to voting period
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        // Prepare vote signature - use sqrt of voting power for quadratic voting
        uint256 voteWeight = 1; // Start with a small weight
        uint256 voteDeadline = block.timestamp + 1 hours;
        uint256 voteNonce = TokenizedAllocationMechanism(address(allocationMechanism)).nonces(address(contractSigner));

        // Create vote struct hash
        bytes32 CAST_VOTE_TYPEHASH = keccak256(
            "CastVote(address voter,uint256 proposalId,uint8 choice,uint256 weight,address expectedRecipient,uint256 nonce,uint256 deadline)"
        );

        bytes32 voteStructHash = keccak256(
            abi.encode(
                CAST_VOTE_TYPEHASH,
                address(contractSigner),
                proposalId,
                uint8(1), // For vote
                voteWeight,
                recipient,
                voteNonce,
                voteDeadline
            )
        );

        // Create vote digest
        bytes32 voteDigest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, voteStructHash));

        // Sign vote with contract signer's owner
        (uint8 voteV, bytes32 voteR, bytes32 voteS) = vm.sign(contractSignerOwnerPk, voteDigest);

        // Contract signer casts vote
        vm.prank(address(contractSigner));
        TokenizedAllocationMechanism(address(allocationMechanism)).castVoteWithSignature(
            address(contractSigner),
            proposalId,
            TokenizedAllocationMechanism.VoteType.For,
            voteWeight,
            recipient,
            voteDeadline,
            voteV,
            voteR,
            voteS
        );

        // Verify vote was cast
        uint256 remainingVotingPower = TokenizedAllocationMechanism(address(allocationMechanism)).votingPower(
            address(contractSigner)
        );
        assertLt(remainingVotingPower, votingPower, "Voting power should have decreased after voting");
    }

    function testEOASignerStillWorksAfterERC1271Update() public {
        // Regular EOA user stakes
        vm.startPrank(user);
        stakeToken.approve(address(regenStaker), STAKE_AMOUNT);
        RegenStakerBase.DepositIdentifier depositId = regenStaker.stake(STAKE_AMOUNT, user);
        vm.stopPrank();

        // Add rewards
        vm.startPrank(notifier);
        rewardToken.transfer(address(regenStaker), REWARD_AMOUNT);
        regenStaker.notifyRewardAmount(REWARD_AMOUNT);
        vm.stopPrank();

        // Wait for rewards (but not too long to exceed voting period)
        vm.warp(block.timestamp + 1 days);

        // User approves and contributes
        uint256 unclaimedRewards = regenStaker.unclaimedReward(depositId);
        uint256 contributionAmount = unclaimedRewards / 2;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = TokenizedAllocationMechanism(address(allocationMechanism)).nonces(user);

        vm.prank(user);
        rewardToken.approve(address(allocationMechanism), unclaimedRewards);

        // Get the actual domain separator from the contract
        bytes32 domainSeparator = TokenizedAllocationMechanism(address(allocationMechanism)).DOMAIN_SEPARATOR();

        bytes32 structHash = keccak256(
            abi.encode(
                SIGNUP_TYPEHASH,
                user, // user
                address(regenStaker), // msg.sender (payer)
                contributionAmount, // deposit
                nonce,
                deadline
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Sign with EOA
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);

        vm.startPrank(user);

        // Contribute
        uint256 contributedAmount = regenStaker.contribute(
            depositId,
            address(allocationMechanism),
            contributionAmount,
            deadline,
            v,
            r,
            s
        );
        vm.stopPrank();

        // Verify contribution was successful
        assertEq(contributedAmount, contributionAmount, "EOA should still be able to contribute");
        assertGt(
            TokenizedAllocationMechanism(address(allocationMechanism)).votingPower(user),
            0,
            "EOA should have voting power"
        );
    }
}
