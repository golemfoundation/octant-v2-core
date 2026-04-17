// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.25;

import { Test } from "forge-std/Test.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { ERC4626Strategy } from "src/strategies/yieldDonating/ERC4626Strategy.sol";
import { MorphoCompounderStrategy } from "src/strategies/yieldDonating/MorphoCompounderStrategy.sol";

/// @notice Minimal 4626-shaped vault that always credits zero shares on deposit.
/// @dev Simulates the "downstream vault rounds minted shares to zero" regime
///      (high PPS + tiny deposit) without having to stage the inflation manually.
contract ZeroSharesVaultMock {
    address public immutable asset;

    constructor(address underlying) {
        asset = underlying;
    }

    function deposit(uint256 assets, address /*receiver*/) external returns (uint256) {
        IERC20(asset).transferFrom(msg.sender, address(this), assets);
        return 0;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address) external pure returns (uint256) {
        return 0;
    }

    function previewRedeem(uint256) external pure returns (uint256) {
        return 0;
    }

    function convertToAssets(uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @title Bailsec #55 / #57 (ERC4626 + Morpho slice) -- `_deployFunds` must revert on zero shares minted
/// @notice Pre-fix ERC4626Strategy and MorphoCompounderStrategy discarded the share return from their
///         target vault's deposit, so a vault that credits zero shares silently consumed the strategy's
///         assets. Post-fix, `require(shares > 0, ...)` converts that silent loss into an explicit
///         revert. `SparkStrategy` inherits the fix from `ERC4626Strategy`. The YearnV3Strategy slice
///         is in sibling file `BailsecZeroSharesDeployFundsYearn.t.sol` on PR #419.
contract BailsecZeroSharesDeployFundsTest is Test {
    ERC20Mock internal asset;
    YieldDonatingTokenizedStrategy internal implementation;
    ZeroSharesVaultMock internal targetVault;

    address internal management = address(0xA1);
    address internal keeper = address(0xA2);
    address internal emergencyAdmin = address(0xA3);
    address internal donationAddress = address(0xA4);
    address internal user = address(0xBEEF);

    uint256 internal constant DEPOSIT_AMOUNT = 1_000 ether;

    function setUp() public {
        asset = new ERC20Mock();
        targetVault = new ZeroSharesVaultMock(address(asset));
        implementation = new YieldDonatingTokenizedStrategy();
    }

    function _expectDepositReverts(address strategyAddr, string memory reason) internal {
        asset.mint(user, DEPOSIT_AMOUNT);
        vm.startPrank(user);
        asset.approve(strategyAddr, DEPOSIT_AMOUNT);
        vm.expectRevert(bytes(reason));
        ITokenizedStrategy(strategyAddr).deposit(DEPOSIT_AMOUNT, user);
        vm.stopPrank();
    }

    function test_bailsec_55_ERC4626Strategy_deployFundsRevertsOnZeroShares() public {
        ERC4626Strategy strategy = new ERC4626Strategy(
            address(targetVault),
            address(asset),
            "Octant ERC4626 Bailsec",
            "osBailsecE",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false,
            address(implementation)
        );
        _expectDepositReverts(address(strategy), "ERC4626Strategy: zero shares minted");
    }

    function test_bailsec_55_MorphoCompounderStrategy_deployFundsRevertsOnZeroShares() public {
        MorphoCompounderStrategy strategy = new MorphoCompounderStrategy(
            address(targetVault),
            address(asset),
            "Octant Morpho Bailsec",
            "osBailsecM",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false,
            address(implementation)
        );
        _expectDepositReverts(address(strategy), "MorphoCompounderStrategy: zero shares minted");
    }
}
