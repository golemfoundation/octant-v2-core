// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { BaseFactoryIntegrationTest } from "test/integration/factories/base/BaseFactoryIntegrationTest.sol";
import { SparkStrategy } from "src/strategies/yieldDonating/SparkStrategy.sol";
import { SparkStrategyFactory } from "src/factories/SparkStrategyFactory.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { SparkTestConfig } from "test/integration/strategies/config/SparkTestConfig.sol";

/// @title SparkStrategyFactory Test
/// @author Octant
/// @notice Integration tests for the SparkStrategyFactory using a mainnet fork
contract SparkStrategyFactoryTest is BaseFactoryIntegrationTest {
    // Factory and implementation
    SparkStrategyFactory public factory;
    YieldDonatingTokenizedStrategy public implementation;

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
        return SparkTestConfig.USDC;
    }

    function _strategySymbolPrefix() internal pure override returns (string memory) {
        return "osSpark";
    }

    function _deployFactory() internal override {
        factory = new SparkStrategyFactory();
    }

    function _deployImplementation() internal override returns (address) {
        implementation = new YieldDonatingTokenizedStrategy{ salt: keccak256("OCT_YIELD_DONATING_STRATEGY_V1") }();
        vm.etch(SparkTestConfig.TOKENIZED_STRATEGY_ADDRESS, address(implementation).code);
        return address(implementation);
    }

    function _createStrategy(
        string memory name,
        string memory symbol,
        address mgmt
    ) internal override returns (address) {
        return
            factory.createStrategy(
                SparkTestConfig.USDC_SPARK_VAULT,
                SparkTestConfig.USDC,
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
        vm.label(address(factory), "SparkStrategyFactory");
        vm.label(SparkTestConfig.USDC, "USDC");
        vm.label(SparkTestConfig.USDC_SPARK_VAULT, "USDC Spark Vault");
        vm.label(SparkTestConfig.TOKENIZED_STRATEGY_ADDRESS, "TokenizedStrategy");
    }

    function _vault() internal pure override returns (address) {
        return SparkTestConfig.USDC_SPARK_VAULT;
    }

    function _computeStrategyAddress(
        string memory name,
        string memory symbol,
        address mgmt,
        address deployer
    ) internal view override returns (address) {
        return
            factory.computeStrategyAddress(
                SparkTestConfig.USDC_SPARK_VAULT,
                SparkTestConfig.USDC,
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

    // ========== CONCRETE TESTS ==========

    /// @notice Test creating a strategy through the factory
    function testCreateStrategySpark() public {
        _testCreateStrategy("Spark USDC Vault Shares", "osSparkUSDC");
    }

    /// @notice Test creating multiple strategies for the same user
    function testMultipleStrategiesPerUserSpark() public {
        _testMultipleStrategiesPerUser("First Spark Vault", "Second Spark Vault");
    }

    /// @notice Test creating strategies for different users
    function testMultipleUsersSpark() public {
        _testMultipleUsers();
    }

    /// @notice Test for deterministic addressing and duplicate prevention
    function testDeterministicAddressingSpark() public {
        _testDeterministicAddressing();
    }

    /// @notice Test asset validation during strategy creation
    function testAssetValidationSpark() public {
        vm.startPrank(management);
        vm.expectRevert("Asset mismatch with target vault");
        factory.createStrategy(
            SparkTestConfig.USDC_SPARK_VAULT,
            SparkTestConfig.WETH, // Wrong asset - should be USDC
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

    /// @notice Test WETH strategy creation
    function testCreateWETHStrategySpark() public {
        vm.startPrank(management);
        address strategyAddress = factory.createStrategy(
            SparkTestConfig.WETH_SPARK_VAULT,
            SparkTestConfig.WETH,
            "Spark WETH Vault Shares",
            "osSparkWETH",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false,
            address(implementation)
        );
        vm.stopPrank();

        // Verify strategy
        SparkStrategy strategy = SparkStrategy(strategyAddress);
        assertEq(strategy.targetVault(), SparkTestConfig.WETH_SPARK_VAULT, "Target vault incorrect");
        assertEq(IERC4626(strategyAddress).asset(), SparkTestConfig.WETH, "Asset incorrect");
    }

    /// @notice Test computeStrategyAddress matches actual deployment
    function testComputeStrategyAddressMatchesDeploymentSpark() public {
        _testComputeStrategyAddressMatchesDeployment("Spark Compute Test", "osSpark_CT");
    }

    /// @notice Test computeStrategyAddress with different deployers
    function testComputeStrategyAddressDifferentDeployersSpark() public {
        _testComputeStrategyAddressDifferentDeployers();
    }

    /// @notice Test computeStrategyAddress with different parameters
    function testComputeStrategyAddressDifferentParamsSpark() public {
        _testComputeStrategyAddressDifferentParams();
    }
}
