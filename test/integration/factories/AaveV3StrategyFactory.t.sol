// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { AaveV3StrategyFactory } from "src/factories/AaveV3StrategyFactory.sol";
import { AaveV3Strategy } from "src/strategies/yieldDonating/AaveV3Strategy.sol";
import { BaseStrategyFactory } from "src/factories/BaseStrategyFactory.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";
import { CREATE3 } from "solady/utils/CREATE3.sol";

interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

/// @title AaveV3StrategyFactory Test
/// @author Octant
/// @notice Integration tests for the AaveV3StrategyFactory using a mainnet fork
contract AaveV3StrategyFactoryTest is Test {
    using SafeERC20 for ERC20;

    // Factory for creating strategies
    YieldDonatingTokenizedStrategy public tokenizedStrategy;
    AaveV3StrategyFactory public factory;
    YieldDonatingTokenizedStrategy public implementation;

    // Strategy parameters
    address public management;
    address public keeper;
    address public emergencyAdmin;
    address public donationAddress;

    // Mainnet addresses
    address public constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address public constant AAVE_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address public constant AUSDC_V3 = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant TOKENIZED_STRATEGY_ADDRESS = 0x8cf7246a74704bBE59c9dF614ccB5e3d9717d8Ac;

    // Test constants
    uint256 public mainnetFork;
    uint256 public mainnetForkBlock = 21463000; // Recent mainnet block

    // Test whale address with USDC
    address public constant USDC_WHALE = 0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503;

    function setUp() public {
        // Create a mainnet fork
        mainnetFork = vm.createFork("mainnet");
        vm.selectFork(mainnetFork);

        // Etch YieldDonatingTokenizedStrategy
        implementation = new YieldDonatingTokenizedStrategy{ salt: keccak256("OCT_YIELD_DONATING_STRATEGY_V1") }();
        bytes memory tokenizedStrategyBytecode = address(implementation).code;
        vm.etch(TOKENIZED_STRATEGY_ADDRESS, tokenizedStrategyBytecode);

        // Now use that address as our tokenizedStrategy
        tokenizedStrategy = YieldDonatingTokenizedStrategy(TOKENIZED_STRATEGY_ADDRESS);

        // Set up addresses
        management = address(0x1);
        keeper = address(0x2);
        emergencyAdmin = address(0x3);
        donationAddress = address(0x4);

        // Deploy factory
        factory = new AaveV3StrategyFactory();

        // Label addresses for better trace outputs
        vm.label(address(factory), "AaveV3StrategyFactory");
        vm.label(AAVE_POOL, "Aave V3 Pool");
        vm.label(AAVE_ADDRESSES_PROVIDER, "Aave V3 AddressesProvider");
        vm.label(AUSDC_V3, "aUSDC V3");
        vm.label(USDC, "USDC");
        vm.label(TOKENIZED_STRATEGY_ADDRESS, "TokenizedStrategy");
        vm.label(management, "Management");
        vm.label(keeper, "Keeper");
        vm.label(emergencyAdmin, "Emergency Admin");
        vm.label(donationAddress, "Donation Address");
        vm.label(USDC_WHALE, "USDC Whale");
    }

    /// @notice Test creating a strategy through the factory
    function testCreateStrategy() public {
        string memory vaultSharesName = "AaveV3 Vault Shares";

        // Create a strategy and check events
        vm.startPrank(management);
        vm.expectEmit(true, true, false, true); // Check deployer, donationAddress, and vaultTokenName; ignore strategy address
        emit AaveV3StrategyFactory.StrategyDeploy(management, donationAddress, address(0), vaultSharesName); // We can't predict the exact address

        address strategyAddress = factory.createStrategy(
            vaultSharesName,
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
        AaveV3Strategy strategy = AaveV3Strategy(strategyAddress);
        assertEq(IERC4626(address(strategy)).asset(), USDC, "USDC asset address incorrect");
    }

    /// @notice Test depositing into Aave V3 pool through the strategy
    function testDepositToAavePool() public {
        string memory vaultSharesName = "AaveV3 Vault Shares";

        // Create strategy
        vm.startPrank(management);
        address strategyAddress = factory.createStrategy(
            vaultSharesName,
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // enableBurning
            address(implementation)
        );
        vm.stopPrank();

        // Get some USDC
        uint256 depositAmount = 100_000 * 10 ** 6; // 100k USDC
        deal(USDC, address(this), depositAmount);

        // Approve and deposit to strategy
        ERC20(USDC).forceApprove(strategyAddress, depositAmount);
        uint256 sharesMinted = IERC4626(strategyAddress).deposit(depositAmount, address(this));

        assertGt(sharesMinted, 0, "Should have minted shares");
        // Allow small rounding difference due to Aave internal calculations
        assertApproxEqAbs(
            IERC4626(strategyAddress).balanceOf(address(this)),
            sharesMinted,
            2,
            "Share balance incorrect (allowing 2 wei rounding)"
        );

        // Verify that funds were deployed to Aave
        assertEq(ERC20(USDC).balanceOf(strategyAddress), 0, "Strategy should not hold USDC");
        assertGt(ERC20(AUSDC_V3).balanceOf(strategyAddress), 0, "Strategy should hold aUSDC");

        // Test withdrawal - use maxRedeem to avoid trying to redeem more than available
        uint256 maxRedeemable = IERC4626(strategyAddress).maxRedeem(address(this));
        uint256 assetsWithdrawn = IERC4626(strategyAddress).redeem(maxRedeemable, address(this), address(this));
        assertApproxEqAbs(assetsWithdrawn, depositAmount, 2, "Should withdraw full amount (allowing 2 wei rounding)");
    }

    /// @notice Test strategy reporting and yield distribution
    function testHarvestAndReport() public {
        string memory vaultSharesName = "AaveV3 Vault Shares";

        // Create strategy
        vm.startPrank(management);
        address strategyAddress = factory.createStrategy(
            vaultSharesName,
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // enableBurning
            address(implementation)
        );
        vm.stopPrank();

        // Get some USDC
        uint256 depositAmount = 1_000_000 * 10 ** 6; // 1M USDC
        deal(USDC, address(this), depositAmount);

        // Approve and deposit to strategy
        ERC20(USDC).forceApprove(strategyAddress, depositAmount);
        IERC4626(strategyAddress).deposit(depositAmount, address(this));

        // Record initial state
        uint256 initialTotalAssets = IERC4626(strategyAddress).totalAssets();
        uint256 initialDonationBalance = IERC4626(strategyAddress).balanceOf(donationAddress);

        // Simulate time passing to accrue interest
        vm.roll(block.number + 1000);
        vm.warp(block.timestamp + 30 days);

        // Report as keeper
        vm.prank(keeper);
        ITokenizedStrategy(strategyAddress).report();

        // Check that donation address received profit shares
        uint256 finalDonationBalance = IERC4626(strategyAddress).balanceOf(donationAddress);
        assertGt(finalDonationBalance, initialDonationBalance, "Donation address should have received profit shares");

        // Total assets should have increased due to yield
        uint256 finalTotalAssets = IERC4626(strategyAddress).totalAssets();
        assertGe(finalTotalAssets, initialTotalAssets, "Total assets should not decrease");
    }

    /// @notice Test creating multiple strategies for the same user
    function testMultipleStrategiesPerUser() public {
        // Create first strategy
        string memory firstVaultName = "First AaveV3 Vault";

        vm.startPrank(management);
        address firstStrategyAddress = factory.createStrategy(
            firstVaultName,
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // enableBurning
            address(implementation)
        );

        // Create second strategy for same user
        string memory secondVaultName = "Second AaveV3 Vault";

        address secondStrategyAddress = factory.createStrategy(
            secondVaultName,
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

    /// @notice Test for deterministic addressing and duplicate prevention
    function testDeterministicAddressing() public {
        string memory vaultSharesName = "Deterministic Vault";

        // Create a strategy
        vm.startPrank(management);
        address firstAddress = factory.createStrategy(
            vaultSharesName,
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

    /// @notice Test available deposit and withdraw limits
    function testDepositWithdrawLimits() public {
        string memory vaultSharesName = "AaveV3 Vault Shares";

        // Create strategy
        vm.startPrank(management);
        address strategyAddress = factory.createStrategy(
            vaultSharesName,
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false, // enableBurning
            address(implementation)
        );
        vm.stopPrank();

        AaveV3Strategy strategy = AaveV3Strategy(strategyAddress);

        // Check initial deposit limit
        uint256 depositLimit = strategy.availableDepositLimit(address(this));
        assertGt(depositLimit, 0, "Should have positive deposit limit");

        // Check initial withdraw limit (should be 0 since nothing deposited)
        uint256 withdrawLimit = strategy.availableWithdrawLimit(address(this));
        assertEq(withdrawLimit, 0, "Should have zero withdraw limit initially");

        // Deposit some funds
        uint256 depositAmount = 10_000 * 10 ** 6; // 10k USDC
        deal(USDC, address(this), depositAmount);

        ERC20(USDC).forceApprove(strategyAddress, depositAmount);
        IERC4626(strategyAddress).deposit(depositAmount, address(this));

        // Check withdraw limit after deposit
        withdrawLimit = strategy.availableWithdrawLimit(address(this));
        assertApproxEqAbs(
            withdrawLimit,
            depositAmount,
            2,
            "Withdraw limit should include deposited amount (allowing 2 wei rounding)"
        );
    }
}
