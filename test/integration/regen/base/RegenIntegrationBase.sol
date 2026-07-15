// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { AccessMode } from "src/constants.sol";
import "forge-std/Test.sol";
import "forge-std/console.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Staking } from "staker/interfaces/IERC20Staking.sol";
import { Staker } from "staker/Staker.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockERC20Staking } from "test/mocks/MockERC20Staking.sol";
import { TokenizedAllocationMechanism } from "src/mechanisms/TokenizedAllocationMechanism.sol";
import { OctantQFMechanism } from "src/mechanisms/mechanism/OctantQFMechanism.sol";
// import { SimpleVotingMechanism } from "test/mocks/SimpleVotingMechanism.sol"; // SimpleVotingMechanism removed
import { AllocationMechanismFactory } from "src/mechanisms/AllocationMechanismFactory.sol";
import { AllocationConfig } from "src/mechanisms/BaseAllocationMechanism.sol";

/// @title RegenIntegrationBase
/// @notice Shared scaffolding (state, helpers, setUp) for the RegenStaker integration suites.
/// @dev setUp() is virtual; concern suites may override to tune the deployment.
abstract contract RegenIntegrationBase is Test {
    RegenStaker regenStaker;

    // Event declarations
    event RewardDurationSet(uint256 newDuration);

    RegenEarningPowerCalculator calculator;
    AddressSet stakerAllowset;
    AddressSet contributorAllowset;
    AddressSet allocationMechanismAllowset;
    AddressSet earningPowerAllowset;
    MockERC20 rewardToken;
    MockERC20Staking stakeToken;
    AllocationMechanismFactory allocationFactory;

    uint256 public constant REWARD_AMOUNT_BASE = 30_000_000;
    uint256 public constant STAKE_AMOUNT_BASE = 1_000;
    uint256 public constant MAX_BUMP_TIP = 1e18;
    uint256 public constant MAX_CLAIM_FEE = 1e18;
    uint256 public constant MIN_REWARD_DURATION = 7 days;
    uint256 public constant MAX_REWARD_DURATION = 3000 days;

    uint256 public constant ONE_PICO = 1e8;
    uint256 public constant ONE_NANO = 1e11;
    uint256 public constant ONE_MICRO = 1e14;
    uint256 public constant ONE_PERCENT = 1e16; // 1% tolerance for extreme edge cases

    address public immutable ADMIN = makeAddr("admin");
    uint8 public rewardTokenDecimals = 18;
    uint8 public stakeTokenDecimals = 18;

    // EIP-2612 signature constants for contribute testing
    bytes32 private constant TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant SIGNUP_TYPEHASH =
        keccak256("Signup(address user,address payer,uint256 deposit,uint256 nonce,uint256 deadline)");
    string private constant EIP712_VERSION = "1";

    // Test accounts with known private keys for signature testing
    uint256 constant ALICE_PRIVATE_KEY = 0x1;
    uint256 constant BOB_PRIVATE_KEY = 0x2;
    address alice;
    address bob;

    /// @notice Test context struct for stack optimization
    /// @dev Consolidates test variables into storage to prevent stack too deep issues
    struct TestContext {
        uint256 stakeAmount;
        uint256 rewardAmount;
        uint256 contributeAmount;
        address allocationMechanism;
        Staker.DepositIdentifier depositId;
        uint256 unclaimedBefore;
        uint256 nonce;
        uint256 deadline;
        uint256 netContribution;
        bytes32 digest;
        uint8 v;
        bytes32 r;
        bytes32 s;
        uint256 actualContribution;
        // Additional fields for compound rewards tests
        uint256 user1StakeBase;
        uint256 user2StakeBase;
        uint256 rewardAmountBase;
        uint256 user2JoinTimePercent;
        address user1;
        address user2;
        uint256 user1Stake;
        uint256 user2Stake;
        Staker.DepositIdentifier depositId1;
        Staker.DepositIdentifier depositId2;
        uint256 unclaimed1;
        uint256 unclaimed2;
        uint256 compounded1;
        uint256 compounded2;
        uint256 soloPhaseRewards;
        uint256 sharedPhaseRewards;
        uint256 totalStake;
        RegenStaker compoundRegenStaker;
        MockERC20Staking sameToken;
        // Additional fields for fee tests
        uint256 feeAmount;
        address feeCollector;
        uint256 feeCollectorBalanceBefore;
    }

    /// @notice Storage-based test context for stack optimization
    TestContext internal currentTestCtx;

    /// @notice Clear test context for fresh initialization
    function _clearTestContext() internal {
        currentTestCtx.stakeAmount = 0;
        currentTestCtx.rewardAmount = 0;
        currentTestCtx.contributeAmount = 0;
        currentTestCtx.allocationMechanism = address(0);
        currentTestCtx.depositId = Staker.DepositIdentifier.wrap(0);
        currentTestCtx.unclaimedBefore = 0;
        currentTestCtx.nonce = 0;
        currentTestCtx.deadline = 0;
        currentTestCtx.netContribution = 0;
        currentTestCtx.digest = bytes32(0);
        currentTestCtx.v = 0;
        currentTestCtx.r = bytes32(0);
        currentTestCtx.s = bytes32(0);
        currentTestCtx.actualContribution = 0;

        // Clear compound rewards test fields
        currentTestCtx.user1StakeBase = 0;
        currentTestCtx.user2StakeBase = 0;
        currentTestCtx.rewardAmountBase = 0;
        currentTestCtx.user2JoinTimePercent = 0;
        currentTestCtx.user1 = address(0);
        currentTestCtx.user2 = address(0);
        currentTestCtx.user1Stake = 0;
        currentTestCtx.user2Stake = 0;
        currentTestCtx.depositId1 = Staker.DepositIdentifier.wrap(0);
        currentTestCtx.depositId2 = Staker.DepositIdentifier.wrap(0);
        currentTestCtx.unclaimed1 = 0;
        currentTestCtx.unclaimed2 = 0;
        currentTestCtx.compounded1 = 0;
        currentTestCtx.compounded2 = 0;
        currentTestCtx.soloPhaseRewards = 0;
        currentTestCtx.sharedPhaseRewards = 0;
        currentTestCtx.totalStake = 0;
        // Note: compoundRegenStaker and sameToken are reference types, set to storage defaults
        delete currentTestCtx.compoundRegenStaker;
        delete currentTestCtx.sameToken;

        // Clear fee test fields
        currentTestCtx.feeAmount = 0;
        currentTestCtx.feeCollector = address(0);
        currentTestCtx.feeCollectorBalanceBefore = 0;
    }

    function getRewardAmount() internal view returns (uint256) {
        return REWARD_AMOUNT_BASE * (10 ** rewardTokenDecimals);
    }

    function getRewardAmount(uint256 baseAmount) internal view returns (uint256) {
        return baseAmount * (10 ** rewardTokenDecimals);
    }

    function getStakeAmount() internal view returns (uint256) {
        return STAKE_AMOUNT_BASE * (10 ** stakeTokenDecimals);
    }

    function getStakeAmount(uint256 baseAmount) internal view returns (uint256) {
        return baseAmount * (10 ** stakeTokenDecimals);
    }

    function authorizeUser(address user, bool forStaking, bool forContributing, bool forEarningPower) internal {
        vm.startPrank(ADMIN);
        if (forStaking) stakerAllowset.add(user);
        if (forContributing) contributorAllowset.add(user);
        if (forEarningPower) earningPowerAllowset.add(user);
        vm.stopPrank();
    }

    function approveMechanism(address allocationMechanism) internal {
        vm.prank(ADMIN);
        allocationMechanismAllowset.add(allocationMechanism);
    }

    function setUp() public virtual {
        rewardTokenDecimals = uint8(bound(vm.randomUint(), 6, 18));
        stakeTokenDecimals = uint8(bound(vm.randomUint(), 6, 18));
        uint256 rewardDuration = bound(vm.randomUint(), uint128(MIN_REWARD_DURATION), MAX_REWARD_DURATION);

        vm.startPrank(ADMIN);

        rewardToken = new MockERC20(rewardTokenDecimals);
        stakeToken = new MockERC20Staking(stakeTokenDecimals);

        stakerAllowset = new AddressSet();
        contributorAllowset = new AddressSet();
        allocationMechanismAllowset = new AddressSet();
        earningPowerAllowset = new AddressSet();

        calculator = new RegenEarningPowerCalculator(
            ADMIN,
            earningPowerAllowset,
            IAddressSet(address(0)),
            AccessMode.ALLOWSET
        );

        allocationFactory = new AllocationMechanismFactory();

        regenStaker = new RegenStaker(
            IERC20(address(rewardToken)),
            IERC20Staking(address(stakeToken)),
            calculator,
            MAX_BUMP_TIP,
            ADMIN,
            uint128(rewardDuration),
            0,
            stakerAllowset,
            IAddressSet(address(0)),
            AccessMode.NONE,
            allocationMechanismAllowset
        );

        regenStaker.setRewardNotifier(ADMIN, true);
        vm.stopPrank();

        alice = vm.addr(ALICE_PRIVATE_KEY);
        bob = vm.addr(BOB_PRIVATE_KEY);
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }

    // ============ EIP712 Helper Functions for Contribute Tests ============

    function _computeDomainSeparator(string memory name, address verifyingContract) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    TYPE_HASH,
                    keccak256(bytes(name)),
                    keccak256(bytes(EIP712_VERSION)),
                    block.chainid,
                    verifyingContract
                )
            );
    }

    function _getSignupDigest(
        address allocationMechanism,
        address user,
        address payer,
        uint256 deposit,
        uint256 nonce,
        uint256 deadline
    ) internal returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(SIGNUP_TYPEHASH, user, payer, deposit, nonce, deadline));
        bytes32 domainSeparator = TokenizedAllocationMechanism(allocationMechanism).DOMAIN_SEPARATOR();
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _signDigest(bytes32 digest, uint256 privateKey) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        (v, r, s) = vm.sign(privateKey, digest);
    }

    function _deployAllocationMechanism() internal returns (address) {
        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(rewardToken)),
            name: "Test Allocation",
            symbol: "TEST",
            votingDelay: 1,
            votingPeriod: 8 days, // Extended to ensure voting period overlaps with reward accumulation
            quorumShares: 1e18,
            timelockDelay: 1 days,
            gracePeriod: 7 days,
            owner: address(0) // Factory sets msg.sender as owner
        });

        // Deploy OctantQFMechanism with no access control (so canSignup() always returns true)
        config.owner = address(this); // Set owner since we're deploying directly
        OctantQFMechanism octantQF = new OctantQFMechanism(
            allocationFactory.tokenizedAllocationImplementation(),
            config,
            50, // alphaNumerator
            100, // alphaDenominator
            IAddressSet(address(0)), // contributionAllowset - null means no restrictions
            IAddressSet(address(0)), // contributionBlockset
            AccessMode.NONE // no access control
        );
        address allocationMechanism = address(octantQF);
        approveMechanism(allocationMechanism);
        return allocationMechanism;
    }

    // ============ Contribute Function Tests ============
}
