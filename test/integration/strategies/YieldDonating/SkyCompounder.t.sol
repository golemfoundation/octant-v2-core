// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SkyCompounderStrategy } from "src/strategies/yieldDonating/SkyCompounderStrategy.sol";
import { SkyCompounderStrategyFactory } from "src/factories/SkyCompounderStrategyFactory.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { BaseYieldDonatingIntegrationTest } from "./base/BaseYieldDonatingIntegrationTest.sol";
import { SkyCompounderTestConfig } from "../config/SkyCompounderTestConfig.sol";

/// @title SkyCompounder Test
/// @author mil0x
/// @notice Unit tests for the SkyCompounder strategy using a mainnet fork
contract SkyCompounderTest is BaseYieldDonatingIntegrationTest {
    // ========== STATE VARIABLES ==========

    SkyCompounderStrategy public strategy;
    SkyCompounderStrategyFactory public factory;

    // Donation recipient for transfer tests
    address public donationRecipient = address(0x5678);

    // ========== CONFIGURATION OVERRIDES ==========

    function _asset() internal pure override returns (address) {
        return SkyCompounderTestConfig.USDS;
    }

    function _strategyName() internal pure override returns (string memory) {
        return SkyCompounderTestConfig.STRATEGY_NAME;
    }

    function _strategySymbol() internal pure override returns (string memory) {
        return SkyCompounderTestConfig.STRATEGY_SYMBOL;
    }

    function _initialDeposit() internal pure override returns (uint256) {
        return SkyCompounderTestConfig.INITIAL_DEPOSIT;
    }

    function _compounderVault() internal pure override returns (address) {
        return SkyCompounderTestConfig.STAKING;
    }

    function _minDeposit() internal pure override returns (uint256) {
        return SkyCompounderTestConfig.MIN_DEPOSIT;
    }

    function _maxDeposit() internal pure override returns (uint256) {
        return SkyCompounderTestConfig.MAX_DEPOSIT;
    }

    function _decimals() internal pure override returns (uint8) {
        return SkyCompounderTestConfig.DECIMALS;
    }

    // ========== SETUP ==========

    function _setupFork() internal override {
        mainnetFork = vm.createFork("mainnet", SkyCompounderTestConfig.FORK_BLOCK);
        vm.selectFork(mainnetFork);
    }

    function _etchImplementation() internal override {
        implementation = new YieldDonatingTokenizedStrategy{ salt: keccak256("OCT_YIELD_DONATING_STRATEGY_V1") }();
    }

    function _deployStrategy() internal override returns (address) {
        _etchImplementation();

        factory = new SkyCompounderStrategyFactory();

        vm.startPrank(management);
        address strategyAddress = factory.createStrategy(
            _strategyName(),
            _strategySymbol(),
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            true, // enableBurning
            address(implementation)
        );
        vm.stopPrank();

        strategy = SkyCompounderStrategy(strategyAddress);
        return strategyAddress;
    }

    function _labelAddresses() internal override {
        vm.label(address(strategy), "SkyCompounder");
        vm.label(address(factory), "SkyCompounderStrategyFactory");
        vm.label(SkyCompounderTestConfig.USDS, "USDS Token");
        vm.label(SkyCompounderTestConfig.STAKING, "Sky Staking");
        vm.label(SkyCompounderTestConfig.WETH, "WETH");
        vm.label(management, "Management");
        vm.label(keeper, "Keeper");
        vm.label(emergencyAdmin, "Emergency Admin");
        vm.label(donationAddress, "Donation Address");
        vm.label(user, "Test User");
    }

    function setUp() public {
        _baseSetUp();
    }

    // ========== TESTS - Delegating to base implementations ==========

    function testInitializationSky() public view {
        _testInitialization();
        assertEq(strategy.staking(), SkyCompounderTestConfig.STAKING, "Staking address incorrect");
        assertEq(strategy.claimRewards(), true, "Claim rewards should default to true");
        assertEq(strategy.useUniV3(), false, "Use UniV3 should default to false");

        // Verify that the strategy was recorded in the factory
        (address deployerAddress, , string memory name, address stratDonationAddress) = factory.strategies(
            management,
            0
        );
        assertEq(deployerAddress, management, "Deployer address incorrect in factory");
        assertEq(name, _strategyName(), "Vault shares name incorrect in factory");
        assertEq(stratDonationAddress, donationAddress, "Donation address incorrect in factory");
    }

    function testDepositSky() public {
        _testDeposit(100e18);
        assertEq(strategy.balanceOfStake(), 100e18, "Staking balance not increased correctly");
    }

    function testWithdrawSky() public {
        _testWithdraw(100e18);
    }

    function testMultipleUserProfitDistributionSky() public {
        _testMultipleUserProfitDistribution();
    }

    function testEmergencyExitSky() public {
        _testEmergencyExit(5000e18);
    }

    // ========== SKY-SPECIFIC TESTS ==========

    /// @notice Test the harvesting functionality using explicit profit simulation
    function testHarvestWithProfitSky() public {
        uint256 depositAmount = 100e18;
        uint256 profitAmount = 10e18;

        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        uint256 totalAssetsBefore = vault.totalAssets();

        skip(1 days);
        vm.roll(block.number + 6500);

        airdrop(ERC20(_asset()), address(strategy), profitAmount);

        vm.startPrank(keeper);
        vm.expectEmit(true, true, true, true);
        emit Reported(profitAmount, 0);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();

        assertGe(profit, profitAmount, "Profit should be at least the airdropped amount");
        assertEq(loss, 0, "There should be no loss");

        uint256 totalAssetsAfter = vault.totalAssets();
        assertGe(totalAssetsAfter, totalAssetsBefore + profitAmount, "Total assets should include profit");

        skip(365 days);

        vm.startPrank(user);
        uint256 sharesToRedeem = vault.balanceOf(user);
        uint256 assetsReceived = vault.redeem(sharesToRedeem, user, user);
        vm.stopPrank();

        assertEq(assetsReceived, depositAmount, "User should only receive original deposit");
        assertEq(vault.balanceOf(donationAddress), profitAmount, "Donation address should receive profit in shares");
    }

    /// @notice Test the harvesting functionality
    function testHarvestSky() public {
        _testHarvest(100e18);
    }

    /// @notice Test profit cycle with UniswapV3 for swapping rewards when reward amount > minAmountToSell
    function testUniswapV3WithProfitCycleAboveMinAmount() public {
        uint256 depositAmount = 100e18;
        address rewardsToken = strategy.rewardsToken();
        uint256 rewardAmount = 50e18;

        vm.startPrank(management);
        strategy.setUseUniV3andFees(true, 3000, 500);
        vm.stopPrank();

        assertTrue(strategy.useUniV3(), "UniV3 should be enabled");
        assertEq(strategy.minAmountToSell(), 50e18, "Min amount should be set correctly");

        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        assertEq(strategy.balanceOfStake(), depositAmount, "Deposit should be staked");

        skip(30 days);
        vm.roll(block.number + 6500 * 30);

        deal(rewardsToken, address(strategy), rewardAmount);

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 rewardsBalanceBefore = ERC20(rewardsToken).balanceOf(address(strategy));

        vm.startPrank(management);
        strategy.setClaimRewards(false);
        assertEq(strategy.balanceOfRewards(), rewardAmount, "Rewards should be in the strategy");
        vm.stopPrank();

        vm.startPrank(keeper);
        vm.expectEmit(true, true, true, true);
        emit Reported(0, 0);
        vault.report();
        vm.stopPrank();

        uint256 rewardsBalanceAfter = ERC20(rewardsToken).balanceOf(address(strategy));
        assertEq(rewardsBalanceAfter, rewardsBalanceBefore, "Rewards should not have been claimed or swapped");

        uint256 totalAssetsAfter = vault.totalAssets();
        assertApproxEqRel(totalAssetsAfter, totalAssetsBefore, 0.01e18, "Total assets should remain similar");

        skip(365 days);

        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        uint256 assetsReceived = vault.redeem(userShares, user, user);
        vm.stopPrank();

        assertApproxEqRel(assetsReceived, depositAmount, 0.05e18, "User should receive approximately original deposit");
    }

    /// @notice Test profit cycle with UniswapV3 for swapping rewards when reward amount < minAmountToSell
    function testUniswapV3WithProfitCycleBelowMinAmount() public {
        uint256 depositAmount = 100e18;
        address rewardsToken = strategy.rewardsToken();
        uint256 rewardAmount = 1e18;
        uint256 minAmount = 5e18;

        vm.startPrank(management);
        strategy.setUseUniV3andFees(true, 3000, 500);
        strategy.setMinAmountToSell(minAmount);
        vm.stopPrank();

        assertTrue(strategy.useUniV3(), "UniV3 should be enabled");
        assertEq(strategy.minAmountToSell(), minAmount, "Min amount should be set correctly");

        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        assertEq(strategy.balanceOfStake(), depositAmount, "Deposit should be staked");

        skip(30 days);
        vm.roll(block.number + 6500 * 30);

        deal(rewardsToken, address(strategy), rewardAmount);

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 rewardsBalanceBefore = ERC20(rewardsToken).balanceOf(address(strategy));

        vm.startPrank(management);
        strategy.setClaimRewards(false);
        assertEq(strategy.balanceOfRewards(), rewardAmount, "Rewards should be in the strategy");
        vm.stopPrank();

        vm.startPrank(keeper);
        vm.expectEmit(true, true, true, true);
        emit Reported(0, 0);
        vault.report();
        vm.stopPrank();

        uint256 rewardsBalanceAfter = ERC20(rewardsToken).balanceOf(address(strategy));
        assertEq(rewardsBalanceAfter, rewardsBalanceBefore, "Rewards should not have been swapped");

        uint256 totalAssetsAfter = vault.totalAssets();
        assertApproxEqRel(totalAssetsAfter, totalAssetsBefore, 0.01e18, "Total assets should remain similar");

        skip(365 days);

        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        uint256 assetsReceived = vault.redeem(userShares, user, user);
        vm.stopPrank();

        assertApproxEqRel(assetsReceived, depositAmount, 0.05e18, "User should receive approximately original deposit");
    }

    /// @notice Test that report emits the Reported event with correct parameters
    function testReportEventSky() public {
        uint256 depositAmount = 100e18;

        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        skip(1 days);
        vm.roll(block.number + 6500);

        vm.startPrank(keeper);
        vm.expectEmit(true, true, true, true);
        emit Reported(0, 0);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();

        assertTrue(profit > 0 || loss > 0 || (profit == 0 && loss == 0), "Either profit or loss should be reported");
    }

    /// @notice Test management functions
    function testManagementFunctions() public {
        vm.startPrank(management);
        strategy.setClaimRewards(false);
        vm.stopPrank();
        assertEq(strategy.claimRewards(), false, "claimRewards not updated correctly");

        vm.startPrank(management);
        strategy.setUseUniV3andFees(true, 3000, 500);
        vm.stopPrank();
        assertEq(strategy.useUniV3(), true, "useUniV3 not updated correctly");

        uint256 newMinAmount = 100e18;
        vm.startPrank(management);
        strategy.setMinAmountToSell(newMinAmount);
        vm.stopPrank();
        assertEq(strategy.minAmountToSell(), newMinAmount, "minAmountToSell not updated correctly");

        uint16 newReferral = 12345;
        vm.startPrank(management);
        strategy.setReferral(newReferral);
        vm.stopPrank();
        assertEq(strategy.referral(), newReferral, "referral not updated correctly");
    }

    /// @notice Test profit cycle with UniswapV2 for swapping rewards when reward amount > minAmountToSell
    function testUniswapV2WithProfitCycleAboveMinAmount() public {
        uint256 depositAmount = 4500e18;
        address rewardsToken = strategy.rewardsToken();

        vm.startPrank(management);
        strategy.setUseUniV3andFees(false, 3000, 500);
        vm.stopPrank();

        assertFalse(strategy.useUniV3(), "UniV3 should be disabled");
        assertEq(strategy.minAmountToSell(), 50e18, "Min amount should be set correctly");
        assertEq(strategy.claimableRewards(), 0, "no claimable rewards we mock this instead");

        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        assertEq(strategy.balanceOfStake(), depositAmount, "Deposit should be staked");

        skip(30 days);
        vm.roll(block.number + 6500 * 30);

        vm.startPrank(management);
        assertEq(strategy.balanceOfRewards(), 0, "None of the rewards should be in the strategy yet");
        uint256 claimableRewards = strategy.claimableRewards();
        if (claimableRewards < 50e18) {
            deal(strategy.rewardsToken(), address(strategy), 50e18);
        }
        assertGt(
            strategy.claimableRewards() + strategy.balanceOfRewards(),
            50e18,
            "Should have enough rewards to swap"
        );

        uint256 rewardsBalanceBefore = strategy.claimableRewards();
        vm.stopPrank();

        vm.startPrank(keeper);
        vm.expectEmit(true, true, true, false);
        emit Reported(type(uint256).max, 0);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();

        assertGt(profit, 0, "Profit should be greater than 0");
        assertEq(loss, 0, "Loss should be 0");

        uint256 rewardsBalanceAfter = ERC20(rewardsToken).balanceOf(address(strategy));
        assertLt(rewardsBalanceAfter, rewardsBalanceBefore, "Rewards should have been claimed and swapped");

        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        uint256 assetsReceived = vault.redeem(userShares, user, user);
        vm.stopPrank();

        assertApproxEqRel(assetsReceived, depositAmount, 0.05e18, "User should receive approximately original deposit");
    }

    /// @notice Test profit cycle with UniswapV2 and verify profits are minted to donation address
    function testUniswapV2ProfitDonation() public {
        uint256 depositAmount = 5000e18;

        vm.startPrank(management);
        strategy.setUseUniV3andFees(false, 3000, 500);
        assertEq(strategy.minAmountToSell(), 50e18, "Min amount should be set correctly");
        strategy.setMinAmountToSell(0);
        vm.stopPrank();

        assertFalse(strategy.useUniV3(), "UniV3 should be disabled");
        assertEq(strategy.claimableRewards(), 0, "No claimable rewards initially");

        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        assertEq(strategy.balanceOfStake(), depositAmount, "Deposit should be staked");

        skip(45 days);
        vm.roll(block.number + 6500 * 45);

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 donationSharesBefore = vault.balanceOf(donationAddress);

        vm.startPrank(management);
        uint256 claimableRewardsBefore = strategy.claimableRewards();
        if (claimableRewardsBefore < 50e18) {
            deal(strategy.rewardsToken(), address(strategy), 50e18);
        }
        assertGt(
            claimableRewardsBefore + strategy.balanceOfRewards(),
            50e18,
            "Should have accrued enough rewards to swap"
        );
        strategy.setClaimRewards(true);
        vm.stopPrank();

        vm.startPrank(keeper);
        vm.expectEmit(true, true, true, false);
        emit Reported(type(uint256).max, 0);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();

        assertGt(profit, 0, "Profit should be greater than 0");
        assertEq(loss, 0, "Loss should be 0");

        uint256 totalAssetsAfter = vault.totalAssets();
        assertGt(totalAssetsAfter, totalAssetsBefore, "Total assets should increase after report");

        uint256 donationSharesAfter = vault.balanceOf(donationAddress);
        assertGt(donationSharesAfter, donationSharesBefore, "Donation address should receive shares from profit");

        uint256 donationSharesIncrease = donationSharesAfter - donationSharesBefore;
        assertApproxEqRel(donationSharesIncrease, profit, 0.01e18, "Donation shares increase should match profit");

        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        uint256 assetsReceived = vault.redeem(userShares, user, user);
        vm.stopPrank();

        assertApproxEqRel(assetsReceived, depositAmount, 0.05e18, "User should receive approximately original deposit");

        vm.startPrank(donationAddress);
        uint256 donationAssets = vault.redeem(donationSharesAfter, donationAddress, donationAddress);
        vm.stopPrank();

        assertGt(donationAssets, 0, "Donation address should receive assets from profit");
    }

    /// @notice Test donation shares can be transferred to another address
    function testDonationSharesTransfer() public {
        uint256 depositAmount = 5000e18;

        vm.startPrank(management);
        strategy.setUseUniV3andFees(false, 3000, 500);
        vm.stopPrank();

        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        skip(45 days);

        vm.startPrank(management);
        uint256 claimableRewardsBefore = strategy.claimableRewards();
        if (claimableRewardsBefore < 50e18) {
            deal(strategy.rewardsToken(), address(strategy), 50e18);
        }
        assertGt(
            claimableRewardsBefore + strategy.balanceOfRewards(),
            50e18,
            "Should have accrued enough rewards to swap"
        );
        strategy.setClaimRewards(true);
        deal(_asset(), address(vault), 50e18);
        vm.stopPrank();

        vm.startPrank(keeper);
        (uint256 profit, ) = vault.report();
        vm.stopPrank();

        assertGt(profit, 0, "Profit should be greater than 0");

        uint256 donationShares = vault.balanceOf(donationAddress);
        assertEq(donationShares, profit, "Donation address should receive shares equal to profit");

        vm.label(donationRecipient, "Donation Recipient");

        uint256 sharesAmountToTransfer = donationShares / 2;
        vm.startPrank(donationAddress);
        vault.transfer(donationRecipient, sharesAmountToTransfer);
        vm.stopPrank();

        uint256 donationAddressSharesAfterTransfer = vault.balanceOf(donationAddress);
        uint256 recipientShares = vault.balanceOf(donationRecipient);

        assertEq(
            donationAddressSharesAfterTransfer,
            donationShares - sharesAmountToTransfer,
            "Donation address should have correct remaining shares"
        );
        assertEq(recipientShares, sharesAmountToTransfer, "Recipient should have received correct shares amount");

        vm.startPrank(donationRecipient);
        uint256 assetsReceived = vault.redeem(recipientShares, donationRecipient, donationRecipient);
        vm.stopPrank();

        assertGt(assetsReceived, 0, "Recipient should receive assets from redeemed shares");
        assertApproxEqRel(
            assetsReceived,
            profit / 2,
            0.01e18,
            "Recipient should receive approximately half of the profit in assets"
        );

        vm.startPrank(donationAddress);
        uint256 donationAssetsReceived = vault.redeem(
            donationAddressSharesAfterTransfer,
            donationAddress,
            donationAddress
        );
        vm.stopPrank();

        assertGt(donationAssetsReceived, 0, "Donation address should receive assets from remaining shares");
        assertApproxEqRel(
            donationAssetsReceived,
            profit / 2,
            0.01e18,
            "Donation address should receive approximately half of the profit in assets"
        );

        assertApproxEqRel(
            assetsReceived + donationAssetsReceived,
            profit,
            0.01e18,
            "Total assets distributed should match the original profit amount"
        );
    }

    /// @notice Test partial emergency withdrawals withdraws only the requested amount
    function testPartialEmergencyWithdrawal() public {
        uint256 depositAmount = 5000e18;

        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        uint256 stakedBefore = strategy.balanceOfStake();
        assertGt(stakedBefore, 0, "Should have staked funds");

        vm.startPrank(emergencyAdmin);
        vault.shutdownStrategy();

        uint256 withdrawAmount = depositAmount / 2;
        vault.emergencyWithdraw(withdrawAmount);
        vm.stopPrank();

        uint256 stakedAfter = strategy.balanceOfStake();
        uint256 assetsAfter = strategy.balanceOfAsset();

        assertApproxEqRel(
            stakedAfter,
            stakedBefore - withdrawAmount,
            0.01e18,
            "About half the funds should remain staked"
        );
        assertApproxEqRel(assetsAfter, withdrawAmount, 0.01e18, "Strategy should have received the withdrawn amount");

        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        uint256 assetsReceived = vault.redeem(userShares, user, user);
        vm.stopPrank();

        assertApproxEqRel(assetsReceived, depositAmount, 0.01e18, "User should receive approximately original deposit");
    }

    /// @notice Test slippage protection through minAmountToSell threshold
    function testSlippageProtection() public {
        uint256 depositAmount = 1000e18;

        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        address rewardsToken = strategy.rewardsToken();

        vm.startPrank(management);
        uint256 highMinAmount = 100e18;
        strategy.setMinAmountToSell(highMinAmount);
        strategy.setClaimRewards(true);
        strategy.setUseUniV3andFees(false, 0, 0);
        vm.stopPrank();

        uint256 smallRewardAmount = highMinAmount / 2;
        deal(rewardsToken, address(strategy), smallRewardAmount);

        vm.startPrank(keeper);
        vault.report();
        vm.stopPrank();

        uint256 rewardsAfter = ERC20(rewardsToken).balanceOf(address(strategy));
        assertGt(rewardsAfter, 0, "Should still have some rewards");
    }

    /// @notice Test slippage configuration in swapper
    function testSlippageConfiguration() public {
        vm.startPrank(management);

        strategy.setUseUniV3andFees(true, 3000, 500);
        assertTrue(strategy.useUniV3(), "UniV3 should be enabled");

        uint256 newMinAmount = 30e18;
        strategy.setMinAmountToSell(newMinAmount);
        assertEq(strategy.minAmountToSell(), newMinAmount, "Min amount should be updated");

        vm.stopPrank();

        uint256 depositAmount = 1000e18;
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        address rewardsToken = strategy.rewardsToken();
        uint256 smallRewardAmount = newMinAmount - 1e18;
        deal(rewardsToken, address(strategy), smallRewardAmount);

        vm.startPrank(management);
        strategy.setClaimRewards(true);
        vm.stopPrank();

        vm.startPrank(keeper);
        vault.report();
        vm.stopPrank();

        uint256 rewardsAfter = ERC20(rewardsToken).balanceOf(address(strategy));
        assertGt(rewardsAfter, 0, "Rewards should remain unswapped");
    }

    /// @notice Test loss tracking with sufficient dragon router shares for full burning
    function testLossTracking_WithSufficientDragonShares() public {
        uint256 userDeposit = 1000e18;
        uint256 dragonDeposit = 500e18;
        uint256 lossAmount = 200e18;

        vm.startPrank(user);
        vault.deposit(userDeposit, user);
        vm.stopPrank();

        airdrop(ERC20(_asset()), donationAddress, dragonDeposit);
        vm.startPrank(donationAddress);
        ERC20(_asset()).approve(address(strategy), type(uint256).max);
        vault.deposit(dragonDeposit, donationAddress);
        vm.stopPrank();

        uint256 initialDragonShares = vault.balanceOf(donationAddress);

        vm.startPrank(management);
        strategy.setDoHealthCheck(false);
        vm.stopPrank();

        uint256 stakingBalance = strategy.balanceOfStake();
        uint256 newStakingBalance = stakingBalance > lossAmount ? stakingBalance - lossAmount : 0;
        vm.mockCall(
            _compounderVault(),
            abi.encodeWithSelector(ERC20.balanceOf.selector, address(strategy)),
            abi.encode(newStakingBalance)
        );

        vm.startPrank(keeper);
        (, uint256 reportedLoss) = vault.report();
        vm.stopPrank();

        uint256 dragonSharesAfterLoss = vault.balanceOf(donationAddress);
        uint256 sharesBurned = initialDragonShares - dragonSharesAfterLoss;

        assertEq(reportedLoss, lossAmount, "Full loss should be reported");
        assertLt(dragonSharesAfterLoss, initialDragonShares, "Some dragon shares should be burned");
        assertGt(dragonSharesAfterLoss, 0, "Not all dragon shares should be burned");
        assertEq(sharesBurned, lossAmount, "Shares burned should equal loss amount with 1:1 share price");

        // Recovery verification
        uint256 smallProfit = 50e18;
        uint256 currentBalance = stakingBalance - lossAmount;

        airdrop(ERC20(_asset()), _compounderVault(), smallProfit);
        vm.mockCall(
            _compounderVault(),
            abi.encodeWithSelector(ERC20.balanceOf.selector, address(strategy)),
            abi.encode(currentBalance + smallProfit)
        );

        vm.startPrank(keeper);
        vault.report();
        vm.stopPrank();

        assertEq(
            vault.balanceOf(donationAddress),
            dragonSharesAfterLoss + smallProfit,
            "All profit should mint shares"
        );

        uint256 additionalProfit = 100e18;
        airdrop(ERC20(_asset()), _compounderVault(), additionalProfit);
        vm.mockCall(
            _compounderVault(),
            abi.encodeWithSelector(ERC20.balanceOf.selector, address(strategy)),
            abi.encode(currentBalance + smallProfit + additionalProfit)
        );

        vm.startPrank(keeper);
        vault.report();
        vm.stopPrank();

        assertEq(
            vault.balanceOf(donationAddress),
            dragonSharesAfterLoss + smallProfit + additionalProfit,
            "All additional profit should mint shares"
        );
    }

    /// @notice Test that dust assets are properly reported in totalAssets (TRST-L-6)
    function testDustAssetsAreProperlyReported() public {
        uint256 depositAmount = 10000e18;
        uint256 dustAmount = 50;

        airdrop(ERC20(_asset()), user, depositAmount);

        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        assertEq(strategy.balanceOfStake(), depositAmount, "All deposited assets should be staked");
        assertEq(strategy.balanceOfAsset(), 0, "No idle assets initially");

        deal(_asset(), address(strategy), dustAmount);

        assertEq(strategy.balanceOfAsset(), dustAmount, "Dust assets should be present");

        uint256 totalAssetsBefore = vault.totalAssets();

        vm.prank(keeper);
        vault.report();

        uint256 totalAssetsAfter = vault.totalAssets();

        uint256 expectedTotalAssets = strategy.balanceOfStake() + strategy.balanceOfAsset();
        assertEq(totalAssetsAfter, expectedTotalAssets, "Total assets should include dust assets");

        assertGe(
            totalAssetsAfter,
            totalAssetsBefore + dustAmount,
            "Total assets should increase by at least dust amount"
        );

        assertTrue(strategy.balanceOfAsset() < 100, "Dust amount should be below ASSET_DUST threshold");
        assertTrue(
            totalAssetsAfter > strategy.balanceOfStake(),
            "Total assets should be greater than just staked amount"
        );
    }

    /// @notice Test edge case where only dust assets exist in strategy
    function testOnlyDustAssetsReported() public {
        uint256 dustAmount = 99;

        deal(_asset(), address(strategy), dustAmount);

        assertEq(strategy.balanceOfAsset(), dustAmount, "Only dust assets should exist");
        assertEq(strategy.balanceOfStake(), 0, "No staked assets should exist");

        vm.prank(management);
        strategy.setDoHealthCheck(false);

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = vault.report();

        uint256 totalAssets = vault.totalAssets();
        assertEq(totalAssets, dustAmount, "Total assets should equal dust amount");

        assertEq(profit, dustAmount, "Profit should equal dust amount as it's a gain from 0");
        assertEq(loss, 0, "No loss should be reported");
    }
}
