// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { Setup } from "test/unit/strategies/yieldDonating/utils/Setup.sol";

/// @title Cantina Competition September 2025 – Finding 262 Fix
/// @notice Ensures donation events report share amounts instead of asset amounts.
contract Finding262Fix is Setup {
    function testFix_DonationMintedEmitsShareAmount() public {
        uint256 initialDeposit = 100 ether;
        mintAndDepositIntoStrategy(strategy, user, initialDeposit);

        // Realize initial state so the strategy has assets deployed.
        vm.prank(keeper);
        strategy.report();

        // Simulate a loss to skew share price below 1.
        uint256 simulatedLoss = 40 ether;
        yieldSource.simulateLoss(simulatedLoss);
        vm.prank(keeper);
        strategy.report();

        // Add a small profit after the loss.
        uint256 profitAssets = 10 ether;
        asset.mint(address(yieldSource), profitAssets);

        uint256 before = strategy.balanceOf(donationAddress);
        uint256 expectedShares = Math.mulDiv(
            profitAssets,
            strategy.totalSupply(),
            strategy.totalAssets(),
            Math.Rounding.Floor
        );

        vm.expectEmit(true, false, false, true, address(strategy));
        emit YieldDonatingTokenizedStrategy.DonationMinted(donationAddress, expectedShares);
        vm.prank(keeper);
        strategy.report();

        uint256 afterBalance = strategy.balanceOf(donationAddress);
        assertEq(afterBalance - before, expectedShares, "shares minted mismatch");
    }

    function testFix_DonationBurnedEmitsShareAmount() public {
        vm.prank(management);
        strategy.setEnableBurning(true);

        uint256 initialDeposit = 100 ether;
        mintAndDepositIntoStrategy(strategy, user, initialDeposit);

        // Realize initial profit so the dragon router holds shares.
        uint256 initialProfit = 30 ether;
        asset.mint(address(yieldSource), initialProfit);
        vm.prank(keeper);
        strategy.report();

        // Record dragon share balance before loss.
        uint256 before = strategy.balanceOf(donationAddress);

        // Simulate loss that will trigger dragon share burning.
        uint256 lossAssets = 20 ether;
        yieldSource.simulateLoss(lossAssets);

        uint256 totalSupply = strategy.totalSupply();
        uint256 totalAssets = strategy.totalAssets();
        uint256 expectedShares = Math.min(
            Math.mulDiv(lossAssets, totalSupply, totalAssets, Math.Rounding.Ceil),
            before
        );

        vm.expectEmit(true, false, false, true, address(strategy));
        emit YieldDonatingTokenizedStrategy.DonationBurned(donationAddress, expectedShares);
        vm.prank(keeper);
        strategy.report();

        uint256 afterBalance = strategy.balanceOf(donationAddress);
        assertEq(before - afterBalance, expectedShares, "shares burned mismatch");
    }
}
