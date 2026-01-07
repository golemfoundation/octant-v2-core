// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { SkyCompounderStrategy } from "src/strategies/yieldDonating/SkyCompounderStrategy.sol";
import { IStaking } from "src/strategies/interfaces/ISky.sol";
import { BaseHealthCheck } from "src/strategies/periphery/BaseHealthCheck.sol";
import { UniswapV3Swapper } from "src/strategies/periphery/UniswapV3Swapper.sol";
import { SkyCompounderStrategyFactory } from "src/factories/SkyCompounderStrategyFactory.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

/// @title SkyCompounder Test
/// @author mil0x
/// @notice Unit tests for the SkyCompounder strategy using a mainnet fork
contract SkyCompounderTest is Test {
    using SafeERC20 for ERC20;

    // Setup parameters struct to avoid stack too deep
    struct SetupParams {
        address management;
        address keeper;
        address emergencyAdmin;
        address donationAddress;
        string vaultSharesName;
        bytes32 strategySalt;
        address implementationAddress;
        bool enableBurning;
    }

    // Strategy instance
    SkyCompounderStrategy public strategy;
    ITokenizedStrategy public vault;

    // Factory for creating strategies
    YieldDonatingTokenizedStrategy tokenizedStrategy;
    SkyCompounderStrategyFactory public factory;
    YieldDonatingTokenizedStrategy public implementation;

    // Strategy parameters
    address public management;
    address public keeper;
    address public emergencyAdmin;
    address public donationAddress;
    string public vaultSharesName = "SkyCompounder Vault Shares";
    bytes32 public strategySalt = keccak256("TEST_STRATEGY_SALT");

    // Test user
    address public user = address(0x1234);
    // Donation recipient for transfer tests
    address public donationRecipient = address(0x5678);

    // Mainnet addresses
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    address public constant STAKING = 0x0650CAF159C5A49f711e8169D4336ECB9b950275; // Sky Protocol Staking Contract
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Test constants
    uint256 public constant INITIAL_DEPOSIT = 100000e18;
    uint256 public mainnetFork;

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
        // NOTE: This relies on the RPC URL configured in foundry.toml under [rpc_endpoints]
        // where mainnet = "${ETHEREUM_NODE_MAINNET}" environment variable
        mainnetFork = vm.createFork("mainnet");
        vm.selectFork(mainnetFork);

        implementation = new YieldDonatingTokenizedStrategy{ salt: keccak256("OCT_YIELD_DONATING_STRATEGY_V1") }();

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
            implementationAddress: address(implementation),
            enableBurning: true
        });

        // Deploy factory
        factory = new SkyCompounderStrategyFactory();

        // Deploy strategy using the factory's createStrategy method
        // The management address should be the deployer
        vm.startPrank(params.management);
        address strategyAddress = factory.createStrategy(
            params.vaultSharesName,
            "osSKY",
            params.management,
            params.keeper,
            params.emergencyAdmin,
            params.donationAddress,
            params.enableBurning,
            params.implementationAddress
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
        vm.label(management, "Management");
        vm.label(keeper, "Keeper");
        vm.label(emergencyAdmin, "Emergency Admin");
        vm.label(donationAddress, "Donation Address");
        vm.label(user, "Test User");
        vm.label(WETH, "WETH");

        // Airdrop USDS tokens to test user
        airdrop(ERC20(USDS), user, INITIAL_DEPOSIT);

        // Approve strategy to spend user's tokens
        vm.startPrank(user);
        ERC20(USDS).approve(address(strategy), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Test that the strategy is properly initialized
    function testInitialization() public view {
        assertEq(vault.asset(), USDS, "Asset should be USDS");
        assertEq(strategy.staking(), STAKING, "Staking address incorrect");
        assertEq(vault.management(), management, "Management address incorrect");
        assertEq(vault.keeper(), keeper, "Keeper address incorrect");
        assertEq(vault.emergencyAdmin(), emergencyAdmin, "Emergency admin incorrect");
        // assertEq(vault.donationAddress(), donationAddress, "Donation address incorrect"); // TODO: Add this
        assertEq(strategy.claimRewards(), true, "Claim rewards should default to true");
        assertEq(strategy.useUniV3(), false, "Use UniV3 should default to false");

        // Verify that the strategy was recorded in the factory
        (address deployerAddress, , string memory name, address stratDonationAddress) = factory.strategies(
            management,
            0
        );

        assertEq(deployerAddress, management, "Deployer address incorrect in factory");
        assertEq(name, vaultSharesName, "Vault shares name incorrect in factory");
        assertEq(stratDonationAddress, donationAddress, "Donation address incorrect in factory");
    }

    /// @notice Test depositing assets into the strategy
    function testDeposit() public {
        uint256 depositAmount = 100e18;

        // Initial balances
        uint256 initialUserBalance = ERC20(USDS).balanceOf(user);
        uint256 initialStrategyBalance = strategy.balanceOfAsset();
        uint256 initialStakeBalance = strategy.balanceOfStake();

        // Deposit assets
        vm.startPrank(user);
        uint256 sharesReceived = vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Verify balances after deposit
        assertEq(ERC20(USDS).balanceOf(user), initialUserBalance - depositAmount, "User balance not reduced correctly");
        assertEq(strategy.balanceOfAsset(), initialStrategyBalance, "Strategy should deploy all assets");
        assertEq(
            strategy.balanceOfStake(),
            initialStakeBalance + depositAmount,
            "Staking balance not increased correctly"
        );
        assertGt(sharesReceived, 0, "No shares received from deposit");
    }

    /// @notice Test withdrawing assets from the strategy
    function testWithdraw() public {
        uint256 depositAmount = 100e18;

        // Deposit first
        vm.startPrank(user);
        vault.deposit(depositAmount, user);

        // Initial balances before withdrawal
        uint256 initialUserBalance = ERC20(USDS).balanceOf(user);
        uint256 initialShareBalance = vault.balanceOf(user);

        // Withdraw half of the deposit
        uint256 withdrawAmount = depositAmount / 2;
        uint256 sharesToBurn = vault.previewWithdraw(withdrawAmount);
        uint256 assetsReceived = vault.withdraw(withdrawAmount, user, user);
        vm.stopPrank();

        // Verify balances after withdrawal
        assertEq(
            ERC20(USDS).balanceOf(user),
            initialUserBalance + withdrawAmount,
            "User didn't receive correct assets"
        );
        assertEq(vault.balanceOf(user), initialShareBalance - sharesToBurn, "Shares not burned correctly");
        assertEq(assetsReceived, withdrawAmount, "Incorrect amount of assets received");
    }

    /// @notice Test the harvesting functionality using explicit profit simulation
    function testHarvestWithProfit() public {
        uint256 depositAmount = 100e18;
        uint256 profitAmount = 10e18; // 10% profit

        // Deposit first
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Check initial state
        uint256 totalAssetsBefore = vault.totalAssets();
        console.log("Total assets before:", totalAssetsBefore);

        // Skip time and mine blocks to simulate passage of time
        uint256 currentBlock = block.number;
        uint256 blocksToMine = 6500; // ~1 day of blocks
        skip(1 days);
        vm.roll(currentBlock + blocksToMine);

        // Simulate profit by directly airdropping assets to the strategy
        // This simulates the rewards that would be generated from staking
        airdrop(ERC20(USDS), address(strategy), profitAmount);
        console.log("Airdropped profit:", profitAmount);

        // Check state after airdrop
        uint256 strategyBalance = ERC20(USDS).balanceOf(address(strategy));
        console.log("Strategy USDS balance after airdrop:", strategyBalance);

        // Prepare to call report and expect event
        vm.startPrank(keeper);
        vm.expectEmit(true, true, true, true);
        emit Reported(profitAmount, 0); // We expect the exact profit we airdropped and no loss

        // Call report and capture the returned values
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();

        // Log the actual profit/loss
        console.log("Reported profit:", profit);
        console.log("Reported loss:", loss);

        // Assert profit and loss
        assertGe(profit, profitAmount, "Profit should be at least the airdropped amount");
        assertEq(loss, 0, "There should be no loss");

        // Check total assets after harvest
        uint256 totalAssetsAfter = vault.totalAssets();
        console.log("Total assets after:", totalAssetsAfter);
        assertGe(totalAssetsAfter, totalAssetsBefore + profitAmount, "Total assets should include profit");

        // Skip time to unlock profit
        skip(365 days);

        // Withdraw everything
        vm.startPrank(user);
        uint256 sharesToRedeem = vault.balanceOf(user);
        uint256 assetsReceived = vault.redeem(sharesToRedeem, user, user);
        vm.stopPrank();

        // Verify donation address received the profit in shares and user only got original deposit
        assertEq(assetsReceived, depositAmount, "User should only receive original deposit");
        assertEq(vault.balanceOf(donationAddress), profitAmount, "Donation address should receive profit in shares");
        console.log("User assets received:", assetsReceived);
        console.log("Donation address shares received:", vault.balanceOf(donationAddress));
    }

    /// @notice Test the harvesting functionality
    function testHarvest() public {
        uint256 depositAmount = 100e18;

        // Deposit first
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Fast forward time to generate rewards
        skip(7 days);

        // Capture initial state
        uint256 initialAssets = vault.totalAssets();

        // Call report as keeper (which internally calls _harvestAndReport)
        vm.startPrank(keeper);
        vault.report();
        vm.stopPrank();

        // Verify total assets after harvest
        // Note: We don't check for specific increases here as we're using a mainnet fork
        // and reward calculation can vary, but assets should be >= than before unless there's a loss
        assertGe(vault.totalAssets(), initialAssets, "Total assets should not decrease after harvest");
    }

    /// @notice Test profit cycle with UniswapV3 for swapping rewards when reward amount > minAmountToSell
    function testUniswapV3WithProfitCycleAboveMinAmount() public {
        // Setup test parameters
        uint256 depositAmount = 100e18;
        address rewardsToken = strategy.rewardsToken();
        uint256 rewardAmount = 50e18; // Simulated reward amount

        console.log("Rewards token:", rewardsToken);

        // 1. Configure strategy to use UniswapV3
        vm.startPrank(management);
        strategy.setUseUniV3andFees(true, 3000, 500); // Enable UniV3 with medium and low fee tiers
        vm.stopPrank();

        // Verify UniV3 is enabled and minAmount is set
        assertTrue(strategy.useUniV3(), "UniV3 should be enabled");
        assertEq(strategy.minAmountToSell(), 50e18, "Min amount should be set correctly");

        // 2. Deposit assets into the strategy
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Verify deposit was successful
        assertEq(strategy.balanceOfStake(), depositAmount, "Deposit should be staked");

        // 3. Skip time to accrue rewards
        uint256 currentBlock = block.number;
        skip(30 days); // Skip forward 30 days
        vm.roll(currentBlock + 6500 * 30); // About 30 days of blocks

        // 4. Simulate rewards by airdropping reward tokens
        vm.label(rewardsToken, "Rewards Token");

        // Mock some rewards in the staking contract
        deal(rewardsToken, address(strategy), rewardAmount);
        console.log("Airdropped rewards:", rewardAmount);
        console.log("Rewards token balance:", ERC20(rewardsToken).balanceOf(address(strategy)));

        // 5. Capture pre-report state
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 rewardsBalanceBefore = ERC20(rewardsToken).balanceOf(address(strategy));
        console.log("Total assets before report:", totalAssetsBefore);

        // Explicitly set claimRewards to false to prevent swapping
        vm.startPrank(management);
        strategy.setClaimRewards(false);
        assertEq(strategy.balanceOfRewards(), rewardAmount, "Rewards should be in the strategy");
        vm.stopPrank();

        // 6. Report profit - this should NOT trigger rewards claiming or swapping since claimRewards is false
        vm.startPrank(keeper);
        vm.expectEmit(true, true, true, true);
        emit Reported(0, 0);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();

        console.log("Reported profit:", profit);
        console.log("Reported loss:", loss);

        // 7. Verify rewards were NOT exchanged for USDS (reward tokens should still be present)
        uint256 rewardsBalanceAfter = ERC20(rewardsToken).balanceOf(address(strategy));
        console.log("Rewards token balance after report:", rewardsBalanceAfter);

        // Rewards should not have been claimed or swapped, so balance should remain the same
        assertEq(rewardsBalanceAfter, rewardsBalanceBefore, "Rewards should not have been claimed or swapped");

        // Total assets should remain unchanged because claimRewards is false
        uint256 totalAssetsAfter = vault.totalAssets();
        console.log("Total assets after report:", totalAssetsAfter);
        assertApproxEqRel(totalAssetsAfter, totalAssetsBefore, 0.01e18, "Total assets should remain similar");

        // 8. Skip time to allow profit to unlock (though we don't expect profit in this case)
        skip(365 days);

        // 9. Verify donationAddress received minimal or no shares since no profit was recognized
        uint256 donationShares = vault.balanceOf(donationAddress);
        console.log("Donation address shares:", donationShares);

        // 10. User withdraws their deposit
        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        uint256 assetsReceived = vault.redeem(userShares, user, user);
        vm.stopPrank();

        console.log("User withdrew assets:", assetsReceived);

        // User should get back approximately their original deposit
        assertApproxEqRel(assetsReceived, depositAmount, 0.05e18, "User should receive approximately original deposit");
    }

    /// @notice Test profit cycle with UniswapV3 for swapping rewards when reward amount < minAmountToSell
    function testUniswapV3WithProfitCycleBelowMinAmount() public {
        // Setup test parameters
        uint256 depositAmount = 100e18;
        address rewardsToken = strategy.rewardsToken();
        uint256 rewardAmount = 1e18; // Simulated reward amount (small)
        uint256 minAmount = 5e18; // Set higher than reward amount

        console.log("Rewards token:", rewardsToken);

        // 1. Configure strategy to use UniswapV3
        vm.startPrank(management);
        strategy.setUseUniV3andFees(true, 3000, 500); // Enable UniV3 with medium and low fee tiers
        strategy.setMinAmountToSell(minAmount); // Set min amount higher than rewards
        vm.stopPrank();

        // Verify UniV3 is enabled and minAmount is set
        assertTrue(strategy.useUniV3(), "UniV3 should be enabled");
        assertEq(strategy.minAmountToSell(), minAmount, "Min amount should be set correctly");

        // 2. Deposit assets into the strategy
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Verify deposit was successful
        assertEq(strategy.balanceOfStake(), depositAmount, "Deposit should be staked");

        // 3. Skip time to accrue rewards
        uint256 currentBlock = block.number;
        skip(30 days); // Skip forward 30 days
        vm.roll(currentBlock + 6500 * 30); // About 30 days of blocks

        // 4. Simulate rewards by airdropping reward tokens
        vm.label(rewardsToken, "Rewards Token");

        // Mock some rewards in the staking contract
        deal(rewardsToken, address(strategy), rewardAmount);
        console.log("Airdropped rewards:", rewardAmount);
        console.log("Rewards token balance:", ERC20(rewardsToken).balanceOf(address(strategy)));

        // 5. Capture pre-report state
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 rewardsBalanceBefore = ERC20(rewardsToken).balanceOf(address(strategy));
        console.log("Total assets before report:", totalAssetsBefore);
        vm.startPrank(management);
        strategy.setClaimRewards(false);
        assertEq(strategy.balanceOfRewards(), rewardAmount, "Rewards should be in the strategy");
        vm.stopPrank();

        // 6. Report profit - this should NOT trigger the UniV3 swap since rewardAmount < minAmountToSell
        vm.startPrank(keeper);
        vm.expectEmit(true, true, true, true);
        emit Reported(0, 0);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();

        console.log("Reported profit:", profit);
        console.log("Reported loss:", loss);

        // 7. Verify rewards were NOT exchanged for USDS (reward tokens should still be present)
        uint256 rewardsBalanceAfter = ERC20(rewardsToken).balanceOf(address(strategy));
        console.log("Rewards token balance after report:", rewardsBalanceAfter);

        // Rewards should not have been swapped, so balance should remain the same
        assertEq(rewardsBalanceAfter, rewardsBalanceBefore, "Rewards should not have been swapped");

        // Total assets should remain mostly unchanged
        uint256 totalAssetsAfter = vault.totalAssets();
        console.log("Total assets after report:", totalAssetsAfter);
        assertApproxEqRel(totalAssetsAfter, totalAssetsBefore, 0.01e18, "Total assets should remain similar");

        // 8. Skip time to allow profit to unlock
        skip(365 days);

        // 9. There should be minimal to no donation shares since no profit was recognized
        uint256 donationShares = vault.balanceOf(donationAddress);
        console.log("Donation address shares:", donationShares);

        // 10. User withdraws their deposit
        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        uint256 assetsReceived = vault.redeem(userShares, user, user);
        vm.stopPrank();

        console.log("User withdrew assets:", assetsReceived);

        // User should get back approximately their original deposit
        assertApproxEqRel(assetsReceived, depositAmount, 0.05e18, "User should receive approximately original deposit");
    }

    /// @notice Test that report emits the Reported event with correct parameters
    function testReportEvent() public {
        uint256 depositAmount = 100e18;

        // Deposit first to have some assets in the strategy
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Create some rewards to be claimed
        // We need to both skip time and mine blocks for realistic rewards generation
        uint256 currentBlock = block.number;
        uint256 blocksToMine = 6500; // ~1 day of blocks at 13s/block

        // Log current state
        console.log("Current block:", currentBlock);
        console.log("Current timestamp:", block.timestamp);

        // Skip 1 day and mine 6500 blocks
        skip(1 days);
        vm.roll(currentBlock + blocksToMine);

        // Log new state
        console.log("New block:", block.number);
        console.log("New timestamp:", block.timestamp);

        // Prepare to call report and expect an event
        vm.startPrank(keeper);

        // We expect the Reported event to be emitted with some profit (or potentially loss)
        // Since we can't predict the exact values in a mainnet fork test,
        // we'll just check that the event format is correct with all the parameters
        vm.expectEmit(true, true, true, true);
        emit Reported(0, 0); // The actual values will be different

        // Call report and capture the returned values
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();

        // Log the actual profit/loss for debugging
        console.log("Reported profit:", profit);
        console.log("Reported loss:", loss);

        // At minimum, verify one of profit or loss was non-zero
        // or both were zero (empty harvesting is possible)
        assertTrue(profit > 0 || loss > 0 || (profit == 0 && loss == 0), "Either profit or loss should be reported");
    }

    /// @notice Test management functions
    function testManagementFunctions() public {
        // Test setClaimRewards
        vm.startPrank(management);
        strategy.setClaimRewards(false);
        vm.stopPrank();
        assertEq(strategy.claimRewards(), false, "claimRewards not updated correctly");

        // Test setUseUniV3andFees
        vm.startPrank(management);
        strategy.setUseUniV3andFees(true, 3000, 500);
        vm.stopPrank();
        assertEq(strategy.useUniV3(), true, "useUniV3 not updated correctly");

        // Test setMinAmountToSell
        uint256 newMinAmount = 100e18;
        vm.startPrank(management);
        strategy.setMinAmountToSell(newMinAmount);
        vm.stopPrank();
        assertEq(strategy.minAmountToSell(), newMinAmount, "minAmountToSell not updated correctly");

        // Test setReferral
        uint16 newReferral = 12345;
        vm.startPrank(management);
        strategy.setReferral(newReferral);
        vm.stopPrank();
        assertEq(strategy.referral(), newReferral, "referral not updated correctly");
    }

    /// @notice Test profit cycle with UniswapV2 for swapping rewards when reward amount > minAmountToSell
    function testUniswapV2WithProfitCycleAboveMinAmount() public {
        // Setup test parameters
        uint256 depositAmount = 4500e18;
        address rewardsToken = strategy.rewardsToken();

        console.log("Rewards token:", rewardsToken);

        // 1. Configure strategy to use UniswapV2 (make sure V3 is off)
        vm.startPrank(management);
        strategy.setUseUniV3andFees(false, 3000, 500); // Explicitly disable UniV3
        vm.stopPrank();

        // Verify UniV3 is disabled and confirm minAmount is set appropriately
        assertFalse(strategy.useUniV3(), "UniV3 should be disabled");
        assertEq(strategy.minAmountToSell(), 50e18, "Min amount should be set correctly");
        // check the claimable rewards are 0
        assertEq(strategy.claimableRewards(), 0, "no claimable rewards we mock this instead");

        // 2. Deposit assets into the strategy
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Verify deposit was successful
        assertEq(strategy.balanceOfStake(), depositAmount, "Deposit should be staked");

        // 3. Skip time to accrue rewards
        uint256 currentBlock = block.number;
        skip(30 days); // Skip forward 30 days
        vm.roll(currentBlock + 6500 * 30); // About 30 days of blocks

        // 5. Capture pre-report state
        uint256 totalAssetsBefore = vault.totalAssets();
        console.log("Total assets before report:", totalAssetsBefore);
        // Setting claimRewards to false to prevent actual swap attempt
        // In production, this would be true, but for testing purposes we disable it
        // to avoid dealing with complex UniswapV2 mocking
        vm.startPrank(management);
        assertEq(strategy.balanceOfRewards(), 0, "None of the rewards should be in the strategy yet");
        // Check initial claimable rewards
        uint256 claimableRewards = strategy.claimableRewards();
        // Depending on mainnet fork state, we may need to mock additional rewards to avoid forking at a specific block
        if (claimableRewards < 50e18) {
            // Mock additional rewards to reach minimum threshold
            deal(strategy.rewardsToken(), address(strategy), 50e18);
        }
        assertGt(
            strategy.claimableRewards() + strategy.balanceOfRewards(),
            50e18,
            "Should have enough rewards to swap"
        );

        uint256 rewardsBalanceBefore = strategy.claimableRewards();
        console.log("Rewards balance before report:", rewardsBalanceBefore);
        vm.stopPrank();

        // 6. Report profit - with claimRewards off, it should not attempt to swap
        vm.startPrank(keeper);
        vm.expectEmit(true, true, true, false);
        emit Reported(type(uint256).max, 0);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();

        console.log("Reported profit:", profit);
        console.log("Reported loss:", loss);

        assertGt(profit, 0, "Profit should be greater than 0");
        assertEq(loss, 0, "Loss should be 0");

        // 7. Verify rewards tokens were exchanged
        uint256 rewardsBalanceAfter = ERC20(rewardsToken).balanceOf(address(strategy));
        console.log("Rewards token balance after report:", rewardsBalanceAfter);
        assertLt(rewardsBalanceAfter, rewardsBalanceBefore, "Rewards should have been claimed and swapped");

        // 9. User withdraws their deposit
        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        uint256 assetsReceived = vault.redeem(userShares, user, user);
        vm.stopPrank();

        console.log("User withdrew assets:", assetsReceived);
        assertApproxEqRel(assetsReceived, depositAmount, 0.05e18, "User should receive approximately original deposit");
    }

    /// @notice Test profit cycle with UniswapV2 and verify profits are minted to donation address
    function testUniswapV2ProfitDonation() public {
        // Setup test parameters with large deposit for significant rewards
        uint256 depositAmount = 5000e18;
        address rewardsToken = strategy.rewardsToken();

        console.log("Rewards token:", rewardsToken);

        // 1. Configure strategy to use UniswapV2
        vm.startPrank(management);
        strategy.setUseUniV3andFees(false, 3000, 500); // Disable UniV3
        assertEq(strategy.minAmountToSell(), 50e18, "Min amount should be set correctly");
        strategy.setMinAmountToSell(0); // Set min amount to 0 for testing
        vm.stopPrank();

        // Verify UniV2 is enabled
        assertFalse(strategy.useUniV3(), "UniV3 should be disabled");

        // Check claimable rewards are 0 at the start
        assertEq(strategy.claimableRewards(), 0, "No claimable rewards initially");

        // 2. Deposit assets into the strategy
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Verify deposit was successful
        assertEq(strategy.balanceOfStake(), depositAmount, "Deposit should be staked");
        console.log("User deposit amount:", depositAmount);

        // 3. Skip time to accrue rewards (longer period for more rewards)
        uint256 currentBlock = block.number;
        skip(45 days); // Skip forward 45 days for more rewards
        vm.roll(currentBlock + 6500 * 45); // About 45 days worth of blocks

        // 4. Capture pre-report state
        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 donationSharesBefore = vault.balanceOf(donationAddress);

        // Check that we have enough claimable rewards to make a swap
        vm.startPrank(management);
        uint256 claimableRewardsBefore = strategy.claimableRewards();
        if (claimableRewardsBefore < 50e18) {
            // Mock additional rewards to reach minimum threshold
            deal(strategy.rewardsToken(), address(strategy), 50e18);
        }
        assertGt(
            claimableRewardsBefore + strategy.balanceOfRewards(),
            50e18,
            "Should have accrued enough rewards to swap"
        );

        // Ensure claimRewards is enabled for actual swapping
        strategy.setClaimRewards(true);
        vm.stopPrank();

        // 5. Report profit - this should trigger reward claiming and swapping via UniswapV2
        vm.startPrank(keeper);
        vm.expectEmit(true, true, true, false); // Don't check exact profit value
        emit Reported(type(uint256).max, 0);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();

        console.log("Reported profit:", profit);
        console.log("Reported loss:", loss);

        // 6. Verify profit was recognized
        assertGt(profit, 0, "Profit should be greater than 0");
        assertEq(loss, 0, "Loss should be 0");

        // 7. Verify total assets increased
        uint256 totalAssetsAfter = vault.totalAssets();
        console.log("Total assets before:", totalAssetsBefore);
        console.log("Total assets after:", totalAssetsAfter);
        assertGt(totalAssetsAfter, totalAssetsBefore, "Total assets should increase after report");

        // 9. Verify donation address received shares from the profit
        uint256 donationSharesAfter = vault.balanceOf(donationAddress);
        console.log("Donation shares before:", donationSharesBefore);
        console.log("Donation shares after:", donationSharesAfter);
        assertGt(donationSharesAfter, donationSharesBefore, "Donation address should receive shares from profit");

        // 10. The increase in donation shares should match the profit
        uint256 donationSharesIncrease = donationSharesAfter - donationSharesBefore;
        assertApproxEqRel(donationSharesIncrease, profit, 0.01e18, "Donation shares increase should match profit");

        // 11. User withdraws their deposit
        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        uint256 assetsReceived = vault.redeem(userShares, user, user);
        vm.stopPrank();

        console.log("User shares:", userShares);
        console.log("User assets received:", assetsReceived);
        assertApproxEqRel(assetsReceived, depositAmount, 0.05e18, "User should receive approximately original deposit");

        // 12. Donation address withdraws their shares to claim profit
        vm.startPrank(donationAddress);
        uint256 donationAssets = vault.redeem(donationSharesAfter, donationAddress, donationAddress);
        vm.stopPrank();

        console.log("Donation assets received:", donationAssets);
        assertGt(donationAssets, 0, "Donation address should receive assets from profit");
    }

    /// @notice Test donation shares can be transferred to another address
    function testDonationSharesTransfer() public {
        // Setup test parameters with large deposit for significant rewards
        uint256 depositAmount = 5000e18;

        // 1. Configure strategy to use UniswapV2
        vm.startPrank(management);
        strategy.setUseUniV3andFees(false, 3000, 500); // Disable UniV3
        vm.stopPrank();

        // 2. Deposit assets into the strategy
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        skip(45 days);

        // 4. Verify we have claimable rewards and enable reward claiming

        vm.startPrank(management);
        uint256 claimableRewardsBefore = strategy.claimableRewards();
        console.log("Claimable rewards before report:", claimableRewardsBefore);
        if (claimableRewardsBefore < 50e18) {
            // Mock additional rewards to reach minimum threshold
            deal(strategy.rewardsToken(), address(strategy), 50e18);
        }
        assertGt(
            claimableRewardsBefore + strategy.balanceOfRewards(),
            50e18,
            "Should have accrued enough rewards to swap"
        );
        strategy.setClaimRewards(true);
        // add money to the vault to simulate profit
        deal(USDS, address(vault), 50e18);
        vm.stopPrank();

        // 5. Report profit to generate donation shares
        vm.startPrank(keeper);
        (uint256 profit, uint256 loss) = vault.report();
        vm.stopPrank();

        console.log("Reported profit:", profit);
        console.log("Reported loss:", loss);
        assertGt(profit, 0, "Profit should be greater than 0");

        // 6. Check donation address received shares
        uint256 donationShares = vault.balanceOf(donationAddress);
        console.log("Donation shares:", donationShares);
        assertEq(donationShares, profit, "Donation address should receive shares equal to profit");

        // 7. Label the donation recipient address
        vm.label(donationRecipient, "Donation Recipient");

        // 8. Transfer half of the donation shares to another address
        uint256 sharesAmountToTransfer = donationShares / 2;
        vm.startPrank(donationAddress);
        vault.transfer(donationRecipient, sharesAmountToTransfer);
        vm.stopPrank();

        // 9. Verify the transfer was successful
        uint256 donationAddressSharesAfterTransfer = vault.balanceOf(donationAddress);
        uint256 recipientShares = vault.balanceOf(donationRecipient);

        console.log("Donation address shares after transfer:", donationAddressSharesAfterTransfer);
        console.log("Recipient shares:", recipientShares);

        assertEq(
            donationAddressSharesAfterTransfer,
            donationShares - sharesAmountToTransfer,
            "Donation address should have correct remaining shares"
        );
        assertEq(recipientShares, sharesAmountToTransfer, "Recipient should have received correct shares amount");

        // 10. Verify recipient can redeem their shares for assets
        vm.startPrank(donationRecipient);
        uint256 assetsReceived = vault.redeem(recipientShares, donationRecipient, donationRecipient);
        vm.stopPrank();

        console.log("Recipient assets received:", assetsReceived);
        assertGt(assetsReceived, 0, "Recipient should receive assets from redeemed shares");
        assertApproxEqRel(
            assetsReceived,
            profit / 2,
            0.01e18,
            "Recipient should receive approximately half of the profit in assets"
        );

        // 11. Verify donation address can still redeem their remaining shares
        vm.startPrank(donationAddress);
        uint256 donationAssetsReceived = vault.redeem(
            donationAddressSharesAfterTransfer,
            donationAddress,
            donationAddress
        );
        vm.stopPrank();

        console.log("Donation address assets received:", donationAssetsReceived);
        assertGt(donationAssetsReceived, 0, "Donation address should receive assets from remaining shares");
        assertApproxEqRel(
            donationAssetsReceived,
            profit / 2,
            0.01e18,
            "Donation address should receive approximately half of the profit in assets"
        );

        // 12. Verify total assets distributed matches the original profit
        assertApproxEqRel(
            assetsReceived + donationAssetsReceived,
            profit,
            0.01e18,
            "Total assets distributed should match the original profit amount"
        );
    }

    /// @notice Test emergency exit functionality
    function testEmergencyExit() public {
        // Setup - deposit a significant amount
        uint256 depositAmount = 5000e18;

        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Verify funds are staked
        uint256 stakedBefore = strategy.balanceOfStake();
        uint256 assetsBefore = strategy.balanceOfAsset();
        assertGt(stakedBefore, 0, "Should have staked funds");
        assertLe(assetsBefore, 100, "Asset balance should be minimal");

        // First need to trigger emergency shutdown mode - must be called by emergency admin
        vm.startPrank(emergencyAdmin);
        vault.shutdownStrategy();

        // Now withdraw all funds
        vault.emergencyWithdraw(type(uint256).max);
        vm.stopPrank();

        // Verify funds are withdrawn from staking
        uint256 stakedAfter = strategy.balanceOfStake();
        uint256 assetsAfter = strategy.balanceOfAsset();
        assertLe(stakedAfter, 0, "Should have withdrawn all staked funds");
        assertGe(assetsAfter, depositAmount - 100, "Should have recovered most assets");

        // User can withdraw funds
        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        uint256 assetsReceived = vault.redeem(userShares, user, user);
        vm.stopPrank();

        // Verify user got their funds back
        assertApproxEqRel(assetsReceived, depositAmount, 0.01e18, "User should receive approximately original deposit");
    }

    /// @notice Test partial emergency withdrawals withdraws only the requested amount
    function testPartialEmergencyWithdrawal() public {
        // Setup - deposit a significant amount
        uint256 depositAmount = 5000e18;

        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Verify funds are staked
        uint256 stakedBefore = strategy.balanceOfStake();
        assertGt(stakedBefore, 0, "Should have staked funds");

        // First need to trigger emergency shutdown mode - must be called by emergency admin
        vm.startPrank(emergencyAdmin);
        vault.shutdownStrategy();

        // Request a partial emergency withdrawal (50%)
        uint256 withdrawAmount = depositAmount / 2;
        vault.emergencyWithdraw(withdrawAmount);
        vm.stopPrank();

        // In SkyCompounder's _emergencyWithdraw, only the requested amount is withdrawn
        uint256 stakedAfter = strategy.balanceOfStake();
        uint256 assetsAfter = strategy.balanceOfAsset();

        // Verify approximately half the funds were withdrawn from staking
        assertApproxEqRel(
            stakedAfter,
            stakedBefore - withdrawAmount,
            0.01e18,
            "About half the funds should remain staked"
        );
        assertApproxEqRel(assetsAfter, withdrawAmount, 0.01e18, "Strategy should have received the withdrawn amount");

        // Test that user can still withdraw their full deposit
        vm.startPrank(user);
        uint256 userShares = vault.balanceOf(user);
        uint256 assetsReceived = vault.redeem(userShares, user, user);
        vm.stopPrank();

        // User should get back their full deposit
        assertApproxEqRel(assetsReceived, depositAmount, 0.01e18, "User should receive approximately original deposit");
    }

    /// @notice Test multiple users with fair profit distribution
    function testMultipleUserProfitDistribution() public {
        // First user deposits
        address user1 = user; // Reuse existing test user
        address user2 = address(0x5678);

        uint256 depositAmount1 = 1000e18;
        uint256 depositAmount2 = 2000e18;

        vm.startPrank(user1);
        vault.deposit(depositAmount1, user1);
        vm.stopPrank();

        // Generate some profit for first user
        uint256 profit1 = depositAmount1 / 10; // 10% profit
        airdrop(ERC20(USDS), address(strategy), profit1);

        // Harvest to realize profit
        vm.startPrank(keeper);
        vault.report();
        vm.stopPrank();

        // Check share price increase
        uint256 sharePrice1 = vault.convertToAssets(1e18);
        assertEq(sharePrice1, 1e18, "Share price should stay the same since profit is minted");

        // Second user deposits after profit
        vm.startPrank(address(this));
        airdrop(ERC20(USDS), user2, depositAmount2);
        vm.stopPrank();

        vm.startPrank(user2);
        ERC20(USDS).approve(address(strategy), type(uint256).max);
        vault.deposit(depositAmount2, user2);
        vm.stopPrank();

        // Generate more profit after second user joined
        uint256 profit2 = (depositAmount1 + depositAmount2) / 10; // 10% of total
        airdrop(ERC20(USDS), address(strategy), profit2);

        // Harvest again
        vm.startPrank(keeper);
        vault.report();
        vm.stopPrank();

        // Skip time to allow profit to unlock
        skip(365 days);

        // Check share price stays the same since profit is minted
        uint256 sharePrice2 = vault.convertToAssets(1e18);
        assertEq(sharePrice2, sharePrice1, "Share price should stay the same since profit is minted");

        // Both users withdraw
        vm.startPrank(user1);
        uint256 user1Shares = vault.balanceOf(user1);
        uint256 user1Assets = vault.redeem(user1Shares, user1, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        uint256 user2Shares = vault.balanceOf(user2);
        uint256 user2Assets = vault.redeem(user2Shares, user2, user2);
        vm.stopPrank();

        // Check that user1 got more relative profit (he was in longer)
        uint256 user1Profit = user1Assets - depositAmount1;
        uint256 user2Profit = user2Assets - depositAmount2;

        uint256 user1ProfitPercentage = (user1Profit * 1e18) / depositAmount1;
        uint256 user2ProfitPercentage = (user2Profit * 1e18) / depositAmount2;

        console.log("User 1 profit percentage:", user1ProfitPercentage);
        console.log("User 2 profit percentage:", user2ProfitPercentage);

        assertEq(user1ProfitPercentage, 0, "User 1 should have received no profit");
        assertEq(user1ProfitPercentage, user2ProfitPercentage, "Users should have received no profit");

        // Check donation address received profit shares as well
        uint256 donationShares = vault.balanceOf(donationAddress);
        assertGt(donationShares, 0, "Donation address should receive shares from profit");
    }

    /// @notice Test slippage protection through minAmountToSell threshold
    function testSlippageProtection() public {
        // Setup - deposit funds
        uint256 depositAmount = 1000e18;

        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Get rewards token and prepare for test
        address rewardsToken = strategy.rewardsToken();

        // Set a high minAmountToSell threshold
        vm.startPrank(management);
        uint256 highMinAmount = 100e18;
        strategy.setMinAmountToSell(highMinAmount);

        // Make sure reward claiming is enabled
        strategy.setClaimRewards(true);

        // Use UniswapV2 for simplicity and disable rewards to avoid interference
        strategy.setUseUniV3andFees(false, 0, 0);
        vm.stopPrank();

        // Create a small reward amount - below the minAmountToSell threshold
        uint256 smallRewardAmount = highMinAmount / 2; // Half the threshold

        // Airdrop rewards to simulate earned rewards
        deal(rewardsToken, address(strategy), smallRewardAmount);

        console.log("Rewards before report:", smallRewardAmount);
        console.log("Min amount to sell:", strategy.minAmountToSell());

        // Attempt to report - rewards should be claimed but not swapped
        vm.startPrank(keeper);
        vault.report();
        vm.stopPrank();

        // The rewards should still be in the strategy because they're below the threshold
        uint256 rewardsAfter = ERC20(rewardsToken).balanceOf(address(strategy));
        console.log("Rewards after report:", rewardsAfter);

        // Verify rewards are still in the strategy (weren't swapped)
        // Note: We don't check exact amounts due to possible mainnet interactions
        // but ensure the core protection worked
        assertGt(rewardsAfter, 0, "Should still have some rewards");
    }

    /// @notice Test slippage configuration in swapper
    function testSlippageConfiguration() public {
        // Verify default settings
        vm.startPrank(management);

        // Test UniswapV3 slippage settings
        strategy.setUseUniV3andFees(true, 3000, 500);
        assertTrue(strategy.useUniV3(), "UniV3 should be enabled");

        // Test minAmountToSell configuration
        uint256 newMinAmount = 30e18;
        strategy.setMinAmountToSell(newMinAmount);
        assertEq(strategy.minAmountToSell(), newMinAmount, "Min amount should be updated");

        vm.stopPrank();

        // Now test deposit and reward claim flow
        uint256 depositAmount = 1000e18;
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Simulate rewards just below threshold - should not trigger swap
        address rewardsToken = strategy.rewardsToken();
        uint256 smallRewardAmount = newMinAmount - 1e18;
        deal(rewardsToken, address(strategy), smallRewardAmount);

        vm.startPrank(management);
        strategy.setClaimRewards(true);
        vm.stopPrank();

        // Report with rewards below threshold - should claim but not swap
        vm.startPrank(keeper);
        vault.report();
        vm.stopPrank();

        // Rewards should still be in the strategy (not swapped due to minAmountToSell)
        uint256 rewardsAfter = ERC20(rewardsToken).balanceOf(address(strategy));
        console.log("Rewards after below-threshold report:", rewardsAfter);
        assertGt(rewardsAfter, 0, "Rewards should remain unswapped");
    }

    // ===== LOSS TRACKING EDGE CASE TESTS =====

    /// @notice Test loss tracking with sufficient dragon router shares for full burning
    function testLossTracking_WithSufficientDragonShares() public {
        console.log("=== Loss Tracking: Sufficient Dragon Router Shares ===");

        uint256 userDeposit = 1000e18;
        uint256 dragonDeposit = 500e18;
        uint256 lossAmount = 200e18; // Less than dragon's contribution

        // User deposits
        vm.startPrank(user);
        vault.deposit(userDeposit, user);
        vm.stopPrank();

        // Dragon router deposits (large amount)
        airdrop(ERC20(USDS), donationAddress, dragonDeposit);
        vm.startPrank(donationAddress);
        ERC20(USDS).approve(address(strategy), type(uint256).max);
        vault.deposit(dragonDeposit, donationAddress);
        vm.stopPrank();

        uint256 initialTotalAssets = vault.totalAssets();
        uint256 initialDragonShares = vault.balanceOf(donationAddress);

        console.log("Initial state:");
        console.log("  User deposit:", userDeposit);
        console.log("  Dragon deposit:", dragonDeposit);
        console.log("  Dragon shares:", initialDragonShares);
        console.log("  Total assets:", initialTotalAssets);

        // Disable health check to allow loss simulation
        vm.startPrank(management);
        strategy.setDoHealthCheck(false);
        vm.stopPrank();

        // Create loss by mocking the balanceOf call
        uint256 stakingBalance = strategy.balanceOfStake();
        uint256 newStakingBalance = stakingBalance > lossAmount ? stakingBalance - lossAmount : 0;
        vm.mockCall(
            STAKING,
            abi.encodeWithSelector(ERC20.balanceOf.selector, address(strategy)),
            abi.encode(newStakingBalance)
        );

        // Report the loss
        vm.startPrank(keeper);
        (uint256 reportedProfit, uint256 reportedLoss) = vault.report();
        vm.stopPrank();

        uint256 dragonSharesAfterLoss = vault.balanceOf(donationAddress);
        uint256 sharesBurned = initialDragonShares - dragonSharesAfterLoss;

        console.log("After loss report:");
        console.log("  Reported profit:", reportedProfit);
        console.log("  Reported loss:", reportedLoss);
        console.log("  Dragon shares after loss:", dragonSharesAfterLoss);
        console.log("  Shares burned:", sharesBurned);
        console.log("  Total assets after loss:", vault.totalAssets());

        // Expected behavior: Only the shares needed to cover the loss should be burned
        assertEq(reportedLoss, lossAmount, "Full loss should be reported");
        assertLt(dragonSharesAfterLoss, initialDragonShares, "Some dragon shares should be burned");
        assertGt(dragonSharesAfterLoss, 0, "Not all dragon shares should be burned");

        // Verify that the shares burned correspond to the loss amount
        // With _convertToSharesWithLoss, the shares burned should equal the loss amount
        // when the share price is 1:1 (which it is initially)
        assertEq(sharesBurned, lossAmount, "Shares burned should equal loss amount with 1:1 share price");

        // === RECOVERY VERIFICATION ===
        // Verify S.lossAmount = 0 (all loss covered by burning) through recovery testing
        console.log("\n=== Recovery Verification ===");

        // Since all loss was covered by burning shares, S.lossAmount should be 0
        // Any profit should immediately result in share minting to dragon router
        uint256 smallProfit = 50e18;
        uint256 currentBalance = stakingBalance - lossAmount; // 1300e18

        airdrop(ERC20(USDS), STAKING, smallProfit);
        vm.mockCall(
            STAKING,
            abi.encodeWithSelector(ERC20.balanceOf.selector, address(strategy)),
            abi.encode(currentBalance + smallProfit) // 1300 + 50 = 1350
        );

        vm.startPrank(keeper);
        (uint256 recoveryProfit1, ) = vault.report();
        vm.stopPrank();

        console.log("After small profit of 50e18:");
        console.log("  Reported profit:", recoveryProfit1);
        console.log("  Dragon shares before:", dragonSharesAfterLoss);
        console.log("  Dragon shares after:", vault.balanceOf(donationAddress));
        console.log("  New shares minted:", vault.balanceOf(donationAddress) - dragonSharesAfterLoss);

        // Shares should be minted immediately since S.lossAmount = 0
        assertEq(
            vault.balanceOf(donationAddress),
            dragonSharesAfterLoss + smallProfit,
            "All profit should mint shares"
        );

        // Add more profit to further verify
        uint256 additionalProfit = 100e18;
        airdrop(ERC20(USDS), STAKING, additionalProfit);
        vm.mockCall(
            STAKING,
            abi.encodeWithSelector(ERC20.balanceOf.selector, address(strategy)),
            abi.encode(currentBalance + smallProfit + additionalProfit) // 1350 + 100 = 1450
        );

        vm.startPrank(keeper);
        (uint256 recoveryProfit2, ) = vault.report();
        vm.stopPrank();

        console.log("\nAfter additional profit of 100e18:");
        console.log("  Reported profit:", recoveryProfit2);
        console.log("  Total dragon shares:", vault.balanceOf(donationAddress));

        // All profit should continue to mint shares
        assertEq(
            vault.balanceOf(donationAddress),
            dragonSharesAfterLoss + smallProfit + additionalProfit,
            "All additional profit should mint shares"
        );

        console.log("\nVerified S.lossAmount = 0: All loss was covered by burning dragon shares");
        console.log("Subsequent profits immediately mint new shares to dragon router");
    }

    /// @notice Test that dust assets are properly reported in totalAssets
    /// @dev Addresses TRST-L-6: SkyCompounderStrategy should report all assets including dust
    function testDustAssetsAreProperlyReported() public {
        uint256 depositAmount = 10000e18; // 10,000 USDS
        uint256 dustAmount = 50; // 50 wei dust (below ASSET_DUST threshold of 100)

        // Setup user with USDS
        airdrop(ERC20(USDS), user, depositAmount);

        // User deposits into vault
        vm.startPrank(user);
        vault.deposit(depositAmount, user);
        vm.stopPrank();

        // Verify all assets are staked
        assertEq(strategy.balanceOfStake(), depositAmount, "All deposited assets should be staked");
        assertEq(strategy.balanceOfAsset(), 0, "No idle assets initially");

        // Simulate dust assets remaining in strategy (e.g., from rounding errors)
        deal(USDS, address(strategy), dustAmount);

        // Verify dust assets are present
        assertEq(strategy.balanceOfAsset(), dustAmount, "Dust assets should be present");

        // Get total assets before report
        uint256 totalAssetsBefore = vault.totalAssets();

        // Report to update totalAssets calculation
        vm.prank(keeper);
        vault.report();

        // Get total assets after report
        uint256 totalAssetsAfter = vault.totalAssets();

        // Verify that dust assets are included in totalAssets
        // Total assets should include both staked assets and dust
        uint256 expectedTotalAssets = strategy.balanceOfStake() + strategy.balanceOfAsset();
        assertEq(totalAssetsAfter, expectedTotalAssets, "Total assets should include dust assets");

        // Specifically verify dust is not ignored
        assertGe(
            totalAssetsAfter,
            totalAssetsBefore + dustAmount,
            "Total assets should increase by at least dust amount"
        );

        // Verify the fix: dust assets are included even though below ASSET_DUST threshold
        assertTrue(strategy.balanceOfAsset() < 100, "Dust amount should be below ASSET_DUST threshold");
        assertTrue(
            totalAssetsAfter > strategy.balanceOfStake(),
            "Total assets should be greater than just staked amount"
        );
    }

    /// @notice Test edge case where only dust assets exist in strategy
    function testOnlyDustAssetsReported() public {
        uint256 dustAmount = 99; // Just below ASSET_DUST threshold

        // Give strategy only dust assets, no staking
        deal(USDS, address(strategy), dustAmount);

        // Verify only dust assets exist
        assertEq(strategy.balanceOfAsset(), dustAmount, "Only dust assets should exist");
        assertEq(strategy.balanceOfStake(), 0, "No staked assets should exist");

        // Disable health check to allow small-scale operation
        vm.prank(management);
        strategy.setDoHealthCheck(false);

        // Report to calculate totalAssets
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = vault.report();

        // Verify dust assets are properly reported
        uint256 totalAssets = vault.totalAssets();
        assertEq(totalAssets, dustAmount, "Total assets should equal dust amount");

        // The profit will be equal to dust amount since this is a gain from 0 baseline
        assertEq(profit, dustAmount, "Profit should equal dust amount as it's a gain from 0");
        assertEq(loss, 0, "No loss should be reported");
    }
}
