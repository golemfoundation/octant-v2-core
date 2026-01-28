// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { BaseFactoryIntegrationTest } from "test/integration/factories/base/BaseFactoryIntegrationTest.sol";
import { ERC4626Strategy } from "src/strategies/yieldDonating/ERC4626Strategy.sol";
import { ERC4626StrategyFactory } from "src/factories/ERC4626StrategyFactory.sol";
import { BaseERC4626StrategyFactory } from "src/factories/BaseERC4626StrategyFactory.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title ERC4626StrategyFactory Test
/// @author Octant
/// @notice Integration tests for the ERC4626StrategyFactory using a mainnet fork
contract ERC4626StrategyFactoryTest is BaseFactoryIntegrationTest {
    // Factory and implementation
    ERC4626StrategyFactory public factory;
    YieldDonatingTokenizedStrategy public implementation;

    // Mainnet addresses - Spark vaults (using USDC as default for shared tests)
    address public constant USDC_SPARK_VAULT = 0x28B3a8fb53B741A8Fd78c0fb9A6B2393d896a43d;
    address public constant WETH_SPARK_VAULT = 0xfE6eb3b609a7C8352A241f7F3A21CEA4e9209B8f;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant TOKENIZED_STRATEGY_ADDRESS = 0x8cf7246a74704bBE59c9dF614ccB5e3d9717d8Ac;

    function setUp() public {
        _baseSetUp();
    }

    // ========== ABSTRACT IMPLEMENTATIONS ==========

    function _factory() internal view override returns (address) {
        return address(factory);
    }

    function _implementation() internal view override returns (address) {
        return address(implementation);
    }

    function _asset() internal pure override returns (address) {
        return USDC;
    }

    function _vault() internal pure override returns (address) {
        return USDC_SPARK_VAULT;
    }

    function _strategySymbolPrefix() internal pure override returns (string memory) {
        return "osERC4626";
    }

    function _deployFactory() internal override {
        factory = new ERC4626StrategyFactory();
    }

    function _deployImplementation() internal override returns (address) {
        implementation = new YieldDonatingTokenizedStrategy{ salt: keccak256("OCT_YIELD_DONATING_STRATEGY_V1") }();
        vm.etch(TOKENIZED_STRATEGY_ADDRESS, address(implementation).code);
        return address(implementation);
    }

    function _createStrategy(
        string memory name,
        string memory symbol,
        address mgmt
    ) internal override returns (address) {
        return
            factory.createStrategy(
                USDC_SPARK_VAULT,
                USDC,
                name,
                symbol,
                mgmt,
                keeper,
                emergencyAdmin,
                donationAddress,
                false, // enableBurning
                address(implementation)
            );
    }

    function _labelFactoryAddresses() internal override {
        vm.label(address(factory), "ERC4626StrategyFactory");
        vm.label(USDC_SPARK_VAULT, "USDC Spark Vault");
        vm.label(WETH_SPARK_VAULT, "WETH Spark Vault");
        vm.label(USDC, "USDC");
        vm.label(WETH, "WETH");
        vm.label(TOKENIZED_STRATEGY_ADDRESS, "TokenizedStrategy");
    }

    function _computeStrategyAddress(
        string memory name,
        string memory symbol,
        address mgmt,
        address deployer
    ) internal view override returns (address) {
        return
            factory.computeStrategyAddress(
                USDC_SPARK_VAULT,
                USDC,
                name,
                symbol,
                mgmt,
                keeper,
                emergencyAdmin,
                donationAddress,
                false, // enableBurning
                address(implementation),
                deployer
            );
    }

    // ========== SHARED TESTS ==========

    /// @notice Test creating a strategy through the factory
    function testCreateStrategyERC4626() public {
        _testCreateStrategy("ERC4626 Vault Shares", "osERC4626");
    }

    /// @notice Test creating multiple strategies for the same user
    function testMultipleStrategiesPerUserERC4626() public {
        _testMultipleStrategiesPerUser("First ERC4626 Vault", "Second ERC4626 Vault");
    }

    /// @notice Test creating strategies for different users
    function testMultipleUsersERC4626() public {
        _testMultipleUsers();
    }

    /// @notice Test for deterministic addressing and duplicate prevention
    function testDeterministicAddressingERC4626() public {
        _testDeterministicAddressing();
    }

    /// @notice Test computeStrategyAddress matches actual deployment
    function testComputeStrategyAddressMatchesDeploymentERC4626() public {
        _testComputeStrategyAddressMatchesDeployment("ERC4626 Compute Test", "osERC4626_CT");
    }

    /// @notice Test computeStrategyAddress with different deployers
    function testComputeStrategyAddressDifferentDeployersERC4626() public {
        _testComputeStrategyAddressDifferentDeployers();
    }

    /// @notice Test computeStrategyAddress with different parameters
    function testComputeStrategyAddressDifferentParamsERC4626() public {
        _testComputeStrategyAddressDifferentParams();
    }

    // ========== ERC4626-SPECIFIC TESTS (multi-vault support) ==========

    /// @notice Test creating a strategy for WETH Spark vault
    function testCreateStrategyWETH() public {
        string memory strategyName = "Spark WETH Donating Strategy";

        vm.startPrank(management);
        vm.expectEmit(true, true, true, false);
        emit BaseERC4626StrategyFactory.StrategyDeploy(
            management,
            WETH_SPARK_VAULT,
            donationAddress,
            address(0),
            strategyName
        );

        address strategyAddress = factory.createStrategy(
            WETH_SPARK_VAULT,
            WETH,
            strategyName,
            "osSparkWETH",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false,
            address(implementation)
        );
        vm.stopPrank();

        // Verify strategy was initialized correctly
        ERC4626Strategy strategy = ERC4626Strategy(strategyAddress);
        assertEq(IERC4626(address(strategy)).asset(), WETH, "Asset should be WETH");
        assertEq(strategy.targetVault(), WETH_SPARK_VAULT, "Target vault should be WETH Spark vault");
    }

    /// @notice Test creating strategy with different vault (same user, different target vault)
    function testDifferentVaultSameParams() public {
        string memory strategyName = "Same Name Different Vault";

        vm.startPrank(management);
        address usdcStrategyAddress = factory.createStrategy(
            USDC_SPARK_VAULT,
            USDC,
            strategyName,
            "osSame1",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false,
            address(implementation)
        );

        address wethStrategyAddress = factory.createStrategy(
            WETH_SPARK_VAULT,
            WETH,
            strategyName,
            "osSame1",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false,
            address(implementation)
        );
        vm.stopPrank();

        assertTrue(
            usdcStrategyAddress != wethStrategyAddress,
            "Different target vaults should create different strategies"
        );

        // Verify both are tracked
        ERC4626Strategy usdcStrategy = ERC4626Strategy(usdcStrategyAddress);
        ERC4626Strategy wethStrategy = ERC4626Strategy(wethStrategyAddress);
        assertEq(usdcStrategy.targetVault(), USDC_SPARK_VAULT, "First strategy should target USDC vault");
        assertEq(wethStrategy.targetVault(), WETH_SPARK_VAULT, "Second strategy should target WETH vault");
    }

    /// @notice Test asset validation during strategy creation
    function testAssetValidation() public {
        vm.startPrank(management);
        vm.expectRevert("Asset mismatch with target vault");
        factory.createStrategy(
            USDC_SPARK_VAULT,
            WETH, // Wrong asset - should be USDC
            "Invalid Strategy",
            "osInvalid",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false,
            address(implementation)
        );
        vm.stopPrank();

        vm.startPrank(management);
        vm.expectRevert("Asset mismatch with target vault");
        factory.createStrategy(
            WETH_SPARK_VAULT,
            USDC, // Wrong asset - should be WETH
            "Invalid Strategy",
            "osInvalid",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false,
            address(implementation)
        );
        vm.stopPrank();
    }

    /// @notice Test creating strategy with enableBurning = true
    function testEnableBurning() public {
        string memory strategyName = "Burning Enabled Strategy";

        vm.startPrank(management);
        address strategyAddress = factory.createStrategy(
            USDC_SPARK_VAULT,
            USDC,
            strategyName,
            "osBurning",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            true, // enableBurning = true
            address(implementation)
        );
        vm.stopPrank();

        assertTrue(strategyAddress != address(0), "Strategy should be deployed");
    }

    /// @notice Test computeStrategyAddress with different vaults produces different addresses
    function testComputeStrategyAddressDifferentVaults() public view {
        string memory strategyName = "Vault Test Strategy";

        address addr1 = factory.computeStrategyAddress(
            USDC_SPARK_VAULT,
            USDC,
            strategyName,
            "osVT1",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false,
            address(implementation),
            management
        );

        address addr2 = factory.computeStrategyAddress(
            WETH_SPARK_VAULT,
            WETH,
            strategyName,
            "osVT1",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false,
            address(implementation),
            management
        );

        assertTrue(addr1 != addr2, "Different vaults should produce different addresses");
    }
}
