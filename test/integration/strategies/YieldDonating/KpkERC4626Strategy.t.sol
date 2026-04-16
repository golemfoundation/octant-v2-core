// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ERC4626Strategy } from "src/strategies/yieldDonating/ERC4626Strategy.sol";
import { ERC4626StrategyFactory } from "src/factories/ERC4626StrategyFactory.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { IMockStrategy } from "test/mocks/core/IMockStrategy.sol";
import { BaseYieldDonatingIntegrationTest } from "./base/BaseYieldDonatingIntegrationTest.sol";
import { KpkTestConfig } from "../config/KpkTestConfig.sol";

/// @title KPK ERC4626 Yield Donating Test
/// @author Octant
/// @notice Integration tests for ERC4626Strategy against KPK (karpatkey) MetaMorpho vaults on mainnet
/// @dev KPK vaults are standard ERC-4626 MetaMorpho vaults curated by karpatkey on Morpho.
///      This test uses the generic ERC4626Strategy since no protocol-specific adapter is needed.
///      Defaults to USDC configuration; override config getters for other assets (e.g., WETH).
contract KpkERC4626StrategyTest is BaseYieldDonatingIntegrationTest {
    // ========== STATE VARIABLES ==========

    ERC4626Strategy public strategy;
    ERC4626StrategyFactory public factory;

    // ========== CONFIGURATION OVERRIDES ==========

    function _asset() internal pure virtual override returns (address) {
        return KpkTestConfig.USDC;
    }

    function _strategyName() internal pure virtual override returns (string memory) {
        return KpkTestConfig.USDC_STRATEGY_NAME;
    }

    function _strategySymbol() internal pure virtual override returns (string memory) {
        return KpkTestConfig.USDC_STRATEGY_SYMBOL;
    }

    function _initialDeposit() internal pure virtual override returns (uint256) {
        return KpkTestConfig.USDC_INITIAL_DEPOSIT;
    }

    function _compounderVault() internal pure virtual override returns (address) {
        return KpkTestConfig.USDC_KPK_VAULT;
    }

    function _minDeposit() internal pure virtual override returns (uint256) {
        return KpkTestConfig.USDC_MIN_DEPOSIT;
    }

    function _maxDeposit() internal pure virtual override returns (uint256) {
        return KpkTestConfig.USDC_MAX_DEPOSIT;
    }

    function _decimals() internal pure virtual override returns (uint8) {
        return KpkTestConfig.USDC_DECIMALS;
    }

    // ========== TEST-SPECIFIC CONFIGURATION ==========

    function _depositCapMaxCheck() internal pure virtual returns (uint256) {
        return KpkTestConfig.USDC_DEPOSIT_CAP_MAX_CHECK;
    }

    function _depositCapExcess() internal pure virtual returns (uint256) {
        return KpkTestConfig.USDC_DEPOSIT_CAP_EXCESS;
    }

    function _multiUserDeposit1() internal pure virtual returns (uint256) {
        return KpkTestConfig.USDC_MULTI_USER_DEPOSIT_1;
    }

    function _multiUserDeposit2() internal pure virtual returns (uint256) {
        return KpkTestConfig.USDC_MULTI_USER_DEPOSIT_2;
    }

    // ========== SETUP ==========

    function _etchImplementation() internal override {
        implementation = new YieldDonatingTokenizedStrategy{ salt: keccak256("OCT_YIELD_DONATING_STRATEGY_V1") }();
        bytes memory tokenizedStrategyBytecode = address(implementation).code;
        vm.etch(KpkTestConfig.TOKENIZED_STRATEGY_ADDRESS, tokenizedStrategyBytecode);
    }

    function _deployStrategy() internal override returns (address) {
        _etchImplementation();

        factory = new ERC4626StrategyFactory{ salt: keccak256("OCT_ERC4626_STRATEGY_FACTORY_V1") }();

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

        strategy = ERC4626Strategy(strategyAddress);
        return strategyAddress;
    }

    function _labelAddresses() internal virtual override {
        vm.label(address(strategy), "KpkERC4626Donating");
        vm.label(address(factory), "ERC4626StrategyFactory");
        vm.label(_compounderVault(), "KPK Vault");
        vm.label(_asset(), "Asset");
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

    function testInitializationKpk() public view {
        _testInitialization();
    }

    function testFuzzDepositKpk(uint256 depositAmount) public {
        _testFuzzDeposit(depositAmount);
    }

    function testFuzzWithdrawKpk(uint256 depositAmount, uint256 withdrawFraction) public {
        _testFuzzWithdraw(depositAmount, withdrawFraction);
    }

    function testFuzzHarvestWithProfitDonationKpk(uint256 depositAmount, uint256 profitAmount) public {
        depositAmount = bound(depositAmount, _minDeposit(), _maxDeposit());
        profitAmount = bound(profitAmount, 1e5, depositAmount);

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

        // Mock profit by mocking KPK vault return value
        uint256 balanceOfKpkVault = IERC4626(_compounderVault()).balanceOf(address(strategy));
        vm.mockCall(
            address(IERC4626(_compounderVault())),
            abi.encodeWithSelector(IERC4626.convertToAssets.selector, balanceOfKpkVault),
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

    function testFuzzEmergencyWithdrawKpk(uint256 depositAmount, uint256 withdrawFraction) public {
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

        // Cap emergency withdraw to what's available in KPK vault
        uint256 maxWithdrawableFromKpk = IERC4626(_compounderVault()).maxWithdraw(address(strategy));
        if (emergencyWithdrawAmount > maxWithdrawableFromKpk) {
            emergencyWithdrawAmount = maxWithdrawableFromKpk;
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

    // ========== ERC4626 STRATEGY TESTS ==========

    /// @notice Test that strategy uses the correct target vault and asset
    function testBasicConfiguration() public view {
        assertEq(IERC4626(address(strategy)).asset(), _asset(), "Asset should be correct");
        assertEq(strategy.targetVault(), _compounderVault(), "Target vault should be correct");
    }

    /// @notice Test available deposit limit without idle assets
    function testAvailableDepositLimitWithoutIdleAssets() public view {
        uint256 limit = strategy.availableDepositLimit(user);
        uint256 kpkLimit = IERC4626(_compounderVault()).maxDeposit(address(strategy));
        uint256 idleBalance = ERC20(_asset()).balanceOf(address(strategy));

        assertEq(idleBalance, 0, "Strategy should have no idle assets initially");
        assertEq(limit, kpkLimit, "Available deposit limit should match KPK vault limit when no idle assets");
    }

    /// @notice Test available deposit limit with idle assets
    /// @dev Mocks the target vault's `maxDeposit` and the asset's `balanceOf` so the assertion
    ///      isolates the strategy's arithmetic (`vaultLimit - idleBalance`). Using the live
    ///      fork response for `maxDeposit` (which can be `type(uint256).max` for some target
    ///      vaults) combined with `deal()`-based airdrops is flaky across CI environments,
    ///      where the strategy's internal `balanceOf` read would return zero while the
    ///      external read still reported the airdropped amount.
    function testAvailableDepositLimitWithIdleAssets() public {
        uint256 idleAmount = 1000 * 10 ** uint256(_decimals());
        uint256 mockedVaultLimit = 100_000_000 * 10 ** uint256(_decimals());

        vm.mockCall(
            _compounderVault(),
            abi.encodeWithSelector(IERC4626.maxDeposit.selector, address(strategy)),
            abi.encode(mockedVaultLimit)
        );
        vm.mockCall(
            _asset(),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(strategy)),
            abi.encode(idleAmount)
        );

        uint256 limit = strategy.availableDepositLimit(user);
        uint256 kpkLimit = IERC4626(_compounderVault()).maxDeposit(address(strategy));
        uint256 idleBalance = ERC20(_asset()).balanceOf(address(strategy));

        assertEq(idleBalance, idleAmount, "Strategy should have idle assets");

        uint256 expectedLimit = kpkLimit > idleAmount ? kpkLimit - idleAmount : 0;
        assertEq(limit, expectedLimit, "Available deposit limit should account for idle assets");
        assertLt(limit, kpkLimit, "Available deposit limit should be less than KPK limit when idle assets exist");
    }

    /// @notice Test deposit cap handling
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

    // ========== AVAILABLE WITHDRAW LIMIT OVERFLOW TESTS ==========

    function testAvailableWithdrawLimitNoOverflowKpk() public {
        _testAvailableWithdrawLimitOverflow();
    }

    function testAvailableWithdrawLimitNormalCaseKpk() public {
        _testAvailableWithdrawLimitNormal();
    }

    function testAvailableWithdrawLimitZeroIdleMaxVaultKpk() public {
        _testAvailableWithdrawLimitZeroIdleMaxVault();
    }

    function testAvailableWithdrawLimitExactBoundaryKpk() public {
        _testAvailableWithdrawLimitExactBoundary();
    }

    function testFuzzAvailableWithdrawLimitNeverRevertsKpk(uint256 a, uint256 b) public {
        _testFuzzAvailableWithdrawLimitNeverReverts(a, b);
    }

    // ========== HARVEST OVERFLOW TESTS ==========

    function testHarvestOverflowFromVaultKpk() public {
        _testHarvestOverflowFromVault();
    }

    // ========== CONSTRUCTOR TESTS ==========

    /// @notice Test constructor asset validation rejects wrong asset
    function testConstructorAssetValidation() public {
        // Use USDT (a real contract but wrong asset for the vault) to trigger the asset mismatch check
        address wrongAsset = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
        vm.expectRevert("Asset mismatch with target vault");
        new ERC4626Strategy(
            _compounderVault(),
            wrongAsset,
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
