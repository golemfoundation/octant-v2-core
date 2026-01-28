// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";

/// @title BaseIntegrationTest
/// @notice Base contract for all strategy integration tests providing common infrastructure
abstract contract BaseIntegrationTest is Test {
    using SafeERC20 for ERC20;

    // ========== STATE VARIABLES ==========

    /// @notice The vault interface for the deployed strategy
    ITokenizedStrategy public vault;

    /// @notice Management address
    address public management;

    /// @notice Keeper address
    address public keeper;

    /// @notice Emergency admin address
    address public emergencyAdmin;

    /// @notice Donation/dragon router address
    address public donationAddress;

    /// @notice Primary test user
    address public user;

    /// @notice Mainnet fork ID
    uint256 public mainnetFork;

    // ========== EVENTS ==========

    event Reported(uint256 profit, uint256 loss);

    // ========== ABSTRACT METHODS ==========

    /// @notice Returns the asset address for this strategy
    function _asset() internal view virtual returns (address);

    /// @notice Returns the strategy name
    function _strategyName() internal view virtual returns (string memory);

    /// @notice Returns the strategy symbol
    function _strategySymbol() internal view virtual returns (string memory);

    /// @notice Deploys the strategy and returns its address
    function _deployStrategy() internal virtual returns (address);

    /// @notice Labels addresses for better trace outputs
    function _labelAddresses() internal virtual;

    /// @notice Returns the initial deposit amount for setup
    function _initialDeposit() internal view virtual returns (uint256);

    // ========== SHARED HELPERS ==========

    /// @notice Helper function to airdrop tokens to a specified address
    /// @param _token The ERC20 token to airdrop
    /// @param _to The recipient address
    /// @param _amount The amount of tokens to airdrop
    function airdrop(ERC20 _token, address _to, uint256 _amount) public {
        uint256 balanceBefore = _token.balanceOf(_to);
        deal(address(_token), _to, balanceBefore + _amount);
    }

    /// @notice Sets up the mainnet fork
    function _setupFork() internal virtual {
        mainnetFork = vm.createFork("mainnet");
        vm.selectFork(mainnetFork);
    }

    /// @notice Sets up role addresses
    function _setupRoles() internal virtual {
        management = address(0x1);
        keeper = address(0x2);
        emergencyAdmin = address(0x3);
        donationAddress = address(0x4);
        user = address(0x1234);
    }

    /// @notice Airdrops initial assets to the test user
    function _airdropInitialAssets() internal virtual {
        airdrop(ERC20(_asset()), user, _initialDeposit());
    }

    /// @notice Approves strategy to spend user's tokens
    function _approveStrategy() internal virtual {
        vm.startPrank(user);
        ERC20(_asset()).approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Base setup that should be called by derived contracts
    function _baseSetUp() internal virtual {
        _setupFork();
        _setupRoles();
        address strategyAddr = _deployStrategy();
        vault = ITokenizedStrategy(strategyAddr);
        _labelAddresses();
        _airdropInitialAssets();
        _approveStrategy();
    }
}
