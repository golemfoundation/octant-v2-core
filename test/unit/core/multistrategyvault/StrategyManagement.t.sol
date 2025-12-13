// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockYieldStrategy } from "test/mocks/zodiac-core/MockYieldStrategy.sol";
import { Constants } from "test/unit/utils/constants.sol";
import { Checks } from "test/unit/utils/checks.sol";

contract StrategyManagementTest is Test {
    MultistrategyVault vaultImplementation;
    MultistrategyVault vault;
    MockERC20 asset;
    MockERC20 mockToken;
    MockYieldStrategy strategy;
    MultistrategyVaultFactory vaultFactory;
    address gov;
    address user;
    uint256 userAmount;

    function setUp() public {
        gov = address(this);
        user = makeAddr("user");
        userAmount = 1e18;

        asset = new MockERC20(18);
        mockToken = new MockERC20(18); // Different asset for tests

        vaultImplementation = new MultistrategyVault();
        vaultFactory = new MultistrategyVaultFactory("Test Vault", address(vaultImplementation), gov);

        // Create and initialize the vault
        vault = MultistrategyVault(vaultFactory.deployNewVault(address(asset), "Test Vault", "tvTEST", gov, 7 days));

        // Set up roles for governance
        vault.add_role(gov, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.REVOKE_STRATEGY_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.FORCE_REVOKE_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEBT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.REPORTING_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.MAX_DEBT_MANAGER);

        vault.set_deposit_limit(type(uint256).max, true);
        // Create initial strategy
        strategy = new MockYieldStrategy(address(asset), address(vault));

        // Add initial strategy to vault
        vault.add_strategy(address(strategy), true);

        // Give user some tokens
        asset.mint(user, userAmount);
    }

    function createStrategy(address assetAddress) internal returns (MockYieldStrategy) {
        return new MockYieldStrategy(assetAddress, address(vault));
    }

    function createGenericStrategy(address assetAddress) internal returns (MockYieldStrategy) {
        return new MockYieldStrategy(assetAddress, address(0)); // No vault specified
    }

    function mintAndDepositIntoVault() internal returns (uint256) {
        vm.startPrank(user);
        asset.approve(address(vault), userAmount);
        vault.deposit(userAmount, user);
        vm.stopPrank();
        return userAmount;
    }

    function addDebtToStrategy(MockYieldStrategy strat, uint256 amount) internal {
        vault.update_debt(address(strat), amount, 0);
    }

    // Test Cases

    function testAddStrategyWithValidStrategy() public {
        MockYieldStrategy newStrategy = createStrategy(address(asset));

        uint256 snapshot = block.timestamp;
        vm.expectEmit(true, true, true, true);
        emit IMultistrategyVault.StrategyChanged(address(newStrategy), Constants.STRATEGY_CHANGE_ADDED);
        vault.add_strategy(address(newStrategy), false);

        IMultistrategyVault.StrategyParams memory strategyParams = vault.strategies(address(newStrategy));
        assertEq(strategyParams.activation, snapshot);
        assertEq(strategyParams.currentDebt, 0);
        assertEq(strategyParams.maxDebt, 0);
        assertEq(strategyParams.lastReport, snapshot);
    }

    function testAddStrategyWithZeroAddressFails() public {
        vm.expectRevert(IMultistrategyVault.StrategyCannotBeZeroAddress.selector);
        vault.add_strategy(Constants.ZERO_ADDRESS, false);
    }

    function testAddStrategyWithActivationFails() public {
        vm.expectRevert(IMultistrategyVault.StrategyAlreadyActive.selector);
        vault.add_strategy(address(strategy), false);
    }

    function testAddStrategyWithIncorrectAssetFails() public {
        // Create strategy with the other vault's asset
        MockYieldStrategy mockTokenStrategy = createStrategy(address(mockToken));

        vm.expectRevert(IMultistrategyVault.InvalidAsset.selector);
        vault.add_strategy(address(mockTokenStrategy), false);
    }

    function testAddStrategyWithGenericStrategy() public {
        // Create strategy with same asset but no vault
        MockYieldStrategy genericStrategy = createGenericStrategy(address(asset));

        uint256 snapshot = block.timestamp;
        vm.expectEmit(true, true, true, true);
        emit IMultistrategyVault.StrategyChanged(address(genericStrategy), Constants.STRATEGY_CHANGE_ADDED);
        vault.add_strategy(address(genericStrategy), false);

        IMultistrategyVault.StrategyParams memory strategyParams = vault.strategies(address(genericStrategy));
        assertEq(strategyParams.activation, snapshot);
        assertEq(strategyParams.currentDebt, 0);
        assertEq(strategyParams.maxDebt, 0);
        assertEq(strategyParams.lastReport, snapshot);
    }

    function testRevokeStrategyWithExistingStrategy() public {
        vm.expectEmit(true, true, true, true);
        emit IMultistrategyVault.StrategyChanged(address(strategy), Constants.STRATEGY_CHANGE_REVOKED);
        vault.revoke_strategy(address(strategy));

        Checks.checkRevokedStrategy(vault, address(strategy));
    }

    function testRevokeStrategyWithNonZeroDebtFails() public {
        mintAndDepositIntoVault();
        uint256 vaultBalance = asset.balanceOf(address(vault));
        uint256 newDebt = vaultBalance;

        vault.update_max_debt_for_strategy(address(strategy), vaultBalance);

        addDebtToStrategy(strategy, newDebt);

        vm.expectRevert(IMultistrategyVault.StrategyHasDebt.selector);
        vault.revoke_strategy(address(strategy));
    }

    function testRevokeStrategyWithInactiveStrategyFails() public {
        MockYieldStrategy inactiveStrategy = createStrategy(address(asset));

        vm.expectRevert(IMultistrategyVault.StrategyNotActive.selector);
        vault.revoke_strategy(address(inactiveStrategy));
    }

    function testForceRevokeStrategyWithExistingStrategy() public {
        vm.expectEmit(true, true, true, true);
        emit IMultistrategyVault.StrategyChanged(address(strategy), Constants.STRATEGY_CHANGE_REVOKED);
        vault.force_revoke_strategy(address(strategy));

        Checks.checkRevokedStrategy(vault, address(strategy));
    }

    function testForceRevokeStrategyWithNonZeroDebt() public {
        // First deposit
        mintAndDepositIntoVault();
        uint256 vaultBalance = asset.balanceOf(address(vault));

        // THIS IS THE KEY FIX: Set the max debt for the strategy first
        vault.update_max_debt_for_strategy(address(strategy), vaultBalance);

        // Now update the debt - this will work since maxDebt is no longer 0
        vault.update_debt(address(strategy), vaultBalance, 0);

        // Verify debt is properly allocated
        assertEq(vault.strategies(address(strategy)).currentDebt, vaultBalance);

        // Now when we force revoke, it will emit the loss event
        vm.expectEmit(true, true, true, true);
        emit IMultistrategyVault.StrategyReported(address(strategy), 0, vaultBalance, 0, 0, 0, 0);

        vault.force_revoke_strategy(address(strategy));

        // Verify strategy was revoked and debt is cleared
        assertEq(vault.totalDebt(), 0);
        assertEq(vault.strategies(address(strategy)).activation, 0);
        assertEq(vault.strategies(address(strategy)).currentDebt, 0);
    }

    function testForceRevokeStrategyWithInactiveStrategyFails() public {
        MockYieldStrategy inactiveStrategy = createStrategy(address(asset));

        vm.expectRevert(IMultistrategyVault.StrategyNotActive.selector);
        vault.force_revoke_strategy(address(inactiveStrategy));
    }
}
