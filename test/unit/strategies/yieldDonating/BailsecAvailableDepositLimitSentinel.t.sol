// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.25;

import { Test } from "forge-std/Test.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { YearnV3Strategy } from "src/strategies/yieldDonating/YearnV3Strategy.sol";

/// @notice Minimal vault that always advertises `type(uint256).max` as `maxDeposit`.
/// @dev Mirrors the ERC-4626 "infinite capacity" sentinel returned by unrestricted Yearn/Morpho/Spark vaults.
contract InfiniteCapacityVaultMock {
    address public immutable asset;

    constructor(address underlying) {
        asset = underlying;
    }

    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address) external pure returns (uint256) {
        return 0;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function convertToAssets(uint256) external pure returns (uint256) {
        return 0;
    }

    function previewRedeem(uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @title Bailsec #52 -- `availableDepositLimit` must preserve the `type(uint256).max` sentinel
/// @notice Pre-fix the function subtracts idle balance unconditionally, so `maxDeposit == uint256.max`
///         becomes `uint256.max - idle`; `TokenizedStrategy._maxMint` then runs `_convertToShares` with
///         that near-max assets argument and overflows in `mulDiv` whenever share price != 1.
///         Post-fix the function returns the sentinel verbatim so `_maxMint` short-circuits.
contract BailsecAvailableDepositLimitSentinelTest is Test {
    ERC20Mock internal asset;
    YieldDonatingTokenizedStrategy internal implementation;
    InfiniteCapacityVaultMock internal yearnVault;
    YearnV3Strategy internal strategy;

    address internal management = address(0xA1);
    address internal keeper = address(0xA2);
    address internal emergencyAdmin = address(0xA3);
    address internal donationAddress = address(0xA4);

    uint256 internal constant IDLE_BALANCE = 1_000 ether;

    function setUp() public {
        asset = new ERC20Mock();
        yearnVault = new InfiniteCapacityVaultMock(address(asset));
        implementation = new YieldDonatingTokenizedStrategy();

        strategy = new YearnV3Strategy(
            address(yearnVault),
            address(asset),
            "Octant Yearn Bailsec",
            "osBailsecY",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false,
            address(implementation)
        );

        // Seed idle balance directly on the strategy so the pre-fix arithmetic clobbers the sentinel.
        asset.mint(address(strategy), IDLE_BALANCE);
    }

    function test_bailsec_52_availableDepositLimit_preservesMaxSentinel() public view {
        // Pre-fix this returns `type(uint256).max - IDLE_BALANCE`; post-fix it returns the sentinel
        // so `TokenizedStrategy._maxMint` can short-circuit `_convertToShares`.
        assertEq(
            strategy.availableDepositLimit(address(0)),
            type(uint256).max,
            "availableDepositLimit must preserve the uint256.max sentinel when the target vault advertises infinite capacity"
        );
    }

    function test_bailsec_52_maxMint_returnsMaxSentinel() public view {
        // Pre-fix `_maxMint` enters the `_convertToShares(huge_value, ...)` branch and would overflow
        // once share price != 1; post-fix it short-circuits and returns the sentinel directly.
        assertEq(
            ITokenizedStrategy(address(strategy)).maxMint(address(0xBEEF)),
            type(uint256).max,
            "maxMint must forward the uint256.max sentinel from availableDepositLimit"
        );
    }
}
