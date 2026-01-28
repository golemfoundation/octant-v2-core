// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { MorphoCompounderStrategy } from "src/strategies/yieldDonating/MorphoCompounderStrategy.sol";
import { MorphoCompounderStrategyFactory } from "src/factories/MorphoCompounderStrategyFactory.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { IMockStrategy } from "test/mocks/zodiac-core/IMockStrategy.sol";
import { BaseYieldDonatingIntegrationTest } from "./base/BaseYieldDonatingIntegrationTest.sol";
import { MorphoTestConfig } from "../config/MorphoTestConfig.sol";

/// @title MorphoCompounder Yield Donating Test
/// @author Octant
/// @notice Integration tests for the yield donating MorphoCompounder strategy using a mainnet fork
contract MorphoCompounderDonatingStrategyTest is BaseYieldDonatingIntegrationTest {
    // ========== STATE VARIABLES ==========

    MorphoCompounderStrategy public strategy;
    MorphoCompounderStrategyFactory public factory;

    // ========== CONFIGURATION OVERRIDES ==========

    function _asset() internal pure override returns (address) {
        return MorphoTestConfig.USDC;
    }

    function _strategyName() internal pure override returns (string memory) {
        return MorphoTestConfig.STRATEGY_NAME;
    }

    function _strategySymbol() internal pure override returns (string memory) {
        return MorphoTestConfig.STRATEGY_SYMBOL;
    }

    function _initialDeposit() internal pure override returns (uint256) {
        return MorphoTestConfig.INITIAL_DEPOSIT;
    }

    function _compounderVault() internal pure override returns (address) {
        return MorphoTestConfig.MORPHO_VAULT;
    }

    function _minDeposit() internal pure override returns (uint256) {
        return MorphoTestConfig.MIN_DEPOSIT;
    }

    function _maxDeposit() internal pure override returns (uint256) {
        return MorphoTestConfig.MAX_DEPOSIT;
    }

    function _decimals() internal pure override returns (uint8) {
        return MorphoTestConfig.DECIMALS;
    }

    // ========== SETUP ==========

    function _etchImplementation() internal override {
        implementation = new YieldDonatingTokenizedStrategy{ salt: keccak256("OCT_YIELD_SKIMMING_STRATEGY_V1") }();
        bytes memory tokenizedStrategyBytecode = address(implementation).code;
        vm.etch(MorphoTestConfig.TOKENIZED_STRATEGY_ADDRESS, tokenizedStrategyBytecode);
    }

    function _deployStrategy() internal override returns (address) {
        _etchImplementation();

        factory = new MorphoCompounderStrategyFactory{
            salt: keccak256("OCT_MORPHO_COMPOUNDER_STRATEGY_VAULT_FACTORY_V1")
        }();

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

        strategy = MorphoCompounderStrategy(strategyAddress);
        return strategyAddress;
    }

    function _labelAddresses() internal override {
        vm.label(address(strategy), "MorphoCompounderDonating");
        vm.label(address(factory), "MorphoCompounderStrategyFactory");
        vm.label(MorphoTestConfig.MORPHO_VAULT, "Morpho Vault");
        vm.label(MorphoTestConfig.USDC, "USDC");
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

    function testInitializationMorpho() public view {
        _testInitialization();
    }

    function testFuzzDepositMorpho(uint256 depositAmount) public {
        _testFuzzDeposit(depositAmount);
    }

    function testFuzzWithdrawMorpho(uint256 depositAmount, uint256 withdrawFraction) public {
        _testFuzzWithdraw(depositAmount, withdrawFraction);
    }

    // ========== MORPHO-SPECIFIC TESTS ==========

    /// @notice Fuzz test the harvesting functionality with profit donation
    function testFuzzHarvestWithProfitDonationMorpho(uint256 depositAmount, uint256 profitAmount) public {
        depositAmount = bound(depositAmount, _minDeposit(), _maxDeposit());
        profitAmount = bound(profitAmount, 1e5, depositAmount);

        // Ensure user has enough balance
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

        // Mock profit by mocking Morpho vault return value
        uint256 balanceOfMorphoVault = IERC4626(_compounderVault()).balanceOf(address(strategy));
        vm.mockCall(
            address(IERC4626(_compounderVault())),
            abi.encodeWithSelector(IERC4626.convertToAssets.selector, balanceOfMorphoVault),
            abi.encode(depositAmount + profitAmount)
        );

        vm.startPrank(keeper);
        (uint256 profit, uint256 loss) = IMockStrategy(address(strategy)).report();
        vm.stopPrank();

        vm.clearMockedCalls();

        // Airdrop profit to simulate the actual profit
        airdrop(ERC20(_asset()), address(strategy), profitAmount);

        assertGt(profit, 0, "Should have captured profit from yield");
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
    function testAvailableDepositLimitWithoutIdleAssets() public view {
        uint256 limit = strategy.availableDepositLimit(user);
        uint256 morphoLimit = IERC4626(_compounderVault()).maxDeposit(address(strategy));
        uint256 idleBalance = ERC20(_asset()).balanceOf(address(strategy));

        assertEq(idleBalance, 0, "Strategy should have no idle assets initially");
        assertEq(limit, morphoLimit, "Available deposit limit should match Morpho vault limit when no idle assets");
    }

    /// @notice Test available deposit limit with idle assets (TRST-M-8 fix)
    function testAvailableDepositLimitWithIdleAssets() public {
        uint256 idleAmount = 1000e6; // 1,000 USDC idle assets

        // Airdrop idle assets to strategy to simulate undeployed funds
        airdrop(ERC20(_asset()), address(strategy), idleAmount);

        uint256 limit = strategy.availableDepositLimit(user);
        uint256 morphoLimit = IERC4626(_compounderVault()).maxDeposit(address(strategy));
        uint256 idleBalance = ERC20(_asset()).balanceOf(address(strategy));

        assertEq(idleBalance, idleAmount, "Strategy should have idle assets");

        uint256 expectedLimit = morphoLimit > idleAmount ? morphoLimit - idleAmount : 0;
        assertEq(limit, expectedLimit, "Available deposit limit should account for idle assets");
        assertLt(limit, morphoLimit, "Available deposit limit should be less than morpho limit when idle assets exist");
    }

    /// @notice Test available deposit limit edge case where idle assets exceed morpho limit
    function testAvailableDepositLimitIdleAssetsExceedMorphoLimit() public {
        uint256 morphoLimit = IERC4626(_compounderVault()).maxDeposit(address(strategy));

        vm.assume(morphoLimit < type(uint256).max / 2);

        uint256 excessIdleAmount = morphoLimit + 1000e6;
        airdrop(ERC20(_asset()), address(strategy), excessIdleAmount);

        uint256 limit = strategy.availableDepositLimit(user);
        uint256 idleBalance = ERC20(_asset()).balanceOf(address(strategy));

        assertEq(idleBalance, excessIdleAmount, "Strategy should have excess idle assets");
        assertGt(idleBalance, morphoLimit, "Idle assets should exceed morpho limit");
        assertEq(limit, 0, "Available deposit limit should be 0 when idle assets exceed morpho limit");
    }

    /// @notice Fuzz test emergency withdraw functionality
    function testFuzzEmergencyWithdrawMorpho(uint256 depositAmount, uint256 withdrawFraction) public {
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

        uint256 maxWithdrawableFromMorpho = IERC4626(_compounderVault()).maxWithdraw(address(strategy));
        if (emergencyWithdrawAmount > maxWithdrawableFromMorpho) {
            emergencyWithdrawAmount = maxWithdrawableFromMorpho;
        }

        uint256 initialMorphoShares = IERC4626(_compounderVault()).balanceOf(address(strategy));

        vm.startPrank(emergencyAdmin);
        IMockStrategy(address(strategy)).shutdownStrategy();
        IMockStrategy(address(strategy)).emergencyWithdraw(emergencyWithdrawAmount);
        vm.stopPrank();

        uint256 finalMorphoShares = IERC4626(_compounderVault()).balanceOf(address(strategy));
        assertLe(finalMorphoShares, initialMorphoShares, "Should have withdrawn from Morpho vault or stayed same");

        if (emergencyWithdrawAmount < depositAmount) {
            assertGt(ERC20(_asset()).balanceOf(address(strategy)), 0, "Strategy should have idle USDC");
        }
    }

    /// @notice Test emergency withdraw works even when maxWithdraw returns less than requested
    function testEmergencyWithdrawBypassesMaxWithdraw() public {
        uint256 depositAmount = 100000e6;

        airdrop(ERC20(_asset()), user, depositAmount);

        vm.startPrank(user);
        ERC20(_asset()).approve(address(strategy), depositAmount);
        IERC4626(address(strategy)).deposit(depositAmount, user);
        vm.stopPrank();

        uint256 strategySharesInMorpho = IERC4626(_compounderVault()).balanceOf(address(strategy));
        uint256 strategyAssetsInMorpho = IERC4626(_compounderVault()).convertToAssets(strategySharesInMorpho);

        uint256 emergencyWithdrawAmount = strategyAssetsInMorpho;

        vm.startPrank(emergencyAdmin);
        IMockStrategy(address(strategy)).shutdownStrategy();
        IMockStrategy(address(strategy)).emergencyWithdraw(emergencyWithdrawAmount);
        vm.stopPrank();

        uint256 finalSharesInMorpho = IERC4626(_compounderVault()).balanceOf(address(strategy));
        assertEq(finalSharesInMorpho, 0, "Should have withdrawn all shares from Morpho");

        uint256 strategyUSDCBalance = ERC20(_asset()).balanceOf(address(strategy));
        assertGe(
            strategyUSDCBalance,
            (depositAmount * 99) / 100,
            "Strategy should have received at least 99% of deposited USDC"
        );
    }

    /// @notice Fuzz test that _harvestAndReport returns correct total assets
    function testFuzzHarvestAndReportView(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, _minDeposit(), _maxDeposit());

        if (ERC20(_asset()).balanceOf(user) < depositAmount) {
            airdrop(ERC20(_asset()), user, depositAmount);
        }

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        IERC4626(address(vault)).deposit(depositAmount, user);
        vm.stopPrank();

        uint256 totalAssets = IERC4626(address(vault)).totalAssets();
        uint256 morphoShares = IERC4626(_compounderVault()).balanceOf(address(strategy));
        uint256 morphoAssets = IERC4626(_compounderVault()).convertToAssets(morphoShares);
        uint256 idleAssets = ERC20(_asset()).balanceOf(address(strategy));

        assertApproxEqRel(
            totalAssets,
            morphoAssets + idleAssets,
            1e14,
            "Total assets should match Morpho assets plus idle"
        );
    }

    /// @notice Test that _harvestAndReport includes idle funds and donations work correctly
    function testHarvestAndReportIncludesIdleFundsWithDonation() public {
        uint256 depositAmount = 10000e6;
        uint256 vaultProfit = 500e6;
        uint256 idleProfit = 500e6;
        uint256 totalProfit = vaultProfit + idleProfit;

        airdrop(ERC20(_asset()), user, depositAmount);

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        IERC4626(address(vault)).deposit(depositAmount, user);
        vm.stopPrank();

        uint256 initialTotalAssets = IERC4626(address(vault)).totalAssets();
        uint256 morphoSharesBefore = IERC4626(_compounderVault()).balanceOf(address(strategy));

        vm.mockCall(
            address(_compounderVault()),
            abi.encodeWithSelector(IERC4626.convertToAssets.selector, morphoSharesBefore),
            abi.encode(depositAmount + vaultProfit)
        );

        airdrop(ERC20(_asset()), address(strategy), idleProfit);

        uint256 donationBalanceBefore = ERC20(address(vault)).balanceOf(donationAddress);

        vm.prank(keeper);
        (uint256 reportedProfit, uint256 loss) = IMockStrategy(address(strategy)).report();

        vm.clearMockedCalls();

        assertEq(reportedProfit, totalProfit, "Reported profit should include both vault and idle profits");
        assertEq(loss, 0, "Should have no loss");

        uint256 donationBalanceAfter = ERC20(address(vault)).balanceOf(donationAddress);
        assertGt(donationBalanceAfter, donationBalanceBefore, "Donation address should receive profit");
        assertEq(
            donationBalanceAfter - donationBalanceBefore,
            totalProfit,
            "Donation should equal the total profit (vault + idle)"
        );

        uint256 finalTotalAssets = IERC4626(address(vault)).totalAssets();
        assertApproxEqRel(
            finalTotalAssets - initialTotalAssets,
            totalProfit,
            1e14,
            "Total assets should increase by total profit"
        );
    }

    /// @notice Test that constructor validates asset compatibility
    function testConstructorAssetValidation() public {
        vm.expectRevert();
        new MorphoCompounderStrategy(
            _compounderVault(),
            address(0x123), // Wrong asset
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
    function testFuzzMultipleDepositsAndWithdrawals(
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

    /// @notice Test that triggers "too much loss" by removing idle funds and mocking withdraw
    function testLossDoesNotTriggerTooMuchLossError() public {
        uint256 depositAmount = 100000e6;
        address morphoBlueVault = MorphoTestConfig.MORPHO_BLUE_VAULT;

        vm.startPrank(user);
        uint256 vaultShares = IERC4626(address(strategy)).deposit(depositAmount, user);
        vm.stopPrank();

        assertEq(ERC20(_asset()).balanceOf(user), 0, "User should have no USDC");

        uint256 yearnIdleBalance = ERC20(_asset()).balanceOf(_compounderVault());

        if (yearnIdleBalance > 0) {
            vm.startPrank(_compounderVault());
            ERC20(_asset()).transfer(address(0xdead), yearnIdleBalance);
            vm.stopPrank();
        }

        assertEq(ERC20(_asset()).balanceOf(_compounderVault()), 0, "Yearn vault should have no idle funds");

        vm.startPrank(morphoBlueVault);
        ERC20(_asset()).transfer(address(0xdead), ERC20(_asset()).balanceOf(morphoBlueVault));
        vm.stopPrank();

        assertEq(ERC20(_asset()).balanceOf(morphoBlueVault), 0, "Morpho blue vault should have no idle funds");

        airdrop(ERC20(_asset()), _compounderVault(), depositAmount / 10);

        vm.mockCall(_compounderVault(), abi.encodeWithSignature("freeFunds(uint256)"), "");

        vm.startPrank(user);
        YieldDonatingTokenizedStrategy(address(strategy)).redeem(vaultShares - 2, user, user, 10_000);
        vm.stopPrank();

        vm.clearMockedCalls();

        assertEq(ERC20(_asset()).balanceOf(user), depositAmount / 10, "User should have received balance");
    }
}
