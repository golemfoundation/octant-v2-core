// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.23;

import { AccessMode } from "src/constants.sol";
import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { RegenStakerWithoutDelegateSurrogateVotes } from "src/regen/RegenStakerWithoutDelegateSurrogateVotes.sol";
import { ISwapRouter } from "src/utils/vendor/uniswap/ISwapRouter.sol";
import { Staker } from "staker/Staker.sol";
import { MockERC20Staking } from "test/mocks/MockERC20Staking.sol";
import { MockEarningPowerCalculator } from "test/mocks/MockEarningPowerCalculator.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { AddressSet } from "src/utils/AddressSet.sol";

/// @title Tests for Same-Token Behavior in RegenStaker
/// @notice Tests that RegenStaker with surrogates relies on base Staker protection
/// @dev Addresses REG-023 (OSU-956) - Surrogate variant doesn't need custom protection
contract RegenStakerSameTokenProtectionTest is Test {
    RegenStaker public staker;
    MockERC20Staking public token;
    RegenEarningPowerCalculator public earningPowerCalculator;
    AddressSet public allowset;

    address public admin = address(0x1);
    address public notifier = address(0x2);
    address public user1 = address(0x3);
    address public delegatee = address(0x4);

    uint256 constant INITIAL_BALANCE = 1_000_000e18;
    uint256 constant STAKE_AMOUNT = 1000e18;
    uint256 constant REWARD_AMOUNT = 500e18;

    function setUp() public {
        // Deploy token with delegation support
        token = new MockERC20Staking(18);

        // Deploy allowset
        allowset = new AddressSet();
        allowset.add(user1);

        // Deploy earning power calculator
        earningPowerCalculator = new RegenEarningPowerCalculator(
            admin,
            IAddressSet(address(allowset)),
            IAddressSet(address(0)),
            AccessMode.ALLOWSET
        );

        // Deploy staker with SAME token for staking and rewards
        staker = new RegenStaker(
            IERC20(address(token)), // rewards token (SAME)
            token, // stake token (SAME)
            earningPowerCalculator,
            0, // maxBumpTip
            admin,
            30 days, // rewardDuration
            0, // minimumStakeAmount
            IAddressSet(address(0)), // no staker allowset
            IAddressSet(address(0)),
            AccessMode.NONE,
            allowset // allocation mechanism allowset
        );

        // Setup admin and notifier
        vm.startPrank(admin);
        staker.setRewardNotifier(notifier, true);
        vm.stopPrank();

        // Fund users
        token.mint(user1, INITIAL_BALANCE);
        token.mint(notifier, INITIAL_BALANCE);
    }

    /// @notice Test that RegenStaker relies on base Staker check (reward balance >= amount)
    function test_baseStakerCheckSufficientForSurrogates() public {
        // User stakes tokens (goes to surrogate)
        vm.startPrank(user1);
        token.approve(address(staker), STAKE_AMOUNT);
        staker.stake(STAKE_AMOUNT, delegatee, user1);
        vm.stopPrank();

        // Verify tokens are in surrogate, not main contract
        assertEq(token.balanceOf(address(staker)), 0, "Main contract should have no stake tokens");
        address surrogate = address(staker.surrogates(delegatee));
        assertEq(token.balanceOf(surrogate), STAKE_AMOUNT, "Surrogate should hold stake tokens");

        // Base Staker requires reward balance >= notified amount
        vm.startPrank(notifier);

        // Should revert - new balance validation: no rewards transferred yet
        vm.expectRevert(
            abi.encodeWithSelector(
                RegenStakerBase.InsufficientRewardBalance.selector,
                0, // currentBalance = 0 (no tokens transferred yet)
                REWARD_AMOUNT // required = totalRewards - totalClaimedRewards + amount = 0 - 0 + 500e18
            )
        );
        staker.notifyRewardAmount(REWARD_AMOUNT);

        // Transfer LESS than reward amount - should still fail balance check
        token.transfer(address(staker), REWARD_AMOUNT - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                RegenStakerBase.InsufficientRewardBalance.selector,
                REWARD_AMOUNT - 1, // currentBalance = 499e18 (transferred amount)
                REWARD_AMOUNT // required = 0 - 0 + 500e18 = 500e18
            )
        );
        staker.notifyRewardAmount(REWARD_AMOUNT);

        // Transfer exactly reward amount - should succeed
        // Note: Does NOT need totalStaked since stakes are segregated in surrogates
        token.transfer(address(staker), 1); // Add the missing 1 wei to reach REWARD_AMOUNT
        staker.notifyRewardAmount(REWARD_AMOUNT);
        vm.stopPrank();

        // This demonstrates that surrogate segregation makes the same-token scenario safe
        // without needing the additional protection that WithoutDelegate variant requires
    }

    /// @notice Test that different token scenario still works normally
    function test_differentTokensNoProtectionNeeded() public {
        // Deploy a variant with different reward token
        MockERC20Staking rewardToken = new MockERC20Staking(18);
        RegenStaker differentTokenStaker = new RegenStaker(
            IERC20(address(rewardToken)), // different reward token
            token, // stake token
            earningPowerCalculator,
            0,
            admin,
            30 days,
            0,
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            allowset
        );

        vm.startPrank(admin);
        differentTokenStaker.setRewardNotifier(notifier, true);
        vm.stopPrank();

        // Fund and notify - protection check is skipped for different tokens
        rewardToken.mint(notifier, REWARD_AMOUNT);
        vm.startPrank(notifier);
        rewardToken.transfer(address(differentTokenStaker), REWARD_AMOUNT);
        differentTokenStaker.notifyRewardAmount(REWARD_AMOUNT);
        vm.stopPrank();
    }
}

// ---- Moved from MockAdvanceRewardsSwapRouter.sol ----
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

// ---- Moved from RegenStakerAdvanceRewardSwap.t.sol ----
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

    function test_stakeWithAdvanceReward_swapsAndPaysOut_whenDifferentToken() public {
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
        assertEq(rewardToken.balanceOf(alice), ADVANCE_AMOUNT, "reward payout mismatch");
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

contract RegenStakerWithoutDelegateAdvanceRewardSwapTest is Test {
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
        assertEq(rewardToken.balanceOf(alice), ADVANCE_AMOUNT, "reward payout mismatch");
        assertEq(stakeToken.balanceOf(address(swapRouter)), ADVANCE_AMOUNT, "router should receive surrendered stake");

        uint64 lockEnd = regenStaker.advanceRewardLockEnd(depositId);
        assertEq(lockEnd, block.timestamp + (ADVANCE_AMOUNT * 3000 days) / STAKE_AMOUNT, "lock end mismatch");
    }
}
