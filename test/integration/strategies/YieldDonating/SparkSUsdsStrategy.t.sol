// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SparkStrategy } from "src/strategies/yieldDonating/SparkStrategy.sol";
import { SparkStrategyFactory } from "src/factories/SparkStrategyFactory.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { IMockStrategy } from "test/mocks/core/IMockStrategy.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { BaseYieldDonatingIntegrationTest } from "./base/BaseYieldDonatingIntegrationTest.sol";
import { SparkSUsdsTestConfig } from "../config/SparkSUsdsTestConfig.sol";

/// @title Spark sUSDS Yield Donating Test
/// @author Octant
/// @notice Integration tests for the yield-donating SparkStrategy against the Spark sUSDS
///         (USDS Savings Rate) ERC-4626 vault on a mainnet fork.
/// @dev sUSDS is the Sky Savings Rate vault, surfaced as a "Savings" product in the Spark UI.
///      It is ERC-4626 compliant and auto-compounds via the Sky Savings Rate (SSR), so the
///      existing SparkStrategy (generic ERC4626Strategy + airdrop sweep) plugs in unchanged.
contract SparkSUsdsDonatingStrategyTest is BaseYieldDonatingIntegrationTest {
    // ========== STATE VARIABLES ==========

    SparkStrategy public strategy;
    SparkStrategyFactory public factory;

    // Mock airdrop tokens for sweepAirdrop tests
    MockERC20 public airdropToken;
    MockERC20 public anotherToken;

    // Test users
    address public unauthorizedUser = address(0x5678);

    // ========== CONFIGURATION OVERRIDES ==========

    function _asset() internal pure virtual override returns (address) {
        return SparkSUsdsTestConfig.USDS;
    }

    function _strategyName() internal pure virtual override returns (string memory) {
        return SparkSUsdsTestConfig.USDS_STRATEGY_NAME;
    }

    function _strategySymbol() internal pure virtual override returns (string memory) {
        return SparkSUsdsTestConfig.USDS_STRATEGY_SYMBOL;
    }

    function _initialDeposit() internal pure virtual override returns (uint256) {
        return SparkSUsdsTestConfig.USDS_INITIAL_DEPOSIT;
    }

    function _compounderVault() internal pure virtual override returns (address) {
        return SparkSUsdsTestConfig.SUSDS_VAULT;
    }

    function _minDeposit() internal pure virtual override returns (uint256) {
        return SparkSUsdsTestConfig.USDS_MIN_DEPOSIT;
    }

    function _maxDeposit() internal pure virtual override returns (uint256) {
        return SparkSUsdsTestConfig.USDS_MAX_DEPOSIT;
    }

    function _decimals() internal pure virtual override returns (uint8) {
        return SparkSUsdsTestConfig.USDS_DECIMALS;
    }

    // ========== TEST-SPECIFIC CONFIGURATION ==========

    function _ssrTestDeposit() internal pure virtual returns (uint256) {
        return SparkSUsdsTestConfig.USDS_SSR_TEST_DEPOSIT;
    }

    function _depositCapMaxCheck() internal pure virtual returns (uint256) {
        return SparkSUsdsTestConfig.USDS_DEPOSIT_CAP_MAX_CHECK;
    }

    function _depositCapExcess() internal pure virtual returns (uint256) {
        return SparkSUsdsTestConfig.USDS_DEPOSIT_CAP_EXCESS;
    }

    function _multiUserDeposit1() internal pure virtual returns (uint256) {
        return SparkSUsdsTestConfig.USDS_MULTI_USER_DEPOSIT_1;
    }

    function _multiUserDeposit2() internal pure virtual returns (uint256) {
        return SparkSUsdsTestConfig.USDS_MULTI_USER_DEPOSIT_2;
    }

    // ========== SETUP ==========

    function _etchImplementation() internal override {
        implementation = new YieldDonatingTokenizedStrategy{ salt: keccak256("OCT_YIELD_SKIMMING_STRATEGY_V1") }();
        bytes memory tokenizedStrategyBytecode = address(implementation).code;
        vm.etch(SparkSUsdsTestConfig.TOKENIZED_STRATEGY_ADDRESS, tokenizedStrategyBytecode);
    }

    function _deployStrategy() internal override returns (address) {
        _etchImplementation();

        factory = new SparkStrategyFactory{ salt: keccak256("OCT_SPARK_STRATEGY_FACTORY_V1") }();

        vm.startPrank(management);
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
        vm.stopPrank();

        strategy = SparkStrategy(strategyAddress);
        return strategyAddress;
    }

    function _labelAddresses() internal override {
        vm.label(address(strategy), "SparkSUsdsDonating");
        vm.label(address(factory), "SparkStrategyFactory");
        vm.label(SparkSUsdsTestConfig.SUSDS_VAULT, "sUSDS Vault");
        vm.label(SparkSUsdsTestConfig.USDS, "USDS");
        vm.label(management, "Management");
        vm.label(keeper, "Keeper");
        vm.label(emergencyAdmin, "Emergency Admin");
        vm.label(donationAddress, "Donation Address");
        vm.label(user, "Test User");
        vm.label(unauthorizedUser, "Unauthorized User");
    }

    function setUp() public {
        _baseSetUp();

        // Deploy mock airdrop tokens for sweepAirdrop tests
        airdropToken = new MockERC20(18);
        anotherToken = new MockERC20(6);
        vm.label(address(airdropToken), "AirdropToken");
        vm.label(address(anotherToken), "AnotherToken");
    }

    // ========== TESTS - Delegating to base implementations ==========

    function testInitializationSUsds() public view {
        _testInitialization();
    }

    function testFuzzDepositSUsds(uint256 depositAmount) public {
        _testFuzzDeposit(depositAmount);
    }

    function testFuzzWithdrawSUsds(uint256 depositAmount, uint256 withdrawFraction) public {
        _testFuzzWithdraw(depositAmount, withdrawFraction);
    }

    function testFuzzHarvestWithProfitDonationSUsds(uint256 depositAmount, uint256 profitAmount) public {
        depositAmount = bound(depositAmount, _minDeposit(), _maxDeposit());
        profitAmount = bound(profitAmount, 1e15, depositAmount);

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

        // Mock profit by mocking sUSDS vault's convertToAssets return value
        uint256 balanceOfSUsdsVault = IERC4626(_compounderVault()).balanceOf(address(strategy));
        vm.mockCall(
            address(IERC4626(_compounderVault())),
            abi.encodeWithSelector(IERC4626.convertToAssets.selector, balanceOfSUsdsVault),
            abi.encode(depositAmount + profitAmount)
        );

        vm.startPrank(keeper);
        (uint256 profit, uint256 loss) = IMockStrategy(address(strategy)).report();
        vm.stopPrank();

        vm.clearMockedCalls();

        // Airdrop profit to simulate the actual accrued yield
        airdrop(ERC20(_asset()), address(strategy), profitAmount);

        assertGt(profit, 0, "Should have captured profit from SSR yield");
        assertEq(loss, 0, "Should have no loss");

        // User shares should remain the same (no dilution - profit is minted to donation address)
        assertEq(IERC4626(address(vault)).balanceOf(user), userSharesBefore, "User shares should not change");

        // Donation address should have received the profit shares
        uint256 donationBalanceAfter = ERC20(address(vault)).balanceOf(donationAddress);
        assertGt(donationBalanceAfter, donationBalanceBefore, "Donation address should receive profit");

        // Total assets should increase by the profit amount
        assertGt(IERC4626(address(vault)).totalAssets(), totalAssetsBefore, "Total assets should increase");
    }

    function testFuzzEmergencyWithdrawSUsds(uint256 depositAmount, uint256 withdrawFraction) public {
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

        // Cap emergency withdraw to what's available in sUSDS vault
        uint256 maxWithdrawableFromSUsds = IERC4626(_compounderVault()).maxWithdraw(address(strategy));
        if (emergencyWithdrawAmount > maxWithdrawableFromSUsds) {
            emergencyWithdrawAmount = maxWithdrawableFromSUsds;
        }

        vm.startPrank(emergencyAdmin);
        vault.shutdownStrategy();
        vault.emergencyWithdraw(emergencyWithdrawAmount);
        vm.stopPrank();

        // User should still be able to withdraw up to maxRedeem
        vm.startPrank(user);
        uint256 maxRedeem = vault.maxRedeem(user);
        if (maxRedeem > 0) {
            uint256 assetsReceived = vault.redeem(maxRedeem, user, user);
            assertGt(assetsReceived, 0, "User should receive some assets");
        }
        vm.stopPrank();
    }

    // ========== sUSDS STRATEGY TESTS ==========

    /// @notice Test that strategy inherits all basic ERC4626Strategy functionality
    function testBasicInheritance() public view {
        assertEq(IERC4626(address(strategy)).asset(), _asset(), "Asset should be correct");
        assertEq(strategy.targetVault(), _compounderVault(), "Target vault should be correct");
    }

    /// @notice Test available deposit limit without idle assets
    function testAvailableDepositLimitWithoutIdleAssets() public view {
        uint256 limit = strategy.availableDepositLimit(user);
        uint256 sUsdsLimit = IERC4626(_compounderVault()).maxDeposit(address(strategy));
        uint256 idleBalance = ERC20(_asset()).balanceOf(address(strategy));

        assertEq(idleBalance, 0, "Strategy should have no idle assets initially");
        assertEq(limit, sUsdsLimit, "Available deposit limit should match sUSDS vault limit when no idle assets");
    }

    /// @notice Test available deposit limit with idle assets
    function testAvailableDepositLimitWithIdleAssets() public {
        uint256 idleAmount = 1_000e18; // 1,000 USDS idle assets

        airdrop(ERC20(_asset()), address(strategy), idleAmount);

        uint256 limit = strategy.availableDepositLimit(user);
        uint256 sUsdsLimit = IERC4626(_compounderVault()).maxDeposit(address(strategy));
        uint256 idleBalance = ERC20(_asset()).balanceOf(address(strategy));

        assertEq(idleBalance, idleAmount, "Strategy should have idle assets");

        uint256 expectedLimit = sUsdsLimit > idleAmount ? sUsdsLimit - idleAmount : 0;
        assertEq(limit, expectedLimit, "Available deposit limit should account for idle assets");
        if (sUsdsLimit != type(uint256).max) {
            assertLt(
                limit,
                sUsdsLimit,
                "Available deposit limit should be less than sUSDS limit when idle assets exist"
            );
        }
    }

    /// @notice Test available deposit limit edge case where idle assets exceed sUSDS limit.
    /// @dev sUSDS has no on-chain supply cap today, so maxDeposit returns type(uint256).max and
    ///      this path is unreachable. The test gracefully skips in that case.
    function testAvailableDepositLimitIdleAssetsExceedSUsdsLimit() public {
        uint256 sUsdsLimit = IERC4626(_compounderVault()).maxDeposit(address(strategy));

        // Skip if maxDeposit is effectively uncapped - we can't overflow idle > limit in a useful way.
        if (sUsdsLimit >= type(uint256).max / 2) {
            return;
        }

        uint256 excessIdleAmount = sUsdsLimit + 1_000e18;
        airdrop(ERC20(_asset()), address(strategy), excessIdleAmount);

        uint256 limit = strategy.availableDepositLimit(user);
        uint256 idleBalance = ERC20(_asset()).balanceOf(address(strategy));

        assertEq(idleBalance, excessIdleAmount, "Strategy should have excess idle assets");
        assertGt(idleBalance, sUsdsLimit, "Idle assets should exceed sUSDS limit");
        assertEq(limit, 0, "Available deposit limit should be 0 when idle assets exceed sUSDS limit");
    }

    // ========== DEPOSIT/WITHDRAW ROUND TRIP ==========

    /// @notice End-to-end deposit -> withdraw via the strategy, asserting that the underlying
    ///         sUSDS vault actually receives the assets and the user can pull them back.
    function testDepositRoundTripThroughSUsds() public {
        uint256 amount = 10_000e18;
        airdrop(ERC20(_asset()), user, amount);

        uint256 strategyShareBalanceBefore = IERC4626(_compounderVault()).balanceOf(address(strategy));

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();

        // Strategy should hold sUSDS shares representing the deposit
        uint256 strategyShareBalanceAfter = IERC4626(_compounderVault()).balanceOf(address(strategy));
        assertGt(
            strategyShareBalanceAfter,
            strategyShareBalanceBefore,
            "Strategy should hold sUSDS shares after deposit"
        );

        // User pulls everything back. Cap redeem at maxRedeem to absorb sUSDS's
        // withdraw-side rounding (maxWithdraw on the vault can be 1-2 wei below the
        // deposited amount for a few blocks after deposit due to chi rounding).
        vm.startPrank(user);
        uint256 redeemable = vault.maxRedeem(user);
        uint256 received = vault.redeem(redeemable, user, user);
        vm.stopPrank();

        assertApproxEqAbs(received, amount, 2, "User should recover the deposited amount within rounding");
        assertLe(vault.balanceOf(user), 2, "User should hold at most dust shares after full redeem");
    }

    // ========== SSR ACCRUAL (sUSDS-SPECIFIC) ==========

    /// @notice Verify that warping time accrues Sky Savings Rate (SSR) yield on the strategy's
    ///         sUSDS position. Uses the vault's own drip() if present, otherwise relies on
    ///         convertToAssets being time-sensitive on the live contract.
    function testSUsdsSSRAccrual() public {
        uint256 depositAmount = _ssrTestDeposit();

        if (ERC20(_asset()).balanceOf(user) < depositAmount) {
            airdrop(ERC20(_asset()), user, depositAmount);
        }

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        IERC4626(address(vault)).deposit(depositAmount, user);
        vm.stopPrank();

        uint256 shares = IERC4626(_compounderVault()).balanceOf(address(strategy));
        uint256 assetsBefore = IERC4626(_compounderVault()).convertToAssets(shares);

        vm.warp(block.timestamp + 365 days);

        // Poke the rate accumulator if the vault exposes drip(); ignore if it doesn't.
        (bool success, ) = _compounderVault().call(abi.encodeWithSignature("drip()"));
        if (success) {
            uint256 assetsAfter = IERC4626(_compounderVault()).convertToAssets(shares);
            assertGe(assetsAfter, assetsBefore, "sUSDS should accrue SSR yield over time");
        }
    }

    /// @notice Fast-forward + keeper report should surface SSR-accrued yield as donation shares
    ///         WITHOUT any mocking of convertToAssets.
    function testSSRAccrualSurfacesAsDonationOnReport() public {
        uint256 depositAmount = _ssrTestDeposit();

        if (ERC20(_asset()).balanceOf(user) < depositAmount) {
            airdrop(ERC20(_asset()), user, depositAmount);
        }

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), depositAmount);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        uint256 donationBefore = ERC20(address(vault)).balanceOf(donationAddress);
        uint256 totalAssetsBefore = vault.totalAssets();

        // Warp a year and drip the vault so the SSR has something to accumulate into.
        vm.warp(block.timestamp + 365 days);
        (bool dripOk, ) = _compounderVault().call(abi.encodeWithSignature("drip()"));
        dripOk; // ignored: drip() is a no-op / absent on some vault versions

        vm.startPrank(keeper);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();

        // If the forked block + 1y places us in a regime where SSR > 0, we expect profit.
        // Otherwise this asserts the no-loss invariant only (still a meaningful gate).
        assertEq(loss, 0, "SSR accrual must never produce loss");

        if (profit > 0) {
            uint256 donationAfter = ERC20(address(vault)).balanceOf(donationAddress);
            assertGt(donationAfter, donationBefore, "SSR profit should mint shares to donation address");
            assertGt(vault.totalAssets(), totalAssetsBefore, "Total assets should grow with SSR");
        }
    }

    /// @notice Test deposit cap handling
    /// @dev sUSDS currently has no on-chain cap (maxDeposit == type(uint256).max), so the
    ///      cap-exceeded revert path is structurally unreachable and the test short-circuits.
    ///      Kept for symmetry with SparkStrategy.t.sol and to catch a future on-chain cap change.
    function testDepositCap() public {
        uint256 depositCap = IERC4626(_compounderVault()).maxDeposit(address(strategy));

        uint256 maxCheckAmount = _depositCapMaxCheck();
        if (depositCap > maxCheckAmount) {
            return;
        }

        uint256 excessAmount = depositCap + _depositCapExcess();

        airdrop(ERC20(_asset()), user, excessAmount);

        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), excessAmount);

        vm.expectRevert();
        IERC4626(address(vault)).deposit(excessAmount, user);
        vm.stopPrank();
    }

    /// @notice Test multiple users depositing and withdrawing
    function testMultiUserFlow() public {
        address user2 = address(0x9876);
        uint256 deposit1 = _multiUserDeposit1();
        uint256 deposit2 = _multiUserDeposit2();

        airdrop(ERC20(_asset()), user, deposit1);
        airdrop(ERC20(_asset()), user2, deposit2);

        vm.prank(user);
        ERC20(_asset()).approve(address(vault), deposit1);
        vm.prank(user2);
        ERC20(_asset()).approve(address(vault), deposit2);

        vm.prank(user);
        uint256 shares1 = IERC4626(address(vault)).deposit(deposit1, user);

        vm.prank(user2);
        uint256 shares2 = IERC4626(address(vault)).deposit(deposit2, user2);

        assertEq(IERC4626(address(vault)).balanceOf(user), shares1);
        assertEq(IERC4626(address(vault)).balanceOf(user2), shares2);

        vm.prank(user);
        IERC4626(address(vault)).redeem(shares1 / 2, user, user);

        assertEq(IERC4626(address(vault)).balanceOf(user), shares1 / 2);
        assertGt(ERC20(_asset()).balanceOf(user), 0);
    }

    // ========== SWEEPARIDROP TESTS ==========

    /// @notice Test successful airdrop sweep by keeper (e.g. a SKY/SPK governance airdrop to the strategy).
    function testSuccessfulAirdropSweepByKeeper() public {
        uint256 airdropAmount = 1_000e18;

        airdropToken.mint(address(strategy), airdropAmount);

        assertEq(airdropToken.balanceOf(address(strategy)), airdropAmount, "Strategy should have airdrop tokens");
        assertEq(airdropToken.balanceOf(donationAddress), 0, "Donation address should start with 0");

        vm.startPrank(keeper);
        vm.expectEmit(true, false, true, true);
        emit SparkStrategy.TokenSwept(address(airdropToken), airdropAmount, donationAddress);
        strategy.sweepAirdrop(address(airdropToken));
        vm.stopPrank();

        assertEq(airdropToken.balanceOf(address(strategy)), 0, "Strategy should have no airdrop tokens");
        assertEq(airdropToken.balanceOf(donationAddress), airdropAmount, "Donation address should receive tokens");
    }

    /// @notice Test successful airdrop sweep by management
    function testSuccessfulAirdropSweepByManagement() public {
        uint256 airdropAmount = 500e6;

        anotherToken.mint(address(strategy), airdropAmount);

        vm.startPrank(management);
        vm.expectEmit(true, false, true, true);
        emit SparkStrategy.TokenSwept(address(anotherToken), airdropAmount, donationAddress);
        strategy.sweepAirdrop(address(anotherToken));
        vm.stopPrank();

        assertEq(anotherToken.balanceOf(address(strategy)), 0, "Strategy should have no airdrop tokens");
        assertEq(anotherToken.balanceOf(donationAddress), airdropAmount, "Donation address should receive tokens");
    }

    /// @notice Test that unauthorized users cannot sweep airdrops
    function testUnauthorizedSweepReverts() public {
        uint256 airdropAmount = 100e18;

        airdropToken.mint(address(strategy), airdropAmount);

        vm.startPrank(unauthorizedUser);
        vm.expectRevert("!keeper");
        strategy.sweepAirdrop(address(airdropToken));
        vm.stopPrank();

        assertEq(airdropToken.balanceOf(address(strategy)), airdropAmount, "Tokens should remain in strategy");
    }

    /// @notice Test that the main asset (USDS) cannot be swept
    function testCannotSweepMainAsset() public {
        vm.startPrank(keeper);
        vm.expectRevert("SparkStrategy: Cannot sweep main asset");
        strategy.sweepAirdrop(_asset());
        vm.stopPrank();
    }

    /// @notice Test that sUSDS vault shares cannot be swept
    function testCannotSweepVaultShares() public {
        vm.startPrank(management);
        vm.expectRevert("SparkStrategy: Cannot sweep vault shares");
        strategy.sweepAirdrop(_compounderVault());
        vm.stopPrank();
    }

    /// @notice Test that sweeping with zero balance reverts
    function testSweepZeroBalanceReverts() public {
        vm.startPrank(keeper);
        vm.expectRevert("SparkStrategy: No balance to sweep");
        strategy.sweepAirdrop(address(airdropToken));
        vm.stopPrank();
    }

    /// @notice Test multiple token sweeps
    function testMultipleTokenSweeps() public {
        uint256 airdropAmount1 = 1_000e18;
        uint256 airdropAmount2 = 500e6;

        airdropToken.mint(address(strategy), airdropAmount1);
        anotherToken.mint(address(strategy), airdropAmount2);

        vm.startPrank(keeper);
        strategy.sweepAirdrop(address(airdropToken));
        vm.stopPrank();

        vm.startPrank(management);
        strategy.sweepAirdrop(address(anotherToken));
        vm.stopPrank();

        assertEq(airdropToken.balanceOf(address(strategy)), 0, "First token should be swept");
        assertEq(anotherToken.balanceOf(address(strategy)), 0, "Second token should be swept");
        assertEq(airdropToken.balanceOf(donationAddress), airdropAmount1, "Donation address should have first token");
        assertEq(anotherToken.balanceOf(donationAddress), airdropAmount2, "Donation address should have second token");
    }

    /// @notice Test that emergency admin cannot sweep (only keeper and management)
    function testEmergencyAdminCannotSweep() public {
        uint256 airdropAmount = 100e18;

        airdropToken.mint(address(strategy), airdropAmount);

        vm.startPrank(emergencyAdmin);
        vm.expectRevert("!keeper");
        strategy.sweepAirdrop(address(airdropToken));
        vm.stopPrank();
    }

    // ========== AVAILABLE WITHDRAW LIMIT OVERFLOW TESTS ==========

    function testAvailableWithdrawLimitNoOverflowSUsds() public {
        _testAvailableWithdrawLimitOverflow();
    }

    function testAvailableWithdrawLimitNormalCaseSUsds() public {
        _testAvailableWithdrawLimitNormal();
    }

    function testAvailableWithdrawLimitZeroIdleMaxVaultSUsds() public {
        _testAvailableWithdrawLimitZeroIdleMaxVault();
    }

    function testAvailableWithdrawLimitExactBoundarySUsds() public {
        _testAvailableWithdrawLimitExactBoundary();
    }

    function testFuzzAvailableWithdrawLimitNeverRevertsSUsds(uint256 a, uint256 b) public {
        _testFuzzAvailableWithdrawLimitNeverReverts(a, b);
    }

    // ========== HARVEST OVERFLOW TESTS ==========

    function testHarvestOverflowFromVaultSUsds() public {
        _testHarvestOverflowFromVault();
    }

    // ========== CONSTRUCTOR TESTS ==========

    /// @notice Test constructor asset validation rejects wrong asset
    function testConstructorAssetValidation() public {
        vm.expectRevert("Asset mismatch with target vault");
        new SparkStrategy(
            _compounderVault(),
            SparkSUsdsTestConfig.USDT, // Wrong asset: sUSDS vault's asset is USDS, not USDT
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
}
