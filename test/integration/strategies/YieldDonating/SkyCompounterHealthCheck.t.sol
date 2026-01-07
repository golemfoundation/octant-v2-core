// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { SkyCompounderStrategy } from "src/strategies/yieldDonating/SkyCompounderStrategy.sol";
import { IStaking } from "src/strategies/interfaces/ISky.sol";
import { BaseHealthCheck } from "src/strategies/periphery/BaseHealthCheck.sol";
import { SkyCompounderStrategyFactory } from "src/factories/SkyCompounderStrategyFactory.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

/// @title SkyCompounder Health Check Test
/// @author mil0x
/// @notice Unit tests for the BaseHealthCheck functionality in SkyCompounder strategy
contract SkyCompounterHealthCheckTest is Test {
    using SafeERC20 for ERC20;

    // Setup parameters struct to avoid stack too deep
    struct SetupParams {
        address management;
        address keeper;
        address emergencyAdmin;
        address donationAddress;
        string vaultSharesName;
        bytes32 strategySalt;
        address tokenizedStrategyAddress;
        bool enableBurning;
    }

    // Strategy instance
    SkyCompounderStrategy public strategy;
    ITokenizedStrategy public vault;

    // Factory for creating strategies
    YieldDonatingTokenizedStrategy tokenizedStrategy;
    SkyCompounderStrategyFactory public factory;

    // Strategy parameters
    address public management;
    address public keeper;
    address public emergencyAdmin;
    address public donationAddress;
    string public vaultSharesName = "SkyCompounder Health Check Test";
    bytes32 public strategySalt = keccak256("HEALTH_CHECK_TEST_SALT");

    // Test user
    address public user = address(0x1234);

    // Mainnet addresses
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address public constant STAKING = 0x0650CAF159C5A49f711e8169D4336ECB9b950275; // Sky Protocol Staking Contract
    address public constant TOKENIZED_STRATEGY_ADDRESS = 0x8cf7246a74704bBE59c9dF614ccB5e3d9717d8Ac;

    // Test constants
    uint256 public constant INITIAL_DEPOSIT = 100000e18;
    uint256 public mainnetFork;
    uint256 public mainnetForkBlock = 19230000; // A recent Ethereum mainnet block

    // Events from ITokenizedStrategy
    event Reported(uint256 profit, uint256 loss);

    /**
     * @notice Helper function to airdrop tokens to a specified address
     * @param _asset The ERC20 token to airdrop
     * @param _to The recipient address
     * @param _amount The amount of tokens to airdrop
     */
    function airdrop(ERC20 _asset, address _to, uint256 _amount) public {
        uint256 balanceBefore = _asset.balanceOf(_to);
        deal(address(_asset), _to, balanceBefore + _amount);
    }

    function setUp() public {
        // Create a mainnet fork
        mainnetFork = vm.createFork("mainnet");
        vm.selectFork(mainnetFork);

        // Etch YieldDonatingTokenizedStrategy
        YieldDonatingTokenizedStrategy tempStrategy = new YieldDonatingTokenizedStrategy{
            salt: keccak256("OCT_YIELD_DONATING_STRATEGY_V1")
        }();
        bytes memory tokenizedStrategyBytecode = address(tempStrategy).code;
        vm.etch(TOKENIZED_STRATEGY_ADDRESS, tokenizedStrategyBytecode);

        // Now use that address as our tokenizedStrategy
        tokenizedStrategy = YieldDonatingTokenizedStrategy(TOKENIZED_STRATEGY_ADDRESS);

        // Set up addresses
        management = address(0x1);
        keeper = address(0x2);
        emergencyAdmin = address(0x3);
        donationAddress = address(0x4);

        // Create setup params to avoid stack too deep
        SetupParams memory params = SetupParams({
            management: management,
            keeper: keeper,
            emergencyAdmin: emergencyAdmin,
            donationAddress: donationAddress,
            vaultSharesName: vaultSharesName,
            strategySalt: strategySalt,
            tokenizedStrategyAddress: address(tokenizedStrategy),
            enableBurning: true
        });

        // Deploy factory
        factory = new SkyCompounderStrategyFactory();

        // Deploy strategy using the factory's createStrategy method
        vm.startPrank(params.management);
        address strategyAddress = factory.createStrategy(
            params.vaultSharesName,
            "osSKY",
            params.management,
            params.keeper,
            params.emergencyAdmin,
            params.donationAddress,
            params.enableBurning,
            params.tokenizedStrategyAddress
        );
        vm.stopPrank();

        // Cast the deployed address to our strategy type
        strategy = SkyCompounderStrategy(strategyAddress);
        vault = ITokenizedStrategy(address(strategy));

        // Label addresses for better trace outputs
        vm.label(address(strategy), "SkyCompounder");
        vm.label(address(factory), "SkyCompounderStrategyFactory");
        vm.label(USDS, "USDS Token");
        vm.label(STAKING, "Sky Staking");
        vm.label(TOKENIZED_STRATEGY_ADDRESS, "TokenizedStrategy");
        vm.label(management, "Management");
        vm.label(keeper, "Keeper");
        vm.label(emergencyAdmin, "Emergency Admin");
        vm.label(donationAddress, "Donation Address");
        vm.label(user, "Test User");

        // Airdrop USDS tokens to test user
        airdrop(ERC20(USDS), user, INITIAL_DEPOSIT);

        // Approve strategy to spend user's tokens
        vm.startPrank(user);
        ERC20(USDS).approve(address(strategy), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Test the default health check parameters
    function testDefaultHealthCheckParams() public view {
        // Verify default settings
        assertTrue(strategy.doHealthCheck(), "Health check should be enabled by default");
        assertEq(strategy.profitLimitRatio(), 10000, "Default profit limit ratio should be 100%");
        assertEq(strategy.lossLimitRatio(), 0, "Default loss limit ratio should be 0%");
    }

    /// @notice Test setting health check parameters
    function testSetHealthCheckParams() public {
        // Set new values as management
        vm.startPrank(management);
        strategy.setProfitLimitRatio(5000); // 50%
        strategy.setLossLimitRatio(1000); // 10%
        strategy.setDoHealthCheck(false); // Turn off
        vm.stopPrank();

        // Verify the changes
        assertEq(strategy.profitLimitRatio(), 5000, "Profit limit ratio should be updated to 50%");
        assertEq(strategy.lossLimitRatio(), 1000, "Loss limit ratio should be updated to 10%");
        assertFalse(strategy.doHealthCheck(), "Health check should be turned off");

        // Test that unauthorized users cannot change parameters
        vm.startPrank(user);
        vm.expectRevert();
        strategy.setProfitLimitRatio(2000);

        vm.expectRevert();
        strategy.setLossLimitRatio(500);

        vm.expectRevert();
        strategy.setDoHealthCheck(true);
        vm.stopPrank();
    }

    /// @notice Test profit within limits passes health check
    function testProfitWithinLimits() public {
        // Set profit limit to 20%
        vm.startPrank(management);
        strategy.setProfitLimitRatio(2000);
        vm.stopPrank();

        // Make a deposit
        uint256 depositAmount = 1000e18;
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Simulate profit (10% - within the 20% limit)
        uint256 profitAmount = depositAmount / 10; // 10% profit
        airdrop(ERC20(USDS), address(strategy), profitAmount);

        // Report should pass health check
        vm.startPrank(keeper);
        vm.expectEmit(true, true, true, true);
        emit Reported(profitAmount, 0);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();

        // Verify profit was recognized
        assertEq(profit, profitAmount, "Profit should match airdropped amount");
        assertEq(loss, 0, "Loss should be zero");
    }

    /// @notice Test profit exceeding limits fails health check
    function testProfitExceedingLimits() public {
        // Set profit limit to 5%
        vm.startPrank(management);
        strategy.setProfitLimitRatio(500);
        vm.stopPrank();

        // Make a deposit
        uint256 depositAmount = 1000e18;
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Simulate profit (10% - exceeds the 5% limit)
        uint256 profitAmount = depositAmount / 10; // 10% profit
        airdrop(ERC20(USDS), address(strategy), profitAmount);

        // Report should fail health check
        vm.startPrank(keeper);
        vm.expectRevert("healthCheck");
        vault.report();
        vm.stopPrank();
    }

    /// @notice Test loss within limits passes health check
    function testLossWithinLimits() public {
        // Set loss limit to 10%
        vm.startPrank(management);
        strategy.setLossLimitRatio(1000);
        vm.stopPrank();

        // Make a deposit
        uint256 depositAmount = 1000e18;
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Simulate loss (5% - within the 10% limit)
        uint256 lossAmount = depositAmount / 20; // 5% loss

        // To simulate a loss, we'll manipulate the staked balance
        // The staking contract is treated as an ERC20 token
        uint256 currentStakedBalance = strategy.balanceOfStake();
        uint256 expectedAfterLoss = currentStakedBalance - lossAmount;

        // We need to mock the ERC20 balanceOf function on the staking contract
        vm.mockCall(
            STAKING,
            abi.encodeWithSelector(ERC20.balanceOf.selector, address(strategy)),
            abi.encode(expectedAfterLoss)
        );

        // Report should pass health check with the loss within limits
        vm.startPrank(keeper);
        vm.expectEmit(true, true, true, false); // Don't check exact loss amount
        emit Reported(0, 0); // Placeholder values
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();

        // The actual loss might be slightly different due to rounding
        assertEq(profit, 0, "Profit should be zero");
        assertApproxEqAbs(loss, lossAmount, 100, "Loss should approximately match simulated amount");
    }

    /// @notice Test loss exceeding limits fails health check
    function testLossExceedingLimits() public {
        // Set loss limit to 5%
        vm.startPrank(management);
        strategy.setLossLimitRatio(500);
        vm.stopPrank();

        // Make a deposit
        uint256 depositAmount = 1000e18;
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Simulate loss (10% - exceeds the 5% limit)
        uint256 lossAmount = depositAmount / 10; // 10% loss

        // To simulate a loss, we'll manipulate the staked balance
        uint256 currentStakedBalance = strategy.balanceOfStake();
        uint256 expectedAfterLoss = currentStakedBalance - lossAmount;

        // We need to mock the ERC20 balanceOf function on the staking contract
        vm.mockCall(
            STAKING,
            abi.encodeWithSelector(ERC20.balanceOf.selector, address(strategy)),
            abi.encode(expectedAfterLoss)
        );

        // Report should fail health check since the loss exceeds limits
        vm.startPrank(keeper);
        vm.expectRevert("healthCheck");
        vault.report();
        vm.stopPrank();
    }

    /// @notice Test disabled health check allows any profit/loss
    function testDisabledHealthCheck() public {
        // Set low limits
        vm.startPrank(management);
        strategy.setProfitLimitRatio(100); // 1%
        strategy.setLossLimitRatio(100); // 1%
        // But disable health check
        strategy.setDoHealthCheck(false);
        vm.stopPrank();

        // Make a deposit
        uint256 depositAmount = 1000e18;
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Simulate excessive profit (20% - would exceed the 1% limit)
        uint256 profitAmount = depositAmount / 5; // 20% profit
        airdrop(ERC20(USDS), address(strategy), profitAmount);

        // Report should pass despite exceeding limits because health check is disabled
        vm.startPrank(keeper);
        vm.expectEmit(true, true, true, true);
        emit Reported(profitAmount, 0);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();

        // Verify profit was recognized
        assertEq(profit, profitAmount, "Profit should match airdropped amount");
        assertEq(loss, 0, "Loss should be zero");

        // Verify health check was automatically re-enabled
        assertTrue(strategy.doHealthCheck(), "Health check should be automatically re-enabled");
    }

    /// @notice Test profit edge cases
    function testProfitEdgeCases() public {
        // Test profit limit ratio cannot be zero
        vm.startPrank(management);
        vm.expectRevert("!zero profit");
        strategy.setProfitLimitRatio(0);

        // Test profit limit ratio cannot exceed uint16 max
        vm.expectRevert("!too high");
        strategy.setProfitLimitRatio(uint256(type(uint16).max) + 1);

        // Valid value should work
        strategy.setProfitLimitRatio(1); // 0.01%
        assertEq(strategy.profitLimitRatio(), 1, "Profit limit ratio should be updated to 0.01%");
        vm.stopPrank();
    }

    /// @notice Test loss edge cases
    function testLossEdgeCases() public {
        // Test loss limit ratio cannot be 100% or higher
        vm.startPrank(management);
        vm.expectRevert("!loss limit");
        strategy.setLossLimitRatio(10000); // 100%

        // Valid value should work
        strategy.setLossLimitRatio(9999); // 99.99%
        assertEq(strategy.lossLimitRatio(), 9999, "Loss limit ratio should be updated to 99.99%");
        vm.stopPrank();
    }
}
