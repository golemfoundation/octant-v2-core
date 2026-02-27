// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.23;

import { AccessMode } from "src/constants.sol";
import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { RegenStakerWithoutDelegateSurrogateVotes } from "src/regen/RegenStakerWithoutDelegateSurrogateVotes.sol";
import { ISwapRouter } from "src/utils/vendor/uniswap/ISwapRouter.sol";
import { Staker } from "staker/Staker.sol";
import { MockERC20Staking } from "test/mocks/MockERC20Staking.sol";
import { MockEarningPowerCalculator } from "test/mocks/MockEarningPowerCalculator.sol";
import { TokenizedAllocationMechanism } from "src/mechanisms/TokenizedAllocationMechanism.sol";
import { OctantQFMechanism } from "src/mechanisms/mechanism/OctantQFMechanism.sol";
import { AllocationConfig } from "src/mechanisms/BaseAllocationMechanism.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";

// =========================================================================
// Helpers & mocks
// =========================================================================

interface IMintableToken {
    function mint(address to, uint256 amount) external;
}

/// @notice Minimal Uniswap V3 router mock for advance rewards tests
contract MockAdvanceRewardsSwapRouter is ISwapRouter {
    using SafeERC20 for IERC20;

    error MockInsufficientOutput(uint256 actualOut, uint256 minOut);

    uint256 public outputBps = 10_000;

    function setOutputBps(uint256 _outputBps) external {
        outputBps = _outputBps;
    }

    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable override returns (uint256 amountOut) {
        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
        amountOut = (params.amountIn * outputBps) / 10_000;
        if (amountOut < params.amountOutMinimum) {
            revert MockInsufficientOutput(amountOut, params.amountOutMinimum);
        }
        IMintableToken(params.tokenOut).mint(params.recipient, amountOut);
    }

    function exactInput(ExactInputParams calldata) external payable override returns (uint256) {
        revert("unsupported");
    }

    function exactOutputSingle(ExactOutputSingleParams calldata) external payable override returns (uint256) {
        revert("unsupported");
    }

    function exactOutput(ExactOutputParams calldata) external payable override returns (uint256) {
        revert("unsupported");
    }

    function uniswapV3SwapCallback(int256, int256, bytes calldata) external pure override {
        revert("unsupported");
    }
}

interface ITransferFromHook {
    function onTransferFromHook() external;
}

contract ReenteringMockERC20Staking is MockERC20Staking {
    bool public reenterEnabled;
    uint256 public transferFromCount;

    constructor() MockERC20Staking(18) {}

    function setReenterEnabled(bool _enabled) external {
        reenterEnabled = _enabled;
    }

    function transferFrom(address from, address to, uint256 value) public override(ERC20, IERC20) returns (bool) {
        transferFromCount++;
        bool ok = super.transferFrom(from, to, value);

        // Trigger reentry on the second transferFrom in stakeWithAdvanceReward:
        // deposit is already created and lock must already be active.
        if (reenterEnabled && transferFromCount == 2 && from.code.length > 0) {
            ITransferFromHook(from).onTransferFromHook();
        }

        return ok;
    }
}

contract AdvanceRewardReentrantAttacker is ITransferFromHook {
    RegenStakerWithoutDelegateSurrogateVotes public immutable staker;
    ReenteringMockERC20Staking public immutable token;

    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes public reentryRevertData;

    uint256 public attackAmount;
    uint256 public attackAdvance;

    constructor(RegenStakerWithoutDelegateSurrogateVotes _staker, ReenteringMockERC20Staking _token) {
        staker = _staker;
        token = _token;
    }

    function execute(uint256 _amount, uint256 _advance) external {
        attackAmount = _amount;
        attackAdvance = _advance;

        token.approve(address(staker), _amount);
        staker.stakeWithAdvanceReward(_amount, address(0xBEEF), address(this), _advance, _advance);
    }

    function onTransferFromHook() external override {
        require(msg.sender == address(token), "only token");
        if (reentryAttempted) return;

        reentryAttempted = true;
        try staker.withdraw(Staker.DepositIdentifier.wrap(0), attackAmount - attackAdvance) {
            reentrySucceeded = true;
        } catch (bytes memory data) {
            reentryRevertData = data;
        }
    }
}

// =========================================================================
// Same-token advance rewards (with delegation)
// =========================================================================

contract RegenStakerAdvanceRewardSameTokenTest is Test {
    RegenStaker public regenStaker;
    MockERC20Staking public token;
    MockEarningPowerCalculator public earningPowerCalculator;
    OctantQFMechanism public allocationMechanism;
    AddressSet public allocationAllowset;

    address public admin = makeAddr("admin");
    address public owner;
    uint256 private ownerPk;
    address public claimer;
    address public delegatee = makeAddr("delegatee");
    address public stranger = makeAddr("stranger");

    uint256 public constant STAKE_AMOUNT = 1000e18;
    uint256 public constant REWARD_AMOUNT = 10_000e18;
    uint128 public constant REWARD_DURATION = 30 days;

    Staker.DepositIdentifier public depositId;

    function setUp() public {
        (owner, ownerPk) = makeAddrAndKey("owner");
        claimer = makeAddr("claimer");

        token = new MockERC20Staking(18);
        earningPowerCalculator = new MockEarningPowerCalculator();

        // Deploy a real OctantQFMechanism (same token for stake/reward)
        TokenizedAllocationMechanism impl = new TokenizedAllocationMechanism();
        AllocationConfig memory cfg = AllocationConfig({
            asset: IERC20(address(token)),
            name: "AdvanceTest",
            symbol: "ST",
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
            IAddressSet(address(0)), // contributionAllowset (open)
            IAddressSet(address(0)), // contributionBlockset (none)
            AccessMode.NONE
        );

        vm.startPrank(admin);
        allocationAllowset = new AddressSet();
        allocationAllowset.add(address(allocationMechanism));
        vm.stopPrank();

        vm.prank(admin);
        regenStaker = new RegenStaker(
            IERC20(address(token)), // rewardsToken (same as stake token)
            token,
            earningPowerCalculator,
            0, // maxBumpTip
            admin,
            REWARD_DURATION,
            1e18, // minimumStakeAmount
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            IAddressSet(address(allocationAllowset))
        );

        // Fund owner and stake
        token.mint(owner, STAKE_AMOUNT);
        token.mint(address(regenStaker), REWARD_AMOUNT);

        vm.startPrank(owner);
        token.approve(address(regenStaker), STAKE_AMOUNT);
        depositId = regenStaker.stake(STAKE_AMOUNT, delegatee, claimer);
        vm.stopPrank();

        // Schedule rewards
        vm.startPrank(admin);
        regenStaker.setRewardNotifier(admin, true);
        regenStaker.notifyRewardAmount(REWARD_AMOUNT);
        vm.stopPrank();
    }

    // =========================================================
    // Helpers
    // =========================================================

    /// @dev Returns deposit balance from the public tuple getter
    function _depositBalance(Staker.DepositIdentifier _depositId) internal view returns (uint96 bal) {
        (bal, , , , , , ) = regenStaker.deposits(_depositId);
    }

    function _contributeSignatureFor(
        address _contributor,
        uint256 _contributorPk,
        uint256 _amount
    ) internal returns (uint256 deadline, uint8 v, bytes32 r, bytes32 s) {
        bytes32 domainSeparator = TokenizedAllocationMechanism(address(allocationMechanism)).DOMAIN_SEPARATOR();
        uint256 nonce = TokenizedAllocationMechanism(address(allocationMechanism)).nonces(_contributor);
        deadline = block.timestamp + 1 days;

        bytes32 typeHash = keccak256(
            bytes("Signup(address user,address payer,uint256 deposit,uint256 nonce,uint256 deadline)")
        );
        bytes32 structHash = keccak256(
            abi.encode(typeHash, _contributor, address(regenStaker), _amount, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (v, r, s) = vm.sign(_contributorPk, digest);
    }

    // =========================================================
    // stakeWithAdvanceReward
    // =========================================================

    function test_stakeWithAdvanceReward_stakesAndEarmarksInOneCall() public {
        address bob = makeAddr("bob");
        uint256 bobStakeAmount = 200e18;
        uint256 advanceAmount = (bobStakeAmount * 5) / 100;

        token.mint(bob, bobStakeAmount);

        vm.startPrank(bob);
        token.approve(address(regenStaker), bobStakeAmount);
        Staker.DepositIdentifier bobDepositId = regenStaker.stakeWithAdvanceReward(
            bobStakeAmount,
            delegatee,
            bob,
            advanceAmount,
            advanceAmount
        );
        vm.stopPrank();

        (uint96 balance, address ownerAddr, , address delegateeAddr, address claimerAddr, , ) = regenStaker.deposits(
            bobDepositId
        );
        assertEq(ownerAddr, bob, "owner mismatch");
        assertEq(delegateeAddr, delegatee, "delegatee mismatch");
        assertEq(claimerAddr, bob, "claimer mismatch");
        assertEq(balance, bobStakeAmount - advanceAmount, "deposit balance should be reduced by earmark");

        uint64 lockEnd = regenStaker.advanceRewardLockEnd(bobDepositId);
        assertEq(lockEnd, block.timestamp + 5 * 30 days, "lock end mismatch");

        // Advance is credited as unclaimed rewards on the deposit, not paid out to caller.
        assertEq(token.balanceOf(bob), 0, "advance should not be paid out to caller");
        assertEq(regenStaker.unclaimedReward(bobDepositId), advanceAmount, "unclaimed reward should equal advance");
    }

    function test_stakeWithAdvanceRewardThenContribute() public {
        (address alice, uint256 alicePk) = makeAddrAndKey("alice-advance-e2e");
        uint256 advanceAmount = 10e18;
        uint256 stakeAmount = 200e18;

        token.mint(alice, stakeAmount);

        Staker.DepositIdentifier aliceDepositId;
        {
            vm.startPrank(alice);
            token.approve(address(regenStaker), stakeAmount);
            aliceDepositId = regenStaker.stakeWithAdvanceReward(
                stakeAmount,
                delegatee,
                alice,
                advanceAmount,
                advanceAmount
            );
            vm.stopPrank();
        }

        // Alice should NOT have received reward tokens.
        assertEq(token.balanceOf(alice), 0, "alice should not receive payout");

        // Lock must be set.
        assertGt(regenStaker.advanceRewardLockEnd(aliceDepositId), block.timestamp, "lock end should be in future");

        // The unclaimed amount should equal the advance.
        assertEq(regenStaker.unclaimedReward(aliceDepositId), advanceAmount, "unclaimed reward should equal advance");

        uint256 mechanismBalanceBefore = token.balanceOf(address(allocationMechanism));

        {
            (uint256 deadline, uint8 v, bytes32 r, bytes32 s) = _contributeSignatureFor(alice, alicePk, advanceAmount);
            vm.prank(alice);
            uint256 contributed = regenStaker.contribute(
                aliceDepositId,
                address(allocationMechanism),
                advanceAmount,
                deadline,
                v,
                r,
                s
            );
            assertEq(contributed, advanceAmount, "contributed amount mismatch");
        }

        assertEq(
            token.balanceOf(address(allocationMechanism)) - mechanismBalanceBefore,
            advanceAmount,
            "mechanism should receive advance reward tokens"
        );
    }

    function test_stakeWithAdvanceReward_withExplicitClaimer() public {
        address bob = makeAddr("bob2");
        uint256 bobStakeAmount = 120e18;

        token.mint(bob, bobStakeAmount);

        vm.startPrank(bob);
        token.approve(address(regenStaker), bobStakeAmount);
        uint256 advanceAmount = (bobStakeAmount * 2) / 100;
        Staker.DepositIdentifier bobDepositId = regenStaker.stakeWithAdvanceReward(
            bobStakeAmount,
            delegatee,
            claimer,
            advanceAmount,
            advanceAmount
        );
        vm.stopPrank();

        (, address ownerAddr, , , address claimerAddr, , ) = regenStaker.deposits(bobDepositId);
        assertEq(ownerAddr, bob, "owner mismatch");
        assertEq(claimerAddr, claimer, "explicit claimer mismatch");

        // Advance is credited as unclaimed rewards, not paid out to bob.
        assertEq(token.balanceOf(bob), 0, "advance should not be paid out to caller");
        assertEq(regenStaker.unclaimedReward(bobDepositId), advanceAmount, "unclaimed reward should equal advance");
    }

    function test_stakeWithAdvanceReward_usesCeilDivisionForTinyAdvanceLock() public {
        uint256 smallStakeAmount = 20e18;
        uint256 tinyAdvance = 1;
        uint256 lockDurationPerPercent = 30 days;
        token.mint(owner, smallStakeAmount);

        uint256 expectedDuration = ((tinyAdvance * lockDurationPerPercent * 100) - 1) / smallStakeAmount + 1;
        assertEq(expectedDuration, 1, "expected tiny advance lock duration should be 1 second");

        vm.startPrank(owner);
        token.approve(address(regenStaker), smallStakeAmount);
        Staker.DepositIdentifier tinyDepositId = regenStaker.stakeWithAdvanceReward(
            smallStakeAmount,
            delegatee,
            owner,
            tinyAdvance,
            tinyAdvance
        );
        vm.stopPrank();

        uint64 lockEnd = regenStaker.advanceRewardLockEnd(tinyDepositId);
        assertEq(lockEnd, block.timestamp + expectedDuration, "lock end should use ceil division");
    }

    function test_stakeWithAdvanceReward_revertsInvalidAdvanceAmount() public {
        address bob = makeAddr("bob3");
        uint256 bobStakeAmount = 120e18;
        token.mint(bob, bobStakeAmount);

        vm.startPrank(bob);
        token.approve(address(regenStaker), bobStakeAmount);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.ZeroOperation.selector));
        regenStaker.stakeWithAdvanceReward(bobStakeAmount, delegatee, claimer, 0, 0);
        uint256 tooLargeAdvance = (bobStakeAmount * 5) / 100 + 1;
        vm.expectRevert(
            abi.encodeWithSelector(RegenStakerBase.AdvanceExceedsCap.selector, tooLargeAdvance, bobStakeAmount / 20)
        );
        regenStaker.stakeWithAdvanceReward(bobStakeAmount, delegatee, claimer, tooLargeAdvance, 0);
        vm.stopPrank();
    }

    function test_stakeWithAdvanceReward_sameTokenRevertsWhenMinOutTooHigh() public {
        address bob = makeAddr("bob4");
        uint256 bobStakeAmount = 120e18;
        uint256 advanceAmount = (bobStakeAmount * 2) / 100;
        token.mint(bob, bobStakeAmount);

        vm.startPrank(bob);
        token.approve(address(regenStaker), bobStakeAmount);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.CantAfford.selector, advanceAmount + 1, advanceAmount));
        regenStaker.stakeWithAdvanceReward(bobStakeAmount, delegatee, claimer, advanceAmount, advanceAmount + 1);
        vm.stopPrank();
    }

    function test_setAdvanceSwapConfig_adminOnlyAndStores() public {
        address router = makeAddr("router");
        uint24 fee = 500;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not admin"), owner));
        regenStaker.setAdvanceSwapConfig(router, fee);

        vm.prank(admin);
        regenStaker.setAdvanceSwapConfig(router, fee);
    }

    function test_withdraw_revertsDuringLock_andAllowedAfterExpiry() public {
        address bob = makeAddr("bob5");
        uint256 bobStakeAmount = 200e18;
        uint256 advanceAmount = (bobStakeAmount * 5) / 100;
        token.mint(bob, bobStakeAmount);

        vm.startPrank(bob);
        token.approve(address(regenStaker), bobStakeAmount);
        Staker.DepositIdentifier bobDepositId = regenStaker.stakeWithAdvanceReward(
            bobStakeAmount,
            delegatee,
            bob,
            advanceAmount,
            advanceAmount
        );
        (uint96 balance, , , , , , ) = regenStaker.deposits(bobDepositId);
        uint64 lockEnd = regenStaker.advanceRewardLockEnd(bobDepositId);

        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.CommitmentLockActive.selector, bobDepositId, lockEnd));
        regenStaker.withdraw(bobDepositId, balance);

        vm.warp(lockEnd + 1);
        regenStaker.withdraw(bobDepositId, balance);
        vm.stopPrank();

        (uint96 remainingBalance, , , , , , ) = regenStaker.deposits(bobDepositId);
        assertEq(remainingBalance, 0, "full withdraw should clear balance");
        uint64 currentLockEnd = regenStaker.advanceRewardLockEnd(bobDepositId);
        assertEq(currentLockEnd, 0, "lock should clear after lock expiry and withdraw");
    }

    // =========================================================
    // contribute (reward-only, REWARD_TOKEN path)
    // =========================================================

    function test_contribute_usesRewardsOnly_whenAvailable() public {
        vm.warp(block.timestamp + REWARD_DURATION / 4);

        uint256 rewardAvailable = regenStaker.unclaimedReward(depositId);
        uint256 rewardToContribute = rewardAvailable / 2;
        require(rewardToContribute > 0, "reward-to-contribute should be > 0");

        (uint256 deadline, uint8 v, bytes32 r, bytes32 s) = _contributeSignatureFor(owner, ownerPk, rewardToContribute);

        uint256 mechanismBalanceBefore = token.balanceOf(address(allocationMechanism));
        uint96 balanceBefore = _depositBalance(depositId);
        uint256 totalStakedBefore = regenStaker.totalStaked();

        vm.prank(owner);
        uint256 contributed = regenStaker.contribute(
            depositId,
            address(allocationMechanism),
            rewardToContribute,
            deadline,
            v,
            r,
            s
        );

        assertEq(contributed, rewardToContribute, "contributed amount mismatch");
        assertEq(
            token.balanceOf(address(allocationMechanism)) - mechanismBalanceBefore,
            rewardToContribute,
            "all contribution should hit mechanism"
        );
        assertEq(_depositBalance(depositId), balanceBefore, "deposit balance should not reduce");
        assertEq(regenStaker.totalStaked(), totalStakedBefore, "total staked should not change");
    }

    function test_contribute_rewardOnlyLegStillWorksDuringActiveLock() public {
        uint256 ownerStakeAmount = 200e18;
        token.mint(owner, ownerStakeAmount);

        vm.startPrank(owner);
        token.approve(address(regenStaker), ownerStakeAmount);
        Staker.DepositIdentifier lockedDepositId = regenStaker.stakeWithAdvanceReward(
            ownerStakeAmount,
            delegatee,
            owner,
            (ownerStakeAmount * 5) / 100,
            (ownerStakeAmount * 5) / 100
        );
        vm.stopPrank();

        vm.warp(block.timestamp + REWARD_DURATION / 4);

        uint64 lockEnd = regenStaker.advanceRewardLockEnd(lockedDepositId);

        uint256 rewardAvailable = regenStaker.unclaimedReward(lockedDepositId);
        uint256 rewardToContribute = rewardAvailable / 2;
        require(rewardToContribute > 0, "reward-to-contribute should be > 0");

        (uint256 deadline, uint8 v, bytes32 r, bytes32 s) = _contributeSignatureFor(owner, ownerPk, rewardToContribute);

        uint256 mechanismBalanceBefore = token.balanceOf(address(allocationMechanism));
        vm.prank(owner);
        uint256 contributed = regenStaker.contribute(
            lockedDepositId,
            address(allocationMechanism),
            rewardToContribute,
            deadline,
            v,
            r,
            s
        );

        assertEq(contributed, rewardToContribute);
        assertEq(token.balanceOf(address(allocationMechanism)) - mechanismBalanceBefore, rewardToContribute);
        // contribute() does not touch lock metadata
        uint64 currentLockEnd = regenStaker.advanceRewardLockEnd(lockedDepositId);
        assertEq(currentLockEnd, lockEnd);
    }

    function test_contribute_zeroAmountStillAllowedForContributionSignup() public {
        vm.warp(block.timestamp + REWARD_DURATION / 4);
        uint256 rewardAvailable = regenStaker.unclaimedReward(depositId);
        require(rewardAvailable > 0, "reward should be available");

        (uint256 deadline, uint8 v, bytes32 r, bytes32 s) = _contributeSignatureFor(owner, ownerPk, 0);

        vm.prank(owner);
        uint256 contributed = regenStaker.contribute(depositId, address(allocationMechanism), 0, deadline, v, r, s);
        assertEq(contributed, 0, "zero amount should still be a valid signup path");
    }

    function test_stakeWithAdvanceReward_totalRewardsTracked_notifyRemainsUnbricked() public {
        // Regression: without totalRewards += rewardOut, consuming advance rewards via contribute()
        // increments totalClaimedRewards without a corresponding totalRewards increase, causing
        // totalRewards - totalClaimedRewards to underflow and brick future notifyRewardAmount calls.
        address bob = makeAddr("bob-totalRewards");
        uint256 bobStakeAmount = 200e18;
        uint256 advanceAmount = 10e18;
        token.mint(bob, bobStakeAmount);

        vm.startPrank(bob);
        token.approve(address(regenStaker), bobStakeAmount);
        Staker.DepositIdentifier bobDepositId = regenStaker.stakeWithAdvanceReward(
            bobStakeAmount,
            delegatee,
            bob,
            advanceAmount,
            advanceAmount
        );
        vm.stopPrank();

        // totalRewards must have grown by exactly advanceAmount: tokens are in the contract
        // and the obligation is now tracked so _consumeRewards won't cause an underflow later.
        assertEq(
            regenStaker.totalRewards() - regenStaker.totalClaimedRewards(),
            advanceAmount + REWARD_AMOUNT,
            "outstanding obligations should include advance"
        );

        // Consume the advance via contribute().
        (, uint256 bobPk) = makeAddrAndKey("bob-totalRewards");
        (uint256 deadline, uint8 v, bytes32 r, bytes32 s) = _contributeSignatureFor(bob, bobPk, advanceAmount);

        vm.prank(bob);
        regenStaker.contribute(bobDepositId, address(allocationMechanism), advanceAmount, deadline, v, r, s);

        // totalRewards - totalClaimedRewards must not underflow; notifyRewardAmount must succeed.
        uint256 totalRewardsAfterContribute = regenStaker.totalRewards();
        uint256 notifyAmount = 100e18;
        token.mint(admin, notifyAmount);
        vm.startPrank(admin);
        token.transfer(address(regenStaker), notifyAmount);
        regenStaker.notifyRewardAmount(notifyAmount); // would revert with underflow before fix
        vm.stopPrank();

        assertEq(
            regenStaker.totalRewards(),
            totalRewardsAfterContribute + notifyAmount,
            "totalRewards should include notify amount"
        );
    }
}

// =========================================================================
// Different-token advance rewards (swap path, with delegation)
// =========================================================================

contract RegenStakerAdvanceRewardSwapTest is Test {
    RegenStaker public regenStaker;
    MockERC20Staking public stakeToken;
    MockERC20Staking public rewardToken;
    MockEarningPowerCalculator public earningPowerCalculator;
    AddressSet public allocationAllowset;
    MockAdvanceRewardsSwapRouter public swapRouter;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public delegatee = makeAddr("delegatee");
    address public claimer = makeAddr("claimer");

    uint256 public constant STAKE_AMOUNT = 200e18;
    uint256 public constant ADVANCE_AMOUNT = 10e18;
    uint128 public constant REWARD_DURATION = 30 days;

    function setUp() public {
        stakeToken = new MockERC20Staking(18);
        rewardToken = new MockERC20Staking(18);
        earningPowerCalculator = new MockEarningPowerCalculator();
        swapRouter = new MockAdvanceRewardsSwapRouter();

        vm.startPrank(admin);
        allocationAllowset = new AddressSet();
        vm.stopPrank();

        vm.prank(admin);
        regenStaker = new RegenStaker(
            IERC20(address(rewardToken)),
            stakeToken,
            earningPowerCalculator,
            0,
            admin,
            REWARD_DURATION,
            1e18,
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            IAddressSet(address(allocationAllowset))
        );

        stakeToken.mint(alice, STAKE_AMOUNT);
    }

    function test_stakeWithAdvanceReward_swapsAndCreditsRewards_whenDifferentToken() public {
        vm.prank(admin);
        regenStaker.setAdvanceSwapConfig(address(swapRouter), 3000);

        vm.startPrank(alice);
        stakeToken.approve(address(regenStaker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = regenStaker.stakeWithAdvanceReward(
            STAKE_AMOUNT,
            delegatee,
            claimer,
            ADVANCE_AMOUNT,
            ADVANCE_AMOUNT
        );
        vm.stopPrank();

        (uint96 balance, address ownerAddr, , address delegateeAddr, address claimerAddr, , ) = regenStaker.deposits(
            depositId
        );
        assertEq(balance, STAKE_AMOUNT - ADVANCE_AMOUNT, "net stake balance mismatch");
        assertEq(ownerAddr, alice, "owner mismatch");
        assertEq(delegateeAddr, delegatee, "delegatee mismatch");
        assertEq(claimerAddr, claimer, "claimer mismatch");

        // Swap output stays in contract, credited as unclaimed rewards: not paid out to alice.
        assertEq(rewardToken.balanceOf(alice), 0, "advance should not be paid out to caller");
        assertEq(regenStaker.unclaimedReward(depositId), ADVANCE_AMOUNT, "unclaimed reward should equal swap output");
        assertEq(stakeToken.balanceOf(address(swapRouter)), ADVANCE_AMOUNT, "router should receive surrendered stake");
        assertEq(stakeToken.allowance(address(regenStaker), address(swapRouter)), 0, "router allowance should clear");

        uint64 lockEnd = regenStaker.advanceRewardLockEnd(depositId);
        assertEq(lockEnd, block.timestamp + (ADVANCE_AMOUNT * 3000 days) / STAKE_AMOUNT, "lock end mismatch");
    }

    function test_stakeWithAdvanceReward_revertsWhenRouterNotSet_forDifferentToken() public {
        vm.startPrank(alice);
        stakeToken.approve(address(regenStaker), STAKE_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(Staker.Staker__InvalidAddress.selector));
        regenStaker.stakeWithAdvanceReward(STAKE_AMOUNT, delegatee, claimer, ADVANCE_AMOUNT, ADVANCE_AMOUNT);
        vm.stopPrank();
    }

    function test_stakeWithAdvanceReward_revertsWhenSwapOutputBelowMinOut() public {
        vm.prank(admin);
        regenStaker.setAdvanceSwapConfig(address(swapRouter), 3000);
        swapRouter.setOutputBps(9000);

        vm.startPrank(alice);
        stakeToken.approve(address(regenStaker), STAKE_AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockAdvanceRewardsSwapRouter.MockInsufficientOutput.selector,
                (ADVANCE_AMOUNT * 9000) / 10_000,
                ADVANCE_AMOUNT
            )
        );
        regenStaker.stakeWithAdvanceReward(STAKE_AMOUNT, delegatee, claimer, ADVANCE_AMOUNT, ADVANCE_AMOUNT);
        vm.stopPrank();
    }
}

// =========================================================================
// Different-token advance rewards (swap path, without delegation)
// =========================================================================

contract RegenStakerAdvanceRewardNoDelegationSwapTest is Test {
    RegenStakerWithoutDelegateSurrogateVotes public regenStaker;
    MockERC20Staking public stakeToken;
    MockERC20Staking public rewardToken;
    MockEarningPowerCalculator public earningPowerCalculator;
    AddressSet public allocationAllowset;
    MockAdvanceRewardsSwapRouter public swapRouter;

    address public admin = makeAddr("admin-no-delegation");
    address public alice = makeAddr("alice-no-delegation");
    address public delegatee = makeAddr("delegatee-no-delegation");

    uint256 public constant STAKE_AMOUNT = 200e18;
    uint256 public constant ADVANCE_AMOUNT = 10e18;
    uint128 public constant REWARD_DURATION = 30 days;

    function setUp() public {
        stakeToken = new MockERC20Staking(18);
        rewardToken = new MockERC20Staking(18);
        earningPowerCalculator = new MockEarningPowerCalculator();
        swapRouter = new MockAdvanceRewardsSwapRouter();

        vm.startPrank(admin);
        allocationAllowset = new AddressSet();
        vm.stopPrank();

        vm.prank(admin);
        regenStaker = new RegenStakerWithoutDelegateSurrogateVotes(
            IERC20(address(rewardToken)),
            IERC20(address(stakeToken)),
            earningPowerCalculator,
            0,
            admin,
            REWARD_DURATION,
            1e18,
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            IAddressSet(address(allocationAllowset))
        );

        vm.prank(admin);
        regenStaker.setAdvanceSwapConfig(address(swapRouter), 3000);
        stakeToken.mint(alice, STAKE_AMOUNT);
    }

    function test_stakeWithAdvanceReward_noDelegationVariant_usesSameExchangeSemantics() public {
        vm.startPrank(alice);
        stakeToken.approve(address(regenStaker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = regenStaker.stakeWithAdvanceReward(
            STAKE_AMOUNT,
            delegatee,
            alice,
            ADVANCE_AMOUNT,
            ADVANCE_AMOUNT
        );
        vm.stopPrank();

        (uint96 balance, address ownerAddr, , address delegateeAddr, address claimerAddr, , ) = regenStaker.deposits(
            depositId
        );
        assertEq(balance, STAKE_AMOUNT - ADVANCE_AMOUNT, "net stake balance mismatch");
        assertEq(ownerAddr, alice, "owner mismatch");
        assertEq(delegateeAddr, delegatee, "delegatee mismatch");
        assertEq(claimerAddr, alice, "claimer mismatch");

        // Swap output stays in contract, credited as unclaimed rewards: not paid out to alice.
        assertEq(rewardToken.balanceOf(alice), 0, "advance should not be paid out to caller");
        assertEq(regenStaker.unclaimedReward(depositId), ADVANCE_AMOUNT, "unclaimed reward should equal swap output");
        assertEq(stakeToken.balanceOf(address(swapRouter)), ADVANCE_AMOUNT, "router should receive surrendered stake");

        uint64 lockEnd = regenStaker.advanceRewardLockEnd(depositId);
        assertEq(lockEnd, block.timestamp + (ADVANCE_AMOUNT * 3000 days) / STAKE_AMOUNT, "lock end mismatch");
    }
}

// =========================================================================
// Reentrancy protection
// =========================================================================

contract RegenStakerAdvanceRewardReentrancyTest is Test {
    ReenteringMockERC20Staking public token;
    MockEarningPowerCalculator public earningPowerCalculator;
    RegenStakerWithoutDelegateSurrogateVotes public staker;
    AddressSet public allocationAllowset;

    address public admin = makeAddr("admin");
    uint128 public constant REWARD_DURATION = 30 days;

    function setUp() public {
        token = new ReenteringMockERC20Staking();
        earningPowerCalculator = new MockEarningPowerCalculator();

        vm.startPrank(admin);
        allocationAllowset = new AddressSet();
        vm.stopPrank();

        vm.prank(admin);
        staker = new RegenStakerWithoutDelegateSurrogateVotes(
            IERC20(address(token)),
            IERC20(address(token)),
            earningPowerCalculator,
            0,
            admin,
            REWARD_DURATION,
            1e18,
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            IAddressSet(address(allocationAllowset))
        );
    }

    function test_stakeWithAdvanceReward_reentrantWithdrawBlockedByReentrancyGuard() public {
        AdvanceRewardReentrantAttacker attacker = new AdvanceRewardReentrantAttacker(staker, token);

        uint256 amount = 100e18;
        uint256 advance = 5e18;

        token.mint(address(attacker), amount);
        token.setReenterEnabled(true);

        attacker.execute(amount, advance);

        assertTrue(attacker.reentryAttempted(), "reentry should have been attempted");
        assertFalse(attacker.reentrySucceeded(), "reentrant withdraw must fail");
        // stakeWithAdvanceReward now holds the nonReentrant lock for its full execution, so the
        // reentrant withdraw attempt hits the reentrancy guard before the commitment lock check.
        assertEq(
            _selector(attacker.reentryRevertData()),
            ReentrancyGuard.ReentrancyGuardReentrantCall.selector,
            "wrong revert selector"
        );

        Staker.DepositIdentifier depositId = Staker.DepositIdentifier.wrap(0);
        (uint96 balance, , , , , , ) = staker.deposits(depositId);
        assertEq(balance, amount - advance, "deposit should remain locked and staked");
        assertGt(staker.advanceRewardLockEnd(depositId), block.timestamp, "commitment lock should be active");
        // Advance is credited as unclaimed rewards on the deposit, not paid out.
        assertEq(token.balanceOf(address(attacker)), 0, "attacker should receive no advance payout");
        assertEq(staker.unclaimedReward(depositId), advance, "advance should be credited as unclaimed rewards");
    }

    function _selector(bytes memory data) internal pure returns (bytes4 sel) {
        if (data.length < 4) return bytes4(0);
        assembly {
            sel := mload(add(data, 32))
        }
    }
}
