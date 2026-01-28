// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { BaseFactoryIntegrationTest } from "test/integration/factories/base/BaseFactoryIntegrationTest.sol";
import { RocketPoolStrategy } from "src/strategies/yieldSkimming/RocketPoolStrategy.sol";
import { RocketPoolStrategyFactory } from "src/factories/yieldSkimming/RocketPoolStrategyFactory.sol";
import { YieldSkimmingTokenizedStrategy } from "src/strategies/yieldSkimming/YieldSkimmingTokenizedStrategy.sol";

/// @title RocketPoolFactory Test
/// @author Octant
/// @notice Integration tests for the RocketPoolVaultFactory using a mainnet fork
contract RocketPoolStrategyFactoryTest is BaseFactoryIntegrationTest {
    // Factory and implementation
    RocketPoolStrategyFactory public factory;
    YieldSkimmingTokenizedStrategy public implementation;

    // Mainnet addresses
    address public constant R_ETH = 0xae78736Cd615f374D3085123A210448E74Fc6393;
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
        return R_ETH;
    }

    function _strategySymbolPrefix() internal pure override returns (string memory) {
        return "osRPL";
    }

    function _deployFactory() internal override {
        factory = new RocketPoolStrategyFactory();
    }

    function _deployImplementation() internal override returns (address) {
        implementation = new YieldSkimmingTokenizedStrategy{ salt: keccak256("OCT_YIELD_SKIMMING_STRATEGY_V1") }();
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
        vm.label(address(factory), "RocketPoolVaultFactory");
        vm.label(R_ETH, "rETH");
        vm.label(TOKENIZED_STRATEGY_ADDRESS, "TokenizedStrategy");
    }

    function _vault() internal pure override returns (address) {
        return R_ETH;
    }

    function _factoryValidatesVaultAsset() internal pure override returns (bool) {
        return true;
    }

    function _computeStrategyAddress(
        string memory name,
        string memory symbol,
        address mgmt,
        address deployer
    ) internal view override returns (address) {
        return
            factory.computeStrategyAddress(
                R_ETH,
                R_ETH,
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

    function _computeStrategyAddressWithVault(
        address vault,
        address asset,
        string memory name,
        string memory symbol,
        address mgmt,
        address deployer
    ) internal view override returns (address) {
        return
            factory.computeStrategyAddress(
                vault,
                asset,
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
    function testCreateStrategyRocketPool() public {
        _testCreateStrategy("RocketPool Vault Shares", "osRPL");
    }

    /// @notice Test creating multiple strategies for the same user
    function testMultipleStrategiesPerUserRocketPool() public {
        _testMultipleStrategiesPerUser("First RocketPool Vault", "Second RocketPool Vault");
    }

    /// @notice Test creating strategies for different users
    function testMultipleUsersRocketPool() public {
        _testMultipleUsers();
    }

    /// @notice Test for deterministic addressing and duplicate prevention
    function testDeterministicAddressingRocketPool() public {
        _testDeterministicAddressing();
    }

    /// @notice Test computeStrategyAddress matches actual deployment
    function testComputeStrategyAddressMatchesDeploymentRocketPool() public {
        _testComputeStrategyAddressMatchesDeployment("RocketPool Compute Test", "osRPL_CT");
    }

    /// @notice Test computeStrategyAddress with different deployers
    function testComputeStrategyAddressDifferentDeployersRocketPool() public {
        _testComputeStrategyAddressDifferentDeployers();
    }

    /// @notice Test computeStrategyAddress with different parameters
    function testComputeStrategyAddressDifferentParamsRocketPool() public {
        _testComputeStrategyAddressDifferentParams();
    }

    /// @notice Test computeStrategyAddress reverts on invalid vault
    function testComputeStrategyAddressInvalidVaultRocketPool() public {
        _testComputeStrategyAddressInvalidVault();
    }

    /// @notice Test computeStrategyAddress reverts on invalid asset
    function testComputeStrategyAddressInvalidAssetRocketPool() public {
        _testComputeStrategyAddressInvalidAsset();
    }
}
