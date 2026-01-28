// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";
import { IBaseHealthCheck } from "src/strategies/interfaces/IBaseHealthCheck.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { BaseIntegrationTest } from "../../base/BaseIntegrationTest.sol";

/// @title BaseYieldDonatingIntegrationTest
/// @notice Base contract for all yield donating strategy integration tests
/// @dev Provides shared test implementations that can be called from concrete test contracts
abstract contract BaseYieldDonatingIntegrationTest is BaseIntegrationTest {
    using SafeERC20 for ERC20;

    // ========== STATE VARIABLES ==========

    /// @notice Implementation of YieldDonatingTokenizedStrategy
    YieldDonatingTokenizedStrategy public implementation;

    // ========== ABSTRACT METHODS ==========

    /// @notice Returns the compounder/staking vault address for mocking
    function _compounderVault() internal view virtual returns (address);

    /// @notice Etches the implementation bytecode to the expected address (if needed)
    function _etchImplementation() internal virtual;

    /// @notice Returns the minimum deposit amount for fuzz tests
    function _minDeposit() internal view virtual returns (uint256);

    /// @notice Returns the maximum deposit amount for fuzz tests
    function _maxDeposit() internal view virtual returns (uint256);

    // ========== SHARED TEST IMPLEMENTATIONS ==========

    /// @notice Test that the strategy is properly initialized
    function _testInitialization() internal view virtual {
        assertEq(IERC4626(address(vault)).asset(), _asset(), "Asset address incorrect");
        assertEq(vault.management(), management, "Management address incorrect");
        assertEq(vault.keeper(), keeper, "Keeper address incorrect");
        assertEq(vault.emergencyAdmin(), emergencyAdmin, "Emergency admin incorrect");
    }

    /// @notice Fuzz test depositing assets into the strategy
    /// @param depositAmount Amount to deposit (will be bounded)
    function _testFuzzDeposit(uint256 depositAmount) internal {
        depositAmount = bound(depositAmount, _minDeposit(), _maxDeposit());

        // Ensure user has enough balance
        if (ERC20(_asset()).balanceOf(user) < depositAmount) {
            airdrop(ERC20(_asset()), user, depositAmount);
        }

        uint256 initialUserBalance = ERC20(_asset()).balanceOf(user);
        uint256 initialStrategyAssets = IERC4626(address(vault)).totalAssets();

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        uint256 sharesReceived = IERC4626(address(vault)).deposit(depositAmount, user);
        vm.stopPrank();

        assertEq(
            ERC20(_asset()).balanceOf(user),
            initialUserBalance - depositAmount,
            "User balance not reduced correctly"
        );
        assertGt(sharesReceived, 0, "No shares received from deposit");
        assertEq(
            IERC4626(address(vault)).totalAssets(),
            initialStrategyAssets + depositAmount,
            "Strategy total assets should increase"
        );
    }

    /// @notice Fuzz test withdrawing assets from the strategy
    /// @param depositAmount Amount to deposit (will be bounded)
    /// @param withdrawFraction Percentage to withdraw (1-100)
    function _testFuzzWithdraw(uint256 depositAmount, uint256 withdrawFraction) internal {
        depositAmount = bound(depositAmount, _minDeposit(), _maxDeposit());
        withdrawFraction = bound(withdrawFraction, 1, 100);

        // Ensure user has enough balance
        if (ERC20(_asset()).balanceOf(user) < depositAmount) {
            airdrop(ERC20(_asset()), user, depositAmount);
        }

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        IERC4626(address(vault)).deposit(depositAmount, user);

        uint256 withdrawAmount = (depositAmount * withdrawFraction) / 100;
        vm.assume(withdrawAmount > 0);

        uint256 initialUserBalance = ERC20(_asset()).balanceOf(user);
        uint256 initialShareBalance = IERC4626(address(vault)).balanceOf(user);

        uint256 previewMaxWithdraw = IERC4626(address(vault)).maxWithdraw(user);
        vm.assume(previewMaxWithdraw >= withdrawAmount);
        uint256 sharesToBurn = IERC4626(address(vault)).previewWithdraw(withdrawAmount);
        uint256 assetsReceived = IERC4626(address(vault)).withdraw(withdrawAmount, user, user);
        vm.stopPrank();

        assertEq(
            ERC20(_asset()).balanceOf(user),
            initialUserBalance + withdrawAmount,
            "User didn't receive correct assets"
        );
        assertEq(
            IERC4626(address(vault)).balanceOf(user),
            initialShareBalance - sharesToBurn,
            "Shares not burned correctly"
        );
        assertEq(assetsReceived, withdrawAmount, "Incorrect amount of assets received");
    }

    /// @notice Basic test depositing assets into the strategy
    /// @param depositAmount Amount to deposit
    function _testDeposit(uint256 depositAmount) internal {
        uint256 initialUserBalance = ERC20(_asset()).balanceOf(user);

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        uint256 sharesReceived = vault.deposit(depositAmount, user);
        vm.stopPrank();

        assertEq(
            ERC20(_asset()).balanceOf(user),
            initialUserBalance - depositAmount,
            "User balance not reduced correctly"
        );
        assertGt(sharesReceived, 0, "No shares received from deposit");
    }

    /// @notice Basic test withdrawing assets from the strategy
    /// @param depositAmount Amount to deposit first
    function _testWithdraw(uint256 depositAmount) internal {
        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user);

        uint256 initialUserBalance = ERC20(_asset()).balanceOf(user);
        uint256 initialShareBalance = vault.balanceOf(user);

        uint256 withdrawAmount = depositAmount / 2;
        uint256 sharesToBurn = vault.previewWithdraw(withdrawAmount);
        uint256 assetsReceived = vault.withdraw(withdrawAmount, user, user);
        vm.stopPrank();

        assertEq(
            ERC20(_asset()).balanceOf(user),
            initialUserBalance + withdrawAmount,
            "User didn't receive correct assets"
        );
        assertEq(vault.balanceOf(user), initialShareBalance - sharesToBurn, "Shares not burned correctly");
        assertEq(assetsReceived, withdrawAmount, "Incorrect amount of assets received");
    }

    /// @notice Test harvesting functionality with profit
    /// @param depositAmount Amount to deposit
    /// @param profitAmount Amount of profit to simulate
    function _testHarvestWithProfit(uint256 depositAmount, uint256 profitAmount) internal virtual {
        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 userSharesBefore = vault.balanceOf(user);

        // Simulate profit by airdropping assets to strategy
        airdrop(ERC20(_asset()), address(vault), profitAmount);

        // Expect the Reported event
        vm.startPrank(keeper);
        vm.expectEmit(true, true, true, true);
        emit Reported(profitAmount, 0);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();

        assertGt(profit, 0, "Should have captured profit");
        assertEq(loss, 0, "Should have no loss");

        // User shares should remain the same (profit is donated)
        assertEq(vault.balanceOf(user), userSharesBefore, "User shares should not change");

        // Total assets should increase
        assertGt(vault.totalAssets(), totalAssetsBefore, "Total assets should increase");

        // Donation address should have received profit shares
        uint256 donationBalance = ERC20(address(vault)).balanceOf(donationAddress);
        assertGt(donationBalance, 0, "Donation address should receive profit shares");
    }

    /// @notice Test multiple users with fair profit distribution
    function _testMultipleUserProfitDistribution() internal virtual {
        address user1 = user;
        address user2 = address(0x5678);

        uint256 depositAmount1 = 1000 * 10 ** _decimals();
        uint256 depositAmount2 = 2000 * 10 ** _decimals();

        vm.startPrank(user1);
        ERC20(_asset()).approve(address(vault), depositAmount1);
        vault.deposit(depositAmount1, user1);
        vm.stopPrank();

        // Generate some profit for first user
        uint256 profit1 = depositAmount1 / 10; // 10% profit
        airdrop(ERC20(_asset()), address(vault), profit1);

        // Harvest to realize profit
        vm.startPrank(keeper);
        vault.report();
        vm.stopPrank();

        // Check share price stays the same (profit is donated)
        uint256 sharePrice1 = vault.convertToAssets(1e18);
        assertEq(sharePrice1, 1e18, "Share price should stay the same since profit is minted");

        // Second user deposits after profit
        airdrop(ERC20(_asset()), user2, depositAmount2);

        vm.startPrank(user2);
        ERC20(_asset()).approve(address(vault), type(uint256).max);
        vault.deposit(depositAmount2, user2);
        vm.stopPrank();

        // Generate more profit after second user joined
        uint256 profit2 = (depositAmount1 + depositAmount2) / 10; // 10% of total
        airdrop(ERC20(_asset()), address(vault), profit2);

        // Harvest again
        vm.startPrank(keeper);
        vault.report();
        vm.stopPrank();

        // Skip time to allow profit to unlock
        skip(365 days);

        // Check share price stays the same since profit is minted
        uint256 sharePrice2 = vault.convertToAssets(1e18);
        assertEq(sharePrice2, sharePrice1, "Share price should stay the same since profit is minted");

        // Both users withdraw
        vm.startPrank(user1);
        uint256 user1Shares = vault.balanceOf(user1);
        uint256 user1Assets = vault.redeem(user1Shares, user1, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        uint256 user2Shares = vault.balanceOf(user2);
        uint256 user2Assets = vault.redeem(user2Shares, user2, user2);
        vm.stopPrank();

        // Users should receive approximately their original deposits (profit goes to donation address)
        uint256 user1ProfitPercentage = ((user1Assets - depositAmount1) * 1e18) / depositAmount1;
        uint256 user2ProfitPercentage = ((user2Assets - depositAmount2) * 1e18) / depositAmount2;

        assertEq(user1ProfitPercentage, 0, "User 1 should have received no profit");
        assertEq(user1ProfitPercentage, user2ProfitPercentage, "Users should have received no profit");

        // Check donation address received profit shares
        uint256 donationShares = vault.balanceOf(donationAddress);
        assertGt(donationShares, 0, "Donation address should receive shares from profit");
    }

    /// @notice Returns the asset decimals for calculations
    function _decimals() internal view virtual returns (uint8) {
        return 18;
    }

    /// @notice Test basic harvest functionality
    /// @param depositAmount Amount to deposit
    function _testHarvest(uint256 depositAmount) internal {
        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Fast forward time
        skip(7 days);

        uint256 initialAssets = vault.totalAssets();

        vm.startPrank(keeper);
        vault.report();
        vm.stopPrank();

        // Assets should not decrease
        assertGe(vault.totalAssets(), initialAssets, "Total assets should not decrease after harvest");
    }

    /// @notice Test emergency exit functionality
    /// @param depositAmount Amount to deposit
    function _testEmergencyExit(uint256 depositAmount) internal virtual {
        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Emergency shutdown and withdraw
        vm.startPrank(emergencyAdmin);
        vault.shutdownStrategy();
        vault.emergencyWithdraw(type(uint256).max);
        vm.stopPrank();

        // User should be able to withdraw their funds
        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        uint256 assetsReceived = vault.redeem(userShares, user, user);
        vm.stopPrank();

        assertApproxEqRel(assetsReceived, depositAmount, 0.01e18, "User should receive approximately original deposit");
    }

    /// @notice Fuzz test emergency withdraw functionality
    /// @param depositAmount Amount to deposit
    /// @param withdrawFraction Percentage to withdraw (1-100)
    function _testFuzzEmergencyWithdraw(uint256 depositAmount, uint256 withdrawFraction) internal virtual {
        depositAmount = bound(depositAmount, _minDeposit(), _maxDeposit());
        withdrawFraction = bound(withdrawFraction, 1, 100);

        // Ensure user has enough balance
        if (ERC20(_asset()).balanceOf(user) < depositAmount) {
            airdrop(ERC20(_asset()), user, depositAmount);
        }

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        IERC4626(address(vault)).deposit(depositAmount, user);
        vm.stopPrank();

        uint256 emergencyWithdrawAmount = (depositAmount * withdrawFraction) / 100;
        vm.assume(emergencyWithdrawAmount > 0);

        vm.startPrank(emergencyAdmin);
        vault.shutdownStrategy();
        vault.emergencyWithdraw(emergencyWithdrawAmount);
        vm.stopPrank();

        // User should still be able to withdraw
        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        uint256 assetsReceived = vault.redeem(userShares, user, user);
        vm.stopPrank();

        assertGt(assetsReceived, 0, "User should receive some assets");
    }
}
