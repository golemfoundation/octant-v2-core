// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { AaveV3Strategy } from "src/strategies/yieldDonating/AaveV3Strategy.sol";
import { BaseHealthCheck } from "src/strategies/periphery/BaseHealthCheck.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IMockStrategy } from "test/mocks/zodiac-core/IMockStrategy.sol";
import { AaveV3StrategyFactory } from "src/factories/AaveV3StrategyFactory.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IPoolDataProvider {
    function getReserveCaps(address asset) external view returns (uint256 borrowCap, uint256 supplyCap);
    function getATokenTotalSupply(address asset) external view returns (uint256);
}

/// @title AaveV3 Yield Donating Test
/// @author Octant
/// @notice Integration tests for the yield donating AaveV3 strategy using a mainnet fork
contract AaveV3DonatingStrategyTest is Test {
    using SafeERC20 for ERC20;

    // Setup parameters struct to avoid stack too deep
    struct SetupParams {
        address management;
        address keeper;
        address emergencyAdmin;
        address donationAddress;
        string strategyName;
        bytes32 salt;
        address implementationAddress;
    }

    // Strategy instance
    AaveV3Strategy public strategy;

    // Strategy parameters
    address public management;
    address public keeper;
    address public emergencyAdmin;
    address public donationAddress;
    AaveV3StrategyFactory public factory;
    string public strategyName = "AaveV3 Donating Strategy";

    // Test user
    address public user = address(0x1234);

    // Mainnet addresses
    address public constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address public constant AAVE_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address public constant AAVE_DATA_PROVIDER = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;
    address public constant AUSDC_V3 = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant TOKENIZED_STRATEGY_ADDRESS = 0x8cf7246a74704bBE59c9dF614ccB5e3d9717d8Ac;
    YieldDonatingTokenizedStrategy public implementation;

    // Test constants
    uint256 public constant INITIAL_DEPOSIT = 100000e6; // USDC has 6 decimals
    uint256 public mainnetFork;
    uint256 public mainnetForkBlock = 21463000; // Recent mainnet block

    // Test whale address with USDC
    address public constant USDC_WHALE = 0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503;

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
        implementation = new YieldDonatingTokenizedStrategy{ salt: keccak256("OCT_YIELD_DONATING_STRATEGY_V1") }();
        bytes memory tokenizedStrategyBytecode = address(implementation).code;
        vm.etch(TOKENIZED_STRATEGY_ADDRESS, tokenizedStrategyBytecode);

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
            strategyName: strategyName,
            salt: keccak256("OCT_AAVE_V3_STRATEGY_V1"),
            implementationAddress: address(implementation)
        });

        // AaveV3StrategyFactory
        factory = new AaveV3StrategyFactory{ salt: keccak256("OCT_AAVE_V3_STRATEGY_VAULT_FACTORY_V1") }();

        // Deploy strategy
        strategy = AaveV3Strategy(
            factory.createStrategy(
                params.strategyName,
                params.management,
                params.keeper,
                params.emergencyAdmin,
                params.donationAddress,
                false, // enableBurning
                params.implementationAddress
            )
        );

        // Label addresses for better trace outputs
        vm.label(address(strategy), "AaveV3Donating");
        vm.label(AAVE_POOL, "Aave V3 Pool");
        vm.label(AUSDC_V3, "aUSDC V3");
        vm.label(USDC, "USDC");
        vm.label(management, "Management");
        vm.label(keeper, "Keeper");
        vm.label(emergencyAdmin, "Emergency Admin");
        vm.label(donationAddress, "Donation Address");
        vm.label(user, "Test User");
        vm.label(USDC_WHALE, "USDC Whale");

        // Airdrop USDC tokens to test user
        airdrop(ERC20(USDC), user, INITIAL_DEPOSIT);

        // Approve strategy to spend user's tokens
        vm.startPrank(user);
        ERC20(USDC).approve(address(strategy), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Test that the strategy is properly initialized
    function testInitialization() public view {
        assertEq(IERC4626(address(strategy)).asset(), USDC, "Asset should be USDC");
        assertEq(strategy.aToken(), AUSDC_V3, "aToken should be aUSDC V3");
    }

    /// @notice Fuzz test depositing assets into the strategy
    function testFuzzDeposit(uint256 depositAmount) public {
        // Bound the deposit amount to reasonable values for USDC (6 decimals)
        depositAmount = bound(depositAmount, 1e6, INITIAL_DEPOSIT); // 1 USDC to 100,000 USDC

        // Ensure user has enough balance
        if (ERC20(USDC).balanceOf(user) < depositAmount) {
            airdrop(ERC20(USDC), user, depositAmount);
        }

        // Initial balances
        uint256 initialUserBalance = ERC20(USDC).balanceOf(user);
        uint256 initialStrategyAssets = IERC4626(address(strategy)).totalAssets();

        // Deposit assets
        vm.startPrank(user);
        uint256 sharesReceived = IERC4626(address(strategy)).deposit(depositAmount, user);
        vm.stopPrank();

        // Verify balances after deposit
        assertEq(ERC20(USDC).balanceOf(user), initialUserBalance - depositAmount, "User balance not reduced correctly");

        assertGt(sharesReceived, 0, "No shares received from deposit");
        assertEq(
            IERC4626(address(strategy)).totalAssets(),
            initialStrategyAssets + depositAmount,
            "Strategy total assets should increase"
        );

        // Verify funds were deposited to Aave
        assertEq(ERC20(USDC).balanceOf(address(strategy)), 0, "Strategy should not hold USDC");
        assertGt(ERC20(AUSDC_V3).balanceOf(address(strategy)), 0, "Strategy should hold aUSDC");
    }

    /// @notice Fuzz test withdrawing assets from the strategy
    function testFuzzWithdraw(uint256 depositAmount, uint256 withdrawFraction) public {
        // Bound the deposit amount to reasonable values
        depositAmount = bound(depositAmount, 1e6, INITIAL_DEPOSIT); // 1 USDC to 100,000 USDC
        withdrawFraction = bound(withdrawFraction, 1, 100); // 1% to 100%

        // Ensure user has enough balance
        if (ERC20(USDC).balanceOf(user) < depositAmount) {
            airdrop(ERC20(USDC), user, depositAmount);
        }

        // Deposit first
        vm.startPrank(user);
        IERC4626(address(strategy)).deposit(depositAmount, user);

        // Calculate withdrawal amount as a fraction of deposit
        uint256 withdrawAmount = (depositAmount * withdrawFraction) / 100;

        // Skip if withdraw amount is 0
        vm.assume(withdrawAmount > 0);

        // Initial balances before withdrawal
        uint256 initialUserBalance = ERC20(USDC).balanceOf(user);
        uint256 initialShareBalance = IERC4626(address(strategy)).balanceOf(user);

        // Withdraw portion of the deposit
        uint256 previewMaxWithdraw = IERC4626(address(strategy)).maxWithdraw(user);
        vm.assume(previewMaxWithdraw >= withdrawAmount);
        uint256 sharesToBurn = IERC4626(address(strategy)).previewWithdraw(withdrawAmount);
        uint256 assetsReceived = IERC4626(address(strategy)).withdraw(withdrawAmount, user, user);
        vm.stopPrank();

        // Verify balances after withdrawal
        assertEq(
            ERC20(USDC).balanceOf(user),
            initialUserBalance + withdrawAmount,
            "User didn't receive correct assets"
        );
        assertEq(
            IERC4626(address(strategy)).balanceOf(user),
            initialShareBalance - sharesToBurn,
            "Shares not burned correctly"
        );
        assertEq(assetsReceived, withdrawAmount, "Incorrect amount of assets received");
    }

    /// @notice Fuzz test the harvesting functionality with profit donation
    function testFuzzHarvestWithProfitDonation(uint256 depositAmount, uint256 profitAmount) public {
        // Bound amounts to reasonable values
        depositAmount = bound(depositAmount, 1e6, INITIAL_DEPOSIT); // 1 USDC to 100,000 USDC
        profitAmount = bound(profitAmount, 1e5, depositAmount / 10); // 0.1 USDC to 10% of deposit

        // Ensure user has enough balance
        if (ERC20(USDC).balanceOf(user) < depositAmount) {
            airdrop(ERC20(USDC), user, depositAmount);
        }

        // Deposit first
        vm.startPrank(user);
        IERC4626(address(strategy)).deposit(depositAmount, user);
        vm.stopPrank();

        // Check initial state
        uint256 totalAssetsBefore = IERC4626(address(strategy)).totalAssets();
        uint256 userSharesBefore = IERC4626(address(strategy)).balanceOf(user);
        uint256 donationBalanceBefore = ERC20(address(strategy)).balanceOf(donationAddress);

        // Simulate profit by mocking the balanceOf call so that it returns the deposit amount plus the profit amount
        vm.mockCall(
            address(AUSDC_V3),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(strategy)),
            abi.encode(depositAmount + profitAmount)
        );

        // Call report to harvest and donate yield
        vm.startPrank(keeper);
        (uint256 profit, uint256 loss) = IMockStrategy(address(strategy)).report();
        vm.stopPrank();

        // Verify results
        assertGt(profit, 0, "Should have captured profit from yield");
        assertEq(loss, 0, "Should have no loss");

        // User shares should remain the same (no dilution)
        assertEq(IERC4626(address(strategy)).balanceOf(user), userSharesBefore, "User shares should not change");

        // Donation address should have received the profit
        uint256 donationBalanceAfter = ERC20(address(strategy)).balanceOf(donationAddress);
        assertGt(donationBalanceAfter, donationBalanceBefore, "Donation address should receive profit");

        // Total assets should increase by the profit amount
        assertGe(IERC4626(address(strategy)).totalAssets(), totalAssetsBefore, "Total assets should increase");
    }

    /// @notice Test available deposit limit checks supply cap
    function testAvailableDepositLimitWithSupplyCap() public view {
        // Get current supply cap from Aave
        IPoolDataProvider dataProvider = IPoolDataProvider(AAVE_DATA_PROVIDER);
        (, uint256 supplyCap) = dataProvider.getReserveCaps(USDC);

        // If supply cap is 0, it means unlimited
        if (supplyCap == 0) {
            uint256 limit = strategy.availableDepositLimit(user);
            assertEq(limit, type(uint256).max, "Should return max uint256 when no supply cap");
        } else {
            // Get current total supply
            uint256 totalSupply = dataProvider.getATokenTotalSupply(USDC);
            uint256 supplyCapScaled = supplyCap * 10 ** 6; // USDC has 6 decimals

            uint256 limit = strategy.availableDepositLimit(user);

            if (supplyCapScaled > totalSupply) {
                uint256 expectedLimit = supplyCapScaled - totalSupply;
                assertEq(limit, expectedLimit, "Limit should be cap minus current supply");
            } else {
                assertEq(limit, 0, "Limit should be 0 when cap is reached");
            }
        }
    }

    /// @notice Test available deposit limit with idle assets
    function testAvailableDepositLimitWithIdleAssets() public {
        uint256 idleAmount = 1000e6; // 1,000 USDC idle assets

        // Airdrop idle assets to strategy to simulate undeployed funds
        airdrop(ERC20(USDC), address(strategy), idleAmount);

        // Get the limits
        uint256 limit = strategy.availableDepositLimit(user);
        uint256 idleBalance = ERC20(USDC).balanceOf(address(strategy));

        // Verify idle assets are present
        assertEq(idleBalance, idleAmount, "Strategy should have idle assets");

        // Get supply cap info
        IPoolDataProvider dataProvider = IPoolDataProvider(AAVE_DATA_PROVIDER);
        (, uint256 supplyCap) = dataProvider.getReserveCaps(USDC);

        if (supplyCap == 0) {
            assertEq(limit, type(uint256).max, "Should return max uint256 when no supply cap");
        } else {
            uint256 totalSupply = dataProvider.getATokenTotalSupply(USDC);
            uint256 supplyCapScaled = supplyCap * 10 ** 6;

            if (supplyCapScaled > totalSupply) {
                uint256 availableCapacity = supplyCapScaled - totalSupply;
                uint256 expectedLimit = availableCapacity > idleAmount ? availableCapacity - idleAmount : 0;
                assertEq(limit, expectedLimit, "Available deposit limit should account for idle assets");
            }
        }
    }

    /// @notice Fuzz test emergency withdraw functionality
    function testFuzzEmergencyWithdraw(uint256 depositAmount, uint256 withdrawFraction) public {
        // Bound amounts to reasonable values
        depositAmount = bound(depositAmount, 1e6, INITIAL_DEPOSIT); // 1 USDC to 100,000 USDC
        withdrawFraction = bound(withdrawFraction, 1, 100); // 1% to 100%

        // Ensure user has enough balance
        if (ERC20(USDC).balanceOf(user) < depositAmount) {
            airdrop(ERC20(USDC), user, depositAmount);
        }

        // Deposit first
        vm.startPrank(user);
        IERC4626(address(strategy)).deposit(depositAmount, user);
        vm.stopPrank();

        // Calculate emergency withdraw amount based on actual available balance
        uint256 availableBalance = strategy.availableWithdrawLimit(address(this));
        uint256 emergencyWithdrawAmount = (availableBalance * withdrawFraction) / 100;
        vm.assume(emergencyWithdrawAmount > 0);

        // Get initial aToken balance
        uint256 initialATokenBalance = ERC20(AUSDC_V3).balanceOf(address(strategy));

        // Emergency withdraw
        vm.startPrank(emergencyAdmin);
        IMockStrategy(address(strategy)).shutdownStrategy();
        IMockStrategy(address(strategy)).emergencyWithdraw(emergencyWithdrawAmount);
        vm.stopPrank();

        // Verify some funds were withdrawn from Aave
        uint256 finalATokenBalance = ERC20(AUSDC_V3).balanceOf(address(strategy));
        assertApproxEqAbs(
            finalATokenBalance,
            initialATokenBalance - emergencyWithdrawAmount,
            2,
            "Should have withdrawn from Aave pool"
        );
        assertEq(ERC20(USDC).balanceOf(address(strategy)), emergencyWithdrawAmount, "Strategy should have idle USDC");
    }

    /// @notice Test that _harvestAndReport returns correct total assets
    function testFuzzHarvestAndReportView(uint256 depositAmount) public {
        // Bound the deposit amount to reasonable values
        depositAmount = bound(depositAmount, 1e6, INITIAL_DEPOSIT); // 1 USDC to 100,000 USDC

        // Ensure user has enough balance
        if (ERC20(USDC).balanceOf(user) < depositAmount) {
            airdrop(ERC20(USDC), user, depositAmount);
        }

        // Deposit first
        vm.startPrank(user);
        IERC4626(address(strategy)).deposit(depositAmount, user);
        vm.stopPrank();

        // Check that total assets matches the strategy's view of assets
        uint256 totalAssets = IERC4626(address(strategy)).totalAssets();
        uint256 aTokenBalance = ERC20(AUSDC_V3).balanceOf(address(strategy));
        uint256 idleAssets = ERC20(USDC).balanceOf(address(strategy));

        // aTokens are 1:1 with underlying USDC
        assertApproxEqRel(
            totalAssets,
            aTokenBalance + idleAssets,
            1e14, // 0.01%
            "Total assets should match aToken balance plus idle"
        );
    }

    /// @notice Test that _harvestAndReport includes idle funds and donations work correctly
    function testHarvestAndReportIncludesIdleFundsWithDonation() public {
        uint256 depositAmount = 10000e6; // 10,000 USDC
        uint256 aTokenProfit = 500e6; // 500 USDC profit in aTokens
        uint256 idleProfit = 500e6; // 500 USDC idle profit
        uint256 totalProfit = aTokenProfit + idleProfit; // 1,000 USDC total

        // Ensure user has enough balance
        airdrop(ERC20(USDC), user, depositAmount);

        // Deposit funds to strategy
        vm.startPrank(user);
        IERC4626(address(strategy)).deposit(depositAmount, user);
        vm.stopPrank();

        // Record initial state
        uint256 initialTotalAssets = IERC4626(address(strategy)).totalAssets();

        // Simulate aToken profit by mocking the balanceOf call so that it returns the deposit amount plus the profit amount
        vm.mockCall(
            address(AUSDC_V3),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(strategy)),
            abi.encode(depositAmount + aTokenProfit)
        );

        // Transfer idle funds to strategy to simulate additional profit
        airdrop(ERC20(USDC), address(strategy), idleProfit);

        // Check donation balance before report
        uint256 donationBalanceBefore = ERC20(address(strategy)).balanceOf(donationAddress);

        // Verify _harvestAndReport correctly includes idle funds
        uint256 idleAssets = ERC20(USDC).balanceOf(address(strategy));
        assertEq(idleAssets, idleProfit, "Strategy should have idle funds equal to idle profit");

        // Call report to trigger donation
        vm.prank(keeper);
        (uint256 reportedProfit, uint256 loss) = IMockStrategy(address(strategy)).report();

        // The reported profit should include BOTH aToken profit AND idle profit
        assertEq(reportedProfit, totalProfit, "Reported profit should include both aToken and idle profits");
        assertEq(loss, 0, "Should have no loss");

        // Verify donation occurred
        uint256 donationBalanceAfter = ERC20(address(strategy)).balanceOf(donationAddress);
        assertGt(donationBalanceAfter, donationBalanceBefore, "Donation address should receive profit");
        assertEq(
            donationBalanceAfter - donationBalanceBefore,
            totalProfit,
            "Donation should equal the total profit (aToken + idle)"
        );

        // Verify total assets increased by the total profit
        uint256 finalTotalAssets = IERC4626(address(strategy)).totalAssets();
        assertApproxEqRel(
            finalTotalAssets - initialTotalAssets,
            totalProfit,
            1e14,
            "Total assets should increase by total profit"
        );
    }

    /// @notice Test that constructor validates asset compatibility
    function testConstructorAssetValidation() public {
        // Try to deploy with wrong asset - should revert
        vm.expectRevert();
        new AaveV3Strategy(
            AAVE_ADDRESSES_PROVIDER,
            AUSDC_V3,
            address(0x123), // Wrong asset (not USDC)
            strategyName,
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            true, // enableBurning
            address(implementation)
        );
    }

    /// @notice Fuzz test multiple deposits and withdrawals
    function testFuzzMultipleDepositsAndWithdrawals(
        uint256 depositAmount1,
        uint256 depositAmount2,
        bool shouldUser1Withdraw,
        bool shouldUser2Withdraw
    ) public {
        // Bound deposit amounts to reasonable values
        depositAmount1 = bound(depositAmount1, 1e6, INITIAL_DEPOSIT / 2); // 1 USDC to 50,000 USDC
        depositAmount2 = bound(depositAmount2, 1e6, INITIAL_DEPOSIT / 2); // 1 USDC to 50,000 USDC

        address user2 = address(0x5678);

        // Ensure users have enough balance
        if (ERC20(USDC).balanceOf(user) < depositAmount1) {
            airdrop(ERC20(USDC), user, depositAmount1);
        }
        airdrop(ERC20(USDC), user2, depositAmount2);

        vm.startPrank(user2);
        ERC20(USDC).approve(address(strategy), type(uint256).max);
        vm.stopPrank();

        // First user deposits
        vm.startPrank(user);
        IERC4626(address(strategy)).deposit(depositAmount1, user);
        vm.stopPrank();

        // Second user deposits
        vm.startPrank(user2);
        IERC4626(address(strategy)).deposit(depositAmount2, user2);
        vm.stopPrank();

        // Verify total assets
        assertEq(
            IERC4626(address(strategy)).totalAssets(),
            depositAmount1 + depositAmount2,
            "Total assets should equal deposits"
        );

        // Conditionally withdraw based on fuzz parameters
        if (shouldUser1Withdraw) {
            vm.startPrank(user);
            IERC4626(address(strategy)).redeem(IERC4626(address(strategy)).balanceOf(user), user, user);
            vm.stopPrank();
        }

        if (shouldUser2Withdraw) {
            vm.startPrank(user2);
            uint256 maxRedeem = IERC4626(address(strategy)).maxRedeem(user2);
            IMockStrategy(address(strategy)).redeem(maxRedeem, user2, user2, 10);
            vm.stopPrank();
        }

        // If both withdrew, strategy should be nearly empty
        if (shouldUser1Withdraw && shouldUser2Withdraw) {
            assertLt(
                IERC4626(address(strategy)).totalAssets(),
                10,
                "Strategy should be nearly empty after all withdrawals"
            );
        }
    }

    /// @notice Test interaction with actual Aave V3 pool
    function testAaveV3PoolIntegration() public {
        uint256 depositAmount = 50000e6; // 50,000 USDC

        // Get USDC for user
        airdrop(ERC20(USDC), user, depositAmount);

        // User deposits into strategy
        vm.startPrank(user);
        ERC20(USDC).approve(address(strategy), depositAmount);
        uint256 shares = IERC4626(address(strategy)).deposit(depositAmount, user);
        vm.stopPrank();

        // Verify strategy received shares and deposited to Aave
        assertGt(shares, 0, "User should receive shares");
        assertEq(ERC20(USDC).balanceOf(address(strategy)), 0, "Strategy should have no idle USDC");
        assertGt(ERC20(AUSDC_V3).balanceOf(address(strategy)), 0, "Strategy should have aUSDC");

        // Simulate time passing for interest accrual
        vm.roll(block.number + 1000);
        vm.warp(block.timestamp + 30 days);

        // Get balances before report
        uint256 donationSharesBefore = IERC4626(address(strategy)).balanceOf(donationAddress);

        // Report to capture yield
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = IMockStrategy(address(strategy)).report();

        // Verify profit was captured (even if small due to simulation)
        assertGe(profit, 0, "Should have non-negative profit");
        assertEq(loss, 0, "Should have no loss");

        // If there was profit, donation address should receive shares
        if (profit > 0) {
            uint256 donationSharesAfter = IERC4626(address(strategy)).balanceOf(donationAddress);
            assertGt(donationSharesAfter, donationSharesBefore, "Donation address should receive profit shares");
        }

        // User withdraws
        vm.startPrank(user);
        uint256 assetsWithdrawn = IERC4626(address(strategy)).redeem(shares, user, user);
        vm.stopPrank();

        // User should receive at least their deposit back (minus any rounding)
        assertGe(assetsWithdrawn, (depositAmount * 99) / 100, "User should receive at least 99% of deposit");
    }

    /// @notice Test that available withdraw limit returns correct value
    function testAvailableWithdrawLimit() public {
        uint256 depositAmount = 10000e6; // 10,000 USDC

        // Initially should be 0
        uint256 initialLimit = strategy.availableWithdrawLimit(user);
        assertEq(initialLimit, 0, "Initial withdraw limit should be 0");

        // Deposit funds
        airdrop(ERC20(USDC), user, depositAmount);
        vm.startPrank(user);
        IERC4626(address(strategy)).deposit(depositAmount, user);
        vm.stopPrank();

        // Now limit should equal aToken balance
        uint256 limitAfterDeposit = strategy.availableWithdrawLimit(user);
        uint256 aTokenBalance = ERC20(AUSDC_V3).balanceOf(address(strategy));
        assertEq(limitAfterDeposit, aTokenBalance, "Withdraw limit should equal aToken balance");

        // Add some idle USDC
        uint256 idleAmount = 1000e6;
        airdrop(ERC20(USDC), address(strategy), idleAmount);

        // Limit should now include idle balance
        uint256 limitWithIdle = strategy.availableWithdrawLimit(user);
        assertEq(limitWithIdle, aTokenBalance + idleAmount, "Withdraw limit should include idle balance");
    }
}
