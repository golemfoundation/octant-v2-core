// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MorphoCompounderStrategy } from "src/strategies/yieldDonating/MorphoCompounderStrategy.sol";
import { BaseHealthCheck } from "src/strategies/periphery/BaseHealthCheck.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { IMockStrategy } from "test/mocks/zodiac-core/IMockStrategy.sol";
import { MorphoCompounderStrategyFactory } from "src/factories/MorphoCompounderStrategyFactory.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

/// @title MorphoCompounder Yield Donating Test
/// @author Octant
/// @notice Integration tests for the yield donating MorphoCompounder strategy using a mainnet fork
contract MorphoCompounderDonatingStrategyTest is Test {
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
    MorphoCompounderStrategy public strategy;

    // Strategy parameters
    address public management;
    address public keeper;
    address public emergencyAdmin;
    address public donationAddress;
    MorphoCompounderStrategyFactory public factory;
    string public strategyName = "MorphoCompounder Donating Strategy";

    // Test user
    address public user = address(0x1234);

    // Mainnet addresses
    address public constant MORPHO_VAULT = 0x074134A2784F4F66b6ceD6f68849382990Ff3215; // Steakhouse USDC vault
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC token
    address public constant TOKENIZED_STRATEGY_ADDRESS = 0x8cf7246a74704bBE59c9dF614ccB5e3d9717d8Ac;
    YieldDonatingTokenizedStrategy public implementation;

    // Test constants
    uint256 public constant INITIAL_DEPOSIT = 100000e6; // USDC has 6 decimals
    uint256 public mainnetFork;
    uint256 public mainnetForkBlock = 22508883 - 6500 * 90; // latest alchemy block - 90 days

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

        // Etch YieldSkimmingTokenizedStrategy
        implementation = new YieldDonatingTokenizedStrategy{ salt: keccak256("OCT_YIELD_SKIMMING_STRATEGY_V1") }();
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
            salt: keccak256("OCT_MORPHO_COMPOUNDER_STRATEGY_V1"),
            implementationAddress: address(implementation)
        });

        // MorphoCompounderStrategyFactory
        factory = new MorphoCompounderStrategyFactory{
            salt: keccak256("OCT_MORPHO_COMPOUNDER_STRATEGY_VAULT_FACTORY_V1")
        }();

        // Deploy strategy
        strategy = MorphoCompounderStrategy(
            factory.createStrategy(
                params.strategyName,
                "osMORPHO",
                params.management,
                params.keeper,
                params.emergencyAdmin,
                params.donationAddress,
                false, // enableBurning
                params.implementationAddress
            )
        );

        // Label addresses for better trace outputs
        vm.label(address(strategy), "MorphoCompounderDonating");
        vm.label(MORPHO_VAULT, "Morpho Vault");
        vm.label(USDC, "USDC");
        vm.label(management, "Management");
        vm.label(keeper, "Keeper");
        vm.label(emergencyAdmin, "Emergency Admin");
        vm.label(donationAddress, "Donation Address");
        vm.label(user, "Test User");

        // Airdrop USDC tokens to test user
        airdrop(ERC20(USDC), user, INITIAL_DEPOSIT);

        // Approve strategy to spend user's tokens
        vm.startPrank(user);
        ERC20(USDC).approve(address(strategy), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Test that the strategy is properly initialized
    function testInitialization() public view {
        // assertEq(IERC4626(strategy).asset(), address(USDC), "Asset should be USDC");
        // assertEq(strategy.management(), management, "Management address incorrect");
        // assertEq(strategy.keeper(), keeper, "Keeper address incorrect");
        // assertEq(strategy.emergencyAdmin(), emergencyAdmin, "Emergency admin incorrect");
        // assertEq(strategy.donationAddress(), donationAddress, "Donation address incorrect");
        // assertEq(strategy.compounderVault(), MORPHO_VAULT, "Compounder vault incorrect");
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
        profitAmount = bound(profitAmount, 1e5, depositAmount); // 0.1 USDC to deposit amount

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

        // Call report to harvest and donate yield
        // mock IERC4626(compounderVault).convertToAssets(shares) so that it returns profit
        uint256 balanceOfMorphoVault = IERC4626(MORPHO_VAULT).balanceOf(address(strategy));
        vm.mockCall(
            address(IERC4626(MORPHO_VAULT)),
            abi.encodeWithSelector(IERC4626.convertToAssets.selector, balanceOfMorphoVault),
            abi.encode(depositAmount + profitAmount)
        );
        vm.startPrank(keeper);
        (uint256 profit, uint256 loss) = IMockStrategy(address(strategy)).report();
        vm.stopPrank();

        vm.clearMockedCalls();

        // airdrop profit to the strategy
        airdrop(ERC20(USDC), address(strategy), profitAmount);

        // Verify results
        assertGt(profit, 0, "Should have captured profit from yield");
        assertEq(loss, 0, "Should have no loss");

        // User shares should remain the same (no dilution)
        assertEq(IERC4626(address(strategy)).balanceOf(user), userSharesBefore, "User shares should not change");

        // Donation address should have received the profit
        uint256 donationBalanceAfter = ERC20(address(strategy)).balanceOf(donationAddress);
        assertGt(donationBalanceAfter, donationBalanceBefore, "Donation address should receive profit");

        // Total assets should increase by the profit amount
        assertGt(IERC4626(address(strategy)).totalAssets(), totalAssetsBefore, "Total assets should increase");
    }

    /// @notice Test available deposit limit without idle assets
    function testAvailableDepositLimitWithoutIdleAssets() public view {
        uint256 limit = strategy.availableDepositLimit(user);
        uint256 morphoLimit = IERC4626(MORPHO_VAULT).maxDeposit(address(strategy));
        uint256 idleBalance = ERC20(USDC).balanceOf(address(strategy));

        // Since there are no idle assets initially, limit should equal morpho limit
        assertEq(idleBalance, 0, "Strategy should have no idle assets initially");
        assertEq(limit, morphoLimit, "Available deposit limit should match Morpho vault limit when no idle assets");
    }

    /// @notice Test available deposit limit with idle assets (TRST-M-8 fix)
    function testAvailableDepositLimitWithIdleAssets() public {
        uint256 idleAmount = 1000e6; // 1,000 USDC idle assets

        // Airdrop idle assets to strategy to simulate undeployed funds
        airdrop(ERC20(USDC), address(strategy), idleAmount);

        // Get the limits
        uint256 limit = strategy.availableDepositLimit(user);
        uint256 morphoLimit = IERC4626(MORPHO_VAULT).maxDeposit(address(strategy));
        uint256 idleBalance = ERC20(USDC).balanceOf(address(strategy));

        // Verify idle assets are present
        assertEq(idleBalance, idleAmount, "Strategy should have idle assets");

        // The available deposit limit should be morpho limit minus idle balance
        uint256 expectedLimit = morphoLimit > idleAmount ? morphoLimit - idleAmount : 0;
        assertEq(limit, expectedLimit, "Available deposit limit should account for idle assets");
        assertLt(limit, morphoLimit, "Available deposit limit should be less than morpho limit when idle assets exist");
    }

    /// @notice Test available deposit limit edge case where idle assets exceed morpho limit
    function testAvailableDepositLimitIdleAssetsExceedMorphoLimit() public {
        uint256 morphoLimit = IERC4626(MORPHO_VAULT).maxDeposit(address(strategy));

        // Skip test if morpho limit is too high for this test
        vm.assume(morphoLimit < type(uint256).max / 2);

        uint256 excessIdleAmount = morphoLimit + 1000e6; // Idle assets exceed morpho limit

        // Airdrop excess idle assets to strategy
        airdrop(ERC20(USDC), address(strategy), excessIdleAmount);

        // Get the limit
        uint256 limit = strategy.availableDepositLimit(user);
        uint256 idleBalance = ERC20(USDC).balanceOf(address(strategy));

        // Verify idle assets are present and exceed morpho limit
        assertEq(idleBalance, excessIdleAmount, "Strategy should have excess idle assets");
        assertGt(idleBalance, morphoLimit, "Idle assets should exceed morpho limit");

        // The available deposit limit should be 0 since idle assets exceed morpho capacity
        assertEq(limit, 0, "Available deposit limit should be 0 when idle assets exceed morpho limit");
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

        // Calculate emergency withdraw amount
        uint256 emergencyWithdrawAmount = (depositAmount * withdrawFraction) / 100;
        vm.assume(emergencyWithdrawAmount > 0);

        // Check the maximum withdrawable amount from Morpho vault to avoid liquidity issues
        uint256 maxWithdrawableFromMorpho = IERC4626(MORPHO_VAULT).maxWithdraw(address(strategy));

        // If the emergency withdraw amount exceeds what's withdrawable, cap it
        if (emergencyWithdrawAmount > maxWithdrawableFromMorpho) {
            emergencyWithdrawAmount = maxWithdrawableFromMorpho;
        }

        // Get initial vault shares in Morpho
        uint256 initialMorphoShares = IERC4626(MORPHO_VAULT).balanceOf(address(strategy));

        // Emergency withdraw
        vm.startPrank(emergencyAdmin);
        IMockStrategy(address(strategy)).shutdownStrategy();
        IMockStrategy(address(strategy)).emergencyWithdraw(emergencyWithdrawAmount);
        vm.stopPrank();

        // Verify some funds were withdrawn from Morpho
        uint256 finalMorphoShares = IERC4626(MORPHO_VAULT).balanceOf(address(strategy));
        assertLe(finalMorphoShares, initialMorphoShares, "Should have withdrawn from Morpho vault or stayed same");

        // Verify strategy has some idle USDC (unless we withdrew everything)
        if (emergencyWithdrawAmount < depositAmount) {
            assertGt(ERC20(USDC).balanceOf(address(strategy)), 0, "Strategy should have idle USDC");
        }
    }

    /// @notice Test emergency withdraw works even when maxWithdraw returns less than requested
    /// @dev This test addresses the audit finding where maxWithdraw could underestimate withdrawable assets
    function testEmergencyWithdrawBypassesMaxWithdraw() public {
        // Setup: Large deposit to ensure we have funds
        uint256 depositAmount = 100000e6; // 100,000 USDC

        // Ensure user has enough balance
        airdrop(ERC20(USDC), user, depositAmount);

        // Deposit funds
        vm.startPrank(user);
        ERC20(USDC).approve(address(strategy), depositAmount);
        IERC4626(address(strategy)).deposit(depositAmount, user);
        vm.stopPrank();

        // Get initial state
        uint256 strategySharesInMorpho = IERC4626(MORPHO_VAULT).balanceOf(address(strategy));
        uint256 strategyAssetsInMorpho = IERC4626(MORPHO_VAULT).convertToAssets(strategySharesInMorpho);

        // Check what maxWithdraw reports
        uint256 maxWithdrawAmount = IERC4626(MORPHO_VAULT).maxWithdraw(address(strategy));

        // Emergency withdraw MORE than maxWithdraw (if maxWithdraw is limiting)
        // This tests that our fix allows withdrawing even when maxWithdraw would limit it
        uint256 emergencyWithdrawAmount = strategyAssetsInMorpho; // Try to withdraw all

        // Log for debugging - this ensures maxWithdrawAmount is used
        emit log_named_uint("maxWithdraw reports", maxWithdrawAmount);
        emit log_named_uint("attempting to withdraw", emergencyWithdrawAmount);

        vm.startPrank(emergencyAdmin);
        IMockStrategy(address(strategy)).shutdownStrategy();

        // This should succeed even if maxWithdraw < emergencyWithdrawAmount
        // because we removed the maxWithdraw check
        IMockStrategy(address(strategy)).emergencyWithdraw(emergencyWithdrawAmount);
        vm.stopPrank();

        // Verify withdrawal happened
        uint256 finalSharesInMorpho = IERC4626(MORPHO_VAULT).balanceOf(address(strategy));
        assertEq(finalSharesInMorpho, 0, "Should have withdrawn all shares from Morpho");

        // Verify strategy received the USDC
        uint256 strategyUSDCBalance = ERC20(USDC).balanceOf(address(strategy));
        assertGe(
            strategyUSDCBalance,
            (depositAmount * 99) / 100,
            "Strategy should have received at least 99% of deposited USDC"
        );
    }

    /// @notice Fuzz test that _harvestAndReport returns correct total assets
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
        uint256 morphoShares = IERC4626(MORPHO_VAULT).balanceOf(address(strategy));
        uint256 morphoAssets = IERC4626(MORPHO_VAULT).convertToAssets(morphoShares);
        uint256 idleAssets = ERC20(USDC).balanceOf(address(strategy));

        assertApproxEqRel(
            totalAssets,
            morphoAssets + idleAssets,
            1e14, // 0.01%
            "Total assets should match Morpho assets plus idle"
        );
    }

    /// @notice Test that _harvestAndReport includes idle funds and donations work correctly
    function testHarvestAndReportIncludesIdleFundsWithDonation() public {
        uint256 depositAmount = 10000e6; // 10,000 USDC
        uint256 vaultProfit = 500e6; // 500 USDC profit in vault
        uint256 idleProfit = 500e6; // 500 USDC idle profit
        uint256 totalProfit = vaultProfit + idleProfit; // 1,000 USDC total

        // Ensure user has enough balance
        airdrop(ERC20(USDC), user, depositAmount);

        // Deposit funds to strategy
        vm.startPrank(user);
        IERC4626(address(strategy)).deposit(depositAmount, user);
        vm.stopPrank();

        // Record initial state
        uint256 initialTotalAssets = IERC4626(address(strategy)).totalAssets();
        uint256 morphoSharesBefore = IERC4626(MORPHO_VAULT).balanceOf(address(strategy));

        // Simulate vault profit by mocking Morpho vault return value
        vm.mockCall(
            address(MORPHO_VAULT),
            abi.encodeWithSelector(IERC4626.convertToAssets.selector, morphoSharesBefore),
            abi.encode(depositAmount + vaultProfit)
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

        vm.clearMockedCalls();

        // The reported profit should include BOTH vault profit AND idle profit
        // This demonstrates the fix is working correctly
        assertEq(reportedProfit, totalProfit, "Reported profit should include both vault and idle profits");
        assertEq(loss, 0, "Should have no loss");

        // Verify donation occurred
        uint256 donationBalanceAfter = ERC20(address(strategy)).balanceOf(donationAddress);
        assertGt(donationBalanceAfter, donationBalanceBefore, "Donation address should receive profit");
        assertEq(
            donationBalanceAfter - donationBalanceBefore,
            totalProfit,
            "Donation should equal the total profit (vault + idle)"
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
        new MorphoCompounderStrategy(
            MORPHO_VAULT,
            address(0x123), // Wrong asset
            strategyName,
            "osMORPHO",
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

    /// @notice Test that triggers "too much loss" by removing idle funds and mocking withdraw
    /// @dev This test demonstrates the vulnerability where maxLoss defaults to 0 in MorphoCompounderStrategy._freeFunds
    function testLossDoesNotTriggerTooMuchLossError() public {
        uint256 depositAmount = 100000e6;

        address morphoBlueVault = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;

        // User deposits into our strategy
        vm.startPrank(user);
        uint256 vaultShares = IERC4626(address(strategy)).deposit(depositAmount, user);

        vm.stopPrank();

        // user usdc balance should be 0
        assertEq(ERC20(USDC).balanceOf(user), 0, "User should have no USDC");

        // Step 1: Remove all idle funds from the Yearn vault (YS_USDC)
        // Check current idle balance in YS_USDC vault
        uint256 yearnIdleBalance = ERC20(USDC).balanceOf(MORPHO_VAULT);

        if (yearnIdleBalance > 0) {
            // Transfer idle funds out of Yearn vault with Yearn vault as caller
            vm.startPrank(MORPHO_VAULT);
            ERC20(USDC).transfer(address(0xdead), yearnIdleBalance);
            vm.stopPrank();
        }

        // Verify idle balance is now 0
        assertEq(ERC20(USDC).balanceOf(MORPHO_VAULT), 0, "Yearn vault should have no idle funds");

        // remove the the idle funds from morpho blue vault
        vm.startPrank(morphoBlueVault);
        ERC20(USDC).transfer(address(0xdead), ERC20(USDC).balanceOf(morphoBlueVault));
        vm.stopPrank();

        // verify morpho blue vault has no idle funds
        assertEq(ERC20(USDC).balanceOf(morphoBlueVault), 0, "Morpho blue vault should have no idle funds");

        // Airdrop some USDC back to YS_USDC so it has enough for the strategy-level maxWithdraw check
        // but we'll mock freeFunds to fail when actually trying to get funds
        airdrop(ERC20(USDC), MORPHO_VAULT, depositAmount / 10); // Give it 10% for the check to pass

        // Mock the freeFunds call on YS_USDC to do nothing
        // This simulates the scenario where freeFunds cannot recover enough assets
        // Since maxLoss=0 in our strategy, any loss will trigger "too much loss"
        vm.mockCall(
            MORPHO_VAULT,
            abi.encodeWithSignature("freeFunds(uint256)"),
            "" // Empty response - freeFunds does nothing, recovering 0 assets
        );

        vm.startPrank(user);
        // if max loss is 10 000, call should not revert
        YieldDonatingTokenizedStrategy(address(strategy)).redeem(vaultShares - 2, user, user, 10_000);
        vm.stopPrank();

        vm.clearMockedCalls();

        // user should have received balance
        assertEq(ERC20(USDC).balanceOf(user), depositAmount / 10, "User should have received balance");
    }
}
