// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { TokenizedStrategy } from "src/core/TokenizedStrategy.sol";
import { PaymentSplitter } from "src/core/PaymentSplitter.sol";

import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { AccessMode } from "src/constants.sol";

import { MorphoCompounderStrategy } from "src/strategies/yieldDonating/MorphoCompounderStrategy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Staking } from "staker/interfaces/IERC20Staking.sol";

/**
 * @title ShutterDAOForkIntegrationTest
 * @notice Realistic integration test using Mainnet Forking.
 * @dev Uses real SHU token (for delegation logic), real USDC, and real Morpho Vault.
 *      Run with: forge test --match-contract ShutterDAOForkIntegration --fork-url $ETH_RPC_URL
 */
contract ShutterDAOForkIntegrationTest is Test {
    using SafeERC20 for IERC20;

    // === Real Mainnet Addresses ===
    address constant SHUTTER_TREASURY = 0x36bD3044ab68f600f6d3e081056F34f2a58432c4;
    address constant SHU_TOKEN = 0xe485E2f1bab389C08721B291f6b59780feC83Fd7;
    address constant USDC_TOKEN = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant MORPHO_STEAKHOUSE_VAULT = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;

    // === Constants ===
    uint256 constant DEPOSIT_AMOUNT = 1_500_000e6; // 1.5M USDC
    uint256 constant STAKE_AMOUNT = 100_000e18; // 100k SHU
    uint256 constant PROFIT_MAX_UNLOCK_TIME = 7 days;

    // === System Contracts ===
    MultistrategyVault vaultImplementation;
    MultistrategyVaultFactory vaultFactory;
    MultistrategyVault dragonVault;
    MorphoCompounderStrategy strategy;
    TokenizedStrategy strategyImpl;
    PaymentSplitter paymentSplitter;

    RegenStaker regenStaker;
    RegenEarningPowerCalculator calculator;
    AddressSet allowset;

    address octantGovernance;
    address keeper;
    address user;

    bool isForked;

    function setUp() public {
        // Only run if forking is active (chainId == 1)
        // Note: When running with --fork-url, chainId will be 1.
        // If running without, it will be 31337.
        // We try to create a fork if URL is present, otherwise skip.
        try vm.envString("ETH_RPC_URL") returns (string memory rpcUrl) {
            vm.createSelectFork(rpcUrl);
            isForked = true;
        } catch {
            console2.log("Skipping fork tests: ETH_RPC_URL not set");
            return;
        }

        octantGovernance = makeAddr("OctantGovernance");
        keeper = makeAddr("Keeper");
        user = makeAddr("User");

        // 1. Deploy System Infrastructure (Mocking Octant Side)
        _deployInfrastructure();

        // 2. Setup Vault & Strategy
        _deployVaultAndStrategy();

        // 3. Setup Regen Staker
        _deployRegenStaker();
    }

    function _deployInfrastructure() internal {
        vaultImplementation = new MultistrategyVault();
        strategyImpl = new TokenizedStrategy();

        vm.prank(octantGovernance);
        vaultFactory = new MultistrategyVaultFactory(
            "Shutter Dragon Vault Factory",
            address(vaultImplementation),
            octantGovernance
        );
    }

    function _deployVaultAndStrategy() internal {
        // --- Deploy Donation Splitter ---
        // 5% ESF, 95% Dragon Pool
        address[] memory payees = new address[](2);
        payees[0] = makeAddr("ESF");
        payees[1] = makeAddr("DragonFundingPool");

        uint256[] memory shares = new uint256[](2);
        shares[0] = 5;
        shares[1] = 95;

        paymentSplitter = new PaymentSplitter();
        paymentSplitter.initialize(payees, shares);

        // --- Deploy Strategy ---
        // Using real Morpho Compounder logic
        vm.prank(SHUTTER_TREASURY);
        strategy = new MorphoCompounderStrategy(
            MORPHO_STEAKHOUSE_VAULT,
            USDC_TOKEN,
            "Octant Morpho USDC",
            SHUTTER_TREASURY, // Management
            keeper, // Keeper
            SHUTTER_TREASURY, // Emergency Admin
            address(paymentSplitter), // Donation Address
            false, // Enable Burning
            address(strategyImpl)
        );

        // --- Deploy Vault ---
        vm.startPrank(SHUTTER_TREASURY);
        dragonVault = MultistrategyVault(
            vaultFactory.deployNewVault(
                USDC_TOKEN,
                "Shutter Dragon Vault",
                "sdUSDC",
                SHUTTER_TREASURY,
                PROFIT_MAX_UNLOCK_TIME
            )
        );

        // Configure Roles
        dragonVault.addRole(SHUTTER_TREASURY, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);
        dragonVault.addRole(SHUTTER_TREASURY, IMultistrategyVault.Roles.DEBT_MANAGER);
        dragonVault.addRole(SHUTTER_TREASURY, IMultistrategyVault.Roles.MAX_DEBT_MANAGER);
        dragonVault.addRole(SHUTTER_TREASURY, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);
        dragonVault.addRole(keeper, IMultistrategyVault.Roles.DEBT_MANAGER);

        // Add Strategy
        dragonVault.addStrategy(address(strategy), true);
        dragonVault.updateMaxDebtForStrategy(address(strategy), type(uint256).max);
        dragonVault.setDepositLimit(type(uint256).max, true);
        dragonVault.setAutoAllocate(true);

        vm.stopPrank();
    }

    function _deployRegenStaker() internal {
        // Mock reward token for RegenStaker (or use real GLM/ETH if needed)
        // Using a mock here just for the reward part, but STAKE token is real SHU.
        // To be 100% realistic we should mock the reward distribution source.

        address mockRewardToken = makeAddr("RewardToken");

        allowset = new AddressSet();
        calculator = new RegenEarningPowerCalculator(
            octantGovernance,
            allowset,
            IAddressSet(address(0)),
            AccessMode.NONE
        );

        regenStaker = new RegenStaker(
            IERC20(mockRewardToken),
            IERC20Staking(SHU_TOKEN), // Real SHU Token
            calculator,
            1e18,
            octantGovernance,
            90 days,
            0,
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            allowset
        );
    }

    // === TESTS ===

    function test_RealSHUDelegation() public {
        if (!isForked) return;

        // Deal SHU to user (needs whale or deal)
        // SHU is deployed, we can use deal
        deal(SHU_TOKEN, user, STAKE_AMOUNT);

        address delegatee = makeAddr("Delegatee");
        address surrogate = regenStaker.predictSurrogateAddress(delegatee);

        vm.startPrank(user);
        IERC20(SHU_TOKEN).approve(address(regenStaker), STAKE_AMOUNT);
        regenStaker.stake(STAKE_AMOUNT, delegatee);
        vm.stopPrank();

        // Verify:
        // 1. Surrogate holds the SHU
        assertEq(IERC20(SHU_TOKEN).balanceOf(surrogate), STAKE_AMOUNT);

        // 2. Real SHU token acknowledges delegation
        // We need to check SHU contract interface for delegates()
        // Using low-level call or interface if known.
        // Assuming generic governance token interface (Comp-like)
        // function delegates(address) returns (address)

        (bool success, bytes memory data) = SHU_TOKEN.staticcall(
            abi.encodeWithSignature("delegates(address)", surrogate)
        );
        require(success, "Delegates call failed");
        address actualDelegatee = abi.decode(data, (address));

        assertEq(actualDelegatee, delegatee, "Delegation failed on real SHU token");
    }

    function test_RealUSDCDepositAndStrategyAlloc() public {
        if (!isForked) return;

        // Deal USDC to Treasury
        deal(USDC_TOKEN, SHUTTER_TREASURY, DEPOSIT_AMOUNT);

        vm.startPrank(SHUTTER_TREASURY);
        IERC20(USDC_TOKEN).approve(address(dragonVault), DEPOSIT_AMOUNT);
        dragonVault.deposit(DEPOSIT_AMOUNT, SHUTTER_TREASURY);
        vm.stopPrank();

        // Check funds moved to Strategy
        // Strategy holds funds? No, Strategy DEPOSITS into Morpho.
        // So Strategy balance of USDC should be 0, but it should hold shares of Morpho Vault.

        assertEq(IERC20(USDC_TOKEN).balanceOf(address(strategy)), 0, "Strategy should not hold idle USDC");

        // Check Strategy totalAssets() reports the value
        // This calls Morpho Vault convertToAssets
        uint256 strategyAssets = strategy.totalAssets();

        // Should be roughly equal to deposit (minus minimal slippage/rounding)
        assertApproxEqAbs(strategyAssets, DEPOSIT_AMOUNT, 1000, "Assets not accounted for in Morpho");
    }
}
