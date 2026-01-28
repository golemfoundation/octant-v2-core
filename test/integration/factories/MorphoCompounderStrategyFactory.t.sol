// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { BaseFactoryIntegrationTest } from "test/integration/factories/base/BaseFactoryIntegrationTest.sol";
import { MorphoCompounderStrategyFactory } from "src/factories/MorphoCompounderStrategyFactory.sol";
import { YieldSkimmingTokenizedStrategy } from "src/strategies/yieldSkimming/YieldSkimmingTokenizedStrategy.sol";

/// @title MorphoCompounderStrategyFactory Test
/// @author Octant
/// @notice Integration tests for the MorphoCompounderFactory using a mainnet fork
contract MorphoCompounderStrategyFactoryTest is BaseFactoryIntegrationTest {
    // Factory and implementation
    MorphoCompounderStrategyFactory public factory;
    YieldSkimmingTokenizedStrategy public implementation;

    // Mainnet addresses
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant YIELD_VAULT = 0x074134A2784F4F66b6ceD6f68849382990Ff3215;
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

    function _strategySymbolPrefix() internal pure override returns (string memory) {
        return "osMORPHO";
    }

    function _deployFactory() internal override {
        factory = new MorphoCompounderStrategyFactory();
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
        vm.label(address(factory), "MorphoCompounderFactory");
        vm.label(USDC, "USDC");
        vm.label(YIELD_VAULT, "Morpho Yield Vault");
        vm.label(TOKENIZED_STRATEGY_ADDRESS, "TokenizedStrategy");
    }

    function _vault() internal pure override returns (address) {
        return YIELD_VAULT;
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
                YIELD_VAULT,
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
    function testCreateStrategyMorpho() public {
        _testCreateStrategy("MorphoCompounder Vault Shares", "osMORPHO");
    }

    /// @notice Test creating multiple strategies for the same user
    function testMultipleStrategiesPerUserMorpho() public {
        _testMultipleStrategiesPerUser("First MorphoCompounder Vault", "Second MorphoCompounder Vault");
    }

    /// @notice Test creating strategies for different users
    function testMultipleUsersMorpho() public {
        _testMultipleUsers();
    }

    /// @notice Test for deterministic addressing and duplicate prevention
    function testDeterministicAddressingMorpho() public {
        _testDeterministicAddressing();
    }

    /// @notice Test computeStrategyAddress matches actual deployment
    function testComputeStrategyAddressMatchesDeploymentMorpho() public {
        _testComputeStrategyAddressMatchesDeployment("Morpho Compute Test", "osMORPHO_CT");
    }

    /// @notice Test computeStrategyAddress with different deployers
    function testComputeStrategyAddressDifferentDeployersMorpho() public {
        _testComputeStrategyAddressDifferentDeployers();
    }

    /// @notice Test computeStrategyAddress with different parameters
    function testComputeStrategyAddressDifferentParamsMorpho() public {
        _testComputeStrategyAddressDifferentParams();
    }

    /// @notice Test computeStrategyAddress reverts on invalid vault
    function testComputeStrategyAddressInvalidVaultMorpho() public {
        _testComputeStrategyAddressInvalidVault();
    }

    /// @notice Test computeStrategyAddress reverts on invalid asset
    function testComputeStrategyAddressInvalidAssetMorpho() public {
        _testComputeStrategyAddressInvalidAsset();
    }
}
