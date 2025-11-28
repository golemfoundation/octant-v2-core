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
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title ShutterDAOIntegrationTest
 * @notice Comprehensive integration test using Mainnet Forking.
 * @dev Replaces previous mock-based tests with fully realistic mainnet fork tests.
 *      Run with: forge test --match-contract ShutterDAOIntegrationTest --fork-url $ETH_RPC_URL
 */
contract ShutterDAOIntegrationTest is Test {
    using SafeERC20 for IERC20;

    // === Real Mainnet Addresses ===
    address constant SHUTTER_TREASURY = 0x36bD3044ab68f600f6d3e081056F34f2a58432c4;
    address constant SHU_TOKEN = 0xe485E2f1bab389C08721B291f6b59780feC83Fd7;
    address constant USDC_TOKEN = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant MORPHO_STEAKHOUSE_VAULT = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;

    // === Constants ===
    uint256 constant TREASURY_USDC_BALANCE = 1_500_000e6;
    uint256 constant SHU_HOLDER_BALANCE = 100_000e18;
    uint256 constant REWARD_DURATION = 90 days;
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

    // === Roles ===
    address octantGovernance;
    address keeper;
    address shuHolder1;
    address shuHolder2;
    address shuHolder3;

    bool isForked;

    function setUp() public {
        // Ensure forking is active
        try vm.envString("ETH_RPC_URL") returns (string memory rpcUrl) {
            vm.createSelectFork(rpcUrl);
            isForked = true;
        } catch {
            console2.log("Skipping fork tests: ETH_RPC_URL not set");
            return;
        }

        octantGovernance = makeAddr("OctantGovernance");
        keeper = makeAddr("Keeper");
        shuHolder1 = makeAddr("SHUHolder1");
        shuHolder2 = makeAddr("SHUHolder2");
        shuHolder3 = makeAddr("SHUHolder3");

        // Setup balances
        deal(USDC_TOKEN, SHUTTER_TREASURY, TREASURY_USDC_BALANCE);
        deal(SHU_TOKEN, shuHolder1, SHU_HOLDER_BALANCE);
        deal(SHU_TOKEN, shuHolder2, SHU_HOLDER_BALANCE);
        deal(SHU_TOKEN, shuHolder3, SHU_HOLDER_BALANCE);

        _deployInfrastructure();
        _deployVaultAndStrategy();
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
        // Donation Splitter (5% ESF, 95% Dragon Pool)
        address[] memory payees = new address[](2);
        payees[0] = makeAddr("ESF");
        payees[1] = makeAddr("DragonFundingPool");
        uint256[] memory shares = new uint256[](2);
        shares[0] = 5;
        shares[1] = 95;

        PaymentSplitter paymentSplitterImpl = new PaymentSplitter();
        bytes memory initData = abi.encodeCall(PaymentSplitter.initialize, (payees, shares));
        ERC1967Proxy proxy = new ERC1967Proxy(address(paymentSplitterImpl), initData);
        paymentSplitter = PaymentSplitter(payable(address(proxy)));

        // Deploy Morpho Strategy
        vm.prank(SHUTTER_TREASURY);
        strategy = new MorphoCompounderStrategy(
            MORPHO_STEAKHOUSE_VAULT,
            USDC_TOKEN,
            "Octant Morpho USDC",
            SHUTTER_TREASURY,
            keeper,
            SHUTTER_TREASURY,
            address(paymentSplitter),
            false,
            address(strategyImpl)
        );

        // Deploy Vault
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
        dragonVault.addRole(SHUTTER_TREASURY, IMultistrategyVault.Roles.QUEUE_MANAGER);
        dragonVault.addRole(SHUTTER_TREASURY, IMultistrategyVault.Roles.WITHDRAW_LIMIT_MANAGER);
        dragonVault.addRole(keeper, IMultistrategyVault.Roles.DEBT_MANAGER);

        // Setup Strategy
        dragonVault.addStrategy(address(strategy), true);
        dragonVault.updateMaxDebtForStrategy(address(strategy), type(uint256).max);
        dragonVault.setDepositLimit(type(uint256).max, true);
        dragonVault.setAutoAllocate(true); // Default to true for most tests

        vm.stopPrank();
    }

    function _deployRegenStaker() internal {
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
            IERC20Staking(SHU_TOKEN),
            calculator,
            1e18,
            octantGovernance,
            uint128(REWARD_DURATION),
            0,
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            allowset
        );
    }

    function test_TreasuryDepositsUSDCIntoDragonVault() public {
        if (!isForked) return;

        uint256 depositAmount = TREASURY_USDC_BALANCE;

        vm.startPrank(SHUTTER_TREASURY);
        IERC20(USDC_TOKEN).approve(address(dragonVault), depositAmount);
        dragonVault.deposit(depositAmount, SHUTTER_TREASURY);
        vm.stopPrank();

        assertEq(dragonVault.balanceOf(SHUTTER_TREASURY), depositAmount);
        assertEq(dragonVault.totalAssets(), depositAmount);
        assertEq(IERC20(USDC_TOKEN).balanceOf(SHUTTER_TREASURY), 0);
    }

    function test_AutoAllocateDeploysToStrategy() public {
        if (!isForked) return;

        uint256 depositAmount = TREASURY_USDC_BALANCE;

        vm.startPrank(SHUTTER_TREASURY);
        IERC20(USDC_TOKEN).approve(address(dragonVault), depositAmount);
        dragonVault.deposit(depositAmount, SHUTTER_TREASURY);
        vm.stopPrank();

        // Check funds moved to Strategy (which deployed to Morpho)
        // Strategy itself should have 0 idle USDC
        assertEq(IERC20(USDC_TOKEN).balanceOf(address(strategy)), 0);
        // But should track assets
        assertApproxEqAbs(strategy.totalAssets(), depositAmount, 1000);

        assertEq(dragonVault.totalDebt(), depositAmount);
        assertEq(dragonVault.totalIdle(), 0);
    }

    function test_KeeperTriggeredAllocation() public {
        if (!isForked) return;

        // Disable auto allocate first
        vm.prank(SHUTTER_TREASURY);
        dragonVault.setAutoAllocate(false);

        uint256 depositAmount = TREASURY_USDC_BALANCE;

        vm.startPrank(SHUTTER_TREASURY);
        IERC20(USDC_TOKEN).approve(address(dragonVault), depositAmount);
        dragonVault.deposit(depositAmount, SHUTTER_TREASURY);
        vm.stopPrank();

        assertEq(dragonVault.totalIdle(), depositAmount);
        assertEq(dragonVault.totalDebt(), 0);

        // Keeper triggers allocation
        vm.prank(keeper);
        dragonVault.updateDebt(address(strategy), type(uint256).max, 0);

        assertEq(dragonVault.totalDebt(), depositAmount);
        assertEq(dragonVault.totalIdle(), 0);
        assertApproxEqAbs(strategy.totalAssets(), depositAmount, 1000);
    }

    function test_TreasuryCanWithdrawInstantly() public {
        if (!isForked) return;

        uint256 depositAmount = TREASURY_USDC_BALANCE;

        vm.startPrank(SHUTTER_TREASURY);
        IERC20(USDC_TOKEN).approve(address(dragonVault), depositAmount);
        dragonVault.deposit(depositAmount, SHUTTER_TREASURY);
        vm.stopPrank();

        vm.prank(SHUTTER_TREASURY);
        dragonVault.withdraw(depositAmount, SHUTTER_TREASURY, SHUTTER_TREASURY, 0, new address[](0));

        assertEq(IERC20(USDC_TOKEN).balanceOf(SHUTTER_TREASURY), depositAmount);
        assertEq(dragonVault.balanceOf(SHUTTER_TREASURY), 0);
    }

    function test_TreasuryCanWithdrawFromStrategy() public {
        if (!isForked) return;
        // AutoAllocate is ON by default in setUp

        uint256 depositAmount = TREASURY_USDC_BALANCE;

        vm.startPrank(SHUTTER_TREASURY);
        IERC20(USDC_TOKEN).approve(address(dragonVault), depositAmount);
        dragonVault.deposit(depositAmount, SHUTTER_TREASURY);
        vm.stopPrank();

        assertEq(dragonVault.totalDebt(), depositAmount);

        vm.prank(SHUTTER_TREASURY);
        dragonVault.withdraw(depositAmount, SHUTTER_TREASURY, SHUTTER_TREASURY, 0, new address[](0));

        assertEq(IERC20(USDC_TOKEN).balanceOf(SHUTTER_TREASURY), depositAmount);
        assertEq(dragonVault.balanceOf(SHUTTER_TREASURY), 0);
        assertEq(dragonVault.totalDebt(), 0);
    }

    function test_SHUHoldersCanDelegateVotingPower() public {
        if (!isForked) return;

        uint256 stakeAmount = SHU_HOLDER_BALANCE;
        address delegatee = makeAddr("Delegatee");
        address surrogate = regenStaker.predictSurrogateAddress(delegatee);

        vm.startPrank(shuHolder1);
        IERC20(SHU_TOKEN).approve(address(regenStaker), stakeAmount);
        regenStaker.stake(stakeAmount, delegatee);
        vm.stopPrank();

        // Verify Real SHU Delegation logic
        // We staticcall SHU.delegates(surrogate)
        (bool success, bytes memory data) = SHU_TOKEN.staticcall(
            abi.encodeWithSignature("delegates(address)", surrogate)
        );
        require(success, "Delegates call failed");
        address actualDelegatee = abi.decode(data, (address));

        assertEq(actualDelegatee, delegatee, "Delegation failed on real SHU token");
        assertEq(regenStaker.totalStaked(), stakeAmount);
    }

    function test_MultipleSHUHoldersCanStake() public {
        if (!isForked) return;

        uint256 stakeAmount = SHU_HOLDER_BALANCE;

        vm.startPrank(shuHolder1);
        IERC20(SHU_TOKEN).approve(address(regenStaker), stakeAmount);
        regenStaker.stake(stakeAmount, shuHolder1);
        vm.stopPrank();

        vm.startPrank(shuHolder2);
        IERC20(SHU_TOKEN).approve(address(regenStaker), stakeAmount);
        regenStaker.stake(stakeAmount, shuHolder2);
        vm.stopPrank();

        assertEq(regenStaker.totalStaked(), stakeAmount * 2);
    }

    function test_SharesAreTransferable() public {
        if (!isForked) return;

        uint256 depositAmount = TREASURY_USDC_BALANCE;

        vm.startPrank(SHUTTER_TREASURY);
        IERC20(USDC_TOKEN).approve(address(dragonVault), depositAmount);
        dragonVault.deposit(depositAmount, SHUTTER_TREASURY);
        vm.stopPrank();

        uint256 shares = dragonVault.balanceOf(SHUTTER_TREASURY);
        uint256 halfShares = shares / 2;

        vm.prank(SHUTTER_TREASURY);
        dragonVault.transfer(shuHolder1, halfShares);

        assertEq(dragonVault.balanceOf(SHUTTER_TREASURY), halfShares);
        assertEq(dragonVault.balanceOf(shuHolder1), halfShares);
    }
}

/**
 * @title ShutterDAOGasProfilingTest
 * @notice Gas profiling test (also adapted for Fork if possible, but using mocks for speed/isolation is usually fine too.
 *         Here we simulate on Fork for realism).
 */
contract ShutterDAOGasProfilingTest is Test {
    using SafeERC20 for IERC20;

    address constant SHUTTER_TREASURY = 0x36bD3044ab68f600f6d3e081056F34f2a58432c4;
    address constant USDC_TOKEN = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant MORPHO_STEAKHOUSE_VAULT = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;

    uint256 constant TREASURY_USDC_BALANCE = 1_500_000e6;
    uint256 constant PROFIT_MAX_UNLOCK_TIME = 7 days;
    uint256 constant EIP_7825_BLOCK_GAS_LIMIT = 16_000_000;

    bool isForked;

    function setUp() public {
        try vm.envString("ETH_RPC_URL") returns (string memory rpcUrl) {
            vm.createSelectFork(rpcUrl);
            isForked = true;
        } catch {
            return;
        }
        deal(USDC_TOKEN, SHUTTER_TREASURY, TREASURY_USDC_BALANCE);
    }

    function test_BatchedProposalGasProfile() public {
        if (!isForked) return;

        address octantGovernance = makeAddr("OctantGovernance");
        address keeper = makeAddr("Keeper");

        uint256 gasStart = gasleft();

        // === BATCHED PROPOSAL STARTS HERE ===
        // Simulating deployment of REAL contracts on the fork

        // Pre-deployed by Octant
        MultistrategyVault vaultImplementation = new MultistrategyVault();
        MultistrategyVaultFactory vaultFactory = new MultistrategyVaultFactory(
            "Shutter Dragon Vault Factory",
            address(vaultImplementation),
            octantGovernance
        );

        TokenizedStrategy strategyImpl = new TokenizedStrategy();
        // PaymentSplitter setup (proxy pattern)
        address[] memory payees = new address[](2);
        payees[0] = makeAddr("ESF");
        payees[1] = makeAddr("DragonFundingPool");
        uint256[] memory shares = new uint256[](2);
        shares[0] = 5;
        shares[1] = 95;

        PaymentSplitter paymentSplitterImpl = new PaymentSplitter();
        bytes memory initData = abi.encodeCall(PaymentSplitter.initialize, (payees, shares));
        ERC1967Proxy proxy = new ERC1967Proxy(address(paymentSplitterImpl), initData);
        PaymentSplitter paymentSplitter = PaymentSplitter(payable(address(proxy)));

        uint256 gasAfterFactoryDeploy = gasleft();

        // TX 1: Deploy Strategy
        vm.prank(SHUTTER_TREASURY);
        MorphoCompounderStrategy strategy = new MorphoCompounderStrategy(
            MORPHO_STEAKHOUSE_VAULT,
            USDC_TOKEN,
            "Octant Morpho USDC",
            SHUTTER_TREASURY,
            keeper,
            SHUTTER_TREASURY,
            address(paymentSplitter),
            false,
            address(strategyImpl)
        );

        uint256 gasAfterStrategyDeploy = gasleft();

        // TX 2: Deploy Vault
        vm.prank(SHUTTER_TREASURY);
        MultistrategyVault dragonVault = MultistrategyVault(
            vaultFactory.deployNewVault(
                USDC_TOKEN,
                "Shutter Dragon Vault",
                "sdUSDC",
                SHUTTER_TREASURY,
                PROFIT_MAX_UNLOCK_TIME
            )
        );

        uint256 gasAfterVaultDeploy = gasleft();

        // Since strategy logic is immutable in MorphoCompounderStrategy, we don't need to recreate it.

        // TX 3-6: Configure
        vm.startPrank(SHUTTER_TREASURY);

        dragonVault.addRole(SHUTTER_TREASURY, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);
        dragonVault.addRole(SHUTTER_TREASURY, IMultistrategyVault.Roles.MAX_DEBT_MANAGER);
        dragonVault.addRole(SHUTTER_TREASURY, IMultistrategyVault.Roles.QUEUE_MANAGER);
        dragonVault.addRole(SHUTTER_TREASURY, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);
        dragonVault.addRole(SHUTTER_TREASURY, IMultistrategyVault.Roles.DEBT_MANAGER);
        dragonVault.addRole(keeper, IMultistrategyVault.Roles.DEBT_MANAGER);

        dragonVault.addStrategy(address(strategy), true);
        dragonVault.updateMaxDebtForStrategy(address(strategy), type(uint256).max);
        dragonVault.setDepositLimit(type(uint256).max, true);
        dragonVault.setAutoAllocate(true);

        uint256 gasAfterConfig = gasleft();

        // TX 7: Approve
        IERC20(USDC_TOKEN).approve(address(dragonVault), TREASURY_USDC_BALANCE);

        // TX 8: Deposit
        dragonVault.deposit(TREASURY_USDC_BALANCE, SHUTTER_TREASURY);

        vm.stopPrank();

        uint256 gasEnd = gasleft();
        uint256 totalGasUsed = gasStart - gasEnd;

        // Metrics
        uint256 daoProposalGas = totalGasUsed - (gasStart - gasAfterFactoryDeploy);

        emit log_named_uint("=== TOTAL GAS USED (Fork) ===", totalGasUsed);
        emit log_named_uint("=== DAO PROPOSAL GAS (Fork) ===", daoProposalGas);

        assertLt(daoProposalGas, EIP_7825_BLOCK_GAS_LIMIT, "Gas limit exceeded");
    }
}
