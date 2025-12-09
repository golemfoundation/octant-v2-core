// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockYieldStrategy } from "test/mocks/zodiac-core/MockYieldStrategy.sol";
import { MockFactory } from "test/mocks/MockFactory.sol";
import { MockLossyStrategy } from "test/mocks/core/MockLossyStrategy.sol";
import { MockLockedStrategy } from "test/mocks/core/MockLockedStrategy.sol";
import { MockWithdrawLimitModule } from "test/mocks/core/MockWithdrawLimitModule.sol";
import { MockDepositLimitModule } from "test/mocks/core/MockDepositLimitModule.sol";

contract ERC4626Test is Test {
    MultistrategyVault vaultImplementation;
    MultistrategyVault vault;
    MockERC20 public asset;
    MockYieldStrategy public strategy;
    MockFactory public factory;
    MultistrategyVaultFactory vaultFactory;

    address public gov = address(0x1);
    address public fish = address(0x2);
    address public feeRecipient = address(0x3);
    address constant ZERO_ADDRESS = address(0);

    uint256 public fishAmount = 10_000e18;
    uint256 public halfFishAmount = fishAmount / 2;
    uint256 constant DAY = 1 days;
    uint256 constant MAX_INT = type(uint256).max;

    function setUp() public {
        // Setup asset
        asset = new MockERC20(18);
        asset.mint(gov, 1_000_000e18);
        asset.mint(fish, fishAmount);

        // Deploy factory
        vm.prank(gov);
        factory = new MockFactory(0, feeRecipient);

        // Deploy vault
        vm.startPrank(address(factory));
        vaultImplementation = new MultistrategyVault();
        vaultFactory = new MultistrategyVaultFactory("Test Vault", address(vaultImplementation), gov);
        vault = MultistrategyVault(vaultFactory.deployNewVault(address(asset), "Test Vault", "vTST", gov, 7 days));
        vm.stopPrank();

        vm.startPrank(gov);
        // Add roles to gov
        vault.addRole(gov, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);
        vault.addRole(gov, IMultistrategyVault.Roles.DEBT_MANAGER);
        vault.addRole(gov, IMultistrategyVault.Roles.MAX_DEBT_MANAGER);
        vault.addRole(gov, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);
        vm.stopPrank();

        // set max deposit limit
        vm.prank(gov);
        vault.setDepositLimit(MAX_INT, false);
    }

    function userDeposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        asset.approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();
    }

    function createStrategy() internal returns (address) {
        MockYieldStrategy newStrategy = new MockYieldStrategy(address(asset), address(vault));

        return address(newStrategy);
    }

    function addStrategyToVault(address strategyAddress) internal {
        vm.prank(gov);
        vault.addStrategy(strategyAddress, true);
        vm.prank(gov);
        vault.updateMaxDebtForStrategy(strategyAddress, type(uint256).max);
    }

    function addDebtToStrategy(address strategyAddress, uint256 amount) internal {
        vm.prank(gov);
        vault.updateDebt(strategyAddress, amount, 0);
    }

    function testTotalAssets() public {
        userDeposit(fish, fishAmount);
        assertEq(vault.totalAssets(), fishAmount, "Total assets should match deposit amount");
    }

    function testConvertToShares() public {
        uint256 assets = fishAmount;
        uint256 shares = assets; // 1:1 ratio for fresh vault

        userDeposit(fish, assets);
        assertEq(vault.convertToShares(assets), shares, "Converted shares should match assets for 1:1 ratio");
    }

    function testConvertToAssets() public {
        uint256 shares = fishAmount;
        uint256 assets = shares; // 1:1 ratio for fresh vault

        userDeposit(fish, assets);
        assertEq(vault.convertToAssets(shares), assets, "Converted assets should match shares for 1:1 ratio");
    }

    function testPreviewDeposit() public {
        uint256 assets = fishAmount;

        userDeposit(fish, assets);
        assertEq(vault.previewDeposit(assets), assets, "Preview deposit should return same amount");
    }

    function testMaxDepositWithTotalAssetsEqualToDepositLimit() public {
        uint256 assets = fishAmount;

        userDeposit(fish, assets);

        vm.prank(gov);
        vault.setDepositLimit(assets, false);

        assertEq(vault.maxDeposit(fish), 0, "Max deposit should be 0 when limit reached");
    }

    function testMaxDepositWithTotalAssetsGreaterThanDepositLimit() public {
        uint256 assets = fishAmount;

        userDeposit(fish, assets);

        vm.prank(gov);
        vault.setDepositLimit(halfFishAmount, false);

        assertEq(vault.maxDeposit(fish), 0, "Max deposit should be 0 when over limit");
    }

    function testMaxDepositWithTotalAssetsLessThanDepositLimit() public {
        uint256 depositLimit = fishAmount;

        vm.prank(gov);
        vault.setDepositLimit(depositLimit, false);

        assertEq(vault.maxDeposit(fish), depositLimit, "Max deposit should equal deposit limit");
    }

    function testPreviewMint() public {
        uint256 shares = fishAmount;
        uint256 assets = shares; // 1:1 ratio

        userDeposit(fish, assets);
        assertEq(vault.previewMint(shares), shares, "Preview mint should return same amount");
    }

    function testMaxMintWithTotalAssetsEqualToDepositLimit() public {
        uint256 assets = fishAmount;

        userDeposit(fish, assets);

        vm.prank(gov);
        vault.setDepositLimit(assets, false);

        assertEq(vault.maxMint(fish), 0, "Max mint should be 0 when limit reached");
    }

    function testMaxMintWithTotalAssetsGreaterThanDepositLimit() public {
        uint256 assets = fishAmount;

        userDeposit(fish, assets);

        vm.prank(gov);
        vault.setDepositLimit(halfFishAmount, false);

        assertEq(vault.maxMint(fish), 0, "Max mint should be 0 when over limit");
    }

    function testMaxMintWithTotalAssetsLessThanDepositLimit() public {
        uint256 depositLimit = fishAmount;

        vm.prank(gov);
        vault.setDepositLimit(depositLimit, false);

        assertEq(vault.maxMint(fish), depositLimit, "Max mint should equal deposit limit");
    }

    function testPreviewWithdraw() public {
        uint256 assets = fishAmount;
        uint256 shares = assets; // 1:1 ratio

        userDeposit(fish, assets);
        assertEq(vault.previewWithdraw(assets), shares, "Preview withdraw should return equivalent shares");
    }

    function testMaxWithdrawWithBalanceGreaterThanTotalIdle() public {
        uint256 assets = fishAmount;
        address strategyAddress = createStrategy();
        uint256 strategyDeposit = assets / 2;

        userDeposit(fish, assets);
        addStrategyToVault(strategyAddress);
        addDebtToStrategy(strategyAddress, strategyDeposit);

        assertEq(vault.maxWithdraw(fish, 0, new address[](0)), assets, "Max withdraw should equal full balance");
    }

    function testMaxWithdrawWithBalanceLessOrEqualToTotalIdle() public {
        uint256 assets = fishAmount;

        userDeposit(fish, assets);

        assertEq(vault.maxWithdraw(fish, 0, new address[](0)), assets, "Max withdraw should equal deposited amount");
    }

    function testMaxWithdrawWithCustomParams() public {
        uint256 assets = fishAmount;
        address strategyAddress = createStrategy();
        uint256 strategyDeposit = assets / 2;

        userDeposit(fish, assets);
        addStrategyToVault(strategyAddress);
        addDebtToStrategy(strategyAddress, strategyDeposit);

        assertEq(
            vault.maxWithdraw(fish, 22, new address[](0)),
            assets,
            "Max withdraw should equal full balance with custom loss param"
        );

        address[] memory strategies = new address[](1);
        strategies[0] = strategyAddress;
        assertEq(
            vault.maxWithdraw(fish, 22, strategies),
            assets,
            "Max withdraw should equal full balance with custom strategy array"
        );
    }

    function createLossyStrategy() internal returns (MockLossyStrategy) {
        MockLossyStrategy lossy = new MockLossyStrategy(address(asset), address(vault));
        lossy.setERC4626TestMode(true);
        return lossy;
    }

    function testMaxWithdrawWithLossyStrategy() public {
        uint256 assets = fishAmount;
        MockLossyStrategy lossy = createLossyStrategy();
        uint256 strategyDeposit = assets / 2;
        uint256 loss = strategyDeposit / 2;
        uint256 totalIdle = assets - strategyDeposit;

        userDeposit(fish, assets);
        addStrategyToVault(address(lossy));
        addDebtToStrategy(address(lossy), strategyDeposit);

        vm.prank(gov);
        lossy.setLoss(loss);

        // With 100% max loss, should not affect returned value
        assertEq(
            vault.maxWithdraw(fish, 10000, new address[](0)),
            assets,
            "Max withdraw should equal full balance with 100% max loss"
        );

        // With default max loss (0), should return just idle
        assertEq(
            vault.maxWithdraw(fish, 0, new address[](0)),
            totalIdle,
            "Max withdraw should equal just idle with 0% max loss"
        );
    }

    function testMaxWithdrawWithLiquidAndLossyStrategy() public {
        uint256 assets = fishAmount;
        address liquidStrategy = createStrategy();
        MockLossyStrategy lossy = createLossyStrategy();
        uint256 strategyDeposit = assets / 2;
        uint256 loss = strategyDeposit / 2;

        userDeposit(fish, assets);
        addStrategyToVault(liquidStrategy);
        addStrategyToVault(address(lossy));
        addDebtToStrategy(liquidStrategy, strategyDeposit);
        addDebtToStrategy(address(lossy), strategyDeposit);

        vm.prank(gov);
        lossy.setLoss(loss);

        // With 100% max loss, should not affect returned value
        assertEq(
            vault.maxWithdraw(fish, 10000, new address[](0)),
            assets,
            "Max withdraw should equal full balance with 100% max loss"
        );

        address[] memory strategies = new address[](2);
        strategies[0] = liquidStrategy;
        strategies[1] = address(lossy);
        assertEq(
            vault.maxWithdraw(fish, 10000, strategies),
            assets,
            "Max withdraw should equal full balance with specific strategies"
        );

        // With 0% max loss, should return just liquid strategy's debt
        assertEq(
            vault.maxWithdraw(fish, 0, new address[](0)),
            strategyDeposit,
            "Max withdraw should equal liquid strategy debt with 0% max loss"
        );

        strategies[0] = liquidStrategy;
        strategies[1] = address(lossy);
        assertEq(
            vault.maxWithdraw(fish, 0, strategies),
            strategyDeposit,
            "Max withdraw should equal liquid strategy debt with specific strategies"
        );

        // With lossy strategy first, should return 0
        strategies[0] = address(lossy);
        strategies[1] = liquidStrategy;
        assertEq(vault.maxWithdraw(fish, 0, strategies), 0, "Max withdraw should be 0 with lossy strategy first");
    }

    function createLockedStrategy() internal returns (MockLockedStrategy) {
        return new MockLockedStrategy(address(asset), address(vault));
    }

    function testMaxWithdrawWithLockedStrategy() public {
        uint256 assets = fishAmount;
        MockLockedStrategy locked = createLockedStrategy();
        uint256 strategyDeposit = assets / 2;
        uint256 lockedAmount = strategyDeposit / 2;

        userDeposit(fish, assets);
        addStrategyToVault(address(locked));
        addDebtToStrategy(address(locked), strategyDeposit);

        vm.prank(gov);
        locked.setLockedFunds(lockedAmount, DAY);

        assertEq(
            vault.maxWithdraw(fish, 0, new address[](0)),
            assets - lockedAmount,
            "Max withdraw should exclude locked funds"
        );
    }

    function testMaxWithdrawWithUseDefaultQueue() public {
        uint256 assets = fishAmount;
        address strategyAddress = createStrategy();
        uint256 strategyDeposit = assets;

        vm.prank(gov);
        vault.addRole(gov, IMultistrategyVault.Roles.QUEUE_MANAGER);

        userDeposit(fish, assets);
        addStrategyToVault(strategyAddress);
        addDebtToStrategy(strategyAddress, strategyDeposit);

        assertEq(vault.maxWithdraw(fish, 0, new address[](0)), assets, "Max withdraw should equal full balance");
        assertEq(
            vault.maxWithdraw(fish, 22, new address[](0)),
            assets,
            "Max withdraw should equal full balance with maxLoss"
        );

        address[] memory strategies = new address[](1);
        strategies[0] = strategyAddress;
        assertEq(
            vault.maxWithdraw(fish, 22, strategies),
            assets,
            "Max withdraw should equal full balance with custom strategy array"
        );

        // Using inactive strategy when useDefaultQueue is false should revert
        address[] memory invalidStrategies = new address[](1);
        invalidStrategies[0] = address(vault); // vault is not a strategy
        vm.expectRevert(IMultistrategyVault.InactiveStrategy.selector);
        vault.maxWithdraw(fish, 22, invalidStrategies);

        // Enable useDefaultQueue
        vm.prank(gov);
        vault.setUseDefaultQueue(true);

        assertEq(
            vault.maxWithdraw(fish, 0, new address[](0)),
            assets,
            "Max withdraw should equal full balance with useDefaultQueue"
        );
        assertEq(
            vault.maxWithdraw(fish, 22, new address[](0)),
            assets,
            "Max withdraw should equal full balance with maxLoss and useDefaultQueue"
        );
        assertEq(
            vault.maxWithdraw(fish, 22, strategies),
            assets,
            "Max withdraw should equal full balance with custom strategies and useDefaultQueue"
        );

        // Even using an inactive strategy should work with useDefaultQueue=true
        assertEq(
            vault.maxWithdraw(fish, 22, invalidStrategies),
            assets,
            "Max withdraw should work with inactive strategy when useDefaultQueue is true"
        );
    }

    function testPreviewRedeem() public {
        uint256 shares = fishAmount;
        uint256 assets = shares; // 1:1 ratio

        userDeposit(fish, assets);

        assertEq(vault.previewRedeem(shares), assets, "Preview redeem should return equivalent assets");
    }

    function testMaxRedeemWithBalanceGreaterThanTotalIdle() public {
        uint256 shares = fishAmount;
        uint256 assets = shares;
        address strategyAddress = createStrategy();
        uint256 strategyDeposit = assets / 2;

        userDeposit(fish, assets);
        addStrategyToVault(strategyAddress);
        addDebtToStrategy(strategyAddress, strategyDeposit);

        assertEq(vault.maxRedeem(fish, 0, new address[](0)), shares, "Max redeem should equal full shares balance");
    }

    function testMaxRedeemWithBalanceLessOrEqualToTotalIdle() public {
        uint256 shares = fishAmount;
        uint256 assets = shares;

        userDeposit(fish, assets);

        assertEq(vault.maxRedeem(fish, 0, new address[](0)), shares, "Max redeem should equal full shares balance");
    }

    function testMaxRedeemWithCustomParams() public {
        uint256 shares = fishAmount;
        uint256 assets = shares;
        address strategyAddress = createStrategy();
        uint256 strategyDeposit = assets / 2;

        userDeposit(fish, assets);
        addStrategyToVault(strategyAddress);
        addDebtToStrategy(strategyAddress, strategyDeposit);

        address[] memory strategies = new address[](1);
        strategies[0] = strategyAddress;

        assertEq(
            vault.maxRedeem(fish, 0, strategies),
            shares,
            "Max redeem should equal full shares balance with custom params"
        );
    }

    function testMaxRedeemWithLiquidAndLossyStrategy() public {
        uint256 assets = fishAmount;
        address liquidStrategy = createStrategy();
        MockLossyStrategy lossy = createLossyStrategy();
        uint256 strategyDeposit = assets / 2;
        uint256 loss = strategyDeposit / 2;

        userDeposit(fish, assets);
        addStrategyToVault(liquidStrategy);
        addStrategyToVault(address(lossy));
        addDebtToStrategy(liquidStrategy, strategyDeposit);
        addDebtToStrategy(address(lossy), strategyDeposit);

        vm.prank(gov);
        lossy.setLoss(loss);

        address[] memory strategies = new address[](2);
        strategies[0] = liquidStrategy;
        strategies[1] = address(lossy);
        assertEq(
            vault.maxRedeem(fish, 10000, strategies),
            assets,
            "Max redeem should equal full shares with specific strategies"
        );

        strategies[0] = address(lossy);
        strategies[1] = liquidStrategy;
        assertEq(
            vault.maxRedeem(fish, 10000, strategies),
            assets,
            "Max redeem should equal full shares with lossy strategy first"
        );

        // With 0% max loss, should return just liquid strategy's debt equivalent in shares
        assertEq(
            vault.maxRedeem(fish, 0, new address[](0)),
            strategyDeposit,
            "Max redeem should equal liquid strategy equivalent shares with 0% max loss"
        );

        strategies[0] = liquidStrategy;
        strategies[1] = address(lossy);
        assertEq(
            vault.maxRedeem(fish, 0, strategies),
            strategyDeposit,
            "Max redeem should equal liquid strategy equivalent shares with specific strategies"
        );

        // With lossy strategy first, should return 0
        strategies[0] = address(lossy);
        strategies[1] = liquidStrategy;
        assertEq(
            vault.maxRedeem(fish, 0, strategies),
            0,
            "Max redeem should be 0 with lossy strategy first and 0% max loss"
        );
    }

    function testMaxRedeemWithLockedStrategy() public {
        uint256 assets = fishAmount;
        MockLockedStrategy locked = createLockedStrategy();
        uint256 strategyDeposit = assets / 2;
        uint256 lockedAmount = strategyDeposit / 2;

        userDeposit(fish, assets);
        addStrategyToVault(address(locked));
        addDebtToStrategy(address(locked), strategyDeposit);

        vm.prank(gov);
        locked.setLockedFunds(lockedAmount, DAY);

        assertEq(
            vault.maxRedeem(fish, 0, new address[](0)),
            assets - lockedAmount,
            "Max redeem should exclude locked funds equivalent shares"
        );
    }

    function testMaxRedeemWithUseDefaultQueue() public {
        uint256 assets = fishAmount;
        address strategyAddress = createStrategy();
        uint256 strategyDeposit = assets;

        vm.prank(gov);
        vault.addRole(gov, IMultistrategyVault.Roles.QUEUE_MANAGER);

        userDeposit(fish, assets);
        addStrategyToVault(strategyAddress);
        addDebtToStrategy(strategyAddress, strategyDeposit);

        assertEq(vault.maxRedeem(fish, 0, new address[](0)), assets, "Max redeem should equal full shares");
        assertEq(
            vault.maxRedeem(fish, 22, new address[](0)),
            assets,
            "Max redeem should equal full shares with custom maxLoss"
        );

        address[] memory strategies = new address[](1);
        strategies[0] = strategyAddress;
        assertEq(
            vault.maxRedeem(fish, 22, strategies),
            assets,
            "Max redeem should equal full shares with custom strategy array"
        );

        // Using inactive strategy when useDefaultQueue is false should revert
        address[] memory invalidStrategies = new address[](1);
        invalidStrategies[0] = address(vault); // vault is not a strategy
        vm.expectRevert(IMultistrategyVault.InactiveStrategy.selector);
        vault.maxRedeem(fish, 22, invalidStrategies);

        // Enable useDefaultQueue
        vm.prank(gov);
        vault.setUseDefaultQueue(true);

        assertEq(
            vault.maxRedeem(fish, 0, new address[](0)),
            assets,
            "Max redeem should equal full shares with useDefaultQueue"
        );
        assertEq(
            vault.maxRedeem(fish, 22, new address[](0)),
            assets,
            "Max redeem should equal full shares with custom maxLoss and useDefaultQueue"
        );
        assertEq(
            vault.maxRedeem(fish, 22, strategies),
            assets,
            "Max redeem should equal full shares with custom strategies and useDefaultQueue"
        );

        // Even using an inactive strategy should work with useDefaultQueue=true
        assertEq(
            vault.maxRedeem(fish, 22, invalidStrategies),
            assets,
            "Max redeem should work with inactive strategy when useDefaultQueue is true"
        );
    }

    // Helper function to deploy modules
    function deployLimitModule() internal returns (MockDepositLimitModule) {
        return new MockDepositLimitModule();
    }

    function deployWithdrawLimitModule() internal returns (MockWithdrawLimitModule) {
        return new MockWithdrawLimitModule();
    }

    function testMaxWithdrawWithWithdrawLimitModule() public {
        address bunny = address(0x4);
        uint256 assets = fishAmount / 2;

        MockWithdrawLimitModule limitModule = deployWithdrawLimitModule();

        assertEq(vault.maxWithdraw(fish, 0, new address[](0)), 0, "Initial max withdraw should be 0");

        // Set withdraw limit module
        vm.prank(gov);
        vault.addRole(gov, IMultistrategyVault.Roles.WITHDRAW_LIMIT_MANAGER);

        vm.prank(gov);
        vault.setWithdrawLimitModule(address(limitModule));

        assertEq(vault.withdrawLimitModule(), address(limitModule), "Withdraw limit module should be set");
        assertEq(vault.maxWithdraw(fish, 0, new address[](0)), 0, "Max withdraw should still be 0 with no balance");

        // Make a deposit
        userDeposit(fish, assets);

        // Check limits with default max limit
        assertEq(limitModule.defaultWithdrawLimit(), MAX_INT, "Default withdraw limit should be MAX_INT");
        assertEq(vault.maxWithdraw(fish, 0, new address[](0)), assets, "Max withdraw should equal balance");
        assertEq(vault.maxWithdraw(bunny, 0, new address[](0)), 0, "Max withdraw for bunny should be 0");

        // Set higher limit in module - shouldn't affect result (limited by balance)
        uint256 newLimit = assets * 2;
        vm.prank(gov);
        limitModule.setDefaultWithdrawLimit(newLimit);

        assertEq(vault.maxWithdraw(fish, 0, new address[](0)), assets, "Max withdraw should still equal balance");
        assertEq(
            vault.maxWithdraw(fish, 23, new address[](0)),
            assets,
            "Max withdraw with params should equal balance"
        );
        assertEq(vault.maxWithdraw(bunny, 0, new address[](0)), 0, "Max withdraw for bunny should still be 0");

        // Set lower limit - should limit withdrawals
        newLimit = assets / 2;
        vm.prank(gov);
        limitModule.setDefaultWithdrawLimit(newLimit);

        assertEq(vault.maxWithdraw(fish, 0, new address[](0)), newLimit, "Max withdraw should be limited by module");
        assertEq(vault.maxWithdraw(fish, 23, new address[](0)), newLimit, "Max withdraw with params should be limited");
        assertEq(vault.maxWithdraw(bunny, 0, new address[](0)), 0, "Max withdraw for bunny should still be 0");
    }

    function testMaxRedeemWithWithdrawLimitModule() public {
        address bunny = address(0x4);
        uint256 assets = fishAmount / 2;

        MockWithdrawLimitModule limitModule = deployWithdrawLimitModule();

        assertEq(vault.maxRedeem(fish, 0, new address[](0)), 0, "Initial max redeem should be 0");

        // Set withdraw limit module
        vm.prank(gov);
        vault.addRole(gov, IMultistrategyVault.Roles.WITHDRAW_LIMIT_MANAGER);

        vm.prank(gov);
        vault.setWithdrawLimitModule(address(limitModule));

        assertEq(vault.withdrawLimitModule(), address(limitModule), "Withdraw limit module should be set");
        assertEq(vault.maxRedeem(fish, 0, new address[](0)), 0, "Max redeem should still be 0 with no balance");

        // Make a deposit
        userDeposit(fish, assets);

        // Check limits with default max limit
        assertEq(limitModule.defaultWithdrawLimit(), MAX_INT, "Default withdraw limit should be MAX_INT");
        assertEq(vault.maxRedeem(fish, 0, new address[](0)), assets, "Max redeem should equal balance");
        assertEq(vault.maxRedeem(bunny, 0, new address[](0)), 0, "Max redeem for bunny should be 0");

        // Set higher limit in module - shouldn't affect result (limited by balance)
        uint256 newLimit = assets * 2;
        vm.prank(gov);
        limitModule.setDefaultWithdrawLimit(newLimit);

        assertEq(vault.maxRedeem(fish, 0, new address[](0)), assets, "Max redeem should still equal balance");
        assertEq(vault.maxRedeem(fish, 23, new address[](0)), assets, "Max redeem with params should equal balance");
        assertEq(vault.maxRedeem(bunny, 0, new address[](0)), 0, "Max redeem for bunny should still be 0");

        // Set lower limit - should limit redemptions
        newLimit = assets / 2;
        vm.prank(gov);
        limitModule.setDefaultWithdrawLimit(newLimit);

        assertEq(vault.maxRedeem(fish, 0, new address[](0)), newLimit, "Max redeem should be limited by module");
        assertEq(vault.maxRedeem(fish, 23, new address[](0)), newLimit, "Max redeem with params should be limited");
        assertEq(vault.maxRedeem(bunny, 0, new address[](0)), 0, "Max redeem for bunny should still be 0");
    }

    function testDepositWithMaxUint() public {
        uint256 assets = fishAmount;

        assertEq(asset.balanceOf(fish), fishAmount, "Fish should have initial balance");

        vm.startPrank(fish);
        asset.approve(address(vault), assets);

        vault.deposit(MAX_INT, fish);
        vm.stopPrank();

        assertEq(vault.balanceOf(fish), assets, "Fish should receive shares equal to assets");
        assertEq(asset.balanceOf(address(vault)), assets, "Vault should have the assets");
    }

    function testDepositWithDepositLimitModule() public {
        // Create vault with zero deposit limit
        vm.prank(gov);
        vault.setDepositLimit(0, false);

        MockDepositLimitModule limitModule = deployLimitModule();
        uint256 assets = fishAmount;

        // Approve assets
        vm.prank(fish);
        asset.approve(address(vault), assets);

        // Set max deposit limit and add module
        vm.startPrank(gov);
        vault.setDepositLimit(MAX_INT, false);
        vault.setDepositLimitModule(address(limitModule), false);
        vm.stopPrank();

        // Enable allowset and make deposit fail
        vm.prank(gov);
        limitModule.setEnforceAllowset(true);

        assertEq(vault.maxDeposit(fish), 0, "Max deposit should be 0 for non-inAllowset");

        vm.prank(fish);
        vm.expectRevert(IMultistrategyVault.ExceedDepositLimit.selector);
        vault.deposit(assets, fish);

        // Allowset fish and make deposit succeed
        vm.prank(gov);
        limitModule.setAllowset(fish);

        assertEq(vault.maxDeposit(fish), MAX_INT, "Max deposit should be MAX_INT for inAllowset");

        // Now deposit should succeed
        vm.prank(fish);
        vault.deposit(assets, fish);

        assertEq(vault.balanceOf(fish), assets, "Fish should receive shares equal to assets");
        assertEq(asset.balanceOf(address(vault)), assets, "Vault should have the assets");
    }

    function testMintWithDepositLimitModule() public {
        // Create vault with zero deposit limit
        vm.prank(gov);
        vault.setDepositLimit(0, false);

        MockDepositLimitModule limitModule = deployLimitModule();
        uint256 assets = fishAmount;

        // Approve assets
        vm.prank(fish);
        asset.approve(address(vault), assets);

        // Set max deposit limit and add module
        vm.startPrank(gov);
        vault.setDepositLimit(MAX_INT, false);
        vault.setDepositLimitModule(address(limitModule), false);
        vm.stopPrank();

        // Enable allowset and make mint fail
        vm.prank(gov);
        limitModule.setEnforceAllowset(true);

        assertEq(vault.maxMint(fish), 0, "Max mint should be 0 for non-inAllowset");

        vm.prank(fish);
        vm.expectRevert(IMultistrategyVault.ExceedDepositLimit.selector);
        vault.mint(assets, fish);

        // Allowset fish and make mint succeed
        vm.prank(gov);
        limitModule.setAllowset(fish);

        assertEq(vault.maxMint(fish), MAX_INT, "Max mint should be MAX_INT for inAllowset");

        // Now mint should succeed
        vm.prank(fish);

        vault.mint(assets, fish);

        assertEq(vault.balanceOf(fish), assets, "Fish should receive shares equal to assets");
        assertEq(asset.balanceOf(address(vault)), assets, "Vault should have the assets");
    }

    function testWithdrawWithWithdrawLimitModule() public {
        uint256 assets = fishAmount;

        // Setup withdraw limit module
        MockWithdrawLimitModule limitModule = deployWithdrawLimitModule();

        // Make deposit first
        userDeposit(fish, assets);

        // Set withdraw limit module
        vm.prank(gov);
        vault.addRole(gov, IMultistrategyVault.Roles.WITHDRAW_LIMIT_MANAGER);

        vm.prank(gov);
        vault.setWithdrawLimitModule(address(limitModule));

        // Initially, max withdraw equals assets (full balance)
        assertEq(vault.maxWithdraw(fish, 0, new address[](0)), assets, "Initial max withdraw should equal assets");

        // Set limit to 0 to force a failure
        vm.prank(gov);
        limitModule.setDefaultWithdrawLimit(0);

        assertEq(vault.maxWithdraw(fish, 0, new address[](0)), 0, "Max withdraw should be 0 with 0 limit");

        // Attempt withdraw - should fail
        vm.prank(fish);
        vm.expectRevert(IMultistrategyVault.ExceedWithdrawLimit.selector);
        vault.withdraw(assets, fish, fish, 0, new address[](0));

        // Now set limit to match assets for successful withdraw
        vm.prank(gov);
        limitModule.setDefaultWithdrawLimit(assets);

        assertEq(
            vault.maxWithdraw(fish, 0, new address[](0)),
            assets,
            "Max withdraw should equal assets with matching limit"
        );

        // Withdraw should succeed now
        vm.prank(fish);

        vault.withdraw(assets, fish, fish, 0, new address[](0));

        assertEq(vault.balanceOf(fish), 0, "Fish should have 0 shares after full withdrawal");
        assertEq(asset.balanceOf(address(vault)), 0, "Vault should have 0 assets after full withdrawal");
        assertEq(asset.balanceOf(fish), assets, "Fish should have all assets after withdrawal");
    }

    function testRedeemWithWithdrawLimitModule() public {
        uint256 assets = fishAmount;
        uint256 shares = assets; // 1:1 ratio initially

        // Setup withdraw limit module
        MockWithdrawLimitModule limitModule = deployWithdrawLimitModule();

        // Make deposit first
        userDeposit(fish, assets);

        // Set withdraw limit module
        vm.prank(gov);
        vault.addRole(gov, IMultistrategyVault.Roles.WITHDRAW_LIMIT_MANAGER);

        vm.prank(gov);
        vault.setWithdrawLimitModule(address(limitModule));

        // Initially, max redeem equals shares (full balance)
        assertEq(vault.maxRedeem(fish, 0, new address[](0)), shares, "Initial max redeem should equal shares");

        // Set limit to 0 to force a failure
        vm.prank(gov);
        limitModule.setDefaultWithdrawLimit(0);

        assertEq(vault.maxRedeem(fish, 0, new address[](0)), 0, "Max redeem should be 0 with 0 limit");

        // Attempt redeem - should fail
        vm.prank(fish);
        vm.expectRevert(IMultistrategyVault.ExceedWithdrawLimit.selector);
        vault.redeem(shares, fish, fish, 0, new address[](0));

        // Now set limit to match shares for successful redeem
        vm.prank(gov);
        limitModule.setDefaultWithdrawLimit(shares);

        assertEq(
            vault.maxRedeem(fish, 0, new address[](0)),
            shares,
            "Max redeem should equal shares with matching limit"
        );

        // Redeem should succeed now
        vm.prank(fish);
        vault.redeem(shares, fish, fish, 0, new address[](0));

        assertEq(vault.balanceOf(fish), 0, "Fish should have 0 shares after full redemption");
        assertEq(asset.balanceOf(address(vault)), 0, "Vault should have 0 assets after full redemption");
        assertEq(asset.balanceOf(fish), assets, "Fish should have all assets after redemption");
    }
}
