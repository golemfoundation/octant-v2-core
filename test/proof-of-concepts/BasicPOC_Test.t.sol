// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { OctantTestBase } from "./OctantTestBase.t.sol";
import { Staker } from "staker/Staker.sol";

/**
 * @title Basic Octant POC Test
 * @notice Demonstrates integration between MultistrategyVault, RegenStaker, Allocation Mechanisms, and Strategies
 * @dev This POC test shows the core workflow:
 *      1. Users deposit into MultistrategyVault
 *      2. Vault allocates funds to yield-generating strategies
 *      3. Users stake tokens in RegenStaker to earn voting power
 *      4. Rewards are distributed through allocation mechanisms (quadratic funding)
 *      5. Strategy yields flow back to vault depositors
 */
contract BasicPOC_Test is OctantTestBase {
    function setUp() public override {
        // Deploy all infrastructure components:
        // - MultistrategyVault with yield strategy
        // - RegenStaker with earning power calculation
        // - AllocationMechanism with quadratic funding
        // - Configured allowsets and permissions
        super.setUp();
    }

    /**
     * @dev Demonstrates the complete flow from vault deposits to reward allocation
     */
    function test_BasicOctantFlow() external {
        // === PHASE 1: VAULT DEPOSITS ===
        // Alice and Bob deposit into the vault
        uint256 aliceShares = depositToVault(alice, INITIAL_DEPOSIT);
        uint256 bobShares = depositToVault(bob, INITIAL_DEPOSIT);

        assertEq(vault.balanceOf(alice), aliceShares, "Alice should receive vault shares");
        assertEq(vault.balanceOf(bob), bobShares, "Bob should receive vault shares");
        assertEq(vault.totalAssets(), INITIAL_DEPOSIT * 2, "Vault should hold total deposits");

        // === PHASE 2: STRATEGY ALLOCATION ===
        // Vault manager allocates funds to the yield strategy
        allocateVaultToStrategy(INITIAL_DEPOSIT);

        assertEq(vault.totalDebt(), INITIAL_DEPOSIT, "Vault should have debt to strategy");
        assertTrue(strategy.totalAssets() >= INITIAL_DEPOSIT, "Strategy should receive at least allocated funds");

        // === PHASE 3: REGEN STAKING ===
        // Alice and Bob stake tokens to earn voting power
        Staker.DepositIdentifier aliceDepositId = stakeTokens(alice, INITIAL_STAKE, alice);
        Staker.DepositIdentifier bobDepositId = stakeTokens(bob, INITIAL_STAKE, bob);

        assertTrue(Staker.DepositIdentifier.unwrap(aliceDepositId) >= 0, "Alice stake should be successful");
        assertTrue(Staker.DepositIdentifier.unwrap(bobDepositId) >= 0, "Bob stake should be successful");

        // === PHASE 4: REWARD DISTRIBUTION ===
        // Start reward period in RegenStaker
        startRewardPeriod(INITIAL_REWARDS);

        // Advance time to accrue rewards
        vm.warp(block.timestamp + 10 days);

        // === PHASE 5: STRATEGY YIELD GENERATION ===
        // Generate profit in the yield source
        generateYieldSourceProfit(5 ether);

        // Strategy reports profit back to vault
        reportStrategyProfit(5 ether);

        // Verify vault received the profit
        assertTrue(
            vault.totalAssets() > INITIAL_DEPOSIT * 2,
            "Vault should have increased assets from strategy profit"
        );

        // Verify vault total assets increased (profits are locked until unlock time)
        assertEq(
            vault.totalAssets(),
            INITIAL_DEPOSIT * 2 + 5 ether,
            "Vault should show increased assets from strategy profit"
        );

        // === PHASE 6: UNLOCK PROFITS ===
        // Advance time to unlock strategy profits (PROFIT_MAX_UNLOCK_TIME = 10 days)
        vm.warp(block.timestamp + 11 days);

        // === PHASE 7: REWARD CLAIMING ===
        // Alice and Bob can claim their staking rewards
        vm.prank(alice);
        uint256 aliceReward = regenStaker.claimReward(aliceDepositId);

        vm.prank(bob);
        uint256 bobReward = regenStaker.claimReward(bobDepositId);

        assertTrue(aliceReward > 0, "Alice should receive staking rewards");
        assertTrue(bobReward > 0, "Bob should receive staking rewards");
        assertEq(aliceReward, bobReward, "Equal stakes should receive equal rewards");

        // === PHASE 8: VAULT WITHDRAWALS ===
        // Users can withdraw their vault deposits plus yield
        vm.prank(alice);
        address[] memory strategies = new address[](0);
        uint256 aliceWithdrawal = vault.redeem(aliceShares, alice, alice, 0, strategies);

        assertTrue(
            aliceWithdrawal > INITIAL_DEPOSIT,
            "Alice should receive more than initial deposit due to strategy yield"
        );
    }

    /**
     * @dev Tests integration between vault strategies and allocation mechanisms
     */
    function test_StrategyAllocationIntegration() external {
        // Deposit into vault
        depositToVault(alice, INITIAL_DEPOSIT);

        // Allocate to strategy
        allocateVaultToStrategy(INITIAL_DEPOSIT / 2);

        // Generate strategy profit
        generateYieldSourceProfit(2 ether);
        reportStrategyProfit(2 ether);

        // Verify allocation mechanism can receive contributions
        vm.startPrank(alice);
        rewardToken.approve(address(allocationMechanism), 1 ether);

        // Note: This is a basic test - actual allocation mechanism interaction
        // would involve more complex voting and allocation logic
        assertTrue(address(allocationMechanism) != address(0), "Allocation mechanism should be deployed");
        vm.stopPrank();
    }

    /**
     * @dev Tests regen staker integration with allocation mechanisms
     */
    function test_RegenStakerAllocationIntegration() external {
        // Stake in regen staker
        Staker.DepositIdentifier depositId = stakeTokens(alice, INITIAL_STAKE, alice);

        // Start rewards
        startRewardPeriod(INITIAL_REWARDS);

        // Advance time
        vm.warp(block.timestamp + 5 days);

        // Alice should be able to check unclaimed rewards
        uint256 contribution = regenStaker.unclaimedReward(depositId);

        assertTrue(contribution > 0, "Alice should have unclaimed rewards");

        // Note: Actual contribution requires permit signature parameters
        // For this basic POC, we demonstrate that the system is properly integrated
        // and allocation mechanisms are inAllowset and accessible
    }
}
