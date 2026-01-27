// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { BaseFactoryIntegrationTest } from "test/integration/factories/base/BaseFactoryIntegrationTest.sol";
import { YearnV3StrategyFactory } from "src/factories/yieldDonating/YearnV3StrategyFactory.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { YearnV3TestConfig } from "test/integration/strategies/config/YearnV3TestConfig.sol";

/// @title YearnV3StrategyFactory Test
/// @author Octant
/// @notice Integration tests for the YearnV3StrategyFactory using a mainnet fork
contract YearnV3StrategyFactoryTest is BaseFactoryIntegrationTest {
    // Factory and implementation
    YearnV3StrategyFactory public factory;
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
        return YearnV3TestConfig.USDC;
    }

    function _vault() internal pure override returns (address) {
        return YearnV3TestConfig.YEARN_V3_USDC_VAULT;
    }

    function _strategySymbolPrefix() internal pure override returns (string memory) {
        return "osYEARN";
    }

    function _deployFactory() internal override {
        factory = new YearnV3StrategyFactory();
    }

    function _deployImplementation() internal override returns (address) {
        implementation = new YieldDonatingTokenizedStrategy{ salt: keccak256("OCT_YIELD_DONATING_STRATEGY_V1") }();
        vm.etch(YearnV3TestConfig.TOKENIZED_STRATEGY_ADDRESS, address(implementation).code);
        return address(implementation);
    }

    function _createStrategy(
        string memory name,
        string memory symbol,
        address mgmt
    ) internal override returns (address) {
        return
            factory.createStrategy(
                YearnV3TestConfig.YEARN_V3_USDC_VAULT,
                YearnV3TestConfig.USDC,
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
        vm.label(address(factory), "YearnV3StrategyFactory");
        vm.label(YearnV3TestConfig.USDC, "USDC");
        vm.label(YearnV3TestConfig.YEARN_V3_USDC_VAULT, "YearnV3USDCVault");
        vm.label(YearnV3TestConfig.TOKENIZED_STRATEGY_ADDRESS, "TokenizedStrategy");
    }

    function _computeStrategyAddress(
        string memory name,
        string memory symbol,
        address mgmt,
        address deployer
    ) internal view override returns (address) {
        return
            factory.computeStrategyAddress(
                YearnV3TestConfig.YEARN_V3_USDC_VAULT,
                YearnV3TestConfig.USDC,
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
    function testCreateStrategyYearnV3() public {
        _testCreateStrategy("YearnV3 Vault Shares", "osYEARN");
    }

    /// @notice Test creating multiple strategies for the same user
    function testMultipleStrategiesPerUserYearnV3() public {
        _testMultipleStrategiesPerUser("First YearnV3 Vault", "Second YearnV3 Vault");
    }

    /// @notice Test creating strategies for different users
    function testMultipleUsersYearnV3() public {
        _testMultipleUsers();
    }

    /// @notice Test for deterministic addressing and duplicate prevention
    function testDeterministicAddressingYearnV3() public {
        _testDeterministicAddressing();
    }

    /// @notice Test computeStrategyAddress matches actual deployment
    function testComputeStrategyAddressMatchesDeploymentYearnV3() public {
        _testComputeStrategyAddressMatchesDeployment("YearnV3 Compute Test", "osYEARN_CT");
    }

    /// @notice Test computeStrategyAddress with different deployers
    function testComputeStrategyAddressDifferentDeployersYearnV3() public {
        _testComputeStrategyAddressDifferentDeployers();
    }

    /// @notice Test computeStrategyAddress with different parameters
    function testComputeStrategyAddressDifferentParamsYearnV3() public {
        _testComputeStrategyAddressDifferentParams();
    }

    /// @notice Test that YearnV3-specific info is stored correctly
    function testYearnV3SpecificInfoStored() public {
        vm.startPrank(management);
        address strategyAddress = _createStrategy("YearnV3 Info Test", "osYEARN_IT", management);
        vm.stopPrank();

        address storedManagement = factory.yearnV3StrategyInfo(strategyAddress);
        assertEq(storedManagement, management, "Management address should be stored in YearnV3-specific info");
    }
}
