// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { YearnV3Strategy } from "src/strategies/yieldDonating/YearnV3Strategy.sol";
import { YearnV3StrategyFactory } from "src/factories/yieldDonating/YearnV3StrategyFactory.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";
import { IMockStrategy } from "test/mocks/zodiac-core/IMockStrategy.sol";
import { BaseYieldDonatingIntegrationTest } from "./base/BaseYieldDonatingIntegrationTest.sol";
import { YearnV3TestConfig } from "../config/YearnV3TestConfig.sol";

/// @title YearnV3 Yield Donating Test
/// @author [Golem Foundation](https://golem.foundation)
/// @notice Integration tests for the yield donating YearnV3 strategy using a mainnet fork
contract YearnV3DonatingStrategyTest is BaseYieldDonatingIntegrationTest {
    // ========== STATE VARIABLES ==========

    YearnV3Strategy public strategy;
    YearnV3StrategyFactory public factory;

    // ========== CONFIGURATION OVERRIDES ==========

    function _asset() internal pure override returns (address) {
        return YearnV3TestConfig.USDC;
    }

    function _strategyName() internal pure override returns (string memory) {
        return YearnV3TestConfig.STRATEGY_NAME;
    }

    function _strategySymbol() internal pure override returns (string memory) {
        return YearnV3TestConfig.STRATEGY_SYMBOL;
    }

    function _initialDeposit() internal pure override returns (uint256) {
        return YearnV3TestConfig.INITIAL_DEPOSIT;
    }

    function _compounderVault() internal pure override returns (address) {
        return YearnV3TestConfig.YEARN_V3_USDC_VAULT;
    }

    function _minDeposit() internal pure override returns (uint256) {
        return YearnV3TestConfig.MIN_DEPOSIT;
    }

    function _maxDeposit() internal pure override returns (uint256) {
        return YearnV3TestConfig.MAX_DEPOSIT;
    }

    function _decimals() internal pure override returns (uint8) {
        return YearnV3TestConfig.DECIMALS;
    }

    // ========== SETUP ==========

    function _etchImplementation() internal override {
        implementation = new YieldDonatingTokenizedStrategy{ salt: keccak256("OCT_YIELD_DONATING_STRATEGY_V1") }();
        bytes memory tokenizedStrategyBytecode = address(implementation).code;
        vm.etch(YearnV3TestConfig.TOKENIZED_STRATEGY_ADDRESS, tokenizedStrategyBytecode);
    }

    function _deployStrategy() internal override returns (address) {
        _etchImplementation();

        factory = new YearnV3StrategyFactory{ salt: keccak256("OCT_YEARN_V3_COMPOUNDER_STRATEGY_VAULT_FACTORY_V1") }();

        address strategyAddress = factory.createStrategy(
            _compounderVault(),
            _asset(),
            _strategyName(),
            _strategySymbol(),
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // enableBurning
            address(implementation)
        );

        strategy = YearnV3Strategy(strategyAddress);
        return strategyAddress;
    }

    function _labelAddresses() internal override {
        vm.label(address(strategy), "YearnV3Donating");
        vm.label(address(factory), "YearnV3StrategyFactory");
        vm.label(YearnV3TestConfig.YEARN_V3_USDC_VAULT, "Yearn V3 USDC Vault");
        vm.label(YearnV3TestConfig.USDC, "USDC");
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

    function testInitializationYearn() public view {
        _testInitialization();
        assertEq(strategy.yearnVault(), YearnV3TestConfig.YEARN_V3_USDC_VAULT, "Yearn vault incorrect");
        // Check health check is enabled by default
        assertTrue(strategy.doHealthCheck(), "Health check should be enabled by default");
        assertEq(strategy.profitLimitRatio(), 10_000, "Default profit limit should be 100%");
        assertEq(strategy.lossLimitRatio(), 0, "Default loss limit should be 0%");
    }

    function testFuzzDepositYearn(uint256 depositAmount) public {
        _testFuzzDeposit(depositAmount);

        // Verify funds were deployed to Yearn vault
        uint256 yearnShares = ITokenizedStrategy(_compounderVault()).balanceOf(address(strategy));
        assertGt(yearnShares, 0, "No shares in Yearn vault after deposit");
    }

    function testFuzzWithdrawYearn(uint256 depositAmount, uint256 withdrawFraction) public {
        _testFuzzWithdraw(depositAmount, withdrawFraction);
    }

    // ========== YEARN-SPECIFIC TESTS ==========

    /// @notice Fuzz test the harvesting functionality with profit donation
    function testFuzzHarvestWithProfitDonationYearn(uint256 depositAmount, uint256 profitAmount) public {
        depositAmount = bound(depositAmount, _minDeposit(), _maxDeposit());
        profitAmount = bound(profitAmount, 1e5, depositAmount / 2);

        if (ERC20(_asset()).balanceOf(user) < depositAmount) {
            airdrop(ERC20(_asset()), user, depositAmount);
        }

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        IERC4626(address(vault)).deposit(depositAmount, user);
        vm.stopPrank();

        uint256 totalAssetsBefore = IERC4626(address(vault)).totalAssets();
        uint256 userSharesBefore = IERC4626(address(vault)).balanceOf(user);
        uint256 donationBalanceBefore = ERC20(address(vault)).balanceOf(donationAddress);

        // Mock Yearn vault to return profit
        uint256 balanceOfYearnVault = ITokenizedStrategy(_compounderVault()).balanceOf(address(strategy));
        vm.mockCall(
            _compounderVault(),
            abi.encodeWithSelector(IERC4626.convertToAssets.selector, balanceOfYearnVault),
            abi.encode(depositAmount + profitAmount)
        );

        vm.startPrank(keeper);
        (uint256 profit, uint256 loss) = IMockStrategy(address(strategy)).report();
        vm.stopPrank();

        vm.clearMockedCalls();

        // Airdrop profit to the strategy to simulate actual yield
        airdrop(ERC20(_asset()), address(strategy), profitAmount);

        assertEq(profit, profitAmount, "Should have captured correct profit");
        assertEq(loss, 0, "Should have no loss");

        // User shares should remain the same (no dilution)
        assertEq(IERC4626(address(vault)).balanceOf(user), userSharesBefore, "User shares should not change");

        // Donation address should have received the profit
        uint256 donationBalanceAfter = ERC20(address(vault)).balanceOf(donationAddress);
        assertGt(donationBalanceAfter, donationBalanceBefore, "Donation address should receive profit");

        // Total assets should increase by the profit amount
        assertGt(IERC4626(address(vault)).totalAssets(), totalAssetsBefore, "Total assets should increase");
    }

    /// @notice Test available deposit limit without idle assets
    function testAvailableDepositLimitWithoutIdleAssetsYearn() public view {
        uint256 limit = strategy.availableDepositLimit(user);
        uint256 yearnLimit = ITokenizedStrategy(_compounderVault()).maxDeposit(address(strategy));
        uint256 idleBalance = ERC20(_asset()).balanceOf(address(strategy));

        assertEq(idleBalance, 0, "Strategy should have no idle assets initially");
        assertEq(limit, yearnLimit, "Available deposit limit should match Yearn vault limit when no idle assets");
    }

    /// @notice Test available deposit limit with idle assets
    function testAvailableDepositLimitWithIdleAssetsYearn() public {
        uint256 idleAmount = 1000e6; // 1,000 USDC idle assets

        airdrop(ERC20(_asset()), address(strategy), idleAmount);

        uint256 limit = strategy.availableDepositLimit(user);
        uint256 yearnLimit = ITokenizedStrategy(_compounderVault()).maxDeposit(address(strategy));
        uint256 idleBalance = ERC20(_asset()).balanceOf(address(strategy));

        assertEq(idleBalance, idleAmount, "Strategy should have idle assets");

        uint256 expectedLimit = yearnLimit > idleAmount ? yearnLimit - idleAmount : 0;
        assertEq(limit, expectedLimit, "Available deposit limit should account for idle assets");
        assertLt(limit, yearnLimit, "Available deposit limit should be less than yearn limit when idle assets exist");
    }

    /// @notice Fuzz test emergency withdraw functionality
    function testFuzzEmergencyWithdrawYearn(uint256 depositAmount, uint256 withdrawFraction) public {
        depositAmount = bound(depositAmount, _minDeposit(), _maxDeposit());
        withdrawFraction = bound(withdrawFraction, 1, 100);

        if (ERC20(_asset()).balanceOf(user) < depositAmount) {
            airdrop(ERC20(_asset()), user, depositAmount);
        }

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        IERC4626(address(vault)).deposit(depositAmount, user);
        vm.stopPrank();

        uint256 emergencyWithdrawAmount = (depositAmount * withdrawFraction) / 100;
        vm.assume(emergencyWithdrawAmount > 0);

        uint256 maxWithdrawableFromYearn = ITokenizedStrategy(_compounderVault()).maxWithdraw(address(strategy));
        if (emergencyWithdrawAmount > maxWithdrawableFromYearn) {
            emergencyWithdrawAmount = maxWithdrawableFromYearn;
        }

        uint256 initialYearnShares = ITokenizedStrategy(_compounderVault()).balanceOf(address(strategy));

        vm.startPrank(emergencyAdmin);
        IMockStrategy(address(strategy)).shutdownStrategy();
        IMockStrategy(address(strategy)).emergencyWithdraw(emergencyWithdrawAmount);
        vm.stopPrank();

        uint256 finalYearnShares = ITokenizedStrategy(_compounderVault()).balanceOf(address(strategy));
        assertLe(finalYearnShares, initialYearnShares, "Should have withdrawn from Yearn vault");

        if (emergencyWithdrawAmount < depositAmount) {
            assertGt(ERC20(_asset()).balanceOf(address(strategy)), 0, "Strategy should have idle USDC");
        }
    }

    /// @notice Test health check functionality
    function testHealthCheckProfitLimitYearn() public {
        uint256 depositAmount = 10000e6;

        airdrop(ERC20(_asset()), user, depositAmount);

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        IERC4626(address(vault)).deposit(depositAmount, user);
        vm.stopPrank();

        vm.prank(management);
        strategy.setProfitLimitRatio(1000); // 10%

        uint256 balanceOfYearnVault = ITokenizedStrategy(_compounderVault()).balanceOf(address(strategy));
        uint256 excessiveProfit = (depositAmount * 20) / 100; // 20% profit
        vm.mockCall(
            _compounderVault(),
            abi.encodeWithSelector(IERC4626.convertToAssets.selector, balanceOfYearnVault),
            abi.encode(depositAmount + excessiveProfit)
        );

        vm.expectRevert("healthCheck");
        vm.prank(keeper);
        IMockStrategy(address(strategy)).report();

        vm.clearMockedCalls();
    }

    /// @notice Test health check functionality for losses
    function testHealthCheckLossLimitYearn() public {
        uint256 depositAmount = 10000e6;

        airdrop(ERC20(_asset()), user, depositAmount);

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        IERC4626(address(vault)).deposit(depositAmount, user);
        vm.stopPrank();

        vm.prank(management);
        strategy.setLossLimitRatio(500); // 5%

        uint256 balanceOfYearnVault = ITokenizedStrategy(_compounderVault()).balanceOf(address(strategy));
        uint256 loss = (depositAmount * 10) / 100; // 10% loss
        vm.mockCall(
            _compounderVault(),
            abi.encodeWithSelector(IERC4626.convertToAssets.selector, balanceOfYearnVault),
            abi.encode(depositAmount - loss)
        );

        vm.expectRevert("healthCheck");
        vm.prank(keeper);
        IMockStrategy(address(strategy)).report();

        vm.clearMockedCalls();
    }

    /// @notice Test disabling health check
    function testDisableHealthCheckYearn() public {
        uint256 depositAmount = 10000e6;

        airdrop(ERC20(_asset()), user, depositAmount);

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        IERC4626(address(vault)).deposit(depositAmount, user);
        vm.stopPrank();

        vm.startPrank(management);
        strategy.setProfitLimitRatio(100); // 1%
        strategy.setLossLimitRatio(100); // 1%
        strategy.setDoHealthCheck(false);
        vm.stopPrank();

        uint256 balanceOfYearnVault = ITokenizedStrategy(_compounderVault()).balanceOf(address(strategy));
        uint256 excessiveProfit = (depositAmount * 50) / 100; // 50% profit
        vm.mockCall(
            _compounderVault(),
            abi.encodeWithSelector(IERC4626.convertToAssets.selector, balanceOfYearnVault),
            abi.encode(depositAmount + excessiveProfit)
        );

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = IMockStrategy(address(strategy)).report();

        assertEq(profit, excessiveProfit, "Should report excessive profit when health check disabled");
        assertEq(loss, 0, "Should have no loss");

        assertTrue(strategy.doHealthCheck(), "Health check should be re-enabled after report");

        vm.clearMockedCalls();
    }

    /// @notice Test harvest and report includes idle funds
    function testHarvestAndReportIncludesIdleFundsYearn() public {
        uint256 depositAmount = 10000e6;
        uint256 vaultProfit = 500e6;
        uint256 idleProfit = 300e6;

        airdrop(ERC20(_asset()), user, depositAmount);

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        IERC4626(address(vault)).deposit(depositAmount, user);
        vm.stopPrank();

        uint256 yearnSharesBefore = ITokenizedStrategy(_compounderVault()).balanceOf(address(strategy));

        vm.mockCall(
            _compounderVault(),
            abi.encodeWithSelector(IERC4626.convertToAssets.selector, yearnSharesBefore),
            abi.encode(depositAmount + vaultProfit)
        );

        airdrop(ERC20(_asset()), address(strategy), idleProfit);

        uint256 donationBalanceBefore = ERC20(address(vault)).balanceOf(donationAddress);

        vm.prank(keeper);
        (uint256 reportedProfit, uint256 loss) = IMockStrategy(address(strategy)).report();

        vm.clearMockedCalls();

        uint256 totalProfit = vaultProfit + idleProfit;
        assertEq(reportedProfit, totalProfit, "Reported profit should include both vault and idle profits");
        assertEq(loss, 0, "Should have no loss");

        uint256 donationBalanceAfter = ERC20(address(vault)).balanceOf(donationAddress);
        assertEq(donationBalanceAfter - donationBalanceBefore, totalProfit, "Donation should equal total profit");
    }

    /// @notice Test constructor validates asset compatibility
    function testConstructorAssetValidationYearn() public {
        vm.expectRevert();
        new YearnV3Strategy(
            _compounderVault(),
            address(0x123), // Wrong asset
            _strategyName(),
            _strategySymbol(),
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false,
            address(implementation)
        );
    }

    /// @notice Fuzz test multiple users deposits and withdrawals
    function testFuzzMultipleUsersDepositsAndWithdrawalsYearn(
        uint256 depositAmount1,
        uint256 depositAmount2,
        bool shouldUser1Withdraw,
        bool shouldUser2Withdraw
    ) public {
        depositAmount1 = bound(depositAmount1, _minDeposit(), _maxDeposit() / 2);
        depositAmount2 = bound(depositAmount2, _minDeposit(), _maxDeposit() / 2);

        address user2 = address(0x5678);

        if (ERC20(_asset()).balanceOf(user) < depositAmount1) {
            airdrop(ERC20(_asset()), user, depositAmount1);
        }
        airdrop(ERC20(_asset()), user2, depositAmount2);

        vm.startPrank(user2);
        ERC20(_asset()).approve(address(strategy), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user);
        uint256 shares1 = IERC4626(address(strategy)).deposit(depositAmount1, user);
        vm.stopPrank();

        vm.startPrank(user2);
        uint256 shares2 = IERC4626(address(strategy)).deposit(depositAmount2, user2);
        vm.stopPrank();

        assertEq(
            IERC4626(address(strategy)).totalAssets(),
            depositAmount1 + depositAmount2,
            "Total assets should equal deposits"
        );

        // Add some profit to test fair distribution (but keep it reasonable to avoid health check issues)
        uint256 profit = 1000e6;
        uint256 totalDeposits = depositAmount1 + depositAmount2;

        if (profit <= totalDeposits) {
            airdrop(ERC20(_asset()), address(strategy), profit);

            vm.prank(keeper);
            IMockStrategy(address(strategy)).report();
        }

        if (shouldUser1Withdraw && shares1 > 0) {
            vm.startPrank(user);
            uint256 maxRedeemable1 = IERC4626(address(strategy)).maxRedeem(user);
            uint256 sharesToRedeem1 = shares1 > maxRedeemable1 ? maxRedeemable1 : shares1;
            if (sharesToRedeem1 > 0) {
                uint256 assets1 = IERC4626(address(strategy)).redeem(sharesToRedeem1, user, user);
                assertEq(assets1, sharesToRedeem1, "User1 should receive some assets");
            }
            vm.stopPrank();
        }

        if (shouldUser2Withdraw && shares2 > 0) {
            vm.startPrank(user2);
            uint256 maxRedeemable2 = IERC4626(address(strategy)).maxRedeem(user2);
            uint256 sharesToRedeem2 = shares2 > maxRedeemable2 ? maxRedeemable2 : shares2;
            if (sharesToRedeem2 > 0) {
                uint256 assets2 = IERC4626(address(strategy)).redeem(sharesToRedeem2, user2, user2);
                assertEq(assets2, sharesToRedeem2, "User2 should receive some assets");
            }
            vm.stopPrank();
        }

        if (shouldUser1Withdraw && shouldUser2Withdraw) {
            assertLt(
                IERC4626(address(strategy)).totalAssets(),
                1000e6,
                "Strategy should be nearly empty after all withdrawals"
            );
        }
    }

    /// @notice Test the available withdraw limit
    function testAvailableWithdrawLimitYearn() public {
        uint256 depositAmount = 10000e6;

        airdrop(ERC20(_asset()), user, depositAmount);
        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        IERC4626(address(vault)).deposit(depositAmount, user);
        vm.stopPrank();

        uint256 limit = strategy.availableWithdrawLimit(user);

        assertApproxEqRel(
            limit,
            depositAmount,
            0.001e16,
            "Withdraw limit should be approximately equal to deposited amount"
        );

        uint256 idleBalance = ERC20(_asset()).balanceOf(address(strategy));
        uint256 yearnMaxWithdraw = ITokenizedStrategy(_compounderVault()).maxWithdraw(address(strategy));
        assertEq(limit, idleBalance + yearnMaxWithdraw, "Withdraw limit should equal idle + Yearn withdrawable");
    }

    /// @notice Fuzz test redeem functionality
    function testFuzzRedeemYearn(uint256 depositAmount, uint256 redeemFraction) public {
        depositAmount = bound(depositAmount, _minDeposit(), _maxDeposit());
        redeemFraction = bound(redeemFraction, 1, 100);

        if (ERC20(_asset()).balanceOf(user) < depositAmount) {
            airdrop(ERC20(_asset()), user, depositAmount);
        }

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        uint256 shares = IERC4626(address(vault)).deposit(depositAmount, user);

        uint256 sharesToRedeem = (shares * redeemFraction) / 100;
        vm.assume(sharesToRedeem > 0);

        uint256 maxRedeemable = IERC4626(address(vault)).maxRedeem(user);
        if (sharesToRedeem > maxRedeemable) {
            sharesToRedeem = maxRedeemable;
        }
        vm.assume(sharesToRedeem > 0);

        uint256 initialUserBalance = ERC20(_asset()).balanceOf(user);
        uint256 initialShareBalance = IERC4626(address(vault)).balanceOf(user);

        uint256 assetsReceived = IERC4626(address(vault)).redeem(sharesToRedeem, user, user);
        vm.stopPrank();

        assertGt(assetsReceived, 0, "Should receive assets from redemption");
        assertEq(
            IERC4626(address(vault)).balanceOf(user),
            initialShareBalance - sharesToRedeem,
            "Share balance should decrease by redeemed amount"
        );
        assertEq(
            ERC20(_asset()).balanceOf(user),
            initialUserBalance + assetsReceived,
            "User should receive redeemed assets"
        );
    }

    // ===== LOSS SCENARIO TESTS =====

    /// @notice Test basic loss reporting when Yearn vault loses value
    function testBasicLossReportingYearn() public {
        uint256 depositAmount = 10000e6;
        uint256 lossAmount = 1000e6;

        airdrop(ERC20(_asset()), user, depositAmount);

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        IERC4626(address(vault)).deposit(depositAmount, user);
        vm.stopPrank();

        vm.prank(management);
        strategy.setLossLimitRatio(1000); // 10%

        uint256 totalAssetsBefore = IERC4626(address(vault)).totalAssets();
        uint256 yearnSharesBefore = ITokenizedStrategy(_compounderVault()).balanceOf(address(strategy));

        vm.mockCall(
            _compounderVault(),
            abi.encodeWithSelector(IERC4626.convertToAssets.selector, yearnSharesBefore),
            abi.encode(depositAmount - lossAmount)
        );

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = IMockStrategy(address(strategy)).report();

        vm.clearMockedCalls();

        assertEq(profit, 0, "Should have no profit");
        assertEq(loss, lossAmount, "Should report correct loss amount");

        uint256 totalAssetsAfter = IERC4626(address(vault)).totalAssets();
        assertEq(totalAssetsAfter, totalAssetsBefore - lossAmount, "Total assets should decrease by loss amount");
    }

    /// @notice Test withdrawals after losses - users should receive less than deposited
    function testWithdrawalAfterLossesYearn() public {
        uint256 depositAmount = 10000e6;
        uint256 lossPercentage = 20;

        airdrop(ERC20(_asset()), user, depositAmount);

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        uint256 shares = IERC4626(address(vault)).deposit(depositAmount, user);
        vm.stopPrank();

        vm.prank(management);
        strategy.setLossLimitRatio(2000); // 20%

        uint256 lossAmount = (depositAmount * lossPercentage) / 100;
        uint256 remainingValue = depositAmount - lossAmount;

        uint256 yearnShares = ITokenizedStrategy(_compounderVault()).balanceOf(address(strategy));
        vm.mockCall(
            _compounderVault(),
            abi.encodeWithSelector(IERC4626.convertToAssets.selector, yearnShares),
            abi.encode(remainingValue)
        );

        vm.prank(keeper);
        IMockStrategy(address(strategy)).report();

        vm.clearMockedCalls();

        vm.startPrank(user);
        uint256 assetsReceived = IERC4626(address(vault)).redeem(shares, user, user);
        vm.stopPrank();

        assertLt(assetsReceived, depositAmount, "User should receive less than deposited");
        assertApproxEqRel(
            assetsReceived,
            remainingValue,
            0.001e16,
            "User should receive proportional share after loss"
        );
    }

    /// @notice Test multiple users experiencing losses - fair distribution
    function testMultipleUsersWithLossesYearn() public {
        uint256 depositAmount1 = 6000e6;
        uint256 depositAmount2 = 4000e6;
        uint256 totalDeposits = depositAmount1 + depositAmount2;
        uint256 lossPercentage = 15;

        address user2 = address(0x5678);

        airdrop(ERC20(_asset()), user, depositAmount1);
        airdrop(ERC20(_asset()), user2, depositAmount2);

        vm.prank(user2);
        ERC20(_asset()).approve(address(strategy), type(uint256).max);

        vm.prank(user);
        uint256 shares1 = IERC4626(address(strategy)).deposit(depositAmount1, user);

        vm.prank(user2);
        uint256 shares2 = IERC4626(address(strategy)).deposit(depositAmount2, user2);

        vm.prank(management);
        strategy.setLossLimitRatio(1500); // 15%

        uint256 totalLoss = (totalDeposits * lossPercentage) / 100;
        uint256 remainingValue = totalDeposits - totalLoss;

        uint256 yearnShares = ITokenizedStrategy(_compounderVault()).balanceOf(address(strategy));
        vm.mockCall(
            _compounderVault(),
            abi.encodeWithSelector(IERC4626.convertToAssets.selector, yearnShares),
            abi.encode(remainingValue)
        );

        vm.prank(keeper);
        IMockStrategy(address(strategy)).report();

        vm.clearMockedCalls();

        vm.prank(user);
        uint256 assets1 = IERC4626(address(strategy)).redeem(shares1, user, user);

        vm.prank(user2);
        uint256 assets2 = IERC4626(address(strategy)).redeem(shares2, user2, user2);

        uint256 expectedAssets1 = depositAmount1 - (depositAmount1 * lossPercentage) / 100;
        uint256 expectedAssets2 = depositAmount2 - (depositAmount2 * lossPercentage) / 100;

        assertApproxEqRel(assets1, expectedAssets1, 0.01e18, "User1 should receive proportional share after loss");
        assertApproxEqRel(assets2, expectedAssets2, 0.01e18, "User2 should receive proportional share after loss");

        assertApproxEqRel(
            assets1 + assets2,
            remainingValue,
            0.01e18,
            "Total withdrawn should equal remaining value after loss"
        );
    }

    /// @notice Test harvest with losses - verify no donation occurs
    function testHarvestWithLossesNoDonationYearn() public {
        uint256 depositAmount = 10000e6;
        uint256 lossAmount = 500e6;

        airdrop(ERC20(_asset()), user, depositAmount);

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        IERC4626(address(vault)).deposit(depositAmount, user);
        vm.stopPrank();

        vm.prank(management);
        strategy.setLossLimitRatio(500); // 5%

        uint256 donationBalanceBefore = ERC20(address(vault)).balanceOf(donationAddress);

        uint256 yearnShares = ITokenizedStrategy(_compounderVault()).balanceOf(address(strategy));
        vm.mockCall(
            _compounderVault(),
            abi.encodeWithSelector(IERC4626.convertToAssets.selector, yearnShares),
            abi.encode(depositAmount - lossAmount)
        );

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = IMockStrategy(address(strategy)).report();

        vm.clearMockedCalls();

        assertEq(profit, 0, "Should have no profit");
        assertEq(loss, lossAmount, "Should report loss");

        uint256 donationBalanceAfter = ERC20(address(vault)).balanceOf(donationAddress);
        assertEq(donationBalanceAfter, donationBalanceBefore, "Donation address balance should not change on loss");
    }

    /// @notice Fuzz test for partial loss scenarios
    function testFuzzPartialLossYearn(uint256 depositAmount, uint256 lossPercentage) public {
        depositAmount = bound(depositAmount, _minDeposit(), _maxDeposit());
        lossPercentage = bound(lossPercentage, 1, 50);

        airdrop(ERC20(_asset()), user, depositAmount);

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        uint256 shares = IERC4626(address(vault)).deposit(depositAmount, user);
        vm.stopPrank();

        vm.prank(management);
        strategy.setLossLimitRatio(5000); // 50%

        uint256 lossAmount = (depositAmount * lossPercentage) / 100;
        uint256 remainingValue = depositAmount - lossAmount;

        uint256 yearnShares = ITokenizedStrategy(_compounderVault()).balanceOf(address(strategy));
        vm.mockCall(
            _compounderVault(),
            abi.encodeWithSelector(IERC4626.convertToAssets.selector, yearnShares),
            abi.encode(remainingValue)
        );

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = IMockStrategy(address(strategy)).report();

        vm.clearMockedCalls();

        assertEq(profit, 0, "Should have no profit");
        assertEq(loss, lossAmount, "Should report correct loss");

        uint256 assetsPerShare = IERC4626(address(vault)).convertToAssets(1e18);
        uint256 expectedAssetsPerShare = (1e18 * remainingValue) / depositAmount;
        assertApproxEqRel(
            assetsPerShare,
            expectedAssetsPerShare,
            0.01e18,
            "Assets per share should decrease proportionally"
        );

        vm.prank(user);
        uint256 withdrawnAssets = IERC4626(address(vault)).redeem(shares, user, user);
        assertApproxEqRel(withdrawnAssets, remainingValue, 0.01e18, "User should be able to withdraw remaining value");
    }

    /// @notice Test that _freeFunds uses maxLoss=10_000 (100%) to handle insufficient funds
    function testFreeFundsMaxLossParameterYearn() public {
        uint256 depositAmount = 30000e6;

        airdrop(ERC20(_asset()), user, depositAmount);
        vm.prank(user);
        IERC4626(address(strategy)).deposit(depositAmount, user);

        // Create loss scenario by draining most funds from Yearn vault
        uint256 yearnBalance = ERC20(_asset()).balanceOf(_compounderVault());
        if (yearnBalance > 0) {
            vm.prank(_compounderVault());
            ERC20(_asset()).transfer(address(0xdead), yearnBalance);
        }

        uint256 mockedMaxWithdraw = 8000e6;
        uint256 actualAvailable = 5000e6;

        airdrop(ERC20(_asset()), _compounderVault(), actualAvailable);

        vm.mockCall(
            _compounderVault(),
            abi.encodeWithSelector(ITokenizedStrategy.maxWithdraw.selector, address(strategy)),
            abi.encode(mockedMaxWithdraw)
        );

        vm.mockCall(
            _compounderVault(),
            abi.encodeWithSignature(
                "withdraw(uint256,address,address,uint256)",
                mockedMaxWithdraw,
                address(strategy),
                address(strategy),
                10000
            ),
            abi.encode(actualAvailable)
        );

        airdrop(ERC20(_asset()), address(strategy), actualAvailable);

        vm.prank(user);
        uint256 received = YieldDonatingTokenizedStrategy(address(strategy)).withdraw(
            mockedMaxWithdraw,
            user,
            user,
            10_000
        );

        vm.clearMockedCalls();

        assertGt(received, 0, "Should receive some amount");
        assertTrue(received > 0, "Transaction succeeded - maxLoss behavior is possible");
    }
}
