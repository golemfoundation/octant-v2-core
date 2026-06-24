// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { QuadraticVotingMechanism } from "src/mechanisms/mechanism/QuadraticVotingMechanism.sol";
import { AllocationMechanismFactory } from "src/mechanisms/AllocationMechanismFactory.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { AllocationTestHelpers } from "./utils/AllocationTestHelpers.sol";

/// @title Mock ERC20 token with configurable decimals
contract MockTokenWithDecimals is ERC20 {
    uint8 private _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

/// @title Test decimal conversion in voting power calculation
contract DecimalConversionTest is AllocationTestHelpers {
    AllocationMechanismFactory factory;
    MockTokenWithDecimals token6; // 6 decimals (USDC-like)
    MockTokenWithDecimals token8; // 8 decimals (Bitcoin-like)
    MockTokenWithDecimals token18; // 18 decimals (ETH-like)

    address alice = address(0x1);

    function setUp() public {
        factory = new AllocationMechanismFactory();

        token6 = new MockTokenWithDecimals("USDC", "USDC", 6);
        token8 = new MockTokenWithDecimals("WBTC", "WBTC", 8);
        token18 = new MockTokenWithDecimals("WETH", "WETH", 18);

        // Mint tokens to alice
        token6.mint(alice, 1000 * 10 ** 6); // 1000 USDC
        token8.mint(alice, 1 * 10 ** 8); // 1 WBTC
        token18.mint(alice, 1000 * 10 ** 18); // 1000 WETH
    }

    function deployQuadraticMechanismWithToken(IERC20 asset) internal returns (QuadraticVotingMechanism) {
        return
            _deployQuadraticVoting(
                factory,
                _config({
                    asset: asset,
                    name: "Test Quadratic Mechanism",
                    symbol: "TESTQ",
                    votingDelay: 100,
                    votingPeriod: 1000,
                    quorumShares: 500,
                    timelockDelay: 1 days,
                    gracePeriod: 7 days,
                    owner: address(0)
                }),
                50,
                100
            );
    }

    /// @notice Test that 6-decimal tokens are properly scaled to 18 decimals (Quadratic)
    function testQuadraticDecimalConversion_6Decimals() public {
        QuadraticVotingMechanism mechanism = deployQuadraticMechanismWithToken(IERC20(address(token6)));

        uint256 deposit = 100 * 10 ** 6; // 100 USDC (6 decimals)

        // Test through actual signup to verify conversion works
        // Warp to ensure we're in the signup window (mechanism allows signup until votingEndTime)
        vm.warp(block.timestamp + 1);
        vm.startPrank(alice);
        token6.approve(address(mechanism), deposit);
        _tokenized(address(mechanism)).signup(deposit);
        vm.stopPrank();

        // Should convert to 18 decimals: 100 * 10^18
        uint256 expected = 100 * 10 ** 18;
        uint256 actualVotingPower = _tokenized(address(mechanism)).votingPower(alice);
        assertEq(actualVotingPower, expected, "6-decimal token should scale up to 18 decimals");
    }

    /// @notice Test that 8-decimal tokens are properly scaled to 18 decimals (Quadratic)
    function testQuadraticDecimalConversion_8Decimals() public {
        QuadraticVotingMechanism mechanism = deployQuadraticMechanismWithToken(IERC20(address(token8)));

        uint256 deposit = 1 * 10 ** 8; // 1 WBTC (8 decimals)

        // Warp to ensure we're in the signup window (mechanism allows signup until votingEndTime)
        vm.warp(block.timestamp + 1);
        vm.startPrank(alice);
        token8.approve(address(mechanism), deposit);
        _tokenized(address(mechanism)).signup(deposit);
        vm.stopPrank();

        // Should convert to 18 decimals: 1 * 10^18
        uint256 expected = 1 * 10 ** 18;
        uint256 actualVotingPower = _tokenized(address(mechanism)).votingPower(alice);
        assertEq(actualVotingPower, expected, "8-decimal token should scale up to 18 decimals");
    }

    /// @notice Test that 18-decimal tokens remain unchanged (Quadratic)
    function testQuadraticDecimalConversion_18Decimals() public {
        QuadraticVotingMechanism mechanism = deployQuadraticMechanismWithToken(IERC20(address(token18)));

        uint256 deposit = 100 * 10 ** 18; // 100 WETH (18 decimals)

        // Warp to ensure we're in the signup window (mechanism allows signup until votingEndTime)
        vm.warp(block.timestamp + 1);
        vm.startPrank(alice);
        token18.approve(address(mechanism), deposit);
        _tokenized(address(mechanism)).signup(deposit);
        vm.stopPrank();

        // Should remain the same
        uint256 actualVotingPower = _tokenized(address(mechanism)).votingPower(alice);
        assertEq(actualVotingPower, deposit, "18-decimal token should remain unchanged");
    }
}
