// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { BaseFactoryIntegrationTest } from "test/integration/factories/base/BaseFactoryIntegrationTest.sol";
import { LidoStrategy } from "src/strategies/yieldSkimming/LidoStrategy.sol";
import { LidoStrategyFactory } from "src/factories/LidoStrategyFactory.sol";
import { YieldSkimmingTokenizedStrategy } from "src/strategies/yieldSkimming/YieldSkimmingTokenizedStrategy.sol";

/// @title LidoStrategyFactory Test
/// @author Octant
/// @notice Integration tests for the LidoVaultFactory using a mainnet fork
contract LidoStrategyFactoryTest is BaseFactoryIntegrationTest {
    // Factory and implementation
    LidoStrategyFactory public factory;
    YieldSkimmingTokenizedStrategy public implementation;

    // Mainnet addresses
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
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
        return WSTETH;
    }

    function _strategySymbolPrefix() internal pure override returns (string memory) {
        return "osLIDO";
    }

    function _deployFactory() internal override {
        factory = new LidoStrategyFactory();
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
        vm.label(address(factory), "LidoVaultFactory");
        vm.label(WSTETH, "wstETH");
        vm.label(TOKENIZED_STRATEGY_ADDRESS, "TokenizedStrategy");
    }

    function _vault() internal pure override returns (address) {
        return WSTETH;
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
                WSTETH,
                WSTETH,
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
    function testCreateStrategyLido() public {
        _testCreateStrategy("Lido Vault Shares", "osLIDO");
    }

    /// @notice Test creating multiple strategies for the same user
    function testMultipleStrategiesPerUserLido() public {
        _testMultipleStrategiesPerUser("First Lido Vault", "Second Lido Vault");
    }

    /// @notice Test creating strategies for different users
    function testMultipleUsersLido() public {
        _testMultipleUsers();
    }

    /// @notice Test for deterministic addressing and duplicate prevention
    function testDeterministicAddressingLido() public {
        _testDeterministicAddressing();
    }

    /// @notice Test computeStrategyAddress matches actual deployment
    function testComputeStrategyAddressMatchesDeploymentLido() public {
        _testComputeStrategyAddressMatchesDeployment("Lido Compute Test", "osLIDO_CT");
    }

    /// @notice Test computeStrategyAddress with different deployers
    function testComputeStrategyAddressDifferentDeployersLido() public {
        _testComputeStrategyAddressDifferentDeployers();
    }

    /// @notice Test computeStrategyAddress with different parameters
    function testComputeStrategyAddressDifferentParamsLido() public {
        _testComputeStrategyAddressDifferentParams();
    }

    /// @notice Test computeStrategyAddress reverts on invalid vault
    function testComputeStrategyAddressInvalidVaultLido() public {
        _testComputeStrategyAddressInvalidVault();
    }

    /// @notice Test computeStrategyAddress reverts on invalid asset
    function testComputeStrategyAddressInvalidAssetLido() public {
        _testComputeStrategyAddressInvalidAsset();
    }
}
