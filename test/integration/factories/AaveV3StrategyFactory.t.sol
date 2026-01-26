// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { BaseFactoryIntegrationTest } from "test/integration/factories/base/BaseFactoryIntegrationTest.sol";
import { AaveV3Strategy } from "src/strategies/yieldDonating/AaveV3Strategy.sol";
import { AaveV3StrategyFactory } from "src/factories/AaveV3StrategyFactory.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

/// @title AaveV3StrategyFactory Test
/// @author Octant
/// @notice Integration tests for the AaveV3StrategyFactory using a mainnet fork
contract AaveV3StrategyFactoryTest is BaseFactoryIntegrationTest {
    // Factory and implementation
    AaveV3StrategyFactory public factory;
    YieldDonatingTokenizedStrategy public implementation;

    // Mainnet addresses
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address public constant AUSDC_V3 = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
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
        return "osAAVE";
    }

    function _deployFactory() internal override {
        factory = new AaveV3StrategyFactory();
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
        vm.label(address(factory), "AaveV3StrategyFactory");
        vm.label(USDC, "USDC");
        vm.label(AAVE_POOL, "Aave V3 Pool");
        vm.label(AUSDC_V3, "aUSDC V3");
        vm.label(TOKENIZED_STRATEGY_ADDRESS, "TokenizedStrategy");
    }

    function _vault() internal pure override returns (address) {
        return 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e; // AAVE_ADDRESSES_PROVIDER
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
                0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e, // AAVE_ADDRESSES_PROVIDER
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
    function testCreateStrategyAave() public {
        _testCreateStrategy("AaveV3 Vault Shares", "osAAVE");
    }

    /// @notice Test creating multiple strategies for the same user
    function testMultipleStrategiesPerUserAave() public {
        _testMultipleStrategiesPerUser("First AaveV3 Vault", "Second AaveV3 Vault");
    }

    /// @notice Test creating strategies for different users
    function testMultipleUsersAave() public {
        _testMultipleUsers();
    }

    /// @notice Test for deterministic addressing and duplicate prevention
    function testDeterministicAddressingAave() public {
        _testDeterministicAddressing();
    }

    /// @notice Test computeStrategyAddress matches actual deployment
    function testComputeStrategyAddressMatchesDeploymentAave() public {
        _testComputeStrategyAddressMatchesDeployment("Aave Compute Test", "osAAVE_CT");
    }

    /// @notice Test computeStrategyAddress with different deployers
    function testComputeStrategyAddressDifferentDeployersAave() public {
        _testComputeStrategyAddressDifferentDeployers();
    }

    /// @notice Test computeStrategyAddress with different parameters
    function testComputeStrategyAddressDifferentParamsAave() public {
        _testComputeStrategyAddressDifferentParams();
    }

    /// @notice Test computeStrategyAddress reverts on invalid vault
    function testComputeStrategyAddressInvalidVaultAave() public {
        _testComputeStrategyAddressInvalidVault();
    }

    /// @notice Test computeStrategyAddress reverts on invalid asset
    function testComputeStrategyAddressInvalidAssetAave() public {
        _testComputeStrategyAddressInvalidAsset();
    }
}
