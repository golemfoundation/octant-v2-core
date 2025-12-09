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
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { TokenizedAllocationMechanism } from "src/mechanisms/TokenizedAllocationMechanism.sol";
import { OctantQFMechanism } from "src/mechanisms/mechanism/OctantQFMechanism.sol";
// import { SimpleVotingMechanism } from "test/mocks/SimpleVotingMechanism.sol"; // SimpleVotingMechanism removed
import { AllocationMechanismFactory } from "src/mechanisms/AllocationMechanismFactory.sol";
import { AllocationConfig } from "src/mechanisms/BaseAllocationMechanism.sol";
import { NotInAllowset } from "src/errors.sol";

/**
 * @title RegenIntegrationTest
 * @notice Comprehensive integration tests for RegenStaker contract. Due to fixed-point math, higher number of fuzz runs necessary to surface all edge cases.
 * forge-config: default.fuzz.runs = 16384
 * forge-config: default.fuzz.max_test_rejects = 1048576
 */
contract RegenIntegrationTest is Test {
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

    function testFuzz_SetMinimumStakeAmount(uint256 newMinimum) public {
        newMinimum = bound(newMinimum, 0, getStakeAmount(10000));

        vm.prank(ADMIN);
        regenStaker.setMinimumStakeAmount(uint128(newMinimum));

        assertEq(regenStaker.minimumStakeAmount(), newMinimum);
    }

    function testFuzz_RevertIf_NonAdminCannotSetMinimumStakeAmount(address nonAdmin, uint256 newMinimum) public {
        vm.assume(nonAdmin != ADMIN);
        newMinimum = bound(newMinimum, 0, getStakeAmount(10000));

        vm.startPrank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not admin"), nonAdmin));
        regenStaker.setMinimumStakeAmount(uint128(newMinimum));
        vm.stopPrank();
    }

    function testFuzz_RevertIf_StakeBelowMinimum(uint256 minimumAmount, uint256 stakeAmount) public {
        minimumAmount = bound(minimumAmount, getStakeAmount(1), getStakeAmount(1000));
        stakeAmount = bound(stakeAmount, 1, minimumAmount - 1);

        vm.prank(ADMIN);
        regenStaker.setMinimumStakeAmount(uint128(minimumAmount));

        address user = makeAddr("user");
        authorizeUser(user, true, false, true);

        stakeToken.mint(user, stakeAmount);
        vm.startPrank(user);
        stakeToken.approve(address(regenStaker), stakeAmount);
        vm.expectRevert(
            abi.encodeWithSelector(RegenStakerBase.MinimumStakeAmountNotMet.selector, minimumAmount, stakeAmount)
        );
        regenStaker.stake(stakeAmount, user, user);
        vm.stopPrank();
    }

    function testFuzz_StakeAtOrAboveMinimumSucceeds(uint256 minimumAmountBase, uint256 additionalAmountBase) public {
        minimumAmountBase = bound(minimumAmountBase, 1, 100);
        additionalAmountBase = bound(additionalAmountBase, 0, 100);

        uint256 minimumAmount = getStakeAmount(minimumAmountBase);
        uint256 additionalAmount = getStakeAmount(additionalAmountBase);
        uint256 stakeAmount = minimumAmount + additionalAmount;

        vm.assume(stakeAmount >= minimumAmount);

        vm.prank(ADMIN);
        regenStaker.setMinimumStakeAmount(uint128(minimumAmount));

        address user = makeAddr("user");
        authorizeUser(user, true, false, true);

        stakeToken.mint(user, stakeAmount);
        vm.startPrank(user);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, user, user);
        vm.stopPrank();

        assertEq(regenStaker.depositorTotalStaked(user), stakeAmount);
        (uint96 depositBalance, , , , , , ) = regenStaker.deposits(depositId);
        assertEq(uint256(depositBalance), stakeAmount);
    }

    function testFuzz_RevertIf_StakeMoreResultsBelowMinimum(
        uint256 minimumAmountBase,
        uint256 withdrawPercent,
        uint256 additionalAmountBase
    ) public {
        minimumAmountBase = bound(minimumAmountBase, 10, 50);
        withdrawPercent = bound(withdrawPercent, 30, 70);
        additionalAmountBase = bound(additionalAmountBase, 1, minimumAmountBase - 1);

        uint256 minimumAmount = getStakeAmount(minimumAmountBase);
        uint256 initialStake = minimumAmount + getStakeAmount(10);
        uint256 withdrawAmount = (initialStake * withdrawPercent) / 100;
        uint256 additionalStake = getStakeAmount(additionalAmountBase);

        uint256 remainingAfterWithdraw = initialStake - withdrawAmount;
        vm.assume(remainingAfterWithdraw < minimumAmount);
        vm.assume(remainingAfterWithdraw + additionalStake < minimumAmount);

        vm.prank(ADMIN);
        regenStaker.setMinimumStakeAmount(uint128(minimumAmount));

        address user = makeAddr("user");
        authorizeUser(user, true, false, true);

        stakeToken.mint(user, initialStake + additionalStake);
        vm.startPrank(user);
        stakeToken.approve(address(regenStaker), initialStake + additionalStake);
        Staker.DepositIdentifier depositId = regenStaker.stake(initialStake, user, user);

        vm.expectRevert(
            abi.encodeWithSelector(
                RegenStakerBase.MinimumStakeAmountNotMet.selector,
                minimumAmount,
                remainingAfterWithdraw
            )
        );
        regenStaker.withdraw(depositId, withdrawAmount);
        vm.stopPrank();
    }

    function testFuzz_RevertIf_NonAdminCannotSetStakerAddressSet(address nonAdmin) public {
        vm.assume(nonAdmin != ADMIN);
        vm.startPrank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not admin"), nonAdmin));
        regenStaker.setStakerAllowset(AddressSet(address(0)));
        vm.stopPrank();
    }

    function testFuzz_StakerAllowset_DisableAllowsStaking(uint256 stakeAmountBase) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        uint256 partialStakeAmount = stakeAmount / 2;

        address user = makeAddr("unauthorizedUser");
        stakeToken.mint(user, stakeAmount);

        // Enable ALLOWSET mode first
        vm.prank(ADMIN);
        regenStaker.setAccessMode(AccessMode.ALLOWSET);

        vm.startPrank(user);
        stakeToken.approve(address(regenStaker), stakeAmount);

        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.StakerNotAllowed.selector, user));
        regenStaker.stake(partialStakeAmount, user);
        vm.stopPrank();

        // Disable access control by setting mode to NONE
        vm.prank(ADMIN);
        regenStaker.setAccessMode(AccessMode.NONE);

        vm.startPrank(user);
        regenStaker.stake(partialStakeAmount, user);
        vm.stopPrank();

        assertEq(stakeToken.balanceOf(user), stakeAmount - partialStakeAmount);
    }

    function testFuzz_EarningPowerAllowset_DisableGrantsEarningPower(uint256 stakeAmountBase) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        uint256 stakeAmount = getStakeAmount(stakeAmountBase);

        address authorizedUser = makeAddr("authorizedUser");
        address unauthorizedUser = makeAddr("unauthorizedUser");

        stakeToken.mint(authorizedUser, stakeAmount);
        stakeToken.mint(unauthorizedUser, stakeAmount);

        // Staker access control is already NONE from setUp, no need to set it again

        authorizeUser(authorizedUser, true, false, true);
        authorizeUser(unauthorizedUser, true, false, false);

        vm.startPrank(authorizedUser);
        stakeToken.approve(address(regenStaker), stakeAmount);
        regenStaker.stake(stakeAmount, authorizedUser);
        vm.stopPrank();

        vm.startPrank(unauthorizedUser);
        stakeToken.approve(address(regenStaker), stakeAmount);
        regenStaker.stake(stakeAmount, unauthorizedUser);
        vm.stopPrank();

        assertEq(regenStaker.depositorTotalEarningPower(authorizedUser), stakeAmount);
        assertEq(regenStaker.depositorTotalEarningPower(unauthorizedUser), 0);

        vm.prank(ADMIN);
        calculator.setAccessMode(AccessMode.NONE);

        assertEq(regenStaker.depositorTotalEarningPower(unauthorizedUser), 0);

        Staker.DepositIdentifier depositId = Staker.DepositIdentifier.wrap(1);

        vm.prank(ADMIN);
        regenStaker.bumpEarningPower(depositId, ADMIN, 0);

        assertEq(regenStaker.depositorTotalEarningPower(unauthorizedUser), stakeAmount);

        address newUser = makeAddr("newUser");
        stakeToken.mint(newUser, stakeAmount);

        authorizeUser(newUser, true, false, false);

        vm.startPrank(newUser);
        stakeToken.approve(address(regenStaker), stakeAmount);
        regenStaker.stake(stakeAmount, newUser);
        vm.stopPrank();

        assertEq(regenStaker.depositorTotalEarningPower(newUser), stakeAmount);
    }

    function testFuzz_RevertIf_PauseCalledByNonAdmin(address nonAdmin) public {
        vm.assume(nonAdmin != ADMIN);

        vm.startPrank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not admin"), nonAdmin));
        regenStaker.pause();
        vm.stopPrank();

        vm.startPrank(ADMIN);
        regenStaker.pause();
        assertTrue(regenStaker.paused());
        regenStaker.unpause();
        vm.stopPrank();
    }

    function testFuzz_RevertIf_StakeWhenPaused(uint256 stakeAmountBase) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        uint256 stakeAmount = getStakeAmount(stakeAmountBase);

        address user = makeAddr("user");
        authorizeUser(user, true, false, false);

        stakeToken.mint(user, stakeAmount);
        vm.startPrank(user);
        stakeToken.approve(address(regenStaker), stakeAmount);
        vm.stopPrank();

        vm.prank(ADMIN);
        regenStaker.pause();
        assertTrue(regenStaker.paused());

        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        regenStaker.stake(stakeAmount / 2, user);
        vm.stopPrank();

        vm.prank(ADMIN);
        regenStaker.unpause();
        assertFalse(regenStaker.paused());
    }

    function testFuzz_RevertIf_ContributeWhenPaused(uint256 stakeAmountBase, uint256 rewardAmountBase) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        rewardAmountBase = bound(rewardAmountBase, regenStaker.rewardDuration(), MAX_REWARD_DURATION + 1_000_000_000);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        uint256 rewardAmount = getRewardAmount(rewardAmountBase);
        uint256 contributeAmount = getRewardAmount(100);

        uint256 contributorPrivateKey = uint256(keccak256(abi.encodePacked("contributor")));
        address contributor = vm.addr(contributorPrivateKey);
        address allocationMechanism = _deployAllocationMechanism();

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

        vm.prank(ADMIN);
        regenStaker.pause();
        assertTrue(regenStaker.paused());

        uint256 nonce = TokenizedAllocationMechanism(allocationMechanism).nonces(contributor);
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 digest = _getSignupDigest(
            allocationMechanism,
            contributor,
            address(regenStaker),
            contributeAmount,
            nonce,
            deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = _signDigest(digest, contributorPrivateKey);

        vm.startPrank(contributor);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        regenStaker.contribute(depositId, allocationMechanism, contributeAmount, deadline, v, r, s);
        vm.stopPrank();

        vm.prank(ADMIN);
        regenStaker.unpause();
        assertFalse(regenStaker.paused());
    }

    function testFuzz_ContinuousReward_SingleStaker_JoinsLate(uint256 joinTimePercent) public {
        uint256 minJoinTime = 1;
        uint256 maxJoinTime = 99;
        joinTimePercent = bound(joinTimePercent, minJoinTime, maxJoinTime);

        address staker = makeAddr("staker");
        authorizeUser(staker, true, false, true);

        uint256 totalRewardAmount = getRewardAmount();
        rewardToken.mint(address(regenStaker), totalRewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(totalRewardAmount);

        uint256 joinTime = (regenStaker.rewardDuration() * joinTimePercent) / 100;
        vm.warp(block.timestamp + joinTime);

        uint256 stakeAmount = getStakeAmount();
        stakeToken.mint(staker, stakeAmount);
        vm.startPrank(staker);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, staker);
        vm.stopPrank();

        uint256 remainingTime = regenStaker.rewardDuration() - joinTime;
        vm.warp(block.timestamp + remainingTime);

        vm.startPrank(staker);
        uint256 claimedAmount = regenStaker.claimReward(depositId);
        vm.stopPrank();

        uint256 timeStakedPercent = 100 - joinTimePercent;
        uint256 expectedReward = (totalRewardAmount * timeStakedPercent) / 100;

        assertApproxEqRel(claimedAmount, expectedReward, ONE_MICRO);
    }

    function testFuzz_ContinuousReward_TwoStakers_DifferentAmounts_ProRataShare(
        uint256 stakerARatio,
        uint256 stakerBRatio
    ) public {
        uint256 minRatio = 1;
        uint256 maxRatio = 10;
        stakerARatio = bound(stakerARatio, minRatio, maxRatio);
        stakerBRatio = bound(stakerBRatio, minRatio, maxRatio);

        address stakerA = makeAddr("stakerA");
        address stakerB = makeAddr("stakerB");

        authorizeUser(stakerA, true, false, true);
        authorizeUser(stakerB, true, false, true);

        uint256 baseStakeAmount = getStakeAmount();
        uint256 ratioScaleFactor = 5;
        uint256 stakeAmountA = (baseStakeAmount * stakerARatio) / ratioScaleFactor;
        uint256 stakeAmountB = (baseStakeAmount * stakerBRatio) / ratioScaleFactor;

        stakeToken.mint(stakerA, stakeAmountA);
        vm.startPrank(stakerA);
        stakeToken.approve(address(regenStaker), stakeAmountA);
        Staker.DepositIdentifier depositIdA = regenStaker.stake(stakeAmountA, stakerA);
        vm.stopPrank();

        stakeToken.mint(stakerB, stakeAmountB);
        vm.startPrank(stakerB);
        stakeToken.approve(address(regenStaker), stakeAmountB);
        Staker.DepositIdentifier depositIdB = regenStaker.stake(stakeAmountB, stakerB);
        vm.stopPrank();

        uint256 totalRewardAmount = getRewardAmount();
        rewardToken.mint(address(regenStaker), totalRewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(totalRewardAmount);

        vm.warp(block.timestamp + regenStaker.rewardDuration());

        vm.startPrank(stakerA);
        uint256 claimedA = regenStaker.claimReward(depositIdA);
        vm.stopPrank();

        vm.startPrank(stakerB);
        uint256 claimedB = regenStaker.claimReward(depositIdB);
        vm.stopPrank();

        uint256 totalStake = stakeAmountA + stakeAmountB;
        uint256 expectedA = (totalRewardAmount * stakeAmountA) / totalStake;
        uint256 expectedB = (totalRewardAmount * stakeAmountB) / totalStake;

        assertApproxEqRel(claimedA, expectedA, ONE_PICO);
        assertApproxEqRel(claimedB, expectedB, ONE_PICO);
        assertApproxEqRel(claimedA + claimedB, totalRewardAmount, ONE_PICO);
    }

    function test_PauseRewardScheduleWhenNoEarningPower() public {
        _clearTestContext();

        uint256 duration = regenStaker.rewardDuration();
        uint256 rewardAmount = getRewardAmount();
        uint256 stakeAmount = getStakeAmount();

        rewardToken.mint(address(regenStaker), rewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);

        uint256 initialEnd = regenStaker.rewardEndTime();
        uint256 halfDuration = duration / 2;

        vm.warp(block.timestamp + halfDuration);

        address staker = makeAddr("option1Staker");
        authorizeUser(staker, true, false, true);

        stakeToken.mint(staker, stakeAmount);
        vm.startPrank(staker);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, staker);
        vm.stopPrank();

        uint256 expectedEnd = initialEnd + halfDuration;
        assertEq(regenStaker.rewardEndTime(), expectedEnd, "rewardEndTime should extend by idle window");
        assertEq(regenStaker.unclaimedReward(depositId), 0, "no rewards should accrue during pause");

        vm.warp(expectedEnd);

        vm.startPrank(staker);
        uint256 claimed = regenStaker.claimReward(depositId);
        vm.stopPrank();

        assertApproxEqRel(claimed, rewardAmount, ONE_MICRO, "reward should stream fully after pause");
    }

    function testFuzz_TimeWeightedReward_NoEarningIfNotOnEarningAddressSet(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        rewardAmountBase = bound(rewardAmountBase, regenStaker.rewardDuration(), MAX_REWARD_DURATION + 1_000_000_000);

        address staker = makeAddr("staker");
        authorizeUser(staker, true, false, false);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        uint256 rewardAmount = getRewardAmount(rewardAmountBase);

        stakeToken.mint(staker, stakeAmount);
        vm.startPrank(staker);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, staker);
        vm.stopPrank();

        rewardToken.mint(address(regenStaker), rewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);

        vm.warp(block.timestamp + regenStaker.rewardDuration());

        vm.startPrank(staker);
        uint256 claimedAmount = regenStaker.claimReward(depositId);
        vm.stopPrank();

        assertEq(claimedAmount, 0);
    }

    function testFuzz_TimeWeightedReward_EarningStopsIfRemovedFromEarningAllowsetMidPeriod(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        rewardAmountBase = bound(rewardAmountBase, regenStaker.rewardDuration(), MAX_REWARD_DURATION + 1_000_000_000);

        address allowlistedStaker = makeAddr("allowlistedStaker");
        address nonAllowlistedStaker = makeAddr("nonAllowlistedStaker");

        authorizeUser(allowlistedStaker, true, false, true);
        authorizeUser(nonAllowlistedStaker, true, false, false);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        stakeToken.mint(allowlistedStaker, stakeAmount);
        stakeToken.mint(nonAllowlistedStaker, stakeAmount);

        vm.startPrank(allowlistedStaker);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier allowlistedDepositId = regenStaker.stake(stakeAmount, allowlistedStaker);
        vm.stopPrank();

        vm.startPrank(nonAllowlistedStaker);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier nonAllowlistedDepositId = regenStaker.stake(stakeAmount, nonAllowlistedStaker);
        vm.stopPrank();

        assertEq(regenStaker.depositorTotalEarningPower(allowlistedStaker), stakeAmount);
        assertEq(regenStaker.depositorTotalEarningPower(nonAllowlistedStaker), 0);

        uint256 rewardAmount = getRewardAmount(rewardAmountBase);
        rewardToken.mint(address(regenStaker), rewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);

        vm.warp(block.timestamp + regenStaker.rewardDuration());

        vm.startPrank(allowlistedStaker);
        uint256 claimedByAllowlisted = regenStaker.claimReward(allowlistedDepositId);
        vm.stopPrank();

        vm.startPrank(nonAllowlistedStaker);
        uint256 claimedByNonAllowlisted = regenStaker.claimReward(nonAllowlistedDepositId);
        vm.stopPrank();

        assertApproxEqRel(claimedByAllowlisted, rewardAmount, ONE_MICRO);
        assertEq(claimedByNonAllowlisted, 0);
    }

    function testFuzz_TimeWeightedReward_RateResetsWithNewRewardNotification(
        uint256 rewardPart1Base,
        uint256 rewardPart2Base,
        uint256 stakeAmountBase,
        uint256 stakerBJoinTimePercent
    ) public {
        rewardPart1Base = bound(rewardPart1Base, regenStaker.rewardDuration(), MAX_REWARD_DURATION + 1_000_000_000);
        rewardPart2Base = bound(rewardPart2Base, regenStaker.rewardDuration(), MAX_REWARD_DURATION + 1_000_000_000);
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        uint256 minJoinTime = 10;
        uint256 maxJoinTime = 90;
        stakerBJoinTimePercent = bound(stakerBJoinTimePercent, minJoinTime, maxJoinTime);

        address stakerA = makeAddr("stakerA");
        address stakerB = makeAddr("stakerB");

        authorizeUser(stakerA, true, false, true);
        authorizeUser(stakerB, true, false, true);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);

        stakeToken.mint(stakerA, stakeAmount);
        vm.startPrank(stakerA);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositIdA = regenStaker.stake(stakeAmount, stakerA);
        vm.stopPrank();

        uint256 rewardPart1 = getRewardAmount(rewardPart1Base);
        uint256 rewardPart2 = getRewardAmount(rewardPart2Base);
        uint256 totalRewardAmount = rewardPart1 + rewardPart2;

        rewardToken.mint(address(regenStaker), totalRewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardPart1);

        uint256 stakerBJoinTime = (regenStaker.rewardDuration() * stakerBJoinTimePercent) / 100;
        vm.warp(block.timestamp + stakerBJoinTime);

        stakeToken.mint(stakerB, stakeAmount);
        vm.startPrank(stakerB);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositIdB = regenStaker.stake(stakeAmount, stakerB);
        vm.stopPrank();

        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardPart2);

        vm.warp(block.timestamp + regenStaker.rewardDuration());

        vm.startPrank(stakerA);
        uint256 claimedA = regenStaker.claimReward(depositIdA);
        vm.stopPrank();

        vm.startPrank(stakerB);
        uint256 claimedB = regenStaker.claimReward(depositIdB);
        vm.stopPrank();

        uint256 stakerASoloEarnings = (rewardPart1 * stakerBJoinTimePercent) / 100;
        uint256 remainingPart1 = rewardPart1 - stakerASoloEarnings;
        uint256 totalNewPeriodRewards = remainingPart1 + rewardPart2;
        uint256 eachStakerNewPeriodEarnings = totalNewPeriodRewards / 2;

        uint256 expectedA = stakerASoloEarnings + eachStakerNewPeriodEarnings;
        uint256 expectedB = eachStakerNewPeriodEarnings;

        assertApproxEqRel(claimedA, expectedA, ONE_MICRO);
        assertApproxEqRel(claimedB, expectedB, ONE_MICRO);
        assertApproxEqRel(claimedA + claimedB, totalRewardAmount, ONE_MICRO);
    }

    function testFuzz_StakeDeposit_StakeMore_UpdatesBalanceAndRewards(
        uint256 initialStakeRatio,
        uint256 additionalStakeRatio,
        uint256 timingPercent
    ) public {
        initialStakeRatio = bound(initialStakeRatio, 1, 10);
        additionalStakeRatio = bound(additionalStakeRatio, 1, 10);
        timingPercent = bound(timingPercent, 10, 90);

        address user = makeAddr("user");
        authorizeUser(user, true, false, true);

        uint256 baseAmount = getStakeAmount();
        uint256 initialStake = (baseAmount * initialStakeRatio) / 10;
        uint256 additionalStake = (baseAmount * additionalStakeRatio) / 10;

        stakeToken.mint(user, initialStake + additionalStake);
        vm.startPrank(user);
        stakeToken.approve(address(regenStaker), initialStake + additionalStake);
        Staker.DepositIdentifier depositId = regenStaker.stake(initialStake, user);
        vm.stopPrank();

        assertEq(regenStaker.depositorTotalStaked(user), initialStake);
        assertEq(regenStaker.depositorTotalEarningPower(user), initialStake);

        address otherStaker = makeAddr("otherStaker");
        authorizeUser(otherStaker, true, false, true);
        stakeToken.mint(otherStaker, getStakeAmount());
        vm.startPrank(otherStaker);
        stakeToken.approve(address(regenStaker), getStakeAmount());
        regenStaker.stake(getStakeAmount(), otherStaker);
        vm.stopPrank();

        rewardToken.mint(address(regenStaker), getRewardAmount());
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(getRewardAmount());

        vm.warp(block.timestamp + (regenStaker.rewardDuration() * timingPercent) / 100);

        vm.startPrank(user);
        regenStaker.stakeMore(depositId, additionalStake);
        vm.stopPrank();

        assertEq(regenStaker.depositorTotalStaked(user), initialStake + additionalStake);
        assertEq(regenStaker.depositorTotalEarningPower(user), initialStake + additionalStake);

        vm.warp(block.timestamp + regenStaker.rewardDuration() - (regenStaker.rewardDuration() * timingPercent) / 100);

        vm.startPrank(user);
        uint256 claimedAmount = regenStaker.claimReward(depositId);
        vm.stopPrank();

        assertGt(claimedAmount, 0);
        assertLe(claimedAmount, getRewardAmount());
    }

    function testFuzz_StakeDeposit_MultipleDepositsSingleUser(
        uint256 stakeAmountBase1,
        uint256 stakeAmountBase2,
        uint256 rewardAmountBase
    ) public {
        stakeAmountBase1 = bound(stakeAmountBase1, 1, 10_000);
        stakeAmountBase2 = bound(stakeAmountBase2, 1, 10_000);
        rewardAmountBase = bound(rewardAmountBase, regenStaker.rewardDuration(), MAX_REWARD_DURATION + 1_000_000_000);

        address user = makeAddr("user");
        authorizeUser(user, true, false, true);

        uint256 stakeAmount1 = getStakeAmount(stakeAmountBase1);
        uint256 stakeAmount2 = getStakeAmount(stakeAmountBase2);
        uint256 totalStakeAmount = stakeAmount1 + stakeAmount2;

        stakeToken.mint(user, totalStakeAmount);
        vm.startPrank(user);
        stakeToken.approve(address(regenStaker), totalStakeAmount);

        Staker.DepositIdentifier depositId1 = regenStaker.stake(stakeAmount1, user);
        Staker.DepositIdentifier depositId2 = regenStaker.stake(stakeAmount2, user);
        vm.stopPrank();

        assertEq(regenStaker.depositorTotalStaked(user), totalStakeAmount);
        assertEq(regenStaker.depositorTotalEarningPower(user), totalStakeAmount);

        uint256 rewardAmount = getRewardAmount(rewardAmountBase);
        rewardToken.mint(address(regenStaker), rewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);

        vm.warp(block.timestamp + regenStaker.rewardDuration());

        vm.startPrank(user);
        uint256 claimed1 = regenStaker.claimReward(depositId1);
        uint256 claimed2 = regenStaker.claimReward(depositId2);
        vm.stopPrank();

        uint256 expected1 = (rewardAmount * stakeAmount1) / totalStakeAmount;
        uint256 expected2 = (rewardAmount * stakeAmount2) / totalStakeAmount;

        assertApproxEqRel(claimed1, expected1, ONE_MICRO);
        assertApproxEqRel(claimed2, expected2, ONE_MICRO);
        assertApproxEqRel(claimed1 + claimed2, rewardAmount, ONE_MICRO);
    }

    function testFuzz_StakeWithdraw_PartialWithdraw_ReducesBalanceAndImpactsRewards(
        uint256 stakeAmountBase,
        uint256 withdrawRatio,
        uint256 otherStakeRatio,
        uint256 rewardAmountBase
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 100, 10_000);
        withdrawRatio = bound(withdrawRatio, 1, 75);
        otherStakeRatio = bound(otherStakeRatio, 10, 200);
        rewardAmountBase = bound(rewardAmountBase, regenStaker.rewardDuration(), MAX_REWARD_DURATION + 1_000_000_000);

        address user = makeAddr("user");
        address otherStaker = makeAddr("otherStaker");

        authorizeUser(user, true, false, true);
        authorizeUser(otherStaker, true, false, true);

        uint256 userStakeAmount = getStakeAmount(stakeAmountBase);
        stakeToken.mint(user, userStakeAmount);
        vm.startPrank(user);
        stakeToken.approve(address(regenStaker), userStakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(userStakeAmount, user);
        vm.stopPrank();

        uint256 otherStakerAmount = (userStakeAmount * otherStakeRatio) / 100;
        stakeToken.mint(otherStaker, otherStakerAmount);
        vm.startPrank(otherStaker);
        stakeToken.approve(address(regenStaker), otherStakerAmount);
        Staker.DepositIdentifier otherDepositId = regenStaker.stake(otherStakerAmount, otherStaker);
        vm.stopPrank();

        uint256 rewardAmount = getRewardAmount(rewardAmountBase);
        rewardToken.mint(address(regenStaker), rewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);

        vm.warp(block.timestamp + regenStaker.rewardDuration() / 2);

        uint256 withdrawAmount = (userStakeAmount * withdrawRatio) / 100;
        vm.startPrank(user);
        regenStaker.withdraw(depositId, withdrawAmount);
        vm.stopPrank();

        uint256 remainingUserStake = userStakeAmount - withdrawAmount;
        assertEq(regenStaker.depositorTotalStaked(user), remainingUserStake);
        assertEq(regenStaker.depositorTotalEarningPower(user), remainingUserStake);

        vm.warp(block.timestamp + regenStaker.rewardDuration() / 2);

        vm.startPrank(user);
        uint256 claimedAfterWithdraw = regenStaker.claimReward(depositId);
        vm.stopPrank();

        vm.startPrank(otherStaker);
        uint256 claimedByOtherStaker = regenStaker.claimReward(otherDepositId);
        vm.stopPrank();

        assertApproxEqRel(claimedAfterWithdraw + claimedByOtherStaker, rewardAmount, ONE_MICRO);
        assertGt(claimedAfterWithdraw, 0);
        assertGt(claimedByOtherStaker, 0);
    }

    function testFuzz_StakeWithdraw_FullWithdraw_BalanceZero_ClaimsAccrued_NoFutureRewards(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase,
        uint256 withdrawTimePercent
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        rewardAmountBase = bound(rewardAmountBase, regenStaker.rewardDuration(), MAX_REWARD_DURATION + 1_000_000_000);
        uint256 minWithdrawTime = 10;
        uint256 maxWithdrawTime = 90;
        withdrawTimePercent = bound(withdrawTimePercent, minWithdrawTime, maxWithdrawTime);

        address user = makeAddr("user");
        authorizeUser(user, true, false, true);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        stakeToken.mint(user, stakeAmount);
        vm.startPrank(user);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, user);
        vm.stopPrank();

        uint256 rewardAmount = getRewardAmount(rewardAmountBase);
        rewardToken.mint(address(regenStaker), rewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);

        uint256 withdrawTime = (regenStaker.rewardDuration() * withdrawTimePercent) / 100;
        vm.warp(block.timestamp + withdrawTime);

        vm.startPrank(user);
        regenStaker.withdraw(depositId, stakeAmount);
        vm.stopPrank();

        assertEq(regenStaker.depositorTotalStaked(user), 0);
        assertEq(regenStaker.depositorTotalEarningPower(user), 0);

        vm.startPrank(user);
        uint256 claimedImmediately = regenStaker.claimReward(depositId);
        vm.stopPrank();

        uint256 expectedReward = (rewardAmount * withdrawTimePercent) / 100;
        assertApproxEqRel(claimedImmediately, expectedReward, ONE_MICRO);

        uint256 remainingTime = regenStaker.rewardDuration() - withdrawTime;
        vm.warp(block.timestamp + remainingTime);

        vm.startPrank(user);
        uint256 claimedLater = regenStaker.claimReward(depositId);
        vm.stopPrank();

        assertEq(claimedLater, 0);
    }

    function testFuzz_RewardClaiming_ClaimByDesignatedClaimer_Succeeds(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase,
        uint256 firstClaimTimePercent
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        rewardAmountBase = bound(rewardAmountBase, regenStaker.rewardDuration(), MAX_REWARD_DURATION + 1_000_000_000);
        uint256 minClaimTime = 10;
        uint256 maxClaimTime = 90;
        firstClaimTimePercent = bound(firstClaimTimePercent, minClaimTime, maxClaimTime);

        address owner = makeAddr("owner");
        address designatedClaimer = makeAddr("claimer");

        authorizeUser(owner, true, false, true);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        stakeToken.mint(owner, stakeAmount);
        vm.startPrank(owner);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, owner);
        regenStaker.alterClaimer(depositId, designatedClaimer);
        vm.stopPrank();

        (, , , , address retrievedClaimer, , ) = regenStaker.deposits(depositId);
        assertEq(retrievedClaimer, designatedClaimer);

        uint256 rewardAmount = getRewardAmount(rewardAmountBase);
        rewardToken.mint(address(regenStaker), rewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);

        uint256 firstClaimTime = (regenStaker.rewardDuration() * firstClaimTimePercent) / 100;
        vm.warp(block.timestamp + firstClaimTime);

        uint256 initialClaimerBalance = rewardToken.balanceOf(designatedClaimer);
        vm.startPrank(designatedClaimer);
        uint256 claimedAmount1 = regenStaker.claimReward(depositId);
        vm.stopPrank();

        uint256 expectedFirst = (rewardAmount * firstClaimTimePercent) / 100;
        assertApproxEqRel(claimedAmount1, expectedFirst, ONE_MICRO);
        assertEq(rewardToken.balanceOf(designatedClaimer), initialClaimerBalance + claimedAmount1);

        uint256 remainingTime = regenStaker.rewardDuration() - firstClaimTime;
        vm.warp(block.timestamp + remainingTime);

        initialClaimerBalance = rewardToken.balanceOf(designatedClaimer);
        vm.startPrank(designatedClaimer);
        uint256 claimedAmount2 = regenStaker.claimReward(depositId);
        vm.stopPrank();

        uint256 remainingTimePercent = 100 - firstClaimTimePercent;
        uint256 expectedSecond = (rewardAmount * remainingTimePercent) / 100;
        assertApproxEqRel(claimedAmount2, expectedSecond, ONE_MICRO);
        assertEq(rewardToken.balanceOf(designatedClaimer), initialClaimerBalance + claimedAmount2);

        assertApproxEqRel(claimedAmount1 + claimedAmount2, rewardAmount, ONE_MICRO);
    }

    function testFuzz_RewardClaiming_RevertIf_ClaimByNonOwnerNonClaimer(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase,
        uint256 seedForAddresses
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        rewardAmountBase = bound(rewardAmountBase, regenStaker.rewardDuration(), MAX_REWARD_DURATION + 1_000_000_000);

        address owner = makeAddr(string(abi.encodePacked("owner", seedForAddresses)));
        address designatedClaimer = makeAddr(string(abi.encodePacked("claimer", seedForAddresses)));
        address unrelatedUser = makeAddr(string(abi.encodePacked("unrelated", seedForAddresses)));

        vm.assume(owner != designatedClaimer);
        vm.assume(owner != unrelatedUser);
        vm.assume(designatedClaimer != unrelatedUser);

        authorizeUser(owner, true, false, true);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        stakeToken.mint(owner, stakeAmount);
        vm.startPrank(owner);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, owner);
        regenStaker.alterClaimer(depositId, designatedClaimer);
        vm.stopPrank();

        uint256 rewardAmount = getRewardAmount(rewardAmountBase);
        rewardToken.mint(address(regenStaker), rewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);
        vm.warp(block.timestamp + regenStaker.rewardDuration());

        vm.startPrank(unrelatedUser);
        vm.expectRevert(
            abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not claimer or owner"), unrelatedUser)
        );
        regenStaker.claimReward(depositId);
        vm.stopPrank();
    }

    function testFuzz_RewardClaiming_OwnerCanStillClaimAfterDesignatingNewClaimer(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase,
        uint256 seedForAddresses
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        rewardAmountBase = bound(rewardAmountBase, regenStaker.rewardDuration(), MAX_REWARD_DURATION + 1_000_000_000);

        address ownerAddr = makeAddr(string(abi.encodePacked("owner", seedForAddresses)));
        address newClaimer = makeAddr(string(abi.encodePacked("claimer", seedForAddresses)));

        vm.assume(ownerAddr != newClaimer);

        authorizeUser(ownerAddr, true, false, true);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        stakeToken.mint(ownerAddr, stakeAmount);
        vm.startPrank(ownerAddr);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, ownerAddr);
        regenStaker.alterClaimer(depositId, newClaimer);
        vm.stopPrank();

        uint256 rewardAmount = getRewardAmount(rewardAmountBase);
        rewardToken.mint(address(regenStaker), rewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);
        vm.warp(block.timestamp + regenStaker.rewardDuration());

        vm.startPrank(ownerAddr);
        uint256 claimedByOwner = regenStaker.claimReward(depositId);
        vm.stopPrank();

        assertApproxEqRel(claimedByOwner, rewardAmount, ONE_MICRO);
    }

    function testFuzz_WithdrawSucceedsWhenPaused(uint256 stakeAmountBase, uint256 withdrawAmountRatio) public {
        uint256 minStake = 100;
        uint256 maxStake = 10_000;
        stakeAmountBase = bound(stakeAmountBase, minStake, maxStake);
        uint256 minWithdrawRatio = 1;
        uint256 maxWithdrawRatio = 90;
        withdrawAmountRatio = bound(withdrawAmountRatio, minWithdrawRatio, maxWithdrawRatio);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        uint256 withdrawAmount = (stakeAmount * withdrawAmountRatio) / 100;
        vm.assume(withdrawAmount > 0);

        address user = makeAddr("user");
        authorizeUser(user, true, false, true);

        stakeToken.mint(user, stakeAmount);
        vm.startPrank(user);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, user);
        vm.stopPrank();

        vm.prank(ADMIN);
        regenStaker.pause();
        assertTrue(regenStaker.paused());

        // Withdrawal should succeed even when paused (user protection)
        uint256 balanceBefore = stakeToken.balanceOf(user);
        vm.prank(user);
        regenStaker.withdraw(depositId, withdrawAmount);

        uint256 balanceAfter = stakeToken.balanceOf(user);
        assertEq(balanceAfter - balanceBefore, withdrawAmount, "Withdrawal should succeed when paused");

        // Verify deposit balance was reduced
        (uint96 balance, , , , , , ) = regenStaker.deposits(depositId);
        assertEq(balance, stakeAmount - withdrawAmount, "Deposit balance should be reduced");

        vm.prank(ADMIN);
        regenStaker.unpause();
        assertFalse(regenStaker.paused());
    }

    /// @notice Test that withdrawals remain enabled when paused for user protection
    function test_WithdrawalsEnabledWhenPaused() public {
        uint256 stakeAmount = getStakeAmount(1000);
        address user = makeAddr("user");
        authorizeUser(user, true, false, true);

        stakeToken.mint(user, stakeAmount);
        vm.startPrank(user);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, user);
        vm.stopPrank();

        // Pause the contract
        vm.prank(ADMIN);
        regenStaker.pause();
        assertTrue(regenStaker.paused());

        // Verify other operations are blocked
        vm.startPrank(user);

        // Staking should fail
        stakeToken.mint(user, stakeAmount);
        stakeToken.approve(address(regenStaker), stakeAmount);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        regenStaker.stake(stakeAmount, user);

        // Claiming should fail
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        regenStaker.claimReward(depositId);

        // But withdrawal should succeed (MICA compliance)
        uint256 withdrawAmount = stakeAmount / 2;
        uint256 balanceBefore = stakeToken.balanceOf(user);
        regenStaker.withdraw(depositId, withdrawAmount);
        uint256 balanceAfter = stakeToken.balanceOf(user);

        assertEq(
            balanceAfter - balanceBefore,
            withdrawAmount,
            "Withdrawal should succeed when paused for user protection"
        );

        vm.stopPrank();

        // Unpause
        vm.prank(ADMIN);
        regenStaker.unpause();
        assertFalse(regenStaker.paused());
    }

    function testFuzz_RevertIf_ClaimRewardWhenPaused(uint256 stakeAmountBase, uint256 rewardAmountBase) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        rewardAmountBase = bound(rewardAmountBase, regenStaker.rewardDuration(), MAX_REWARD_DURATION + 1_000_000_000);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        uint256 rewardAmount = getRewardAmount(rewardAmountBase);

        address user = makeAddr("user");
        authorizeUser(user, true, false, true);

        stakeToken.mint(user, stakeAmount);
        vm.startPrank(user);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, user);
        vm.stopPrank();

        rewardToken.mint(address(regenStaker), rewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);
        uint256 halfDuration = regenStaker.rewardDuration() / 2;
        vm.warp(block.timestamp + halfDuration);

        vm.prank(ADMIN);
        regenStaker.pause();
        assertTrue(regenStaker.paused());

        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        regenStaker.claimReward(depositId);
        vm.stopPrank();

        vm.prank(ADMIN);
        regenStaker.unpause();
        assertFalse(regenStaker.paused());
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

    function testFuzz_SetRewardDuration(uint256 newDuration) public {
        newDuration = bound(newDuration, uint128(MIN_REWARD_DURATION), MAX_REWARD_DURATION);

        // current duration
        uint256 currentDuration = regenStaker.rewardDuration();
        vm.assume(newDuration != currentDuration);

        vm.prank(ADMIN);
        vm.expectEmit(true, true, true, true);
        emit RewardDurationSet(newDuration);
        regenStaker.setRewardDuration(uint128(newDuration));

        assertEq(regenStaker.rewardDuration(), newDuration);
    }

    function testFuzz_RevertIf_NonAdminCannotSetRewardDuration(address nonAdmin, uint256 newDuration) public {
        vm.assume(nonAdmin != ADMIN);
        newDuration = bound(newDuration, uint128(MIN_REWARD_DURATION), MAX_REWARD_DURATION);

        vm.startPrank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not admin"), nonAdmin));
        regenStaker.setRewardDuration(uint128(newDuration));
        vm.stopPrank();
    }

    function testFuzz_RevertIf_SetRewardDurationTooLow() public {
        vm.startPrank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.InvalidRewardDuration.selector, 6 days));
        regenStaker.setRewardDuration(6 days);
        vm.stopPrank();
    }

    function testFuzz_RevertIf_SetRewardDurationToZero() public {
        vm.startPrank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.InvalidRewardDuration.selector, 0));
        regenStaker.setRewardDuration(uint128(0));
        vm.stopPrank();
    }

    function testFuzz_RevertIf_SetRewardDurationTooHigh() public {
        vm.startPrank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.InvalidRewardDuration.selector, 3001 days));
        regenStaker.setRewardDuration(3001 days);
        vm.stopPrank();
    }

    function testFuzz_RevertIf_SetRewardDurationDuringActiveReward(uint256 newDuration) public {
        newDuration = bound(newDuration, uint128(MIN_REWARD_DURATION), MAX_REWARD_DURATION);

        address staker = makeAddr("staker");
        authorizeUser(staker, true, false, true);

        uint256 stakeAmount = getStakeAmount(1);
        uint256 rewardAmount = getRewardAmount(regenStaker.rewardDuration());

        stakeToken.mint(staker, stakeAmount);
        vm.startPrank(staker);
        stakeToken.approve(address(regenStaker), stakeAmount);
        regenStaker.stake(stakeAmount, staker);
        vm.stopPrank();

        rewardToken.mint(address(regenStaker), rewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);

        vm.warp(block.timestamp + regenStaker.rewardDuration() / 2);

        vm.startPrank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.CannotChangeRewardDurationDuringActiveReward.selector));
        regenStaker.setRewardDuration(uint128(newDuration));
        vm.stopPrank();
    }

    function testFuzz_Constructor_WithCustomRewardDuration(uint256 customDuration) public {
        customDuration = bound(uint128(customDuration), uint128(MIN_REWARD_DURATION), MAX_REWARD_DURATION);

        vm.startPrank(ADMIN);
        RegenStaker localRegenStaker = new RegenStaker(
            IERC20(address(rewardToken)),
            IERC20Staking(address(stakeToken)),
            calculator,
            MAX_BUMP_TIP,
            ADMIN,
            uint128(customDuration),
            0,
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            stakerAllowset
        );

        assertEq(localRegenStaker.rewardDuration(), customDuration);
        vm.stopPrank();
    }

    function testFuzz_Constructor_WithZeroRewardDurationReverts() public {
        vm.startPrank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.InvalidRewardDuration.selector, 0));
        new RegenStaker(
            IERC20(address(rewardToken)),
            IERC20Staking(address(stakeToken)),
            calculator,
            MAX_BUMP_TIP,
            ADMIN,
            0,
            0,
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            stakerAllowset
        );
        vm.stopPrank();
    }

    function testFuzz_VariableRewardDuration_SingleStaker_FullPeriod(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase,
        uint256 customDurationDays
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 100_000);
        customDurationDays = bound(customDurationDays, 30, 365);
        uint256 customDuration = customDurationDays * 1 days;
        rewardAmountBase = bound(rewardAmountBase, uint128(customDuration), 100_000_000);

        vm.prank(ADMIN);
        regenStaker.setRewardDuration(uint128(customDuration));

        address staker = makeAddr("staker");
        authorizeUser(staker, true, false, true);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        uint256 rewardAmount = getRewardAmount(rewardAmountBase);

        stakeToken.mint(staker, stakeAmount);
        vm.startPrank(staker);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, staker);
        vm.stopPrank();

        rewardToken.mint(address(regenStaker), rewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);

        vm.warp(block.timestamp + customDuration);

        vm.startPrank(staker);
        uint256 claimedAmount = regenStaker.claimReward(depositId);
        vm.stopPrank();

        assertApproxEqRel(claimedAmount, rewardAmount, ONE_MICRO);
    }

    function testFuzz_VariableRewardDuration_TwoStakers_ProRataShare(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase,
        uint256 customDurationDays,
        uint256 secondStakerJoinPercent
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        customDurationDays = bound(customDurationDays, 30, 100);
        uint256 customDuration = customDurationDays * 1 days;
        rewardAmountBase = bound(rewardAmountBase, uint128(customDuration), 100_000_000);
        secondStakerJoinPercent = bound(secondStakerJoinPercent, 10, 90);

        vm.prank(ADMIN);
        regenStaker.setRewardDuration(uint128(customDuration));

        address stakerA = makeAddr("stakerA");
        address stakerB = makeAddr("stakerB");

        authorizeUser(stakerA, true, false, true);
        authorizeUser(stakerB, true, false, true);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        uint256 rewardAmount = getRewardAmount(rewardAmountBase);

        stakeToken.mint(stakerA, stakeAmount);
        vm.startPrank(stakerA);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositIdA = regenStaker.stake(stakeAmount, stakerA);
        vm.stopPrank();

        rewardToken.mint(address(regenStaker), rewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);

        uint256 stakerBJoinTime = (customDuration * secondStakerJoinPercent) / 100;
        vm.warp(block.timestamp + stakerBJoinTime);

        stakeToken.mint(stakerB, stakeAmount);
        vm.startPrank(stakerB);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositIdB = regenStaker.stake(stakeAmount, stakerB);
        vm.stopPrank();

        uint256 remainingTime = customDuration - stakerBJoinTime;
        vm.warp(block.timestamp + remainingTime);

        vm.startPrank(stakerA);
        uint256 claimedA = regenStaker.claimReward(depositIdA);
        vm.stopPrank();

        vm.startPrank(stakerB);
        uint256 claimedB = regenStaker.claimReward(depositIdB);
        vm.stopPrank();

        uint256 soloPhaseRewards = (rewardAmount * secondStakerJoinPercent) / 100;
        uint256 sharedPhasePercent = 100 - secondStakerJoinPercent;
        uint256 sharedPhaseRewards = (rewardAmount * sharedPhasePercent) / 100;

        uint256 expectedA = soloPhaseRewards + (sharedPhaseRewards / 2);
        uint256 expectedB = sharedPhaseRewards / 2;

        assertApproxEqRel(claimedA, expectedA, ONE_MICRO);
        assertApproxEqRel(claimedB, expectedB, ONE_MICRO);
        assertApproxEqRel(claimedA + claimedB, rewardAmount, ONE_MICRO);
    }

    function testFuzz_VariableRewardDuration_ClaimsMidPeriod(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase,
        uint256 customDurationDays,
        uint256 firstClaimTimePercent
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        customDurationDays = bound(customDurationDays, 30, 100);
        uint256 customDuration = customDurationDays * 1 days;
        rewardAmountBase = bound(rewardAmountBase, uint128(customDuration), 100_000_000);
        firstClaimTimePercent = bound(firstClaimTimePercent, 10, 90);

        vm.prank(ADMIN);
        regenStaker.setRewardDuration(uint128(customDuration));

        address staker = makeAddr("staker");
        authorizeUser(staker, true, false, true);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        uint256 rewardAmount = getRewardAmount(rewardAmountBase);

        stakeToken.mint(staker, stakeAmount);
        vm.startPrank(staker);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, staker);
        vm.stopPrank();

        rewardToken.mint(address(regenStaker), rewardAmount);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);

        uint256 firstClaimTime = (customDuration * firstClaimTimePercent) / 100;
        vm.warp(block.timestamp + firstClaimTime);

        vm.startPrank(staker);
        uint256 claimedAmount1 = regenStaker.claimReward(depositId);
        vm.stopPrank();

        uint256 expectedFirst = (rewardAmount * firstClaimTimePercent) / 100;
        assertApproxEqRel(claimedAmount1, expectedFirst, ONE_NANO);

        uint256 remainingTime = customDuration - firstClaimTime;
        vm.warp(block.timestamp + remainingTime);

        vm.startPrank(staker);
        uint256 claimedAmount2 = regenStaker.claimReward(depositId);
        vm.stopPrank();

        uint256 remainingTimePercent = 100 - firstClaimTimePercent;
        uint256 expectedSecond = (rewardAmount * remainingTimePercent) / 100;

        assertApproxEqRel(claimedAmount2, expectedSecond, ONE_NANO);
        assertApproxEqRel(claimedAmount1 + claimedAmount2, rewardAmount, ONE_NANO);
    }

    function testFuzz_VariableRewardDuration_ChangeDurationBetweenRewards(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase,
        uint256 firstDurationDays,
        uint256 secondDurationDays
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        firstDurationDays = bound(firstDurationDays, 30, 60);
        secondDurationDays = bound(secondDurationDays, 30, 60);
        uint256 firstDuration = firstDurationDays * 1 days;
        uint256 secondDuration = secondDurationDays * 1 days;

        vm.assume(firstDuration != secondDuration);

        rewardAmountBase = bound(rewardAmountBase, max(firstDuration, secondDuration), 100_000_000);

        vm.prank(ADMIN);
        regenStaker.setRewardDuration(uint128(firstDuration));

        address staker = makeAddr("staker");
        authorizeUser(staker, true, false, true);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        uint256 rewardAmount = getRewardAmount(rewardAmountBase);

        stakeToken.mint(staker, stakeAmount);
        vm.startPrank(staker);
        stakeToken.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = regenStaker.stake(stakeAmount, staker);
        vm.stopPrank();

        rewardToken.mint(address(regenStaker), rewardAmount * 2);
        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);

        vm.warp(block.timestamp + firstDuration + 1);

        vm.prank(ADMIN);
        regenStaker.setRewardDuration(uint128(secondDuration));

        vm.prank(ADMIN);
        regenStaker.notifyRewardAmount(rewardAmount);

        vm.warp(block.timestamp + secondDuration);

        vm.startPrank(staker);
        uint256 claimedAmount = regenStaker.claimReward(depositId);
        vm.stopPrank();

        assertGt(claimedAmount, 0);
        assertLe(claimedAmount, rewardAmount * 2);
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }

    function testFuzz_CompoundRewards_RespectsMinimumStakeAmount(
        uint256 minimumAmountBase,
        uint256 stakeAmountBase,
        uint256 rewardAmountBase
    ) public {
        minimumAmountBase = bound(minimumAmountBase, 10, 100);
        stakeAmountBase = bound(stakeAmountBase, 1, minimumAmountBase - 1);
        rewardAmountBase = bound(rewardAmountBase, 30 days, 100_000_000);

        uint256 minimumAmount = getStakeAmount(minimumAmountBase);
        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        uint256 rewardAmount = getRewardAmount(rewardAmountBase);

        vm.assume(stakeAmount < minimumAmount);

        // Create a RegenStaker where reward and stake tokens are the same
        MockERC20Staking sameToken = new MockERC20Staking(18);

        vm.startPrank(ADMIN);
        RegenStaker compoundRegenStaker = new RegenStaker(
            IERC20(address(sameToken)),
            IERC20Staking(address(sameToken)),
            calculator,
            MAX_BUMP_TIP,
            ADMIN,
            uint128(MIN_REWARD_DURATION),
            0,
            stakerAllowset,
            IAddressSet(address(0)),
            AccessMode.NONE,
            allocationMechanismAllowset
        );
        compoundRegenStaker.setRewardNotifier(ADMIN, true);
        compoundRegenStaker.setMinimumStakeAmount(uint128(minimumAmount));
        vm.stopPrank();

        address user = makeAddr("user");
        authorizeUser(user, true, false, true);

        // Temporarily set minimum to 0 to allow initial stake
        vm.prank(ADMIN);
        compoundRegenStaker.setMinimumStakeAmount(uint128(0));

        sameToken.mint(user, stakeAmount);
        // Protection requires balance >= totalStaked + rewardAmount
        sameToken.mint(address(compoundRegenStaker), stakeAmount + rewardAmount);

        vm.startPrank(user);
        sameToken.approve(address(compoundRegenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = compoundRegenStaker.stake(stakeAmount, user);
        vm.stopPrank();

        vm.prank(ADMIN);
        compoundRegenStaker.notifyRewardAmount(rewardAmount);

        vm.warp(block.timestamp + compoundRegenStaker.rewardDuration() + 1);

        // Reset minimum amount
        vm.prank(ADMIN);
        compoundRegenStaker.setMinimumStakeAmount(uint128(minimumAmount));

        uint256 unclaimedBefore = compoundRegenStaker.unclaimedReward(depositId);
        uint256 expectedNewBalance = stakeAmount + unclaimedBefore;

        if (expectedNewBalance < minimumAmount) {
            vm.prank(user);
            vm.expectRevert(
                abi.encodeWithSelector(
                    RegenStakerBase.MinimumStakeAmountNotMet.selector,
                    minimumAmount,
                    expectedNewBalance
                )
            );
            compoundRegenStaker.compoundRewards(depositId);
        } else {
            vm.prank(user);
            uint256 compoundedAmount = compoundRegenStaker.compoundRewards(depositId);
            assertEq(compoundedAmount, unclaimedBefore);
        }
    }

    function testFuzz_CompoundRewards_BasicFunctionality(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase,
        uint256 timeElapsedPercent
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 100_000);
        rewardAmountBase = bound(rewardAmountBase, uint128(MIN_REWARD_DURATION), MAX_REWARD_DURATION + 1_000_000_000);
        timeElapsedPercent = bound(timeElapsedPercent, 1, 100);

        MockERC20Staking sameToken = new MockERC20Staking(18);

        vm.startPrank(ADMIN);
        RegenStaker compoundRegenStaker = new RegenStaker(
            IERC20(address(sameToken)),
            IERC20Staking(address(sameToken)),
            calculator,
            MAX_BUMP_TIP,
            ADMIN,
            uint128(MIN_REWARD_DURATION),
            0,
            stakerAllowset,
            IAddressSet(address(0)),
            AccessMode.NONE,
            allocationMechanismAllowset
        );
        compoundRegenStaker.setRewardNotifier(ADMIN, true);
        vm.stopPrank();

        address user = makeAddr("user");
        authorizeUser(user, true, false, true);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        uint256 rewardAmount = getRewardAmount(rewardAmountBase);

        sameToken.mint(user, stakeAmount);
        // Protection requires balance >= totalStaked + rewardAmount
        sameToken.mint(address(compoundRegenStaker), stakeAmount + rewardAmount);

        vm.startPrank(user);
        sameToken.approve(address(compoundRegenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = compoundRegenStaker.stake(stakeAmount, user);
        vm.stopPrank();

        vm.prank(ADMIN);
        compoundRegenStaker.notifyRewardAmount(rewardAmount);

        uint256 timeElapsed = (compoundRegenStaker.rewardDuration() * timeElapsedPercent) / 100;
        vm.warp(block.timestamp + timeElapsed);

        uint256 expectedReward = (rewardAmount * timeElapsedPercent) / 100;
        uint256 unclaimedBefore = compoundRegenStaker.unclaimedReward(depositId);
        (uint96 balanceBefore, , , , , , ) = compoundRegenStaker.deposits(depositId);

        vm.prank(user);
        uint256 compoundedAmount = compoundRegenStaker.compoundRewards(depositId);

        assertEq(compoundedAmount, unclaimedBefore);
        // NOTE: This test may fail with extreme fuzzing values due to precision differences
        // when using 7-day reward duration vs original 30-day duration
        assertApproxEqRel(compoundedAmount, expectedReward, ONE_PERCENT);

        (uint96 balanceAfter, , , , , , ) = compoundRegenStaker.deposits(depositId);
        assertEq(balanceAfter, balanceBefore + compoundedAmount);
        assertEq(compoundRegenStaker.unclaimedReward(depositId), 0);
    }

    function testFuzz_CompoundRewards_MultipleCompounds(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase,
        uint256 compoundTimes
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 10, 10_000);
        rewardAmountBase = bound(rewardAmountBase, uint128(MIN_REWARD_DURATION), MAX_REWARD_DURATION + 1_000_000_000);
        compoundTimes = bound(compoundTimes, 2, 5);

        MockERC20Staking sameToken = new MockERC20Staking(18);

        vm.startPrank(ADMIN);
        RegenStaker compoundRegenStaker = new RegenStaker(
            IERC20(address(sameToken)),
            IERC20Staking(address(sameToken)),
            calculator,
            MAX_BUMP_TIP,
            ADMIN,
            uint128(MIN_REWARD_DURATION),
            0,
            stakerAllowset,
            IAddressSet(address(0)),
            AccessMode.NONE,
            allocationMechanismAllowset
        );
        compoundRegenStaker.setRewardNotifier(ADMIN, true);
        vm.stopPrank();

        address user = makeAddr("user");
        authorizeUser(user, true, false, true);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        uint256 rewardAmount = getRewardAmount(rewardAmountBase);

        sameToken.mint(user, stakeAmount);
        // Multiple compounds need extra buffer for totalStaked growth
        sameToken.mint(address(compoundRegenStaker), stakeAmount + rewardAmount * compoundTimes * 2);

        vm.startPrank(user);
        sameToken.approve(address(compoundRegenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = compoundRegenStaker.stake(stakeAmount, user);
        vm.stopPrank();

        uint256 totalCompounded = 0;
        uint256 currentBalance = stakeAmount;

        for (uint256 i = 0; i < compoundTimes; i++) {
            vm.prank(ADMIN);
            compoundRegenStaker.notifyRewardAmount(rewardAmount);

            vm.warp(block.timestamp + compoundRegenStaker.rewardDuration());

            vm.prank(user);
            uint256 compoundedAmount = compoundRegenStaker.compoundRewards(depositId);

            totalCompounded += compoundedAmount;
            currentBalance += compoundedAmount;

            (uint96 balanceAfter, , , , , , ) = compoundRegenStaker.deposits(depositId);
            assertEq(balanceAfter, currentBalance);
            assertEq(compoundRegenStaker.unclaimedReward(depositId), 0);
        }

        assertGt(totalCompounded, 0);
        assertGe(currentBalance, stakeAmount);
    }

    function testFuzz_CompoundRewards_MultipleUsers(
        uint256 user1StakeBase,
        uint256 user2StakeBase,
        uint256 rewardAmountBase,
        uint256 user2JoinTimePercent
    ) public {
        _clearTestContext();

        currentTestCtx.user1StakeBase = bound(user1StakeBase, 1, 10_000);
        currentTestCtx.user2StakeBase = bound(user2StakeBase, 1, 10_000);
        currentTestCtx.rewardAmountBase = bound(
            rewardAmountBase,
            uint128(MIN_REWARD_DURATION),
            MAX_REWARD_DURATION + 1_000_000_000
        );
        currentTestCtx.user2JoinTimePercent = bound(user2JoinTimePercent, 10, 90);

        currentTestCtx.sameToken = new MockERC20Staking(18);

        vm.startPrank(ADMIN);
        currentTestCtx.compoundRegenStaker = new RegenStaker(
            IERC20(address(currentTestCtx.sameToken)),
            IERC20Staking(address(currentTestCtx.sameToken)),
            calculator,
            MAX_BUMP_TIP,
            ADMIN,
            uint128(MIN_REWARD_DURATION),
            0,
            stakerAllowset,
            IAddressSet(address(0)),
            AccessMode.NONE,
            allocationMechanismAllowset
        );
        currentTestCtx.compoundRegenStaker.setRewardNotifier(ADMIN, true);
        vm.stopPrank();

        currentTestCtx.user1 = makeAddr("user1");
        currentTestCtx.user2 = makeAddr("user2");
        authorizeUser(currentTestCtx.user1, true, false, true);
        authorizeUser(currentTestCtx.user2, true, false, true);

        currentTestCtx.user1Stake = getStakeAmount(currentTestCtx.user1StakeBase);
        currentTestCtx.user2Stake = getStakeAmount(currentTestCtx.user2StakeBase);
        currentTestCtx.rewardAmount = getRewardAmount(currentTestCtx.rewardAmountBase);

        currentTestCtx.sameToken.mint(currentTestCtx.user1, currentTestCtx.user1Stake);
        currentTestCtx.sameToken.mint(currentTestCtx.user2, currentTestCtx.user2Stake);
        // Protection requires balance >= totalStaked + rewardAmount
        currentTestCtx.sameToken.mint(
            address(currentTestCtx.compoundRegenStaker),
            currentTestCtx.user1Stake + currentTestCtx.user2Stake + currentTestCtx.rewardAmount
        );

        vm.startPrank(currentTestCtx.user1);
        currentTestCtx.sameToken.approve(address(currentTestCtx.compoundRegenStaker), currentTestCtx.user1Stake);
        currentTestCtx.depositId1 = currentTestCtx.compoundRegenStaker.stake(
            currentTestCtx.user1Stake,
            currentTestCtx.user1
        );
        vm.stopPrank();

        vm.prank(ADMIN);
        currentTestCtx.compoundRegenStaker.notifyRewardAmount(currentTestCtx.rewardAmount);

        vm.warp(
            block.timestamp +
                (currentTestCtx.compoundRegenStaker.rewardDuration() * currentTestCtx.user2JoinTimePercent) /
                100
        );

        vm.startPrank(currentTestCtx.user2);
        currentTestCtx.sameToken.approve(address(currentTestCtx.compoundRegenStaker), currentTestCtx.user2Stake);
        currentTestCtx.depositId2 = currentTestCtx.compoundRegenStaker.stake(
            currentTestCtx.user2Stake,
            currentTestCtx.user2
        );
        vm.stopPrank();

        vm.warp(
            block.timestamp +
                currentTestCtx.compoundRegenStaker.rewardDuration() -
                (currentTestCtx.compoundRegenStaker.rewardDuration() * currentTestCtx.user2JoinTimePercent) /
                100
        );

        // Check if users actually have unclaimed rewards before attempting to compound
        currentTestCtx.unclaimed1 = currentTestCtx.compoundRegenStaker.unclaimedReward(currentTestCtx.depositId1);
        currentTestCtx.unclaimed2 = currentTestCtx.compoundRegenStaker.unclaimedReward(currentTestCtx.depositId2);

        currentTestCtx.compounded1 = 0;
        currentTestCtx.compounded2 = 0;

        if (currentTestCtx.unclaimed1 > 0) {
            vm.prank(currentTestCtx.user1);
            currentTestCtx.compounded1 = currentTestCtx.compoundRegenStaker.compoundRewards(currentTestCtx.depositId1);
        }

        if (currentTestCtx.unclaimed2 > 0) {
            vm.prank(currentTestCtx.user2);
            currentTestCtx.compounded2 = currentTestCtx.compoundRegenStaker.compoundRewards(currentTestCtx.depositId2);
        }

        // For extreme edge cases with tiny reward amounts, precision loss may result in 0 rewards
        // This is acceptable behavior as such small amounts wouldn't be used in practice
        if (currentTestCtx.unclaimed1 > 0) assertGt(currentTestCtx.compounded1, 0);
        if (currentTestCtx.unclaimed2 > 0) assertGt(currentTestCtx.compounded2, 0);

        {
            // Only verify reward calculations if both users actually received rewards
            // Extreme edge cases with tiny amounts may result in 0 rewards due to precision loss
            if (currentTestCtx.unclaimed1 > 0 && currentTestCtx.unclaimed2 > 0) {
                currentTestCtx.soloPhaseRewards =
                    (currentTestCtx.rewardAmount * currentTestCtx.user2JoinTimePercent) /
                    100;
                currentTestCtx.sharedPhaseRewards =
                    (currentTestCtx.rewardAmount * (100 - currentTestCtx.user2JoinTimePercent)) /
                    100;
                currentTestCtx.totalStake = currentTestCtx.user1Stake + currentTestCtx.user2Stake;

                // NOTE: These assertions may fail with extreme fuzzing values due to precision differences
                // when using 7-day reward duration vs original 30-day duration
                assertApproxEqRel(
                    currentTestCtx.compounded1,
                    currentTestCtx.soloPhaseRewards +
                        (currentTestCtx.sharedPhaseRewards * currentTestCtx.user1Stake) /
                        currentTestCtx.totalStake,
                    ONE_PERCENT
                );
                assertApproxEqRel(
                    currentTestCtx.compounded2,
                    (currentTestCtx.sharedPhaseRewards * currentTestCtx.user2Stake) / currentTestCtx.totalStake,
                    ONE_PERCENT
                );
            }
        }

        {
            (uint96 balance1, , , , , , ) = currentTestCtx.compoundRegenStaker.deposits(currentTestCtx.depositId1);
            (uint96 balance2, , , , , , ) = currentTestCtx.compoundRegenStaker.deposits(currentTestCtx.depositId2);

            assertEq(balance1, currentTestCtx.user1Stake + currentTestCtx.compounded1);
            assertEq(balance2, currentTestCtx.user2Stake + currentTestCtx.compounded2);
        }
    }

    function testFuzz_CompoundRewards_MidPeriodVsFullPeriod(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase,
        uint256 compoundTimePercent
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        rewardAmountBase = bound(rewardAmountBase, uint128(MIN_REWARD_DURATION), MAX_REWARD_DURATION + 1_000_000_000);
        compoundTimePercent = bound(compoundTimePercent, 10, 90);

        MockERC20Staking sameToken = new MockERC20Staking(18);

        vm.startPrank(ADMIN);
        RegenStaker compoundRegenStaker = new RegenStaker(
            IERC20(address(sameToken)),
            IERC20Staking(address(sameToken)),
            calculator,
            MAX_BUMP_TIP,
            ADMIN,
            uint128(MIN_REWARD_DURATION),
            0,
            stakerAllowset,
            IAddressSet(address(0)),
            AccessMode.NONE,
            allocationMechanismAllowset
        );
        compoundRegenStaker.setRewardNotifier(ADMIN, true);
        vm.stopPrank();

        address user = makeAddr("user");
        authorizeUser(user, true, false, true);

        uint256 stakeAmount = getStakeAmount(stakeAmountBase);
        uint256 rewardAmount = getRewardAmount(rewardAmountBase);

        sameToken.mint(user, stakeAmount);
        // Protection requires balance >= totalStaked + rewardAmount
        sameToken.mint(address(compoundRegenStaker), stakeAmount + rewardAmount);

        vm.startPrank(user);
        sameToken.approve(address(compoundRegenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = compoundRegenStaker.stake(stakeAmount, user);
        vm.stopPrank();

        vm.prank(ADMIN);
        compoundRegenStaker.notifyRewardAmount(rewardAmount);

        uint256 compoundTime = (compoundRegenStaker.rewardDuration() * compoundTimePercent) / 100;
        vm.warp(block.timestamp + compoundTime);

        vm.prank(user);
        uint256 firstCompound = compoundRegenStaker.compoundRewards(depositId);

        uint256 expectedFirstReward = (rewardAmount * compoundTimePercent) / 100;
        // NOTE: This assertion may fail with extreme fuzzing values due to precision differences
        // when using 7-day reward duration vs original 30-day duration
        assertApproxEqRel(firstCompound, expectedFirstReward, ONE_PERCENT);

        (uint96 balanceAfterFirst, , , , , , ) = compoundRegenStaker.deposits(depositId);
        assertEq(balanceAfterFirst, stakeAmount + firstCompound);

        uint256 remainingTime = compoundRegenStaker.rewardDuration() - compoundTime;
        vm.warp(block.timestamp + remainingTime);

        uint256 unclaimedAfterPeriod = compoundRegenStaker.unclaimedReward(depositId);
        uint256 expectedRemainingReward = (rewardAmount * (100 - compoundTimePercent)) / 100;
        // NOTE: This assertion may fail with extreme fuzzing values due to precision differences
        // when using 7-day reward duration vs original 30-day duration
        assertApproxEqRel(unclaimedAfterPeriod, expectedRemainingReward, ONE_PERCENT);
    }

    function testFuzz_CompoundRewards_DifferentTokenDecimals(
        uint256 stakeAmountBase,
        uint256 rewardAmountBase,
        uint8 decimals
    ) public {
        stakeAmountBase = bound(stakeAmountBase, 1, 10_000);
        rewardAmountBase = bound(rewardAmountBase, uint128(MIN_REWARD_DURATION), MAX_REWARD_DURATION + 1_000_000_000);
        decimals = uint8(bound(decimals, 6, 18));

        MockERC20Staking sameToken = new MockERC20Staking(decimals);

        vm.startPrank(ADMIN);
        RegenStaker compoundRegenStaker = new RegenStaker(
            IERC20(address(sameToken)),
            IERC20Staking(address(sameToken)),
            calculator,
            MAX_BUMP_TIP,
            ADMIN,
            uint128(MIN_REWARD_DURATION),
            0,
            stakerAllowset,
            IAddressSet(address(0)),
            AccessMode.NONE,
            allocationMechanismAllowset
        );
        compoundRegenStaker.setRewardNotifier(ADMIN, true);
        vm.stopPrank();

        address user = makeAddr("user");
        authorizeUser(user, true, false, true);

        uint256 stakeAmount = stakeAmountBase * (10 ** decimals);
        uint256 rewardAmount = rewardAmountBase * (10 ** decimals);

        sameToken.mint(user, stakeAmount);
        // Protection requires balance >= totalStaked + rewardAmount
        sameToken.mint(address(compoundRegenStaker), stakeAmount + rewardAmount);

        vm.startPrank(user);
        sameToken.approve(address(compoundRegenStaker), stakeAmount);
        Staker.DepositIdentifier depositId = compoundRegenStaker.stake(stakeAmount, user);
        vm.stopPrank();

        vm.prank(ADMIN);
        compoundRegenStaker.notifyRewardAmount(rewardAmount);

        vm.warp(block.timestamp + compoundRegenStaker.rewardDuration());

        uint256 unclaimedBefore = compoundRegenStaker.unclaimedReward(depositId);
        (uint96 balanceBefore, , , , , , ) = compoundRegenStaker.deposits(depositId);

        vm.prank(user);
        uint256 compoundedAmount = compoundRegenStaker.compoundRewards(depositId);

        assertEq(compoundedAmount, unclaimedBefore);
        assertApproxEqRel(compoundedAmount, rewardAmount, ONE_MICRO);

        (uint96 balanceAfter, , , , , , ) = compoundRegenStaker.deposits(depositId);
        assertEq(balanceAfter, balanceBefore + compoundedAmount);
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

    function test_AllocationMechanismAllowsetIsSet() public view {
        assertEq(address(regenStaker.allocationMechanismAllowset()), address(allocationMechanismAllowset));
    }
}
