// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { AaveV3Strategy } from "src/strategies/yieldDonating/AaveV3Strategy.sol";
import { AaveV3StrategyFactory } from "src/factories/AaveV3StrategyFactory.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { IMockStrategy } from "test/mocks/zodiac-core/IMockStrategy.sol";
import { BaseYieldDonatingIntegrationTest } from "./base/BaseYieldDonatingIntegrationTest.sol";
import { AaveV3TestConfig } from "../config/AaveV3TestConfig.sol";

interface IPoolDataProvider {
    function getReserveCaps(address asset) external view returns (uint256 borrowCap, uint256 supplyCap);
    function getATokenTotalSupply(address asset) external view returns (uint256);
}

/// @title AaveV3 Yield Donating Test
/// @author Octant
/// @notice Integration tests for the yield donating AaveV3 strategy using a mainnet fork
contract AaveV3DonatingStrategyTest is BaseYieldDonatingIntegrationTest {
    // ========== STATE VARIABLES ==========

    AaveV3Strategy public strategy;
    AaveV3StrategyFactory public factory;

    // ========== CONFIGURATION OVERRIDES ==========

    function _asset() internal pure override returns (address) {
        return AaveV3TestConfig.USDC;
    }

    function _strategyName() internal pure override returns (string memory) {
        return AaveV3TestConfig.STRATEGY_NAME;
    }

    function _strategySymbol() internal pure override returns (string memory) {
        return AaveV3TestConfig.STRATEGY_SYMBOL;
    }

    function _initialDeposit() internal pure override returns (uint256) {
        return AaveV3TestConfig.INITIAL_DEPOSIT;
    }

    /// @notice For Aave, returns the aToken address (used for mocking profit)
    function _compounderVault() internal pure override returns (address) {
        return AaveV3TestConfig.AUSDC_V3;
    }

    function _minDeposit() internal pure override returns (uint256) {
        return AaveV3TestConfig.MIN_DEPOSIT;
    }

    function _maxDeposit() internal pure override returns (uint256) {
        return AaveV3TestConfig.MAX_DEPOSIT;
    }

    function _decimals() internal pure override returns (uint8) {
        return AaveV3TestConfig.DECIMALS;
    }

    // ========== SETUP ==========

    function _etchImplementation() internal override {
        implementation = new YieldDonatingTokenizedStrategy{ salt: keccak256("OCT_YIELD_DONATING_STRATEGY_V1") }();
        bytes memory tokenizedStrategyBytecode = address(implementation).code;
        vm.etch(AaveV3TestConfig.TOKENIZED_STRATEGY_ADDRESS, tokenizedStrategyBytecode);
    }

    function _deployStrategy() internal override returns (address) {
        _etchImplementation();

        factory = new AaveV3StrategyFactory{ salt: keccak256("OCT_AAVE_V3_STRATEGY_VAULT_FACTORY_V1") }();

        vm.startPrank(management);
        address strategyAddress = factory.createStrategy(
            _strategyName(),
            _strategySymbol(),
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // enableBurning
            address(implementation)
        );
        vm.stopPrank();

        strategy = AaveV3Strategy(strategyAddress);
        return strategyAddress;
    }

    function _labelAddresses() internal override {
        vm.label(address(strategy), "AaveV3Donating");
        vm.label(address(factory), "AaveV3StrategyFactory");
        vm.label(AaveV3TestConfig.AAVE_POOL, "Aave V3 Pool");
        vm.label(AaveV3TestConfig.AUSDC_V3, "aUSDC V3");
        vm.label(AaveV3TestConfig.USDC, "USDC");
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

    function testInitializationAave() public view {
        _testInitialization();
        // Aave-specific initialization checks
        assertEq(strategy.aToken(), AaveV3TestConfig.AUSDC_V3, "aToken should be aUSDC V3");
    }

    function testFuzzDepositAave(uint256 depositAmount) public {
        _testFuzzDeposit(depositAmount);

        // Aave-specific: verify funds were deployed to Aave
        assertEq(ERC20(_asset()).balanceOf(address(strategy)), 0, "Strategy should not hold USDC");
        assertGt(ERC20(AaveV3TestConfig.AUSDC_V3).balanceOf(address(strategy)), 0, "Strategy should hold aUSDC");
    }

    function testFuzzWithdrawAave(uint256 depositAmount, uint256 withdrawFraction) public {
        _testFuzzWithdraw(depositAmount, withdrawFraction);
    }

    // ========== AAVE-SPECIFIC TESTS ==========

    /// @notice Override harvest with profit test for Aave-specific mechanics
    function _testHarvestWithProfit(uint256 depositAmount, uint256 profitAmount) internal override {
        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 userSharesBefore = vault.balanceOf(user);
        uint256 donationBalanceBefore = ERC20(address(vault)).balanceOf(donationAddress);

        // For Aave, simulate profit by mocking the aToken balanceOf
        vm.mockCall(
            AaveV3TestConfig.AUSDC_V3,
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(strategy)),
            abi.encode(depositAmount + profitAmount)
        );

        vm.startPrank(keeper);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();

        vm.clearMockedCalls();

        assertGt(profit, 0, "Should have captured profit from yield");
        assertEq(loss, 0, "Should have no loss");

        // User shares should remain the same (profit is donated)
        assertEq(vault.balanceOf(user), userSharesBefore, "User shares should not change");

        // Donation address should have received the profit
        uint256 donationBalanceAfter = ERC20(address(vault)).balanceOf(donationAddress);
        assertGt(donationBalanceAfter, donationBalanceBefore, "Donation address should receive profit");

        // Total assets should increase
        assertGe(vault.totalAssets(), totalAssetsBefore, "Total assets should increase");
    }

    /// @notice Fuzz test the harvesting functionality with profit donation
    function testFuzzHarvestWithProfitDonationAave(uint256 depositAmount, uint256 profitAmount) public {
        depositAmount = bound(depositAmount, _minDeposit(), _maxDeposit());
        profitAmount = bound(profitAmount, 1e5, depositAmount / 10);

        // Ensure user has enough balance
        if (ERC20(_asset()).balanceOf(user) < depositAmount) {
            airdrop(ERC20(_asset()), user, depositAmount);
        }

        _testHarvestWithProfit(depositAmount, profitAmount);
    }

    /// @notice Test available deposit limit checks supply cap
    function testAvailableDepositLimitWithSupplyCap() public view {
        IPoolDataProvider dataProvider = IPoolDataProvider(AaveV3TestConfig.AAVE_DATA_PROVIDER);
        (, uint256 supplyCap) = dataProvider.getReserveCaps(_asset());

        if (supplyCap == 0) {
            uint256 limit = strategy.availableDepositLimit(user);
            assertEq(limit, type(uint256).max, "Should return max uint256 when no supply cap");
        } else {
            uint256 totalSupply = dataProvider.getATokenTotalSupply(_asset());
            uint256 supplyCapScaled = supplyCap * 10 ** _decimals();

            uint256 limit = strategy.availableDepositLimit(user);

            if (supplyCapScaled > totalSupply) {
                uint256 expectedLimit = supplyCapScaled - totalSupply;
                assertEq(limit, expectedLimit, "Limit should be cap minus current supply");
            } else {
                assertEq(limit, 0, "Limit should be 0 when cap is reached");
            }
        }
    }

    /// @notice Test available deposit limit with idle assets
    function testAvailableDepositLimitWithIdleAssets() public {
        uint256 idleAmount = 1000e6;

        airdrop(ERC20(_asset()), address(strategy), idleAmount);

        uint256 limit = strategy.availableDepositLimit(user);
        uint256 idleBalance = ERC20(_asset()).balanceOf(address(strategy));

        assertEq(idleBalance, idleAmount, "Strategy should have idle assets");

        IPoolDataProvider dataProvider = IPoolDataProvider(AaveV3TestConfig.AAVE_DATA_PROVIDER);
        (, uint256 supplyCap) = dataProvider.getReserveCaps(_asset());

        if (supplyCap == 0) {
            assertEq(limit, type(uint256).max, "Should return max uint256 when no supply cap");
        } else {
            uint256 totalSupply = dataProvider.getATokenTotalSupply(_asset());
            uint256 supplyCapScaled = supplyCap * 10 ** _decimals();

            if (supplyCapScaled > totalSupply) {
                uint256 availableCapacity = supplyCapScaled - totalSupply;
                uint256 expectedLimit = availableCapacity > idleAmount ? availableCapacity - idleAmount : 0;
                assertEq(limit, expectedLimit, "Available deposit limit should account for idle assets");
            }
        }
    }

    /// @notice Fuzz test emergency withdraw functionality
    function testFuzzEmergencyWithdrawAave(uint256 depositAmount, uint256 withdrawFraction) public {
        depositAmount = bound(depositAmount, _minDeposit(), _maxDeposit());
        withdrawFraction = bound(withdrawFraction, 1, 100);

        if (ERC20(_asset()).balanceOf(user) < depositAmount) {
            airdrop(ERC20(_asset()), user, depositAmount);
        }

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        IERC4626(address(vault)).deposit(depositAmount, user);
        vm.stopPrank();

        uint256 availableBalance = strategy.availableWithdrawLimit(address(this));
        uint256 emergencyWithdrawAmount = (availableBalance * withdrawFraction) / 100;
        vm.assume(emergencyWithdrawAmount > 0);

        uint256 initialATokenBalance = ERC20(AaveV3TestConfig.AUSDC_V3).balanceOf(address(strategy));

        vm.startPrank(emergencyAdmin);
        IMockStrategy(address(strategy)).shutdownStrategy();
        IMockStrategy(address(strategy)).emergencyWithdraw(emergencyWithdrawAmount);
        vm.stopPrank();

        uint256 finalATokenBalance = ERC20(AaveV3TestConfig.AUSDC_V3).balanceOf(address(strategy));
        assertApproxEqAbs(
            finalATokenBalance,
            initialATokenBalance - emergencyWithdrawAmount,
            2,
            "Should have withdrawn from Aave pool"
        );
        assertEq(
            ERC20(_asset()).balanceOf(address(strategy)),
            emergencyWithdrawAmount,
            "Strategy should have idle USDC"
        );
    }

    /// @notice Test that _harvestAndReport returns correct total assets
    function testFuzzHarvestAndReportViewAave(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, _minDeposit(), _maxDeposit());

        if (ERC20(_asset()).balanceOf(user) < depositAmount) {
            airdrop(ERC20(_asset()), user, depositAmount);
        }

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        IERC4626(address(vault)).deposit(depositAmount, user);
        vm.stopPrank();

        uint256 totalAssets = IERC4626(address(vault)).totalAssets();
        uint256 aTokenBalance = ERC20(AaveV3TestConfig.AUSDC_V3).balanceOf(address(strategy));
        uint256 idleAssets = ERC20(_asset()).balanceOf(address(strategy));

        // aTokens are 1:1 with underlying USDC
        assertApproxEqRel(
            totalAssets,
            aTokenBalance + idleAssets,
            1e14,
            "Total assets should match aToken balance plus idle"
        );
    }

    /// @notice Test that _harvestAndReport includes idle funds and donations work correctly
    function testHarvestAndReportIncludesIdleFundsWithDonationAave() public {
        uint256 depositAmount = 10000e6;
        uint256 aTokenProfit = 500e6;
        uint256 idleProfit = 500e6;
        uint256 totalProfit = aTokenProfit + idleProfit;

        airdrop(ERC20(_asset()), user, depositAmount);

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        IERC4626(address(vault)).deposit(depositAmount, user);
        vm.stopPrank();

        uint256 initialTotalAssets = IERC4626(address(vault)).totalAssets();

        // Simulate aToken profit by mocking the balanceOf call
        vm.mockCall(
            AaveV3TestConfig.AUSDC_V3,
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(strategy)),
            abi.encode(depositAmount + aTokenProfit)
        );

        airdrop(ERC20(_asset()), address(strategy), idleProfit);

        uint256 donationBalanceBefore = ERC20(address(vault)).balanceOf(donationAddress);

        vm.prank(keeper);
        (uint256 reportedProfit, uint256 loss) = IMockStrategy(address(strategy)).report();

        vm.clearMockedCalls();

        assertEq(reportedProfit, totalProfit, "Reported profit should include both aToken and idle profits");
        assertEq(loss, 0, "Should have no loss");

        uint256 donationBalanceAfter = ERC20(address(vault)).balanceOf(donationAddress);
        assertGt(donationBalanceAfter, donationBalanceBefore, "Donation address should receive profit");
        assertEq(
            donationBalanceAfter - donationBalanceBefore,
            totalProfit,
            "Donation should equal the total profit (aToken + idle)"
        );

        uint256 finalTotalAssets = IERC4626(address(vault)).totalAssets();
        assertApproxEqRel(
            finalTotalAssets - initialTotalAssets,
            totalProfit,
            1e14,
            "Total assets should increase by total profit"
        );
    }

    /// @notice Test that constructor validates asset is supported by Aave pool
    function testConstructorAssetValidation() public {
        // Aave data provider reverts when querying unsupported assets
        vm.expectRevert();
        new AaveV3Strategy(
            AaveV3TestConfig.AAVE_ADDRESSES_PROVIDER,
            address(0x123), // Unsupported asset
            _strategyName(),
            _strategySymbol(),
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            true,
            address(implementation)
        );
    }

    /// @notice Fuzz test multiple deposits and withdrawals
    function testFuzzMultipleDepositsAndWithdrawalsAave(
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
        IERC4626(address(strategy)).deposit(depositAmount1, user);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC4626(address(strategy)).deposit(depositAmount2, user2);
        vm.stopPrank();

        assertEq(
            IERC4626(address(strategy)).totalAssets(),
            depositAmount1 + depositAmount2,
            "Total assets should equal deposits"
        );

        if (shouldUser1Withdraw) {
            vm.startPrank(user);
            IERC4626(address(strategy)).redeem(IERC4626(address(strategy)).balanceOf(user), user, user);
            vm.stopPrank();
        }

        if (shouldUser2Withdraw) {
            vm.startPrank(user2);
            uint256 maxRedeem = IERC4626(address(strategy)).maxRedeem(user2);
            IMockStrategy(address(strategy)).redeem(maxRedeem, user2, user2, 10);
            vm.stopPrank();
        }

        if (shouldUser1Withdraw && shouldUser2Withdraw) {
            assertLt(
                IERC4626(address(strategy)).totalAssets(),
                10,
                "Strategy should be nearly empty after all withdrawals"
            );
        }
    }

    /// @notice Test interaction with actual Aave V3 pool
    function testAaveV3PoolIntegration() public {
        uint256 depositAmount = 50000e6;

        airdrop(ERC20(_asset()), user, depositAmount);

        vm.startPrank(user);
        ERC20(_asset()).approve(address(strategy), depositAmount);
        uint256 shares = IERC4626(address(strategy)).deposit(depositAmount, user);
        vm.stopPrank();

        assertGt(shares, 0, "User should receive shares");
        assertEq(ERC20(_asset()).balanceOf(address(strategy)), 0, "Strategy should have no idle USDC");
        assertGt(ERC20(AaveV3TestConfig.AUSDC_V3).balanceOf(address(strategy)), 0, "Strategy should have aUSDC");

        // Simulate time passing for interest accrual
        vm.roll(block.number + 1000);
        vm.warp(block.timestamp + 30 days);

        uint256 donationSharesBefore = IERC4626(address(strategy)).balanceOf(donationAddress);

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = IMockStrategy(address(strategy)).report();

        assertGe(profit, 0, "Should have non-negative profit");
        assertEq(loss, 0, "Should have no loss");

        if (profit > 0) {
            uint256 donationSharesAfter = IERC4626(address(strategy)).balanceOf(donationAddress);
            assertGt(donationSharesAfter, donationSharesBefore, "Donation address should receive profit shares");
        }

        vm.startPrank(user);
        uint256 assetsWithdrawn = IERC4626(address(strategy)).redeem(shares, user, user);
        vm.stopPrank();

        assertGe(assetsWithdrawn, (depositAmount * 99) / 100, "User should receive at least 99% of deposit");
    }

    /// @notice Test that available withdraw limit returns correct value
    function testAvailableWithdrawLimit() public {
        uint256 depositAmount = 10000e6;

        uint256 initialLimit = strategy.availableWithdrawLimit(user);
        assertEq(initialLimit, 0, "Initial withdraw limit should be 0");

        airdrop(ERC20(_asset()), user, depositAmount);
        vm.startPrank(user);
        IERC4626(address(strategy)).deposit(depositAmount, user);
        vm.stopPrank();

        uint256 limitAfterDeposit = strategy.availableWithdrawLimit(user);
        uint256 aTokenBalance = ERC20(AaveV3TestConfig.AUSDC_V3).balanceOf(address(strategy));
        assertEq(limitAfterDeposit, aTokenBalance, "Withdraw limit should equal aToken balance");

        uint256 idleAmount = 1000e6;
        airdrop(ERC20(_asset()), address(strategy), idleAmount);

        uint256 limitWithIdle = strategy.availableWithdrawLimit(user);
        assertEq(limitWithIdle, aTokenBalance + idleAmount, "Withdraw limit should include idle balance");
    }
}
