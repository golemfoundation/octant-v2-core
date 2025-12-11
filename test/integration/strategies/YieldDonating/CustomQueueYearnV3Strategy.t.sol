// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockCompounderVault } from "test/mocks/MockCompounderVault.sol";
import { CustomQueueYearnV3Strategy } from "src/strategies/yieldDonating/CustomQueueYearnV3Strategy.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";
import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { MorphoCompounderStrategy } from "src/strategies/yieldDonating/MorphoCompounderStrategy.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";

/**
 * @title CustomQueueYearnV3Strategy Test Suite
 * @author [Golem Foundation](https://golem.foundation)
 * @notice Tests for CustomQueueYearnV3Strategy with real MultistrategyVault integration
 * @dev Tests the emergency withdraw mechanism using real contracts:
 *      - Deploys real MultistrategyVault as the yield source
 *      - Deploys MorphoCompounderStrategy as underlying strategies
 *      - Tests emergency withdrawals with custom strategy queues
 *      - No mocking of contract calls to ensure realistic behavior
 */
contract CustomQueueYearnV3StrategyTest is Test {
    // Contracts
    CustomQueueYearnV3Strategy public customStrategy;
    MultistrategyVault public multistrategyVault;
    MultistrategyVaultFactory public factory;
    MockERC20 public asset;
    MockCompounderVault public mockCompounder1;
    MockCompounderVault public mockCompounder2;
    MockCompounderVault public mockCompounder3;
    MorphoCompounderStrategy public morphoStrategy1;
    MorphoCompounderStrategy public morphoStrategy2;
    MorphoCompounderStrategy public morphoStrategy3;
    YieldDonatingTokenizedStrategy public tokenizedStrategyImplementation;

    // Actors
    address public factoryGovernance = address(0x99);
    address public vaultAdmin = address(0x100);
    address public management = address(0x1);
    address public keeper = address(0x2);
    address public emergencyAdmin = address(0x3);
    address public donationAddress = address(0x4);
    address public user = address(0x6);

    // Protocol fee config
    address public protocolFeeRecipient = address(0x7);
    uint16 public protocolFeeBps = 1000; // 10%

    // Constants
    address public constant TOKENIZED_STRATEGY_ADDRESS = 0x8cf7246a74704bBE59c9dF614ccB5e3d9717d8Ac;

    function setUp() public {
        // Deploy mock asset (underlying token like USDC)
        asset = new MockERC20(18);

        // Deploy a base MultistrategyVault as implementation
        MultistrategyVault vaultImplementation = new MultistrategyVault();

        // Deploy factory
        factory = new MultistrategyVaultFactory("Test Factory", address(vaultImplementation), factoryGovernance);

        // Set protocol fee configuration
        vm.prank(factoryGovernance);
        factory.setProtocolFeeRecipient(protocolFeeRecipient);

        vm.prank(factoryGovernance);
        factory.setProtocolFeeBps(protocolFeeBps);

        // Deploy MultistrategyVault through factory
        multistrategyVault = MultistrategyVault(
            factory.deployNewVault(
                address(asset),
                "Test MultistrategyVault",
                "msvTEST",
                vaultAdmin,
                7200 // 2 hour profit unlock
            )
        );

        // Deploy tokenized strategy implementation
        tokenizedStrategyImplementation = new YieldDonatingTokenizedStrategy();
        vm.etch(TOKENIZED_STRATEGY_ADDRESS, address(tokenizedStrategyImplementation).code);

        // Deploy mock compounder vaults
        mockCompounder1 = new MockCompounderVault(address(asset));
        mockCompounder2 = new MockCompounderVault(address(asset));
        mockCompounder3 = new MockCompounderVault(address(asset));

        // Deploy MorphoCompounderStrategies as underlying strategies
        morphoStrategy1 = new MorphoCompounderStrategy(
            address(mockCompounder1),
            address(asset),
            "Morpho Strategy 1",
            vaultAdmin,
            keeper,
            emergencyAdmin,
            donationAddress,
            false,
            TOKENIZED_STRATEGY_ADDRESS
        );

        morphoStrategy2 = new MorphoCompounderStrategy(
            address(mockCompounder2),
            address(asset),
            "Morpho Strategy 2",
            vaultAdmin,
            keeper,
            emergencyAdmin,
            donationAddress,
            false,
            TOKENIZED_STRATEGY_ADDRESS
        );

        morphoStrategy3 = new MorphoCompounderStrategy(
            address(mockCompounder3),
            address(asset),
            "Morpho Strategy 3",
            vaultAdmin,
            keeper,
            emergencyAdmin,
            donationAddress,
            false,
            TOKENIZED_STRATEGY_ADDRESS
        );

        // Setup MultistrategyVault roles
        vm.startPrank(vaultAdmin);

        // Grant necessary roles
        multistrategyVault.addRole(vaultAdmin, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);
        multistrategyVault.addRole(vaultAdmin, IMultistrategyVault.Roles.MAX_DEBT_MANAGER);
        multistrategyVault.addRole(vaultAdmin, IMultistrategyVault.Roles.DEBT_MANAGER);
        multistrategyVault.addRole(vaultAdmin, IMultistrategyVault.Roles.QUEUE_MANAGER);
        multistrategyVault.addRole(vaultAdmin, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);
        multistrategyVault.addRole(vaultAdmin, IMultistrategyVault.Roles.REPORTING_MANAGER);

        // Set deposit limit
        multistrategyVault.setDepositLimit(type(uint256).max, false);

        // Add strategies to MultistrategyVault
        multistrategyVault.addStrategy(address(morphoStrategy1), true);
        multistrategyVault.addStrategy(address(morphoStrategy2), true);
        multistrategyVault.addStrategy(address(morphoStrategy3), true);

        // Set max debt for strategies
        multistrategyVault.updateMaxDebtForStrategy(address(morphoStrategy1), type(uint256).max);
        multistrategyVault.updateMaxDebtForStrategy(address(morphoStrategy2), type(uint256).max);
        multistrategyVault.updateMaxDebtForStrategy(address(morphoStrategy3), type(uint256).max);

        vm.stopPrank();

        // Deploy CustomQueueYearnV3Strategy
        // This strategy will deposit into the MultistrategyVault
        customStrategy = new CustomQueueYearnV3Strategy(
            address(multistrategyVault), // yearnVault (actually MultistrategyVault)
            address(asset), // asset (underlying token like USDC)
            "Custom Queue Strategy",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // disable burning
            TOKENIZED_STRATEGY_ADDRESS
        );

        // Setup initial balances
        asset.mint(user, 10000e18);
        asset.mint(address(this), 10000e18);

        // The strategy will auto-deploy to the MultistrategyVault during deposit
    }

    /**
     * @notice Test basic contract setup
     */
    function test_setUp() public view {
        assertEq(customStrategy.yearnVault(), address(multistrategyVault));
        // Strategy should be properly initialized
        assertTrue(address(customStrategy) != address(0));
        assertTrue(address(multistrategyVault) != address(0));
        assertTrue(address(asset) != address(0));

        // Verify MultistrategyVault setup
        assertEq(multistrategyVault.asset(), address(asset));
        assertEq(multistrategyVault.roleManager(), vaultAdmin);

        // Verify strategies are added
        address[] memory queue = multistrategyVault.getDefaultQueue();
        assertEq(queue.length, 3);
        assertEq(queue[0], address(morphoStrategy1));
        assertEq(queue[1], address(morphoStrategy2));
        assertEq(queue[2], address(morphoStrategy3));
    }

    /**
     * @notice Test access control - only emergency admin or management can call
     */
    function test_accessControl() public {
        // First deposit assets into the strategy and then into MultistrategyVault
        _setupStrategyWithDeposits();

        address[] memory strategies = new address[](1);
        strategies[0] = address(morphoStrategy1);

        // Shutdown the strategy (required for emergency withdrawals)
        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(customStrategy)).shutdownStrategy();

        // Unauthorized user cannot call
        vm.prank(user);
        vm.expectRevert("Not authorized");
        customStrategy.emergencyWithdraw(100e18, strategies);

        // Emergency admin can call
        vm.prank(emergencyAdmin);
        customStrategy.emergencyWithdraw(100e18, strategies);

        // Management can call
        vm.prank(management);
        customStrategy.emergencyWithdraw(50e18, strategies);
    }

    /**
     * @notice Test shutdown requirement - strategy must be shutdown
     */
    function test_shutdownRequired() public {
        // First deposit assets into the strategy and then into MultistrategyVault
        _setupStrategyWithDeposits();

        address[] memory strategies = new address[](1);
        strategies[0] = address(morphoStrategy1);

        // Strategy not shutdown - should revert
        vm.prank(emergencyAdmin);
        vm.expectRevert("Strategy not shutdown");
        customStrategy.emergencyWithdraw(100e18, strategies);

        // Shutdown the strategy
        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(customStrategy)).shutdownStrategy();

        // Verify it's shutdown
        assertTrue(ITokenizedStrategy(address(customStrategy)).isShutdown());

        // Now it should work
        vm.prank(emergencyAdmin);
        customStrategy.emergencyWithdraw(100e18, strategies);
    }

    /**
     * @notice Test emergency withdraw with custom strategies
     */
    function test_emergencyWithdrawCustomStrategies() public {
        // Setup strategy with deposits distributed across strategies
        _setupStrategyWithDeposits();

        // Create custom queue with different order than default
        address[] memory strategies = new address[](3);
        strategies[0] = address(morphoStrategy3);
        strategies[1] = address(morphoStrategy1);
        strategies[2] = address(morphoStrategy2);

        // Shutdown the strategy
        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(customStrategy)).shutdownStrategy();

        uint256 balanceBefore = asset.balanceOf(address(customStrategy));

        // Emergency withdraw with custom queue
        vm.prank(emergencyAdmin);
        customStrategy.emergencyWithdraw(200e18, strategies);

        // Verify funds were withdrawn
        uint256 balanceAfter = asset.balanceOf(address(customStrategy));
        assertGe(balanceAfter - balanceBefore, 200e18, "Should have withdrawn at least requested amount");
    }

    /**
     * @notice Test empty strategies array
     */
    function test_emptyStrategiesArray() public {
        // Setup strategy with deposits
        _setupStrategyWithDeposits();

        address[] memory emptyStrategies = new address[](0);

        // Shutdown the strategy
        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(customStrategy)).shutdownStrategy();

        // Empty array should work fine (will use default queue)
        vm.prank(emergencyAdmin);
        customStrategy.emergencyWithdraw(50e18, emptyStrategies);
    }

    /**
     * @notice Test large strategies array
     */
    function test_largeStrategiesArray() public {
        // Setup strategy with deposits
        _setupStrategyWithDeposits();

        // Create array with strategies repeated (max 10 allowed)
        address[] memory strategies = new address[](10);
        strategies[0] = address(morphoStrategy1);
        strategies[1] = address(morphoStrategy2);
        strategies[2] = address(morphoStrategy3);
        strategies[3] = address(morphoStrategy1);
        strategies[4] = address(morphoStrategy2);
        strategies[5] = address(morphoStrategy3);
        strategies[6] = address(morphoStrategy1);
        strategies[7] = address(morphoStrategy2);
        strategies[8] = address(morphoStrategy3);
        strategies[9] = address(morphoStrategy1);

        // Shutdown the strategy
        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(customStrategy)).shutdownStrategy();

        uint256 amount = 150e18;

        vm.prank(management);
        customStrategy.emergencyWithdraw(amount, strategies);
    }

    /**
     * @notice Test that normal YearnV3Strategy functionality is preserved
     */
    function test_normalFunctionalityPreserved() public {
        // Deposit some assets to test functionality
        uint256 depositAmount = 1000e18;
        asset.approve(address(customStrategy), depositAmount);

        vm.prank(address(this));
        ITokenizedStrategy(address(customStrategy)).deposit(depositAmount, address(this));

        // Test that we can still call normal strategy functions
        assertGt(customStrategy.availableDepositLimit(address(0)), 0);
        assertGt(customStrategy.availableWithdrawLimit(address(0)), 0);

        // Verify the strategy still points to the correct MultistrategyVault
        assertEq(customStrategy.yearnVault(), address(multistrategyVault));
    }

    /**
     * @notice Test both access control conditions together
     */
    function test_bothAccessControlConditions() public {
        // Setup strategy with deposits
        _setupStrategyWithDeposits();

        address[] memory strategies = new address[](2);
        strategies[0] = address(morphoStrategy1);
        strategies[1] = address(morphoStrategy2);

        // Not authorized and not shutdown - should fail on authorization first
        vm.prank(user);
        vm.expectRevert("Not authorized");
        customStrategy.emergencyWithdraw(100e18, strategies);

        // Authorized but not shutdown - should fail on shutdown check
        vm.prank(emergencyAdmin);
        vm.expectRevert("Strategy not shutdown");
        customStrategy.emergencyWithdraw(100e18, strategies);

        // Shutdown strategy
        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(customStrategy)).shutdownStrategy();

        // Now authorized and shutdown - should succeed
        vm.prank(emergencyAdmin);
        customStrategy.emergencyWithdraw(100e18, strategies);
    }

    /**
     * @notice Test multiple sequential calls
     */
    function test_multipleSequentialCalls() public {
        // Setup strategy with deposits
        _setupStrategyWithDeposits();

        // Shutdown strategy
        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(customStrategy)).shutdownStrategy();

        // First call
        address[] memory strategies1 = new address[](2);
        strategies1[0] = address(morphoStrategy1);
        strategies1[1] = address(morphoStrategy2);

        vm.prank(emergencyAdmin);
        customStrategy.emergencyWithdraw(50e18, strategies1);

        // Second call with different strategies
        address[] memory strategies2 = new address[](3);
        strategies2[0] = address(morphoStrategy3);
        strategies2[1] = address(morphoStrategy2);
        strategies2[2] = address(morphoStrategy1);

        vm.prank(management);
        customStrategy.emergencyWithdraw(75e18, strategies2);

        // Both should succeed
        assertTrue(true, "Multiple sequential calls successful");
    }

    /**
     * @notice Helper function to setup strategy with deposits
     */
    function _setupStrategyWithDeposits() internal {
        // First, we need to deposit assets into the MultistrategyVault to bootstrap it
        uint256 vaultDepositAmount = 3000e18;
        asset.approve(address(multistrategyVault), vaultDepositAmount);
        multistrategyVault.deposit(vaultDepositAmount, address(this));

        // Now have MultistrategyVault distribute to underlying strategies
        vm.prank(vaultAdmin);
        multistrategyVault.updateDebt(address(morphoStrategy1), 1000e18, 0);

        vm.prank(vaultAdmin);
        multistrategyVault.updateDebt(address(morphoStrategy2), 1000e18, 0);

        vm.prank(vaultAdmin);
        multistrategyVault.updateDebt(address(morphoStrategy3), 1000e18, 0);

        // Now deposit assets into the CustomQueueYearnV3Strategy
        // Deposit to the test contract (not the strategy itself) to avoid the self-deposit restriction
        uint256 strategyDepositAmount = 1000e18;
        asset.approve(address(customStrategy), strategyDepositAmount);
        ITokenizedStrategy(address(customStrategy)).deposit(strategyDepositAmount, address(this));
    }
}
