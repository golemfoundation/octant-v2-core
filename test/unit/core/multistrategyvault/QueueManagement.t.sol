// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockYieldStrategy } from "test/mocks/zodiac-core/MockYieldStrategy.sol";
import { MockFactory } from "test/mocks/MockFactory.sol";
import { MockAccountant } from "test/mocks/core/MockAccountant.sol";
import { MockFlexibleAccountant } from "test/mocks/core/MockFlexibleAccountant.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";

contract QueueManagementTest is Test {
    MultistrategyVault vaultImplementation;
    MultistrategyVault vault;
    MockERC20 public asset;
    MockYieldStrategy public strategy;
    MockAccountant public accountant;
    MockFlexibleAccountant public flexibleAccountant;
    MultistrategyVaultFactory vaultFactory;
    MockFactory public factory;
    address public gov = address(0x1);
    address public fish = address(0x2);
    address public feeRecipient = address(0x3);

    uint256 fishAmount = 10_000e18;
    uint256 MAX_BPS = 10_000;
    uint256 constant DAY = 1 days;
    uint256 constant WEEK = 7 days;
    uint256 constant YEAR = 365 days;

    function setUp() public {
        // Setup asset
        asset = new MockERC20(18);
        asset.mint(gov, 1_000_000e18);
        asset.mint(fish, fishAmount);

        // deploy factory
        vm.prank(gov);
        factory = new MockFactory(0, feeRecipient);

        flexibleAccountant = new MockFlexibleAccountant(address(asset));

        // Deploy vault
        vm.startPrank(address(factory));
        vaultImplementation = new MultistrategyVault();
        vaultFactory = new MultistrategyVaultFactory("Test Vault", address(vaultImplementation), gov);
        vault = MultistrategyVault(vaultFactory.deployNewVault(address(asset), "Test Vault", "vTST", gov, 7 days));
        vm.stopPrank();

        vm.startPrank(gov);
        // Add roles to gov
        vault.add_role(gov, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.REVOKE_STRATEGY_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEBT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.ACCOUNTANT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.REPORTING_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.MAX_DEBT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.QUEUE_MANAGER);

        // Setup default strategy
        strategy = new MockYieldStrategy(address(asset), address(vault));

        // Set deposit limit to max
        vault.set_deposit_limit(type(uint256).max, true);

        vm.stopPrank();
    }

    function createStrategy() internal returns (address) {
        MockYieldStrategy newStrategy = new MockYieldStrategy(address(asset), address(vault));
        return address(newStrategy);
    }

    function userDeposit(address user, uint256 amount) internal {
        vm.startPrank(user);
        asset.approve(address(vault), amount);
        vault.deposit(amount, user);
        vm.stopPrank();
    }

    function addStrategyToVault(address strategyAddress) internal {
        vm.prank(gov);
        vault.add_strategy(strategyAddress, true);
        vm.prank(gov);
        vault.update_max_debt_for_strategy(strategyAddress, type(uint256).max);
    }

    function addDebtToStrategy(address strategyAddress, uint256 amount, uint256 maxLoss) internal {
        vm.prank(gov);
        vault.update_debt(strategyAddress, amount, maxLoss);
    }

    function testWithdrawNoQueueWithInsufficientFundsInVaultReverts() public {
        uint256 amount = fishAmount;
        uint256 shares = amount;
        address strategyAddress = createStrategy();
        address[] memory strategies = new address[](0); // Empty array - no strategies

        userDeposit(fish, amount);
        addStrategyToVault(strategyAddress);
        addDebtToStrategy(strategyAddress, amount, 0);

        vm.prank(gov);
        vault.set_default_queue(strategies);

        vm.prank(fish);
        vm.expectRevert(IMultistrategyVault.InsufficientAssetsInVault.selector);
        vault.withdraw(shares, fish, fish, 0, new address[](0));
    }

    function testWithdrawQueueWithInsufficientFundsInVaultWithdraws() public {
        uint256 amount = fishAmount;
        uint256 shares = amount;
        address strategyAddress = createStrategy();
        address[] memory strategies = new address[](1);
        strategies[0] = strategyAddress;

        userDeposit(fish, amount);
        addStrategyToVault(strategyAddress);
        addDebtToStrategy(strategyAddress, amount, 0);

        vm.prank(gov);
        vault.set_default_queue(strategies);

        vm.prank(fish);
        vm.recordLogs();
        vault.withdraw(shares, fish, fish, 0, new address[](0));

        // Check that vault is empty
        assertEq(vault.totalAssets(), 0, "Vault should be empty");
        assertEq(asset.balanceOf(address(vault)), 0, "Vault asset balance should be zero");
        assertEq(asset.balanceOf(strategyAddress), 0, "Strategy asset balance should be zero");
        assertEq(asset.balanceOf(fish), amount, "Fish should have all assets");
    }

    function testWithdrawQueueWithInactiveStrategyReverts() public {
        uint256 amount = fishAmount;
        uint256 shares = amount;
        address strategyAddress = createStrategy();
        address inactiveStrategyAddress = createStrategy();
        address[] memory strategies = new address[](1);
        strategies[0] = inactiveStrategyAddress;

        userDeposit(fish, amount);
        addStrategyToVault(strategyAddress);
        addDebtToStrategy(strategyAddress, amount, 0);

        vm.prank(fish);
        vm.expectRevert(IMultistrategyVault.InactiveStrategy.selector);
        vault.withdraw(shares, fish, fish, 0, strategies);
    }

    function testWithdrawQueueWithLiquidStrategyWithdraws() public {
        uint256 amount = fishAmount;
        uint256 shares = amount;
        address strategyAddress = createStrategy();
        address[] memory strategies = new address[](1);
        strategies[0] = strategyAddress;

        userDeposit(fish, amount);
        addStrategyToVault(strategyAddress);
        addDebtToStrategy(strategyAddress, amount, 0);

        vm.prank(fish);
        vault.withdraw(shares, fish, fish, 0, strategies);

        // Check that vault is empty
        assertEq(vault.totalAssets(), 0, "Vault should be empty");
        assertEq(asset.balanceOf(address(vault)), 0, "Vault asset balance should be zero");
        assertEq(asset.balanceOf(strategyAddress), 0, "Strategy asset balance should be zero");
        assertEq(asset.balanceOf(fish), amount, "Fish should have all assets");
    }

    function testWithdrawQueueWithInactiveStrategyAddressReverts() public {
        uint256 amount = fishAmount;
        uint256 shares = amount;
        address strategyAddress = createStrategy();
        address inactiveStrategyAddress = createStrategy();
        address[] memory strategies = new address[](1);
        strategies[0] = inactiveStrategyAddress;

        userDeposit(fish, amount);
        addStrategyToVault(strategyAddress);
        addDebtToStrategy(strategyAddress, amount, 0);

        vm.prank(fish);
        vm.expectRevert(IMultistrategyVault.InactiveStrategy.selector);
        vault.withdraw(shares, fish, fish, 0, strategies);
    }

    // Add these new test functions after the existing ones

    function testAddStrategyAddsToQueue() public {
        // Check empty queue initially
        address[] memory queue = vault.get_default_queue();
        assertEq(queue.length, 0, "Queue should start empty");

        // Add first strategy
        address strategyOne = createStrategy();
        vm.prank(gov);
        vault.add_strategy(strategyOne, true);

        // Check queue contains the first strategy
        queue = vault.get_default_queue();
        assertEq(queue.length, 1, "Queue should have one strategy");
        assertEq(queue[0], strategyOne, "First strategy should be in queue");

        // Add second strategy
        address strategyTwo = createStrategy();
        vm.prank(gov);
        vault.add_strategy(strategyTwo, true);

        // Check queue contains both strategies in order
        queue = vault.get_default_queue();
        assertEq(queue.length, 2, "Queue should have two strategies");
        assertEq(queue[0], strategyOne, "First strategy should be first in queue");
        assertEq(queue[1], strategyTwo, "Second strategy should be second in queue");
    }

    function testAddStrategyDontAddToQueue() public {
        // Check empty queue initially
        address[] memory queue = vault.get_default_queue();
        assertEq(queue.length, 0, "Queue should start empty");

        // Add first strategy without adding to queue
        address strategyOne = createStrategy();
        vm.prank(gov);
        vault.add_strategy(strategyOne, false);

        // Check queue is still empty
        queue = vault.get_default_queue();
        assertEq(queue.length, 0, "Queue should still be empty");

        // Check strategy is still active
        IMultistrategyVault.StrategyParams memory params = vault.strategies(strategyOne);
        assertGt(params.activation, 0, "Strategy should be active");

        // Add second strategy without adding to queue
        address strategyTwo = createStrategy();
        vm.prank(gov);
        vault.add_strategy(strategyTwo, false);

        // Check queue is still empty
        queue = vault.get_default_queue();
        assertEq(queue.length, 0, "Queue should still be empty");
    }

    function testAddElevenStrategiesAddsTenToQueue() public {
        // Check empty queue initially
        address[] memory queue = vault.get_default_queue();
        assertEq(queue.length, 0, "Queue should start empty");

        // Add 10 strategies and check queue length increases each time
        address[] memory strategies = new address[](11);
        for (uint256 i = 0; i < 10; i++) {
            address newStrategy = createStrategy();
            strategies[i] = newStrategy;

            vm.prank(gov);
            vault.add_strategy(newStrategy, true);

            queue = vault.get_default_queue();
            assertEq(queue.length, i + 1, "Queue length should increase");
        }

        // Store queue for comparison
        address[] memory defaultQueue = vault.get_default_queue();
        assertEq(defaultQueue.length, 10, "Default queue should have 10 strategies");

        // Add 11th strategy
        address eleventhStrategy = createStrategy();
        strategies[10] = eleventhStrategy;

        vm.prank(gov);
        vault.add_strategy(eleventhStrategy, true);

        // Check 11th strategy is active but not in queue
        IMultistrategyVault.StrategyParams memory params = vault.strategies(eleventhStrategy);
        assertGt(params.activation, 0, "Strategy should be active");

        // Check queue remains unchanged
        address[] memory newQueue = vault.get_default_queue();
        assertEq(newQueue.length, 10, "Queue should still have 10 strategies");

        // Verify 11th strategy isn't in queue
        bool found = false;
        for (uint256 i = 0; i < newQueue.length; i++) {
            if (newQueue[i] == eleventhStrategy) {
                found = true;
                break;
            }
        }
        assertFalse(found, "11th strategy should not be in queue");
    }

    function testRevokeStrategyRemovesStrategyFromQueue() public {
        // Check empty queue initially
        address[] memory queue = vault.get_default_queue();
        assertEq(queue.length, 0, "Queue should start empty");

        // Add a strategy
        address strategyOne = createStrategy();
        vm.prank(gov);
        vault.add_strategy(strategyOne, true);

        // Check queue contains the strategy
        queue = vault.get_default_queue();
        assertEq(queue.length, 1, "Queue should have one strategy");
        assertEq(queue[0], strategyOne, "Strategy should be in queue");

        // Revoke the strategy
        vm.prank(gov);
        vault.revoke_strategy(strategyOne);

        // Check strategy is no longer active and queue is empty
        IMultistrategyVault.StrategyParams memory params = vault.strategies(strategyOne);
        assertEq(params.activation, 0, "Strategy should not be active");

        queue = vault.get_default_queue();
        assertEq(queue.length, 0, "Queue should be empty");
    }

    function testRevokeStrategyNotInQueue() public {
        // Add a strategy without adding to queue
        address strategyOne = createStrategy();
        vm.prank(gov);
        vault.add_strategy(strategyOne, false);

        // Check strategy is active but not in queue
        IMultistrategyVault.StrategyParams memory params = vault.strategies(strategyOne);
        assertGt(params.activation, 0, "Strategy should be active");

        address[] memory queue = vault.get_default_queue();
        assertEq(queue.length, 0, "Queue should be empty");

        // Revoke the strategy
        vm.prank(gov);
        vault.revoke_strategy(strategyOne);

        // Check strategy is no longer active and queue is still empty
        params = vault.strategies(strategyOne);
        assertEq(params.activation, 0, "Strategy should not be active");

        queue = vault.get_default_queue();
        assertEq(queue.length, 0, "Queue should still be empty");
    }

    function testRevokeStrategyMultipleStrategiesRemovesStrategyFromQueue() public {
        // Add two strategies
        address strategyOne = createStrategy();
        vm.prank(gov);
        vault.add_strategy(strategyOne, true);

        address strategyTwo = createStrategy();
        vm.prank(gov);
        vault.add_strategy(strategyTwo, true);

        // Check queue contains both strategies
        address[] memory queue = vault.get_default_queue();
        assertEq(queue.length, 2, "Queue should have two strategies");
        assertEq(queue[0], strategyOne, "First strategy should be first in queue");
        assertEq(queue[1], strategyTwo, "Second strategy should be second in queue");

        // Revoke the first strategy
        vm.prank(gov);
        vault.revoke_strategy(strategyOne);

        // Check first strategy is no longer active and only second strategy remains in queue
        IMultistrategyVault.StrategyParams memory params = vault.strategies(strategyOne);
        assertEq(params.activation, 0, "First strategy should not be active");

        queue = vault.get_default_queue();
        assertEq(queue.length, 1, "Queue should have one strategy");
        assertEq(queue[0], strategyTwo, "Only second strategy should be in queue");
    }

    function testRemoveEleventhStrategyDoesntChangeQueue() public {
        // Add 10 strategies to fill queue
        address[] memory tenStrategies = new address[](10);
        for (uint256 i = 0; i < 10; i++) {
            address newStrategy = createStrategy();
            tenStrategies[i] = newStrategy;

            vm.prank(gov);
            vault.add_strategy(newStrategy, true);
        }

        // Store queue for comparison
        address[] memory defaultQueue = vault.get_default_queue();
        assertEq(defaultQueue.length, 10, "Default queue should have 10 strategies");

        // Add 11th strategy
        address eleventhStrategy = createStrategy();
        vm.prank(gov);
        vault.add_strategy(eleventhStrategy, true);

        // Check 11th strategy is active
        IMultistrategyVault.StrategyParams memory params = vault.strategies(eleventhStrategy);
        assertGt(params.activation, 0, "Strategy should be active");

        // Revoke the 11th strategy
        vm.prank(gov);
        vault.revoke_strategy(eleventhStrategy);

        // Check queue is unchanged
        address[] memory newQueue = vault.get_default_queue();
        assertEq(newQueue.length, 10, "Queue should still have 10 strategies");

        // Verify queue is unchanged
        for (uint256 i = 0; i < 10; i++) {
            assertEq(newQueue[i], defaultQueue[i], "Queue elements should be unchanged");
        }
    }

    function testSetDefaultQueue() public {
        // Add two strategies
        address strategyOne = createStrategy();
        vm.prank(gov);
        vault.add_strategy(strategyOne, true);

        address strategyTwo = createStrategy();
        vm.prank(gov);
        vault.add_strategy(strategyTwo, true);

        // Check default queue order
        address[] memory queue = vault.get_default_queue();
        assertEq(queue.length, 2, "Queue should have two strategies");
        assertEq(queue[0], strategyOne, "First strategy should be first in queue");
        assertEq(queue[1], strategyTwo, "Second strategy should be second in queue");

        // Create new queue with reversed order
        address[] memory newQueue = new address[](2);
        newQueue[0] = strategyTwo;
        newQueue[1] = strategyOne;

        // Set new default queue
        vm.prank(gov);
        vm.recordLogs();
        vault.set_default_queue(newQueue);

        // Check new queue is set
        queue = vault.get_default_queue();
        assertEq(queue.length, 2, "Queue should have two strategies");
        assertEq(queue[0], strategyTwo, "First strategy should now be the second strategy");
        assertEq(queue[1], strategyOne, "Second strategy should now be the first strategy");
    }

    function testSetDefaultQueueInactiveStrategyReverts() public {
        // Add one strategy
        address strategyOne = createStrategy();
        vm.prank(gov);
        vault.add_strategy(strategyOne, true);

        // Create another strategy but don't add it to vault
        address strategyTwo = createStrategy();

        // Try to set queue including inactive strategy
        address[] memory newQueue = new address[](2);
        newQueue[0] = strategyTwo; // Inactive strategy
        newQueue[1] = strategyOne;

        // Should revert with "inactive strategy"
        vm.prank(gov);
        vm.expectRevert(IMultistrategyVault.InactiveStrategy.selector);
        vault.set_default_queue(newQueue);
    }

    function testSetDefaultQueueTooLongReverts() public {
        // Add one strategy
        address strategyOne = createStrategy();
        vm.prank(gov);
        vault.add_strategy(strategyOne, true);

        // Create a queue with 11 elements (too long)
        address[] memory newQueue = new address[](11);
        for (uint256 i = 0; i < 11; i++) {
            newQueue[i] = strategyOne;
        }

        // Try to set overly long queue
        vm.prank(gov);
        vm.expectRevert();
        vault.set_default_queue(newQueue);
    }
}
