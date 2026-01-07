// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockLossyStrategy } from "test/mocks/core/MockLossyStrategy.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";

contract LossyStrategyFlowTest is Test {
    MultistrategyVault public vault;
    MockERC20 public asset;
    MockLossyStrategy public strategy;
    MultistrategyVaultFactory public vaultFactory;
    MultistrategyVault public vaultImplementation;

    address gov;
    address fish;
    address bunny;
    address strategist;

    uint256 fishAmount = 10_000e18;
    uint256 constant MAX_INT = type(uint256).max;

    function setUp() public {
        gov = address(0x1);
        fish = address(0x2);
        bunny = address(0x3);
        strategist = address(0x4);

        // Setup asset
        asset = new MockERC20(18);
        asset.mint(gov, 1_000_000e18);
        asset.mint(fish, fishAmount);

        vaultImplementation = new MultistrategyVault();
        vaultFactory = new MultistrategyVaultFactory("Test Factory", address(vaultImplementation), gov);

        // Create vault
        _createVault();
    }

    function testLossyStrategyFlow() public {
        address user1 = fish;
        address user2 = bunny;
        uint256 depositAmount = fishAmount;
        uint256 firstLoss = depositAmount / 4; // 25% loss
        uint256 secondLoss = depositAmount / 2; // 50% loss

        uint256 user1InitialBalance = asset.balanceOf(user1);

        // User1 (fish) deposits assets to vault
        _userDeposit(user1, depositAmount);

        assertEq(vault.balanceOf(user1), depositAmount, "User1 should have 1:1 shares");
        assertEq(vault.pricePerShare() / 10 ** asset.decimals(), 1, "Price per share should be 1:1");

        // Add all assets as debt to strategy
        _addDebtToStrategy(address(strategy), depositAmount);

        assertEq(strategy.totalAssets(), depositAmount, "Strategy should have all assets");
        assertEq(vault.totalAssets(), depositAmount, "Vault assets unchanged");

        // Simulate first loss on strategy
        vm.prank(gov);
        strategy.setLoss(firstLoss);

        assertEq(strategy.totalAssets(), depositAmount - firstLoss, "Strategy should reflect loss");

        // Process report
        vm.prank(gov);
        vault.process_report(address(strategy));

        // Price per share should reflect the loss (75% of original)
        assertEq(vault.pricePerShare(), 0.75e18, "Price per share should be 0.75");

        // User2 (bunny) deposits assets to vault
        _airdropAsset(user2, depositAmount);
        uint256 user2InitialBalance = asset.balanceOf(user2);
        _userDeposit(user2, depositAmount);

        assertEq(vault.totalAssets(), 2 * depositAmount - firstLoss, "Total assets should reflect loss");
        assertTrue(vault.balanceOf(user2) > vault.balanceOf(user1), "User2 should get more shares due to lower price");

        assertEq(vault.totalIdle(), depositAmount, "Idle should equal user2's deposit");
        assertEq(vault.totalDebt(), depositAmount - firstLoss, "Debt should reflect loss");
        // update max debt to 2 * depositAmount
        vm.prank(gov);
        vault.update_max_debt_for_strategy(address(strategy), 2 * depositAmount);

        // Add all assets to strategy
        _addDebtToStrategy(address(strategy), vault.totalAssets());

        assertEq(strategy.totalAssets(), 2 * depositAmount - firstLoss, "Strategy should have all assets");
        assertEq(vault.totalIdle(), 0, "Idle should be 0");
        assertEq(vault.totalDebt(), 2 * depositAmount - firstLoss, "Debt should equal total assets");

        // Simulate second loss
        vm.prank(gov);
        strategy.setLoss(secondLoss);

        assertEq(
            strategy.totalAssets(),
            2 * depositAmount - firstLoss - secondLoss,
            "Strategy should reflect both losses"
        );

        // Process report
        vm.prank(gov);
        vault.process_report(address(strategy));

        assertEq(
            vault.totalAssets(),
            2 * depositAmount - firstLoss - secondLoss,
            "Total assets should reflect both losses"
        );
        assertEq(vault.totalIdle(), 0, "Idle should still be 0");

        // Set minimum idle
        vm.prank(gov);
        vault.set_minimum_total_idle((3 * depositAmount) / 4);

        // Update debt to ensure minimum idle
        _addDebtToStrategy(address(strategy), depositAmount);

        assertEq(vault.totalIdle(), (3 * depositAmount) / 4, "Idle should match minimum");
        assertEq(
            strategy.totalAssets(),
            2 * depositAmount - firstLoss - secondLoss - vault.totalIdle(),
            "Strategy assets should be updated"
        );

        // User1 withdraws all shares
        uint256 user1Shares = vault.balanceOf(user1);
        vm.prank(user1);
        vault.redeem(user1Shares, user1, user1, 0, new address[](0));

        assertEq(vault.balanceOf(user1), 0, "User1 should have no shares left");

        // Calculate share ratio for loss impact
        uint256 shareRatio = ((depositAmount - firstLoss) * 1e18) / (2 * depositAmount - firstLoss);
        uint256 expectedUser1Balance = user1InitialBalance - firstLoss - (secondLoss * shareRatio) / 1e18;

        // Allow for slight rounding differences
        assertTrue(
            _isCloseTo(asset.balanceOf(user1), expectedUser1Balance, 1e14),
            "User1 balance should reflect proportional loss"
        );
        assertTrue(vault.totalIdle() < vault.minimumTotalIdle(), "Total idle should be below minimum");
        vm.prank(gov);
        vault.update_max_debt_for_strategy(address(strategy), depositAmount / 4);

        // Update debt to comply with minimum idle
        _addDebtToStrategy(address(strategy), depositAmount / 4);

        assertEq(strategy.totalAssets(), 0, "Strategy should have no assets");
        assertEq(vault.strategies(address(strategy)).currentDebt, 0, "Strategy should have no debt");
        assertEq(vault.strategies(address(strategy)).maxDebt, depositAmount / 4, "Max debt should be updated");

        // User2 withdraws
        vm.startPrank(user2);
        vm.expectRevert(IMultistrategyVault.InsufficientSharesToRedeem.selector);
        vault.withdraw(depositAmount, user2, user2, 0, new address[](0));

        vault.redeem(vault.balanceOf(user2), user2, user2, 0, new address[](0));
        vm.stopPrank();

        assertEq(vault.totalAssets(), 0, "Vault should have no assets");
        assertEq(vault.pricePerShare() / 10 ** vault.decimals(), 1, "Price per share should be 1:1");
        assertTrue(asset.balanceOf(user2) < user2InitialBalance, "User2 balance should reflect loss");

        // Revoke strategy
        vm.prank(gov);
        vault.revoke_strategy(address(strategy));

        assertEq(vault.strategies(address(strategy)).activation, 0, "Strategy should be deactivated");
    }

    function _createVault() internal {
        vm.startPrank(gov);
        vault = MultistrategyVault(vaultFactory.deployNewVault(address(asset), "Test Vault", "vTST", gov, 7 days));

        // Add roles to gov
        vault.add_role(gov, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.REVOKE_STRATEGY_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.FORCE_REVOKE_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEBT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.ACCOUNTANT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.REPORTING_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.WITHDRAW_LIMIT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.MAX_DEBT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.MINIMUM_IDLE_MANAGER);

        strategy = _createLossyStrategy();

        // Set deposit limit to max
        vault.set_deposit_limit(type(uint256).max, true);
        vault.add_strategy(address(strategy), true);
        vault.update_max_debt_for_strategy(address(strategy), fishAmount);
        vm.stopPrank();
    }

    function _createLossyStrategy() internal returns (MockLossyStrategy) {
        // Note: MockLossyStrategy constructor only takes asset and vault
        return new MockLossyStrategy(address(asset), address(vault));
    }

    function _userDeposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        asset.approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();
    }

    function _addStrategyToVault(address strategyAddress) internal {
        vm.prank(gov);
        vault.add_strategy(strategyAddress, true);
    }

    function _addDebtToStrategy(address strategyAddress, uint256 amount) internal {
        vm.prank(gov);
        vault.update_debt(strategyAddress, amount, 0);
    }

    function _airdropAsset(address to, uint256 amount) internal {
        vm.prank(gov);
        asset.mint(to, amount);
    }

    function _isCloseTo(uint256 a, uint256 b, uint256 tolerance) internal pure returns (bool) {
        if (a > b) {
            return a - b <= tolerance;
        } else {
            return b - a <= tolerance;
        }
    }
}
