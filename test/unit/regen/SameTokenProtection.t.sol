// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { AccessMode } from "src/constants.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { RegenStakerWithoutDelegateSurrogateVotes } from "src/regen/RegenStakerWithoutDelegateSurrogateVotes.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Staker } from "staker/Staker.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockERC20Staking } from "test/mocks/MockERC20Staking.sol";

import { Setup } from "./utils/Setup.sol";

contract RegenStakerSameTokenProtectionTest is Setup {
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
        earningPowerCalculator = _deployCalculator(
            admin,
            IAddressSet(address(allowset)),
            IAddressSet(address(0)),
            AccessMode.ALLOWSET
        );

        // Deploy staker with SAME token for staking and rewards
        staker = _deployRegenStaker(
            RegenCfg({
                rewardsToken: IERC20(address(token)),
                stakeToken: IERC20(address(token)),
                earningPowerCalculator: earningPowerCalculator,
                maxBumpTip: 0,
                admin: admin,
                rewardDuration: 30 days,
                minimumStakeAmount: 0,
                stakerAllowset: IAddressSet(address(0)),
                stakerBlockset: IAddressSet(address(0)),
                stakerAccessMode: AccessMode.NONE,
                allocationMechanismAllowset: allowset
            })
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

/// @title Tests for Same-Token Protection in RegenStakerWithoutDelegateSurrogateVotes
/// @notice Tests the protection mechanism that prevents reward notifications from corrupting user deposits
/// @dev Addresses REG-023 (OSU-956) - Same-token accounting vulnerability
contract RegenStakerWithoutDelegateSurrogateVotesSameTokenProtectionTest is Setup {
    RegenStakerWithoutDelegateSurrogateVotes public staker;
    RegenStakerWithoutDelegateSurrogateVotes public differentTokenStaker;
    MockERC20 public token;
    MockERC20 public rewardToken;
    MockERC20 public differentRewardToken;
    RegenEarningPowerCalculator public earningPowerCalculator;
    AddressSet public allowset;

    address public admin = address(0x1);
    address public notifier = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);

    uint256 public constant INITIAL_BALANCE = 1_000_000e18;
    uint256 public constant STAKE_AMOUNT = 1000e18;
    uint256 public constant REWARD_AMOUNT = 500e18;

    function setUp() public {
        // Deploy tokens
        token = new MockERC20(18);
        rewardToken = new MockERC20(18);
        differentRewardToken = new MockERC20(18);

        // Deploy allowset (constructor sets msg.sender as owner)
        allowset = new AddressSet();
        allowset.add(user1);
        allowset.add(user2);

        // Deploy earning power calculator
        earningPowerCalculator = _deployCalculator(
            admin,
            IAddressSet(address(allowset)),
            IAddressSet(address(0)),
            AccessMode.ALLOWSET
        );

        // Deploy staker with SAME token for staking and rewards (vulnerable scenario)
        staker = _deployRegenStakerWithoutDelegation(
            RegenCfg({
                rewardsToken: IERC20(address(token)),
                stakeToken: IERC20(address(token)),
                earningPowerCalculator: earningPowerCalculator,
                maxBumpTip: 0,
                admin: admin,
                rewardDuration: 30 days,
                minimumStakeAmount: 0,
                stakerAllowset: IAddressSet(address(0)),
                stakerBlockset: IAddressSet(address(0)),
                stakerAccessMode: AccessMode.NONE,
                allocationMechanismAllowset: allowset
            })
        );

        // Deploy staker with DIFFERENT tokens (safe scenario)
        differentTokenStaker = _deployRegenStakerWithoutDelegation(
            RegenCfg({
                rewardsToken: IERC20(address(differentRewardToken)),
                stakeToken: IERC20(address(token)),
                earningPowerCalculator: earningPowerCalculator,
                maxBumpTip: 0,
                admin: admin,
                rewardDuration: 30 days,
                minimumStakeAmount: 0,
                stakerAllowset: IAddressSet(address(0)),
                stakerBlockset: IAddressSet(address(0)),
                stakerAccessMode: AccessMode.NONE,
                allocationMechanismAllowset: allowset
            })
        );

        // Setup admin and notifier
        vm.startPrank(admin);
        staker.setRewardNotifier(notifier, true);
        differentTokenStaker.setRewardNotifier(notifier, true);
        vm.stopPrank();

        // Fund users
        token.mint(user1, INITIAL_BALANCE);
        token.mint(user2, INITIAL_BALANCE);
        token.mint(notifier, INITIAL_BALANCE);
        differentRewardToken.mint(notifier, INITIAL_BALANCE);
    }

    /// @notice Test unauthorized caller gets auth error before balance check
    function test_notifyReward_unauthorizedRevertsWithAuthError() public {
        // Setup: User stakes tokens
        vm.startPrank(user1);
        token.approve(address(staker), STAKE_AMOUNT);
        staker.stake(STAKE_AMOUNT, user1);
        vm.stopPrank();

        // Try to notify as unauthorized user (not notifier)
        // Even with sufficient balance, should fail on auth check first
        token.mint(address(staker), REWARD_AMOUNT); // Contract has sufficient balance

        vm.prank(user1); // user1 is not a notifier
        vm.expectRevert(abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not notifier"), user1));
        staker.notifyRewardAmount(REWARD_AMOUNT);

        // One auth failure is sufficient to validate access control ordering for readability
    }

    /// @notice Test success case: exact balance requirement (covers normal success path too)
    function test_notifyReward_withExactBalance() public {
        // User stakes tokens
        vm.startPrank(user1);
        token.approve(address(staker), STAKE_AMOUNT);
        staker.stake(STAKE_AMOUNT, user1);
        vm.stopPrank();

        // Notifier adds EXACT reward amount
        vm.startPrank(notifier);
        token.transfer(address(staker), REWARD_AMOUNT);

        // Should succeed - we have exactly stakes + rewards
        staker.notifyRewardAmount(REWARD_AMOUNT);
        vm.stopPrank();

        // Verify balance
        assertEq(token.balanceOf(address(staker)), STAKE_AMOUNT + REWARD_AMOUNT);
    }

    /// @notice Test protection case: insufficient balance prevents corruption
    function test_notifyReward_revertsWhenWouldAffectDeposits() public {
        // User stakes tokens
        vm.startPrank(user1);
        token.approve(address(staker), STAKE_AMOUNT);
        staker.stake(STAKE_AMOUNT, user1);
        vm.stopPrank();

        // Notifier tries to notify MORE rewards than available
        vm.startPrank(notifier);
        token.transfer(address(staker), 100e18); // Only transfer 100, but try to notify 500

        // Should revert - would need to eat into user deposits
        vm.expectRevert(
            abi.encodeWithSelector(
                RegenStakerBase.InsufficientRewardBalance.selector,
                STAKE_AMOUNT + 100e18, // currentBalance
                STAKE_AMOUNT + REWARD_AMOUNT // required
            )
        );
        staker.notifyRewardAmount(REWARD_AMOUNT);
        vm.stopPrank();
    }

    // Note: Multi-notification protection is covered by fuzz/property tests; omitting redundant example

    /// @notice Test protection after compounding increases totalStaked
    function test_notifyReward_afterCompounding() public {
        // Setup initial stake and rewards
        vm.startPrank(user1);
        token.approve(address(staker), STAKE_AMOUNT);
        staker.stake(STAKE_AMOUNT, user1);
        vm.stopPrank();

        // Add rewards
        vm.startPrank(notifier);
        token.transfer(address(staker), REWARD_AMOUNT);
        staker.notifyRewardAmount(REWARD_AMOUNT);
        vm.stopPrank();

        // Advance time to earn rewards
        vm.warp(block.timestamp + 15 days);

        // Compound rewards (DepositIdentifier(0) for first deposit)
        vm.prank(user1);
        staker.compoundRewards(Staker.DepositIdentifier.wrap(0));

        // totalStaked should have increased
        uint256 newTotalStaked = staker.totalStaked();
        assertGt(newTotalStaked, STAKE_AMOUNT);

        // Try to notify MORE than available balance - should fail with new simple accounting
        // New accounting: required = totalStaked + totalRewards - totalClaimedRewards + newAmount
        vm.startPrank(notifier);
        uint256 actualBalance = token.balanceOf(address(staker));

        // Get current state for simple accounting
        uint256 currentTotalRewards = staker.totalRewards();
        uint256 currentTotalClaimed = staker.totalClaimedRewards();
        uint256 newAmount = 300e18;

        vm.expectRevert(
            abi.encodeWithSelector(
                RegenStakerBase.InsufficientRewardBalance.selector,
                actualBalance, // currentBalance
                newTotalStaked + currentTotalRewards - currentTotalClaimed + newAmount
            )
        );
        staker.notifyRewardAmount(newAmount);

        // Add enough tokens to satisfy the simple accounting requirements
        // Need: totalStaked + totalRewards - totalClaimedRewards + newAmount - currentBalance
        uint256 additionalNeeded = newTotalStaked +
            currentTotalRewards -
            currentTotalClaimed +
            newAmount -
            actualBalance;
        token.transfer(address(staker), additionalNeeded);
        staker.notifyRewardAmount(300e18);
        vm.stopPrank();
    }

    /// @notice Test different tokens scenario now has appropriate balance validation
    function test_notifyReward_differentTokens_hasValidation() public {
        // User stakes tokens (these go to stake token, separate from reward token)
        vm.startPrank(user1);
        token.approve(address(differentTokenStaker), STAKE_AMOUNT);
        differentTokenStaker.stake(STAKE_AMOUNT, user1);
        vm.stopPrank();

        vm.startPrank(notifier);
        // Should fail without transferring reward tokens first
        vm.expectRevert(
            abi.encodeWithSelector(
                RegenStakerBase.InsufficientRewardBalance.selector,
                0, // currentBalance = 0 (no reward tokens transferred)
                REWARD_AMOUNT // required = totalRewards - totalClaimedRewards + amount = 0 - 0 + 500e18
            )
        );
        differentTokenStaker.notifyRewardAmount(REWARD_AMOUNT);

        // Transfer reward tokens and should succeed
        differentRewardToken.transfer(address(differentTokenStaker), REWARD_AMOUNT);
        differentTokenStaker.notifyRewardAmount(REWARD_AMOUNT);
        vm.stopPrank();
    }

    /// @notice Test admin typo scenario - the exact case we're protecting against
    function test_adminTypo_extraZero_prevented() public {
        // Setup: Users stake significant amounts
        vm.startPrank(user1);
        token.approve(address(staker), 10_000e18);
        staker.stake(10_000e18, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        token.approve(address(staker), 10_000e18);
        staker.stake(10_000e18, user2);
        vm.stopPrank();

        // Admin intends to notify 1,000 tokens but accidentally types 10,000 (extra zero)
        vm.startPrank(notifier);
        token.transfer(address(staker), 1_000e18); // Only transfer the intended amount

        // The typo notification should fail, protecting user deposits
        vm.expectRevert(
            abi.encodeWithSelector(
                RegenStakerBase.InsufficientRewardBalance.selector,
                20_000e18 + 1_000e18, // currentBalance (stakes + transferred rewards)
                20_000e18 + 10_000e18 // required (stakes + typo amount)
            )
        );
        staker.notifyRewardAmount(10_000e18); // Typo: extra zero

        // Correct notification works
        staker.notifyRewardAmount(1_000e18);
        vm.stopPrank();

        // Note: Withdrawal test removed as REG-007 (OSU-918) addresses the withdrawal issue
        // This test focuses on the protection mechanism preventing corruption
    }

    /// @notice Fuzz test: protection holds for various amounts
    function testFuzz_protection(uint256 stakeAmt, uint256 rewardAmt, uint256 actualTransfer) public {
        stakeAmt = bound(stakeAmt, 1e18, 100_000e18);
        rewardAmt = bound(rewardAmt, 1e18, 100_000e18);
        actualTransfer = bound(actualTransfer, 0, rewardAmt);

        // Setup stake
        token.mint(user1, stakeAmt);
        vm.startPrank(user1);
        token.approve(address(staker), stakeAmt);
        staker.stake(stakeAmt, user1);
        vm.stopPrank();

        // Try to notify rewards
        vm.startPrank(notifier);
        token.transfer(address(staker), actualTransfer);

        if (actualTransfer >= rewardAmt) {
            // Should succeed
            staker.notifyRewardAmount(rewardAmt);
        } else {
            // Should revert - insufficient balance
            vm.expectRevert(
                abi.encodeWithSelector(
                    RegenStakerBase.InsufficientRewardBalance.selector,
                    stakeAmt + actualTransfer, // currentBalance
                    stakeAmt + rewardAmt // required
                )
            );
            staker.notifyRewardAmount(rewardAmt);
        }
        vm.stopPrank();
    }
}
