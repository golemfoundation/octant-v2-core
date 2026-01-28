// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { BaseFactoryIntegrationTest } from "test/integration/factories/base/BaseFactoryIntegrationTest.sol";
import { SkyCompounderStrategy } from "src/strategies/yieldDonating/SkyCompounderStrategy.sol";
import { SkyCompounderStrategyFactory } from "src/factories/SkyCompounderStrategyFactory.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

/// @title SkyCompounderStrategyFactory Test
/// @author mil0x
/// @notice Integration tests for the SkyCompounderStrategyFactory using a mainnet fork
contract SkyCompounderStrategyFactoryTest is BaseFactoryIntegrationTest {
    // Factory and implementation
    SkyCompounderStrategyFactory public factory;
    YieldDonatingTokenizedStrategy public tokenizedStrategy;

    // Mainnet addresses
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address public constant STAKING = 0x0650CAF159C5A49f711e8169D4336ECB9b950275;
    address public constant TOKENIZED_STRATEGY_ADDRESS = 0x8cf7246a74704bBE59c9dF614ccB5e3d9717d8Ac;

    function setUp() public {
        _baseSetUp();
    }

    // ========== ABSTRACT IMPLEMENTATIONS ==========

    function _factory() internal view override returns (address) {
        return address(factory);
    }

    function _implementation() internal view override returns (address) {
        return address(tokenizedStrategy);
    }

    function _asset() internal pure override returns (address) {
        return USDS;
    }

    function _strategySymbolPrefix() internal pure override returns (string memory) {
        return "osSKY";
    }

    function _deployFactory() internal override {
        factory = new SkyCompounderStrategyFactory();
    }

    function _deployImplementation() internal override returns (address) {
        YieldDonatingTokenizedStrategy tempStrategy = new YieldDonatingTokenizedStrategy{
            salt: keccak256("OCT_YIELD_DONATING_STRATEGY_V1")
        }();
        vm.etch(TOKENIZED_STRATEGY_ADDRESS, address(tempStrategy).code);
        tokenizedStrategy = YieldDonatingTokenizedStrategy(TOKENIZED_STRATEGY_ADDRESS);
        return address(tokenizedStrategy);
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
                true, // enableBurning
                address(tokenizedStrategy)
            );
    }

    function _labelFactoryAddresses() internal override {
        vm.label(address(factory), "SkyCompounderStrategyFactory");
        vm.label(USDS, "USDS Token");
        vm.label(STAKING, "Sky Staking");
        vm.label(TOKENIZED_STRATEGY_ADDRESS, "TokenizedStrategy");
    }

    function _vault() internal pure override returns (address) {
        return STAKING;
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
                STAKING,
                USDS,
                name,
                symbol,
                mgmt,
                keeper,
                emergencyAdmin,
                donationAddress,
                true, // enableBurning
                address(tokenizedStrategy),
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
                true, // enableBurning
                address(tokenizedStrategy),
                deployer
            );
    }

    // ========== CONCRETE TESTS ==========

    /// @notice Test creating a strategy through the factory
    function testCreateStrategySky() public {
        _testCreateStrategy("SkyCompounder Vault Shares", "osSKY");
    }

    /// @notice Test creating multiple strategies for the same user
    function testMultipleStrategiesPerUserSky() public {
        _testMultipleStrategiesPerUser("First SkyCompounder Vault", "Second SkyCompounder Vault");
    }

    /// @notice Test creating strategies for different users
    function testMultipleUsersSky() public {
        _testMultipleUsers();
    }

    /// @notice Test for deterministic addressing and duplicate prevention
    function testDeterministicAddressingSky() public {
        _testDeterministicAddressing();
    }

    /// @notice Test computeStrategyAddress matches actual deployment
    function testComputeStrategyAddressMatchesDeploymentSky() public {
        _testComputeStrategyAddressMatchesDeployment("Sky Compute Test", "osSKY_CT");
    }

    /// @notice Test computeStrategyAddress with different deployers
    function testComputeStrategyAddressDifferentDeployersSky() public {
        _testComputeStrategyAddressDifferentDeployers();
    }

    /// @notice Test computeStrategyAddress with different parameters
    function testComputeStrategyAddressDifferentParamsSky() public {
        _testComputeStrategyAddressDifferentParams();
    }

    /// @notice Test computeStrategyAddress reverts on invalid vault
    function testComputeStrategyAddressInvalidVaultSky() public {
        _testComputeStrategyAddressInvalidVault();
    }

    /// @notice Test computeStrategyAddress reverts on invalid asset
    function testComputeStrategyAddressInvalidAssetSky() public {
        _testComputeStrategyAddressInvalidAsset();
    }
}
