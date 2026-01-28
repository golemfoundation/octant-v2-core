// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockYieldStrategy } from "test/mocks/zodiac-core/MockYieldStrategy.sol";
import { MockLockedStrategy } from "test/mocks/core/MockLockedStrategy.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";

contract MultipleStrategyWithdrawFlowTest is Test {
    uint256 constant DAY = 1 days;

    MultistrategyVault public vault;
    MockERC20 public asset;
    MockYieldStrategy public liquidStrategy;
    MockLockedStrategy public lockedStrategy;
    MultistrategyVaultFactory public vaultFactory;
    MultistrategyVault public vaultImplementation;

    address public gov;
    address public fish;
    address public whale;
    address public bunny;

    uint256 public fishAmount;
    uint256 public whaleAmount;

    function setUp() public {
        gov = address(0x1);
        fish = address(0x2);
        whale = address(0x3);
        bunny = address(0x4);

        fishAmount = 1_000e18;
        whaleAmount = 3_000e18;

        // Setup asset
        asset = new MockERC20(18);
        asset.mint(gov, 1_000_000e18);
        asset.mint(fish, fishAmount);
        asset.mint(whale, whaleAmount);

        vaultImplementation = new MultistrategyVault();
        vaultFactory = new MultistrategyVaultFactory("Test Factory", address(vaultImplementation), gov);
    }

    function testMultipleStrategyWithdrawFlow() public {
        // Create vault
        _createVault();

        uint256 vaultBalance = fishAmount + whaleAmount;
        uint256 liquidStrategyDebt = vaultBalance / 4; // deposit a quarter
        uint256 lockedStrategyDebt = vaultBalance / 2; // deposit half
        uint256 amountToLock = lockedStrategyDebt / 2;

        // Setup strategies
        liquidStrategy = new MockYieldStrategy(address(asset), address(vault));
        lockedStrategy = new MockLockedStrategy(address(asset), address(vault));

        // Deposit assets to vault
        _userDeposit(fish, fishAmount);
        _userDeposit(whale, whaleAmount);

        // Set up strategies
        vm.startPrank(gov);
        vault.add_role(gov, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEBT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.MAX_DEBT_MANAGER);

        vault.add_strategy(address(liquidStrategy), true);
        vault.add_strategy(address(lockedStrategy), true);

        // Set max debt and allocate to strategies
        vault.update_max_debt_for_strategy(address(liquidStrategy), type(uint256).max);
        vault.update_max_debt_for_strategy(address(lockedStrategy), type(uint256).max);
        vault.update_debt(address(liquidStrategy), liquidStrategyDebt, 0);
        vault.update_debt(address(lockedStrategy), lockedStrategyDebt, 0);
        vm.stopPrank();

        // Lock half of assets in locked strategy
        vm.prank(gov);
        lockedStrategy.setLockedFunds(amountToLock, DAY);

        uint256 currentIdle = vaultBalance / 4;
        uint256 currentDebt = (vaultBalance * 3) / 4;

        // Check initial state
        assertEq(vault.totalIdle(), currentIdle, "Initial idle amount incorrect");
        assertEq(vault.totalDebt(), currentDebt, "Initial debt amount incorrect");
        assertEq(asset.balanceOf(address(vault)), currentIdle, "Initial vault balance incorrect");
        assertEq(
            asset.balanceOf(address(liquidStrategy)),
            liquidStrategyDebt,
            "Initial liquid strategy balance incorrect"
        );
        assertEq(
            asset.balanceOf(address(lockedStrategy)),
            lockedStrategyDebt,
            "Initial locked strategy balance incorrect"
        );

        // Withdraw small amount as fish from total idle
        address[] memory strategies = new address[](2);
        strategies[0] = address(lockedStrategy);
        strategies[1] = address(liquidStrategy);

        vm.prank(fish);
        vault.withdraw(fishAmount / 2, fish, fish, 0, strategies);

        currentIdle -= fishAmount / 2;

        // Check state after first withdrawal
        assertEq(asset.balanceOf(fish), fishAmount / 2, "Fish balance after first withdrawal incorrect");
        assertEq(vault.totalIdle(), currentIdle, "Idle amount after first withdrawal incorrect");
        assertEq(vault.totalDebt(), currentDebt, "Debt amount after first withdrawal incorrect");
        assertEq(asset.balanceOf(address(vault)), currentIdle, "Vault balance after first withdrawal incorrect");
        assertEq(
            asset.balanceOf(address(liquidStrategy)),
            liquidStrategyDebt,
            "Liquid strategy balance after first withdrawal incorrect"
        );
        assertEq(
            asset.balanceOf(address(lockedStrategy)),
            lockedStrategyDebt,
            "Locked strategy balance after first withdrawal incorrect"
        );

        // Drain remaining total idle as whale
        vm.prank(whale);
        vault.withdraw(currentIdle, whale, whale, 0, new address[](0));

        // Check state after draining idle
        assertEq(asset.balanceOf(whale), currentIdle, "Whale balance after draining idle incorrect");
        assertEq(vault.totalIdle(), 0, "Idle amount after draining should be 0");
        assertEq(vault.totalDebt(), currentDebt, "Debt amount after draining incorrect");
        assertEq(asset.balanceOf(address(vault)), 0, "Vault balance after draining should be 0");
        assertEq(
            asset.balanceOf(address(liquidStrategy)),
            liquidStrategyDebt,
            "Liquid strategy balance after draining incorrect"
        );
        assertEq(
            asset.balanceOf(address(lockedStrategy)),
            lockedStrategyDebt,
            "Locked strategy balance after draining incorrect"
        );

        // Withdraw small amount as fish from locked_strategy to bunny
        address[] memory lockedStrategyOnly = new address[](1);
        lockedStrategyOnly[0] = address(lockedStrategy);

        vm.prank(fish);
        vault.withdraw(fishAmount / 2, bunny, fish, 0, lockedStrategyOnly);

        currentDebt -= fishAmount / 2;
        lockedStrategyDebt -= fishAmount / 2;

        // Check state after withdrawal to bunny
        assertEq(asset.balanceOf(bunny), fishAmount / 2, "Bunny balance after withdrawal incorrect");
        assertEq(vault.totalIdle(), 0, "Idle amount after withdrawal to bunny should be 0");
        assertEq(vault.totalDebt(), currentDebt, "Debt amount after withdrawal to bunny incorrect");
        assertEq(asset.balanceOf(address(vault)), 0, "Vault balance after withdrawal to bunny should be 0");
        assertEq(
            asset.balanceOf(address(liquidStrategy)),
            liquidStrategyDebt,
            "Liquid strategy balance after withdrawal to bunny incorrect"
        );
        assertEq(
            asset.balanceOf(address(lockedStrategy)),
            lockedStrategyDebt,
            "Locked strategy balance after withdrawal to bunny incorrect"
        );

        // Attempt to withdraw remaining amount from only liquid strategy but revert
        uint256 whaleBalance = vault.balanceOf(whale) - amountToLock; // exclude locked amount
        address[] memory liquidStrategyOnly = new address[](1);
        liquidStrategyOnly[0] = address(liquidStrategy);

        vm.prank(whale);
        vm.expectRevert(IMultistrategyVault.InsufficientAssetsInVault.selector);
        vault.withdraw(whaleBalance, whale, whale, 0, liquidStrategyOnly);

        // Withdraw remaining balance using both strategies
        vm.prank(whale);
        vault.withdraw(whaleBalance, whale, whale, 0, strategies);

        // Check state after whale withdrawal
        assertEq(asset.balanceOf(whale), whaleAmount - amountToLock, "Whale balance after withdrawal incorrect");
        assertEq(vault.totalIdle(), 0, "Idle amount after whale withdrawal should be 0");
        assertEq(vault.totalDebt(), amountToLock, "Debt amount after whale withdrawal incorrect");
        assertEq(asset.balanceOf(address(vault)), 0, "Vault balance after whale withdrawal should be 0");
        assertEq(
            asset.balanceOf(address(liquidStrategy)),
            0,
            "Liquid strategy balance after whale withdrawal should be 0"
        );
        assertEq(
            asset.balanceOf(address(lockedStrategy)),
            amountToLock,
            "Locked strategy balance after whale withdrawal incorrect"
        );

        // Unlock locked strategy assets
        vm.warp(block.timestamp + DAY);
        vm.prank(gov);
        lockedStrategy.freeLockedFunds();

        // Withdraw newly unlocked funds (test withdrawing from empty strategy)
        vm.prank(whale);
        vault.withdraw(amountToLock, whale, whale, 0, strategies);

        // Check final state
        assertEq(asset.balanceOf(whale), whaleAmount, "Final whale balance incorrect");
        assertEq(vault.totalAssets(), 0, "Final vault assets should be 0");
        assertEq(vault.totalSupply(), 0, "Final vault supply should be 0");
        assertEq(vault.totalIdle(), 0, "Final idle amount should be 0");
        assertEq(vault.totalDebt(), 0, "Final debt amount should be 0");
        assertEq(asset.balanceOf(address(vault)), 0, "Final vault balance should be 0");
        assertEq(asset.balanceOf(address(liquidStrategy)), 0, "Final liquid strategy balance should be 0");
        assertEq(asset.balanceOf(address(lockedStrategy)), 0, "Final locked strategy balance should be 0");
    }

    function _createVault() internal {
        vm.startPrank(gov);
        vault = MultistrategyVault(vaultFactory.deployNewVault(address(asset), "Test Vault", "vTST", gov, 7 days));

        // Set deposit limit to max
        vault.add_role(gov, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);
        vault.set_deposit_limit(type(uint256).max, true);
        vm.stopPrank();
    }

    function _userDeposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        asset.approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();
    }
}
