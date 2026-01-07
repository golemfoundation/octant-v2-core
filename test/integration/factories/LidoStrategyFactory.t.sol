// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { LidoStrategy } from "src/strategies/yieldSkimming/LidoStrategy.sol";
import { LidoStrategyFactory } from "src/factories/LidoStrategyFactory.sol";
import { BaseStrategyFactory } from "src/factories/BaseStrategyFactory.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { YieldSkimmingTokenizedStrategy } from "src/strategies/yieldSkimming/YieldSkimmingTokenizedStrategy.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

/// @title LidoStrategyFactory Test
/// @author Octant
/// @notice Integration tests for the LidoVaultFactory using a mainnet fork
contract LidoStrategyFactoryTest is Test {
    using SafeERC20 for ERC20;

    // Factory for creating strategies
    YieldSkimmingTokenizedStrategy public tokenizedStrategy;
    LidoStrategyFactory public factory;

    // Strategy parameters
    address public management;
    address public keeper;
    address public emergencyAdmin;
    address public donationAddress;

    // Mainnet addresses
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address public constant TOKENIZED_STRATEGY_ADDRESS = 0x8cf7246a74704bBE59c9dF614ccB5e3d9717d8Ac;

    // Test constants
    uint256 public mainnetFork;
    uint256 public mainnetForkBlock = 22508883 - 6500 * 90; // latest alchemy block - 90 days
    YieldSkimmingTokenizedStrategy public implementation;

    function setUp() public {
        // Create a mainnet fork
        mainnetFork = vm.createFork("mainnet");
        vm.selectFork(mainnetFork);

        // Etch YieldSkimmingTokenizedStrategy
        implementation = new YieldSkimmingTokenizedStrategy{ salt: keccak256("OCT_YIELD_SKIMMING_STRATEGY_V1") }();
        bytes memory tokenizedStrategyBytecode = address(implementation).code;
        vm.etch(TOKENIZED_STRATEGY_ADDRESS, tokenizedStrategyBytecode);

        // Now use that address as our tokenizedStrategy
        tokenizedStrategy = YieldSkimmingTokenizedStrategy(TOKENIZED_STRATEGY_ADDRESS);

        // Set up addresses
        management = address(0x1);
        keeper = address(0x2);
        emergencyAdmin = address(0x3);
        donationAddress = address(0x4);

        // Deploy factory
        factory = new LidoStrategyFactory();

        // Label addresses for better trace outputs
        vm.label(address(factory), "LidoVaultFactory");
        vm.label(WSTETH, "Lido Yield Vault");
        vm.label(TOKENIZED_STRATEGY_ADDRESS, "TokenizedStrategy");
        vm.label(management, "Management");
        vm.label(keeper, "Keeper");
        vm.label(emergencyAdmin, "Emergency Admin");
        vm.label(donationAddress, "Donation Address");
    }

    /// @notice Test creating a strategy through the factory
    function testCreateStrategy() public {
        string memory vaultSharesName = "Lido Vault Shares";

        // Create a strategy and check events
        vm.startPrank(management);
        vm.expectEmit(true, true, false, true); // Check deployer, donationAddress, and vaultTokenName; ignore strategy address
        emit LidoStrategyFactory.StrategyDeploy(management, donationAddress, address(0), vaultSharesName); // We can't predict the exact address

        address strategyAddress = factory.createStrategy(
            vaultSharesName,
            "osLIDO",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // enableBurning
            address(implementation)
        );
        vm.stopPrank();

        // Verify strategy is tracked in factory
        (address deployerAddress, uint256 timestamp, string memory name, address stratDonationAddress) = factory
            .strategies(management, 0);

        assertEq(deployerAddress, management, "Deployer address incorrect in factory");
        assertEq(name, vaultSharesName, "Vault shares name incorrect in factory");
        assertEq(stratDonationAddress, donationAddress, "Donation address incorrect in factory");
        assertTrue(timestamp > 0, "Timestamp should be set");

        // Verify strategy was initialized correctly
        LidoStrategy strategy = LidoStrategy(strategyAddress);
        assertEq(IERC4626(address(strategy)).asset(), WSTETH, "Yield vault address incorrect");
    }

    /// @notice Test creating multiple strategies for the same user
    function testMultipleStrategiesPerUser() public {
        // Create first strategy
        string memory firstVaultName = "First Lido Vault";

        vm.startPrank(management);
        address firstStrategyAddress = factory.createStrategy(
            firstVaultName,
            "osLIDO1",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // enableBurning
            address(implementation)
        );

        // Create second strategy for same user
        string memory secondVaultName = "Second Lido Vault";

        address secondStrategyAddress = factory.createStrategy(
            secondVaultName,
            "osLIDO2",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // enableBurning
            address(implementation)
        );
        vm.stopPrank();

        // Verify both strategies exist
        (address deployerAddress, , string memory name, ) = factory.strategies(management, 0);
        assertEq(deployerAddress, management, "First deployer address incorrect");
        assertEq(name, firstVaultName, "First vault name incorrect");

        (deployerAddress, , name, ) = factory.strategies(management, 1);
        assertEq(deployerAddress, management, "Second deployer address incorrect");
        assertEq(name, secondVaultName, "Second vault name incorrect");

        // Verify strategies are different
        assertTrue(firstStrategyAddress != secondStrategyAddress, "Strategies should have different addresses");
    }

    /// @notice Test creating strategies for different users
    function testMultipleUsers() public {
        string memory firstVaultName = "First User's Vault";

        address firstUser = address(0x5678);
        address secondUser = address(0x9876);

        // Create strategy for first user
        vm.startPrank(firstUser);
        address firstStrategyAddress = factory.createStrategy(
            firstVaultName,
            "osLIDO1",
            firstUser,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // enableBurning
            address(implementation)
        );
        vm.stopPrank();

        // Create strategy for second user
        string memory secondVaultName = "Second User's Vault";

        vm.startPrank(secondUser);
        address secondStrategyAddress = factory.createStrategy(
            secondVaultName,
            "osLIDO2",
            secondUser,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // enableBurning
            address(implementation)
        );
        vm.stopPrank();

        // Verify strategies are properly tracked for each user
        (address deployerAddress, , string memory name, ) = factory.strategies(firstUser, 0);
        assertEq(deployerAddress, firstUser, "First user's deployer address incorrect");
        assertEq(name, firstVaultName, "First user's vault name incorrect");

        (deployerAddress, , name, ) = factory.strategies(secondUser, 0);
        assertEq(deployerAddress, secondUser, "Second user's deployer address incorrect");
        assertEq(name, secondVaultName, "Second user's vault name incorrect");

        // Verify strategies are different
        assertTrue(firstStrategyAddress != secondStrategyAddress, "Strategies should have different addresses");
    }

    /// @notice Test for deterministic addressing and duplicate prevention
    function testDeterministicAddressing() public {
        string memory vaultSharesName = "Deterministic Vault";

        // Create a strategy
        vm.startPrank(management);
        address firstAddress = factory.createStrategy(
            vaultSharesName,
            "osDET",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // enableBurning
            address(implementation)
        );
        vm.stopPrank();

        // Try to deploy the exact same strategy again - should revert
        vm.startPrank(management);
        vm.expectRevert(abi.encodeWithSelector(BaseStrategyFactory.StrategyAlreadyExists.selector, firstAddress));
        factory.createStrategy(
            vaultSharesName,
            "osDET",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // enableBurning
            address(implementation)
        );
        vm.stopPrank();

        // Create a strategy with different parameters - should succeed
        string memory differentName = "Different Vault";
        vm.startPrank(management);
        address secondAddress = factory.createStrategy(
            differentName,
            "osDIF",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // enableBurning
            address(implementation)
        );
        vm.stopPrank();

        // Different parameters should result in different address
        assertTrue(firstAddress != secondAddress, "Different params should create different address");
    }
}
