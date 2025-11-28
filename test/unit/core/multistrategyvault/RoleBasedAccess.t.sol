// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockYieldStrategy } from "test/mocks/zodiac-core/MockYieldStrategy.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";

import { MockAccountant } from "test/mocks/core/MockAccountant.sol";
import { MockFlexibleAccountant } from "test/mocks/core/MockFlexibleAccountant.sol";

contract RoleBasedAccessTest is Test {
    MultistrategyVault vaultImplementation;
    MultistrategyVault vault;
    MockERC20 public asset;
    MockYieldStrategy public strategy;
    MockAccountant public accountant;
    MockFlexibleAccountant public flexibleAccountant;
    MultistrategyVaultFactory vaultFactory;

    address public gov = address(0x1);
    address public bunny = address(0x4); // Added bunny address for role testing
    address public feeRecipient = address(0x3);

    uint256 fishAmount = 10_000e18;
    uint256 MAX_BPS = 10_000;
    uint256 constant DAY = 1 days;
    uint256 constant WEEK = 7 days;
    uint256 constant YEAR = 365 days;
    uint256 constant MAX_INT = type(uint256).max;
    address constant ZERO_ADDRESS = address(0);

    function setUp() public {
        // Setup asset
        asset = new MockERC20(18);
        asset.mint(gov, 1_000_000e18);

        // deploy vault implementation
        vaultImplementation = new MultistrategyVault();

        // deploy factory
        vm.prank(gov);
        vaultFactory = new MultistrategyVaultFactory("Test Vault", address(vaultImplementation), gov);

        flexibleAccountant = new MockFlexibleAccountant(address(asset));

        // Deploy vault
        vm.startPrank(address(vaultFactory));
        vault = MultistrategyVault(vaultFactory.deployNewVault(address(asset), "Test Vault", "vTST", gov, 7 days));
        vm.stopPrank();

        vm.startPrank(gov);
        // Gov has all needed roles by default for setup
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

        // Setup default strategy
        strategy = new MockYieldStrategy(address(asset), address(vault));
        vault.add_strategy(address(strategy), true);

        // Set deposit limit to max
        vault.set_deposit_limit(type(uint256).max, true);

        vm.stopPrank();
    }

    function createStrategy() internal returns (address) {
        MockYieldStrategy newStrategy = new MockYieldStrategy(address(asset), address(vault));
        return address(newStrategy);
    }

    // STRATEGY MANAGEMENT TESTS

    function testAddStrategyNoAddStrategyManagerReverts() public {
        address newStrategy = createStrategy();
        vm.prank(bunny);
        vm.expectRevert(IMultistrategyVault.NotAllowed.selector);
        vault.add_strategy(newStrategy, true);
    }

    function testAddStrategyAddStrategyManager() public {
        // Give bunny the ADD_STRATEGY_MANAGER role
        vm.prank(gov);
        vault.add_role(bunny, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);

        // Use bunny to add a strategy
        address newStrategy = createStrategy();
        vm.prank(bunny);
        vault.add_strategy(newStrategy, true);

        // Verify strategy is active
        IMultistrategyVault.StrategyParams memory params = vault.strategies(newStrategy);
        assertGt(params.activation, 0, "Strategy should be active");
    }

    function testRevokeStrategyNoRevokeStrategyManagerReverts() public {
        vm.prank(bunny);
        vm.expectRevert(IMultistrategyVault.NotAllowed.selector);
        vault.revoke_strategy(address(strategy));
    }

    function testRevokeStrategyRevokeStrategyManager() public {
        // Give bunny the REVOKE_STRATEGY_MANAGER role
        vm.prank(gov);
        vault.add_role(bunny, IMultistrategyVault.Roles.REVOKE_STRATEGY_MANAGER);

        // Use bunny to revoke a strategy
        vm.prank(bunny);
        vault.revoke_strategy(address(strategy));

        // Verify strategy is inactive
        IMultistrategyVault.StrategyParams memory params = vault.strategies(address(strategy));
        assertEq(params.activation, 0, "Strategy should be inactive");
    }

    function testForceRevokeStrategyNoRevokeStrategyManagerReverts() public {
        vm.prank(bunny);
        vm.expectRevert(IMultistrategyVault.NotAllowed.selector);
        vault.force_revoke_strategy(address(strategy));
    }

    function testForceRevokeStrategyRevokeStrategyManager() public {
        // Give bunny the FORCE_REVOKE_MANAGER role
        vm.prank(gov);
        vault.add_role(bunny, IMultistrategyVault.Roles.FORCE_REVOKE_MANAGER);

        // Use bunny to force revoke a strategy
        vm.prank(bunny);
        vault.force_revoke_strategy(address(strategy));

        // Verify strategy is inactive
        IMultistrategyVault.StrategyParams memory params = vault.strategies(address(strategy));
        assertEq(params.activation, 0, "Strategy should be inactive");
    }

    // ACCOUNTING MANAGEMENT TESTS

    function testSetMinimumTotalIdleNoMinIdleManagerReverts() public {
        uint256 minimumTotalIdle = 1;
        vm.prank(bunny);
        vm.expectRevert(IMultistrategyVault.NotAllowed.selector);
        vault.set_minimum_total_idle(minimumTotalIdle);
    }

    function testSetMinimumTotalIdleMinIdleManager() public {
        // Give bunny the MINIMUM_IDLE_MANAGER role
        vm.prank(gov);
        vault.add_role(bunny, IMultistrategyVault.Roles.MINIMUM_IDLE_MANAGER);

        // Verify initial value
        assertEq(vault.minimumTotalIdle(), 0, "Initial minimum total idle should be 0");

        // Use bunny to set minimum total idle
        uint256 minimumTotalIdle = 1;
        vm.prank(bunny);
        vault.set_minimum_total_idle(minimumTotalIdle);

        // Verify new value
        assertEq(vault.minimumTotalIdle(), minimumTotalIdle, "Minimum total idle should be updated");
    }

    function testUpdateMaxDebtNoDebtManagerReverts() public {
        assertEq(vault.strategies(address(strategy)).maxDebt, 0, "Initial max debt should be 0");
        uint256 maxDebtForStrategy = 1;

        vm.prank(bunny);
        vm.expectRevert(IMultistrategyVault.NotAllowed.selector);
        vault.update_max_debt_for_strategy(address(strategy), maxDebtForStrategy);
    }

    function testUpdateMaxDebtMaxDebtManager() public {
        // Give bunny the MAX_DEBT_MANAGER role
        vm.prank(gov);
        vault.add_role(bunny, IMultistrategyVault.Roles.MAX_DEBT_MANAGER);

        // Verify initial value
        assertEq(vault.strategies(address(strategy)).maxDebt, 0, "Initial max debt should be 0");

        // Use bunny to update max debt
        uint256 maxDebtForStrategy = 1;
        vm.prank(bunny);
        vault.update_max_debt_for_strategy(address(strategy), maxDebtForStrategy);

        // Verify new value
        assertEq(vault.strategies(address(strategy)).maxDebt, maxDebtForStrategy, "Max debt should be updated");
    }

    // DEPOSIT AND WITHDRAW LIMITS TESTS

    function testSetDepositLimitNoDepositLimitManagerReverts() public {
        uint256 depositLimit = 1;
        vm.prank(bunny);
        vm.expectRevert(IMultistrategyVault.NotAllowed.selector);
        vault.set_deposit_limit(depositLimit, false);
    }

    function testSetDepositLimitDepositLimitManager() public {
        // Give bunny the DEPOSIT_LIMIT_MANAGER role
        vm.prank(gov);
        vault.add_role(bunny, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);

        // Get initial deposit limit
        uint256 initialDepositLimit = vault.depositLimit();
        uint256 newDepositLimit = 1;
        assertTrue(initialDepositLimit != newDepositLimit, "Initial deposit limit should be different");

        // Use bunny to set deposit limit
        vm.prank(bunny);
        vault.set_deposit_limit(newDepositLimit, false);

        // Verify new value
        assertEq(vault.depositLimit(), newDepositLimit, "Deposit limit should be updated");
    }

    function testSetDepositLimitWithLimitModuleReverts() public {
        // Give bunny the DEPOSIT_LIMIT_MANAGER role
        vm.prank(gov);
        vault.add_role(bunny, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);

        uint256 depositLimit = 1;

        // Set deposit limit module
        vm.prank(gov);
        vault.set_deposit_limit_module(bunny, false);

        // Try to set deposit limit without override
        vm.prank(bunny);
        vm.expectRevert(IMultistrategyVault.UsingModule.selector);
        vault.set_deposit_limit(depositLimit, false);
    }

    function testSetDepositLimitWithLimitModuleOverride() public {
        // Give bunny the DEPOSIT_LIMIT_MANAGER role
        vm.prank(gov);
        vault.add_role(bunny, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);

        uint256 depositLimit = 1;

        // Set deposit limit module
        vm.prank(gov);
        vault.set_deposit_limit_module(bunny, true);

        // Verify initial state
        assertEq(vault.depositLimitModule(), bunny, "Deposit limit module should be set to bunny");

        // Set deposit limit with override
        vm.prank(bunny);
        vault.set_deposit_limit(depositLimit, true);

        // Verify new state
        assertEq(vault.depositLimit(), depositLimit, "Deposit limit should be updated");
        assertEq(vault.depositLimitModule(), ZERO_ADDRESS, "Deposit limit module should be cleared");
    }

    function testSetDepositLimitModuleNoDepositLimitManagerReverts() public {
        vm.prank(bunny);
        vm.expectRevert(IMultistrategyVault.NotAllowed.selector);
        vault.set_deposit_limit_module(bunny, false);
    }

    function testSetDepositLimitModuleDepositLimitManager() public {
        // Give bunny the DEPOSIT_LIMIT_MANAGER role
        vm.prank(gov);
        vault.add_role(bunny, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);

        // Verify initial state
        assertEq(vault.depositLimitModule(), ZERO_ADDRESS, "Initial deposit limit module should be zero address");

        // Set deposit limit module
        vm.prank(bunny);
        vault.set_deposit_limit_module(bunny, true);

        // Verify new state
        assertEq(vault.depositLimitModule(), bunny, "Deposit limit module should be set");
    }

    function testSetDepositLimitModuleWithLimitReverts() public {
        // Give bunny the DEPOSIT_LIMIT_MANAGER role
        vm.prank(gov);
        vault.add_role(bunny, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);

        // Set deposit limit
        vm.prank(gov);
        vault.set_deposit_limit(1, false);

        // Try to set deposit limit module without override
        vm.prank(gov);
        vm.expectRevert(IMultistrategyVault.UsingDepositLimit.selector);
        vault.set_deposit_limit_module(bunny, false);
    }

    function testSetDepositLimitModuleWithLimitOverride() public {
        // Give bunny the DEPOSIT_LIMIT_MANAGER role
        vm.prank(gov);
        vault.add_role(bunny, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);

        // Set deposit limit
        vm.prank(gov);
        vault.set_deposit_limit(1, false);

        // Set deposit limit module with override
        vm.prank(gov);
        vault.set_deposit_limit_module(bunny, true);

        // Verify new state
        assertEq(vault.depositLimit(), MAX_INT, "Deposit limit should be set to MAX_INT");
        assertEq(vault.depositLimitModule(), bunny, "Deposit limit module should be set");
    }

    function testSetWithdrawLimitModuleNoWithdrawLimitManagerReverts() public {
        vm.prank(bunny);
        vm.expectRevert(IMultistrategyVault.NotAllowed.selector);
        vault.set_withdraw_limit_module(bunny);
    }

    function testSetWithdrawLimitModuleWithdrawLimitManager() public {
        // Give bunny the WITHDRAW_LIMIT_MANAGER role
        vm.prank(gov);
        vault.add_role(bunny, IMultistrategyVault.Roles.WITHDRAW_LIMIT_MANAGER);

        // Verify initial state
        assertEq(vault.withdrawLimitModule(), ZERO_ADDRESS, "Initial withdraw limit module should be zero address");

        // Set withdraw limit module
        vm.prank(bunny);
        vault.set_withdraw_limit_module(bunny);

        // Verify new state
        assertEq(vault.withdrawLimitModule(), bunny, "Withdraw limit module should be set");
    }

    // DEBT_PURCHASER TESTS

    function testBuyDebtNoDebtPurchaserReverts() public {
        vm.prank(bunny);
        vm.expectRevert(IMultistrategyVault.NotAllowed.selector);
        vault.buy_debt(address(strategy), 0);
    }

    function testBuyDebtDebtPurchaser() public {
        uint256 amount = fishAmount;

        // Give bunny the DEBT_PURCHASER role
        vm.prank(gov);
        vault.add_role(bunny, IMultistrategyVault.Roles.DEBT_PURCHASER);

        // Deposit into vault
        asset.mint(gov, amount);
        vm.startPrank(gov);
        asset.approve(address(vault), amount);
        vault.deposit(amount, gov);
        vm.stopPrank();

        // Set max debt for the strategy first
        vm.prank(gov);
        vault.update_max_debt_for_strategy(address(strategy), amount);

        // Add debt to strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), amount, 0);

        // Mint and approve tokens for bunny
        asset.mint(bunny, amount);
        vm.prank(bunny);
        asset.approve(address(vault), amount);

        // Buy debt
        vm.prank(bunny);
        vault.buy_debt(address(strategy), amount);

        // Verify strategy debt is now 0
        IMultistrategyVault.StrategyParams memory params = vault.strategies(address(strategy));
        assertEq(params.currentDebt, 0, "Strategy debt should be 0 after purchase");
    }

    // DEBT_MANAGER TESTS

    function testUpdateDebtNoDebtManagerReverts() public {
        vm.prank(bunny);
        vm.expectRevert(IMultistrategyVault.NotAllowed.selector);
        vault.update_debt(address(strategy), 1e18, 0);
    }

    function testUpdateDebtDebtManager() public {
        // Give bunny the DEBT_MANAGER role
        vm.prank(gov);
        vault.add_role(bunny, IMultistrategyVault.Roles.DEBT_MANAGER);

        // Provide vault with funds
        asset.mint(gov, 1e18);
        vm.startPrank(gov);
        asset.approve(address(vault), 1e18);
        vault.deposit(1e18, gov);
        vm.stopPrank();

        // Set max debt for strategy
        uint256 maxDebtForStrategy = 1;
        vm.prank(gov);
        vault.update_max_debt_for_strategy(address(strategy), maxDebtForStrategy);

        // Update debt with bunny
        vm.prank(bunny);
        vault.update_debt(address(strategy), maxDebtForStrategy, 0);

        // Verify strategy debt
        IMultistrategyVault.StrategyParams memory params = vault.strategies(address(strategy));
        assertEq(params.currentDebt, maxDebtForStrategy, "Strategy debt should be updated");
    }

    // EMERGENCY_MANAGER TESTS

    function testShutdownVaultNoEmergencyManagerReverts() public {
        vm.prank(bunny);
        vm.expectRevert(IMultistrategyVault.NotAllowed.selector);
        vault.shutdown_vault();
    }

    function testShutdownVaultEmergencyManager() public {
        // Give bunny the EMERGENCY_MANAGER role
        vm.prank(gov);
        vault.add_role(bunny, IMultistrategyVault.Roles.EMERGENCY_MANAGER);

        // Verify initial state
        assertFalse(vault.isShutdown(), "Vault should not be shutdown initially");

        uint256 initialRoles = vault.roles(bunny);

        // Shutdown vault with bunny
        vm.prank(bunny);
        vault.shutdown_vault();

        // Verify bunny now has both EMERGENCY_MANAGER and DEBT_MANAGER roles
        uint256 bunnyRoles = vault.roles(bunny);

        // The expected value is 8256 = EMERGENCY_MANAGER (8192) | DEBT_MANAGER (64)
        uint256 expectedRoles = initialRoles | (1 << uint256(IMultistrategyVault.Roles.DEBT_MANAGER));

        assertEq(bunnyRoles, expectedRoles, "Bunny should have both EMERGENCY_MANAGER and DEBT_MANAGER roles");
    }

    // REPORTING_MANAGER TESTS

    function testProcessReportNoReportingManagerReverts() public {
        vm.prank(bunny);
        vm.expectRevert(IMultistrategyVault.NotAllowed.selector);
        vault.process_report(address(strategy));
    }

    function testProcessReportReportingManager() public {
        // Give bunny the REPORTING_MANAGER role
        vm.prank(gov);
        vault.add_role(bunny, IMultistrategyVault.Roles.REPORTING_MANAGER);

        // Deposit into vault
        asset.mint(gov, 1e18);
        vm.startPrank(gov);
        asset.approve(address(vault), 1e18);
        vault.deposit(1e18, gov);
        vm.stopPrank();

        // Add debt to strategy
        vm.prank(gov);
        vault.update_debt(address(strategy), 2, 0);

        // Airdrop gain to strategy
        asset.mint(address(strategy), 1);

        // Report from strategy
        vm.prank(gov);
        MockYieldStrategy(address(strategy)).report();

        // Process report with bunny
        vm.prank(bunny);
        vault.process_report(address(strategy));

        // should not revert
    }

    // ACCOUNTANT_MANAGER TESTS

    function testSetAccountantNoAccountantManagerReverts() public {
        vm.prank(bunny);
        vm.expectRevert(IMultistrategyVault.NotAllowed.selector);
        vault.set_accountant(bunny);
    }

    function testSetAccountantAccountantManager() public {
        // Give bunny the ACCOUNTANT_MANAGER role
        vm.prank(gov);
        vault.add_role(bunny, IMultistrategyVault.Roles.ACCOUNTANT_MANAGER);

        // Verify initial state
        assertNotEq(vault.accountant(), bunny, "Accountant should not be bunny initially");

        // Set accountant with bunny
        vm.prank(bunny);
        vault.set_accountant(bunny);

        // Verify new state
        assertEq(vault.accountant(), bunny, "Accountant should be set to bunny");
    }

    // QUEUE_MANAGER TESTS

    function testSetDefaultQueueNoQueueManagerReverts() public {
        vm.prank(bunny);
        vm.expectRevert(IMultistrategyVault.NotAllowed.selector);
        vault.set_default_queue(new address[](0));
    }

    function testUseDefaultQueueNoQueueManagerReverts() public {
        vm.prank(bunny);
        vm.expectRevert(IMultistrategyVault.NotAllowed.selector);
        vault.set_use_default_queue(true);
    }

    function testSetDefaultQueueQueueManager() public {
        // Give bunny the QUEUE_MANAGER role
        vm.prank(gov);
        vault.add_role(bunny, IMultistrategyVault.Roles.QUEUE_MANAGER);

        // Get initial queue
        address[] memory initialQueue = vault.defaultQueue();
        assertGt(initialQueue.length, 0, "Initial queue should not be empty");

        // Set default queue with bunny
        vm.prank(bunny);
        vault.set_default_queue(new address[](0));

        // Verify new state
        address[] memory newQueue = vault.defaultQueue();
        assertEq(newQueue.length, 0, "Queue should be empty after setting");
    }

    function testSetUseDefaultQueueQueueManager() public {
        // Give bunny the QUEUE_MANAGER role
        vm.prank(gov);
        vault.add_role(bunny, IMultistrategyVault.Roles.QUEUE_MANAGER);

        // Verify initial state
        assertFalse(vault.useDefaultQueue(), "Use default queue should be false initially");

        // Set use default queue with bunny
        vm.prank(bunny);

        vault.set_use_default_queue(true);

        assertTrue(vault.useDefaultQueue(), "Use default queue should be true after setting");
    }

    // PROFIT_UNLOCK_MANAGER TESTS

    function testSetProfitUnlockNoProfitUnlockManagerReverts() public {
        vm.prank(bunny);
        vm.expectRevert(IMultistrategyVault.NotAllowed.selector);
        vault.setProfitMaxUnlockTime(WEEK / 2);
    }

    function testSetProfitUnlockProfitUnlockManager() public {
        // Give bunny the PROFIT_UNLOCK_MANAGER role
        vm.prank(gov);
        vault.add_role(bunny, IMultistrategyVault.Roles.PROFIT_UNLOCK_MANAGER);

        // Set profit unlock time
        uint256 time = WEEK / 2;
        assertNotEq(vault.profitMaxUnlockTime(), time, "Initial profit unlock time should be different");

        vm.prank(bunny);
        vault.setProfitMaxUnlockTime(time);

        // Verify new value
        assertEq(vault.profitMaxUnlockTime(), time, "Profit unlock time should be updated");
    }

    function testSetProfitUnlockTooHighReverts() public {
        // Give bunny the PROFIT_UNLOCK_MANAGER role
        vm.prank(gov);
        vault.add_role(bunny, IMultistrategyVault.Roles.PROFIT_UNLOCK_MANAGER);

        // Try to set too high unlock time
        uint256 time = 1e20;
        uint256 currentTime = vault.profitMaxUnlockTime();

        vm.prank(bunny);
        vm.expectRevert(IMultistrategyVault.ProfitUnlockTimeTooLong.selector);
        vault.setProfitMaxUnlockTime(time);

        // Verify unchanged
        assertEq(vault.profitMaxUnlockTime(), currentTime, "Profit unlock time should be unchanged");
    }

    // ROLE MANAGEMENT TESTS

    function testAddRole() public {
        // Verify initial state
        assertEq(vault.roles(bunny), 0, "Initial roles should be 0");

        // Add first role
        vm.prank(gov);
        vault.add_role(bunny, IMultistrategyVault.Roles.PROFIT_UNLOCK_MANAGER);

        // Verify role
        assertEq(
            vault.roles(bunny),
            1 << uint256(IMultistrategyVault.Roles.PROFIT_UNLOCK_MANAGER),
            "Should have PROFIT_UNLOCK_MANAGER role"
        );

        // Add second role
        vm.prank(gov);
        vault.add_role(bunny, IMultistrategyVault.Roles.FORCE_REVOKE_MANAGER);

        // Verify combined roles
        uint256 expectedRoles = (1 << uint256(IMultistrategyVault.Roles.PROFIT_UNLOCK_MANAGER)) |
            (1 << uint256(IMultistrategyVault.Roles.FORCE_REVOKE_MANAGER));
        assertEq(vault.roles(bunny), expectedRoles, "Should have both roles");

        // Add third role
        vm.prank(gov);
        vault.add_role(bunny, IMultistrategyVault.Roles.REPORTING_MANAGER);

        // Verify all roles
        expectedRoles =
            (1 << uint256(IMultistrategyVault.Roles.PROFIT_UNLOCK_MANAGER)) |
            (1 << uint256(IMultistrategyVault.Roles.FORCE_REVOKE_MANAGER)) |
            (1 << uint256(IMultistrategyVault.Roles.REPORTING_MANAGER));
        assertEq(vault.roles(bunny), expectedRoles, "Should have all three roles");
    }

    function testRemoveRole() public {
        // Verify initial state
        assertEq(vault.roles(bunny), 0, "Initial roles should be 0");

        // Set multiple roles using proper bit shifting
        uint256 profitUnlockManagerBit = 1 << uint256(IMultistrategyVault.Roles.PROFIT_UNLOCK_MANAGER);
        uint256 forceRevokeManagerBit = 1 << uint256(IMultistrategyVault.Roles.FORCE_REVOKE_MANAGER);
        uint256 reportingManagerBit = 1 << uint256(IMultistrategyVault.Roles.REPORTING_MANAGER);

        uint256 combinedRoles = profitUnlockManagerBit | forceRevokeManagerBit | reportingManagerBit;

        vm.prank(gov);
        vault.set_role(bunny, combinedRoles);

        // Verify initial roles
        assertEq(vault.roles(bunny), combinedRoles, "Should have all three roles");

        // Remove first role
        vm.prank(gov);
        vault.remove_role(bunny, IMultistrategyVault.Roles.FORCE_REVOKE_MANAGER);

        // Verify remaining roles
        uint256 expectedRoles = profitUnlockManagerBit | reportingManagerBit;
        assertEq(vault.roles(bunny), expectedRoles, "Should have two roles left");

        // Remove second role
        vm.prank(gov);
        vault.remove_role(bunny, IMultistrategyVault.Roles.REPORTING_MANAGER);

        // Verify remaining role
        expectedRoles = profitUnlockManagerBit;
        assertEq(vault.roles(bunny), expectedRoles, "Should have one role left");

        // Remove last role
        vm.prank(gov);
        vault.remove_role(bunny, IMultistrategyVault.Roles.PROFIT_UNLOCK_MANAGER);

        // Verify no roles left
        assertEq(vault.roles(bunny), 0, "Should have no roles left");
    }

    function testAddRoleWontRemove() public {
        // Get gov's initial roles
        uint256 initialRoles = vault.roles(gov);

        // Verify gov already has MINIMUM_IDLE_MANAGER role
        assertTrue(
            (initialRoles & uint256(IMultistrategyVault.Roles.MINIMUM_IDLE_MANAGER)) != 0,
            "Gov should already have MINIMUM_IDLE_MANAGER role"
        );

        // Try to add a role gov already has
        vm.prank(gov);
        vault.add_role(gov, IMultistrategyVault.Roles.MINIMUM_IDLE_MANAGER);

        // Verify roles unchanged
        assertEq(vault.roles(gov), initialRoles, "Roles should be unchanged");

        // Test that the role still works
        vm.prank(gov);
        vault.set_minimum_total_idle(100);

        assertEq(vault.minimumTotalIdle(), 100, "Minimum idle should be updated");
    }

    function testRemoveRoleWontAdd() public {
        // Verify bunny has no roles
        assertEq(vault.roles(bunny), 0, "Initial roles should be 0");

        // Try to remove a role bunny doesn't have
        vm.prank(gov);
        vault.remove_role(bunny, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);

        // Verify roles unchanged
        assertEq(vault.roles(bunny), 0, "Roles should still be 0");

        // Verify bunny can't add a strategy
        address newStrategy = createStrategy();
        vm.prank(bunny);
        vm.expectRevert(IMultistrategyVault.NotAllowed.selector);
        vault.add_strategy(newStrategy, true);
    }

    function testSetName() public {
        // Get initial name
        string memory initialName = vault.name();
        string memory newName = "New Vault Name";

        // Verify bunny can't set name
        vm.prank(bunny);
        vm.expectRevert(IMultistrategyVault.NotAllowed.selector);
        vault.set_name(newName);

        // Give bunny ALL roles
        vm.prank(gov);
        vault.set_role(bunny, type(uint256).max); // Set all possible roles

        // Verify bunny still can't set name (only roleManager can)
        vm.prank(bunny);
        vm.expectRevert(IMultistrategyVault.NotAllowed.selector);
        vault.set_name(newName);

        // Verify name unchanged
        assertEq(vault.name(), initialName, "Name should be unchanged");

        // Set name with gov (roleManager)
        vm.prank(gov);
        vault.set_name(newName);

        // Verify name changed
        assertEq(vault.name(), newName, "Name should be changed");
        assertNotEq(vault.name(), initialName, "Name should be different from initial");
    }

    function testSetSymbol() public {
        // Get initial symbol
        string memory initialSymbol = vault.symbol();
        string memory newSymbol = "New Vault Symbol";

        // Verify bunny can't set symbol
        vm.prank(bunny);
        vm.expectRevert(IMultistrategyVault.NotAllowed.selector);
        vault.set_symbol(newSymbol);

        // Give bunny ALL roles
        vm.prank(gov);
        vault.set_role(bunny, type(uint256).max); // Set all possible roles

        // Verify bunny still can't set symbol (only roleManager can)
        vm.prank(bunny);
        vm.expectRevert(IMultistrategyVault.NotAllowed.selector);
        vault.set_symbol(newSymbol);

        // Verify symbol unchanged
        assertEq(vault.symbol(), initialSymbol, "Symbol should be unchanged");

        // Set symbol with gov (roleManager)
        vm.prank(gov);
        vault.set_symbol(newSymbol);

        // Verify symbol changed
        assertEq(vault.symbol(), newSymbol, "Symbol should be changed");
        assertNotEq(vault.symbol(), initialSymbol, "Symbol should be different from initial");
    }

    function uint256ToRole(uint256 roleBitmask) internal pure returns (IMultistrategyVault.Roles) {
        require(roleBitmask > 0 && (roleBitmask & (roleBitmask - 1)) == 0, "Must be a power of 2");

        uint256 position = 0;
        while (roleBitmask > 1) {
            roleBitmask >>= 1;
            position++;
        }

        return IMultistrategyVault.Roles(position);
    }

    function setAllRoles(address account) internal {
        vm.startPrank(gov);
        // Define the roles we want to set
        uint256[] memory roleBitmasks = new uint256[](14);
        roleBitmasks[0] = uint256(1 << uint256(IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER));
        roleBitmasks[1] = uint256(1 << uint256(IMultistrategyVault.Roles.REVOKE_STRATEGY_MANAGER));
        roleBitmasks[2] = uint256(1 << uint256(IMultistrategyVault.Roles.FORCE_REVOKE_MANAGER));
        roleBitmasks[3] = uint256(1 << uint256(IMultistrategyVault.Roles.DEBT_MANAGER));
        roleBitmasks[4] = uint256(1 << uint256(IMultistrategyVault.Roles.ACCOUNTANT_MANAGER));
        roleBitmasks[5] = uint256(1 << uint256(IMultistrategyVault.Roles.REPORTING_MANAGER));
        roleBitmasks[6] = uint256(1 << uint256(IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER));
        roleBitmasks[7] = uint256(1 << uint256(IMultistrategyVault.Roles.WITHDRAW_LIMIT_MANAGER));
        roleBitmasks[8] = uint256(1 << uint256(IMultistrategyVault.Roles.MAX_DEBT_MANAGER));
        roleBitmasks[9] = uint256(1 << uint256(IMultistrategyVault.Roles.MINIMUM_IDLE_MANAGER));
        roleBitmasks[10] = uint256(1 << uint256(IMultistrategyVault.Roles.DEBT_PURCHASER));
        roleBitmasks[11] = uint256(1 << uint256(IMultistrategyVault.Roles.QUEUE_MANAGER));
        roleBitmasks[12] = uint256(1 << uint256(IMultistrategyVault.Roles.EMERGENCY_MANAGER));
        roleBitmasks[13] = uint256(1 << uint256(IMultistrategyVault.Roles.PROFIT_UNLOCK_MANAGER));

        // Set each role individually
        for (uint256 i = 0; i < roleBitmasks.length; i++) {
            vault.add_role(account, uint256ToRole(roleBitmasks[i]));
        }
        vm.stopPrank();
    }
}
