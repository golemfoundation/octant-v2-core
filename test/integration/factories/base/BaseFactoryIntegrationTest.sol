// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";
import { BaseStrategyFactory } from "src/factories/BaseStrategyFactory.sol";

/// @title BaseFactoryIntegrationTest
/// @notice Base contract for all factory integration tests providing common infrastructure
abstract contract BaseFactoryIntegrationTest is Test {
    using SafeERC20 for ERC20;

    // ========== STATE VARIABLES ==========

    /// @notice Management address
    address public management;

    /// @notice Keeper address
    address public keeper;

    /// @notice Emergency admin address
    address public emergencyAdmin;

    /// @notice Donation address
    address public donationAddress;

    /// @notice Mainnet fork ID
    uint256 public mainnetFork;

    // ========== ABSTRACT METHODS ==========

    /// @notice Returns the factory address
    function _factory() internal view virtual returns (address);

    /// @notice Returns the implementation address
    function _implementation() internal view virtual returns (address);

    /// @notice Returns the expected asset address for strategies
    function _asset() internal pure virtual returns (address);

    /// @notice Returns the expected vault address for strategies (used by computeStrategyAddress)
    function _vault() internal view virtual returns (address);

    /// @notice Returns true if the factory validates vault/asset parameters
    /// @dev Override to return true for factories with hardcoded vault/asset that validate inputs
    function _factoryValidatesVaultAsset() internal pure virtual returns (bool) {
        return false;
    }

    /// @notice Returns the strategy symbol prefix
    function _strategySymbolPrefix() internal pure virtual returns (string memory);

    /// @notice Creates a strategy with the given parameters
    /// @param name The strategy name
    /// @param symbol The strategy symbol
    /// @param mgmt The management address
    /// @return The deployed strategy address
    function _createStrategy(string memory name, string memory symbol, address mgmt) internal virtual returns (address);

    /// @notice Deploys the factory
    function _deployFactory() internal virtual;

    /// @notice Deploys the implementation and returns its address
    function _deployImplementation() internal virtual returns (address);

    /// @notice Labels factory-specific addresses
    function _labelFactoryAddresses() internal virtual;

    /// @notice Computes the strategy address using the factory's computeStrategyAddress function
    /// @param name The strategy name
    /// @param symbol The strategy symbol
    /// @param mgmt The management address
    /// @param deployer The deployer address
    /// @return The computed strategy address
    function _computeStrategyAddress(
        string memory name,
        string memory symbol,
        address mgmt,
        address deployer
    ) internal view virtual returns (address);

    // ========== SHARED SETUP ==========

    /// @notice Base setup that should be called by derived contracts
    function _baseSetUp() internal virtual {
        mainnetFork = vm.createFork("mainnet");
        vm.selectFork(mainnetFork);
        _setupRoles();
        _deployImplementation();
        _deployFactory();
        _labelBaseAddresses();
        _labelFactoryAddresses();
    }

    /// @notice Sets up role addresses
    function _setupRoles() internal virtual {
        management = address(0x1);
        keeper = address(0x2);
        emergencyAdmin = address(0x3);
        donationAddress = address(0x4);
    }

    /// @notice Labels base addresses
    function _labelBaseAddresses() internal virtual {
        vm.label(management, "Management");
        vm.label(keeper, "Keeper");
        vm.label(emergencyAdmin, "Emergency Admin");
        vm.label(donationAddress, "Donation Address");
    }

    // ========== SHARED TEST IMPLEMENTATIONS ==========

    /// @notice Shared test: strategy creation
    /// @param vaultName The vault name to use
    /// @param symbol The symbol to use
    function _testCreateStrategy(string memory vaultName, string memory symbol) internal virtual {
        vm.startPrank(management);
        address strategyAddress = _createStrategy(vaultName, symbol, management);
        vm.stopPrank();

        // Verify factory tracking
        (
            address deployerAddress,
            uint256 timestamp,
            string memory name,
            address stratDonationAddress
        ) = BaseStrategyFactory(_factory()).strategies(management, 0);
        assertEq(deployerAddress, management, "Deployer address incorrect");
        assertEq(name, vaultName, "Vault name incorrect");
        assertEq(stratDonationAddress, donationAddress, "Donation address incorrect");
        assertTrue(timestamp > 0, "Timestamp should be set");

        // Verify strategy asset and symbol
        assertEq(IERC4626(strategyAddress).asset(), _asset(), "Asset incorrect");
        assertEq(ITokenizedStrategy(strategyAddress).symbol(), symbol, "Symbol incorrect");
    }

    /// @notice Shared test: multiple strategies per user
    /// @param first The first vault name
    /// @param second The second vault name
    function _testMultipleStrategiesPerUser(string memory first, string memory second) internal virtual {
        vm.startPrank(management);
        address firstAddr = _createStrategy(first, string.concat(_strategySymbolPrefix(), "1"), management);
        address secondAddr = _createStrategy(second, string.concat(_strategySymbolPrefix(), "2"), management);
        vm.stopPrank();

        (address deployer1, , string memory name1, ) = BaseStrategyFactory(_factory()).strategies(management, 0);
        assertEq(deployer1, management, "First deployer address incorrect");
        assertEq(name1, first, "First vault name incorrect");

        (address deployer2, , string memory name2, ) = BaseStrategyFactory(_factory()).strategies(management, 1);
        assertEq(deployer2, management, "Second deployer address incorrect");
        assertEq(name2, second, "Second vault name incorrect");

        assertTrue(firstAddr != secondAddr, "Strategies should have different addresses");
    }

    /// @notice Shared test: multiple users
    function _testMultipleUsers() internal virtual {
        address firstUser = address(0x5678);
        address secondUser = address(0x9876);

        vm.startPrank(firstUser);
        address firstAddr = _createStrategy("First User Vault", string.concat(_strategySymbolPrefix(), "1"), firstUser);
        vm.stopPrank();

        vm.startPrank(secondUser);
        address secondAddr = _createStrategy(
            "Second User Vault",
            string.concat(_strategySymbolPrefix(), "2"),
            secondUser
        );
        vm.stopPrank();

        (address deployer1, , string memory name1, ) = BaseStrategyFactory(_factory()).strategies(firstUser, 0);
        assertEq(deployer1, firstUser, "First user's deployer address incorrect");
        assertEq(name1, "First User Vault", "First user's vault name incorrect");

        (address deployer2, , string memory name2, ) = BaseStrategyFactory(_factory()).strategies(secondUser, 0);
        assertEq(deployer2, secondUser, "Second user's deployer address incorrect");
        assertEq(name2, "Second User Vault", "Second user's vault name incorrect");

        assertTrue(firstAddr != secondAddr, "Strategies should have different addresses");
    }

    /// @notice Shared test: deterministic addressing
    function _testDeterministicAddressing() internal virtual {
        string memory vaultName = "Deterministic Vault";
        string memory symbol = string.concat(_strategySymbolPrefix(), "DET");

        vm.startPrank(management);
        address firstAddr = _createStrategy(vaultName, symbol, management);

        // Same params should revert
        vm.expectRevert(abi.encodeWithSelector(BaseStrategyFactory.StrategyAlreadyExists.selector, firstAddr));
        _createStrategy(vaultName, symbol, management);

        // Different params should succeed
        address secondAddr = _createStrategy(
            "Different Vault",
            string.concat(_strategySymbolPrefix(), "DIF"),
            management
        );
        vm.stopPrank();

        assertTrue(firstAddr != secondAddr, "Different params should create different address");
    }

    /// @notice Shared test: computeStrategyAddress matches actual deployment
    /// @param vaultName The vault name to use
    /// @param symbol The symbol to use
    function _testComputeStrategyAddressMatchesDeployment(
        string memory vaultName,
        string memory symbol
    ) internal virtual {
        // Compute expected address before deployment
        address expectedAddress = _computeStrategyAddress(vaultName, symbol, management, management);

        // Deploy the strategy
        vm.startPrank(management);
        address actualAddress = _createStrategy(vaultName, symbol, management);
        vm.stopPrank();

        // Verify computed address matches actual deployment
        assertEq(expectedAddress, actualAddress, "Computed address should match deployed address");
    }

    /// @notice Shared test: computeStrategyAddress with different deployers
    function _testComputeStrategyAddressDifferentDeployers() internal virtual {
        string memory vaultName = "Deployer Test Vault";
        string memory symbol = string.concat(_strategySymbolPrefix(), "DEP");

        address deployer1 = address(0x1111);
        address deployer2 = address(0x2222);

        // Compute addresses for different deployers
        address addr1 = _computeStrategyAddress(vaultName, symbol, management, deployer1);
        address addr2 = _computeStrategyAddress(vaultName, symbol, management, deployer2);

        // Different deployers should result in different addresses
        assertTrue(addr1 != addr2, "Different deployers should produce different addresses");
    }

    /// @notice Shared test: computeStrategyAddress with different parameters
    function _testComputeStrategyAddressDifferentParams() internal virtual {
        string memory symbol = string.concat(_strategySymbolPrefix(), "PARAM");

        // Same params should give same address
        address addr1 = _computeStrategyAddress("Same Vault", symbol, management, management);
        address addr2 = _computeStrategyAddress("Same Vault", symbol, management, management);
        assertEq(addr1, addr2, "Same params should produce same address");

        // Different name should give different address
        address addr3 = _computeStrategyAddress("Different Vault", symbol, management, management);
        assertTrue(addr1 != addr3, "Different name should produce different address");

        // Different symbol should give different address
        address addr4 = _computeStrategyAddress("Same Vault", "DIFF", management, management);
        assertTrue(addr1 != addr4, "Different symbol should produce different address");
    }

    /// @notice Shared test: computeStrategyAddress reverts on invalid vault (for factories with validation)
    /// @dev Only call this for factories where _factoryValidatesVaultAsset() returns true
    function _testComputeStrategyAddressInvalidVault() internal virtual {
        require(_factoryValidatesVaultAsset(), "Factory does not validate vault/asset");

        address invalidVault = address(0xDEAD);
        string memory name = "Invalid Vault Test";
        string memory symbol = string.concat(_strategySymbolPrefix(), "INV");

        vm.expectRevert(abi.encodeWithSelector(BaseStrategyFactory.InvalidVault.selector, invalidVault, _vault()));

        // Call computeStrategyAddress with invalid vault - this will need to be implemented
        // by calling the factory's computeStrategyAddress directly with the invalid vault
        _computeStrategyAddressWithVault(invalidVault, _asset(), name, symbol, management, management);
    }

    /// @notice Shared test: computeStrategyAddress reverts on invalid asset (for factories with validation)
    /// @dev Only call this for factories where _factoryValidatesVaultAsset() returns true
    function _testComputeStrategyAddressInvalidAsset() internal virtual {
        require(_factoryValidatesVaultAsset(), "Factory does not validate vault/asset");

        address invalidAsset = address(0xBEEF);
        string memory name = "Invalid Asset Test";
        string memory symbol = string.concat(_strategySymbolPrefix(), "INV");

        vm.expectRevert(abi.encodeWithSelector(BaseStrategyFactory.InvalidAsset.selector, invalidAsset, _asset()));

        _computeStrategyAddressWithVault(_vault(), invalidAsset, name, symbol, management, management);
    }

    /// @notice Helper to call computeStrategyAddress with custom vault/asset (for validation tests)
    /// @dev Override in factories that need to test invalid vault/asset validation
    function _computeStrategyAddressWithVault(
        address vault,
        address asset,
        string memory name,
        string memory symbol,
        address mgmt,
        address deployer
    ) internal view virtual returns (address) {
        // Default implementation - override in factory tests that validate vault/asset
        vault;
        asset;
        name;
        symbol;
        mgmt;
        deployer;
        revert("Override _computeStrategyAddressWithVault for vault/asset validation tests");
    }
}
