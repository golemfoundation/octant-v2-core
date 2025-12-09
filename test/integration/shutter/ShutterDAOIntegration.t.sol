// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { PaymentSplitter } from "src/core/PaymentSplitter.sol";

import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { AccessMode } from "src/constants.sol";

import { MorphoCompounderStrategy } from "src/strategies/yieldDonating/MorphoCompounderStrategy.sol";
import { MorphoCompounderStrategyFactory } from "src/factories/MorphoCompounderStrategyFactory.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Staking } from "staker/interfaces/IERC20Staking.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ISafe } from "src/zodiac-core/interfaces/Safe.sol";
import { USDC_MAINNET, MORPHO_STRATEGY_FACTORY_MAINNET, YEARN_TOKENIZED_STRATEGY_MAINNET, EIP_7825_TX_GAS_LIMIT } from "src/constants.sol";

/**
 * @title ShutterDAOIntegrationTest
 * @notice Comprehensive integration test using Mainnet Forking.
 * @dev Replaces previous mock-based tests with fully realistic mainnet fork tests.
 *      Run with: forge test --match-contract ShutterDAOIntegrationTest --fork-url $ETH_RPC_URL
 */
contract ShutterDAOIntegrationTest is Test {
    using SafeERC20 for IERC20;

    // === Shutter DAO Specific Addresses ===
    address constant SHUTTER_TREASURY = 0x36bD3044ab68f600f6d3e081056F34f2a58432c4;
    address constant AZORIUS_MODULE = 0xAA6BfA174d2f803b517026E93DBBEc1eBa26258e;
    address constant SHU_TOKEN = 0xe485E2f1bab389C08721B291f6b59780feC83Fd7;

    // === From src/constants.sol ===
    address constant USDC_TOKEN = USDC_MAINNET;
    address constant MORPHO_STRATEGY_FACTORY = MORPHO_STRATEGY_FACTORY_MAINNET;
    address constant TOKENIZED_STRATEGY_ADDRESS = YEARN_TOKENIZED_STRATEGY_MAINNET;

    string constant STRATEGY_NAME = "SHUGrantPool";

    // === Constants ===
    uint256 constant TREASURY_USDC_BALANCE = 1_200_000e6;
    uint256 constant SHU_HOLDER_BALANCE = 100_000e18;
    uint256 constant REWARD_DURATION = 90 days;
    uint256 constant PROFIT_MAX_UNLOCK_TIME = 7 days;

    // === System Contracts ===
    MultistrategyVault vaultImplementation;
    MultistrategyVaultFactory vaultFactory;
    MultistrategyVault dragonVault;
    MorphoCompounderStrategy strategy;
    PaymentSplitter paymentSplitter;

    RegenStaker regenStaker;
    RegenEarningPowerCalculator calculator;
    AddressSet allowset;

    // === Roles ===
    address octantGovernance;
    address keeperBot;
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
        keeperBot = makeAddr("KeeperBot");
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

        vm.prank(octantGovernance);
        vaultFactory = new MultistrategyVaultFactory(
            "Shutter Dragon Vault Factory",
            address(vaultImplementation),
            octantGovernance
        );
    }

    /// @notice Simulates Azorius module executing a transaction through the Safe
    /// @dev Real call chain: Azorius.executeProposal() → Safe.execTransactionFromModule() → Target
    ///      From target's perspective, msg.sender = Safe (Treasury)
    function _executeFromModule(address to, bytes memory data) internal {
        vm.prank(AZORIUS_MODULE);
        bool success = ISafe(SHUTTER_TREASURY).execTransactionFromModule(to, 0, data, 0);
        require(success, "Module execution failed");
    }

    /// @notice Execute and return data (for calls that return values like factory.createStrategy)
    function _executeFromModuleReturnData(address to, bytes memory data) internal returns (bytes memory returnData) {
        vm.prank(AZORIUS_MODULE);
        (bool success, bytes memory result) = ISafe(SHUTTER_TREASURY).execTransactionFromModuleReturnData(
            to,
            0,
            data,
            0
        );
        require(success, "Module execution failed");
        return result;
    }

    function _deployVaultAndStrategy() internal {
        // PaymentSplitter configuration: 100% to Dragon Funding Pool
        address[] memory payees = new address[](1);
        payees[0] = makeAddr("DragonFundingPool");
        uint256[] memory shares = new uint256[](1);
        shares[0] = 100;

        PaymentSplitter paymentSplitterImpl = new PaymentSplitter();
        bytes memory initData = abi.encodeCall(PaymentSplitter.initialize, (payees, shares));
        ERC1967Proxy proxy = new ERC1967Proxy(address(paymentSplitterImpl), initData);
        paymentSplitter = PaymentSplitter(payable(address(proxy)));

        // ══════════════════════════════════════════════════════════════════════
        // TX 1: Deploy Morpho Strategy via Factory (through Azorius → Safe)
        // ══════════════════════════════════════════════════════════════════════
        bytes memory createStrategyData = abi.encodeCall(
            MorphoCompounderStrategyFactory.createStrategy,
            (
                STRATEGY_NAME,
                SHUTTER_TREASURY,
                keeperBot,
                SHUTTER_TREASURY,
                address(paymentSplitter),
                false,
                TOKENIZED_STRATEGY_ADDRESS
            )
        );
        bytes memory returnData = _executeFromModuleReturnData(MORPHO_STRATEGY_FACTORY, createStrategyData);
        address strategyAddress = abi.decode(returnData, (address));
        strategy = MorphoCompounderStrategy(strategyAddress);

        // ══════════════════════════════════════════════════════════════════════
        // TX 2: Deploy Vault (through Azorius → Safe)
        // ══════════════════════════════════════════════════════════════════════
        bytes memory deployVaultData = abi.encodeCall(
            MultistrategyVaultFactory.deployNewVault,
            (USDC_TOKEN, "Shutter Dragon Vault", "sdUSDC", SHUTTER_TREASURY, PROFIT_MAX_UNLOCK_TIME)
        );
        returnData = _executeFromModuleReturnData(address(vaultFactory), deployVaultData);
        address vaultAddress = abi.decode(returnData, (address));
        dragonVault = MultistrategyVault(vaultAddress);

        // ══════════════════════════════════════════════════════════════════════
        // TX 3-9: Configure Vault Roles (through Azorius → Safe)
        // ══════════════════════════════════════════════════════════════════════
        _executeFromModule(
            vaultAddress,
            abi.encodeCall(
                MultistrategyVault.addRole,
                (SHUTTER_TREASURY, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER)
            )
        );
        _executeFromModule(
            vaultAddress,
            abi.encodeCall(MultistrategyVault.addRole, (SHUTTER_TREASURY, IMultistrategyVault.Roles.MAX_DEBT_MANAGER))
        );
        _executeFromModule(
            vaultAddress,
            abi.encodeCall(
                MultistrategyVault.addRole,
                (SHUTTER_TREASURY, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER)
            )
        );
        _executeFromModule(
            vaultAddress,
            abi.encodeCall(MultistrategyVault.addRole, (SHUTTER_TREASURY, IMultistrategyVault.Roles.QUEUE_MANAGER))
        );
        _executeFromModule(
            vaultAddress,
            abi.encodeCall(
                MultistrategyVault.addRole,
                (SHUTTER_TREASURY, IMultistrategyVault.Roles.WITHDRAW_LIMIT_MANAGER)
            )
        );
        // DEBT_MANAGER needed for setAutoAllocate
        _executeFromModule(
            vaultAddress,
            abi.encodeCall(MultistrategyVault.addRole, (SHUTTER_TREASURY, IMultistrategyVault.Roles.DEBT_MANAGER))
        );
        // Also give keeper DEBT_MANAGER for autonomous debt rebalancing
        _executeFromModule(
            vaultAddress,
            abi.encodeCall(MultistrategyVault.addRole, (keeperBot, IMultistrategyVault.Roles.DEBT_MANAGER))
        );

        // ══════════════════════════════════════════════════════════════════════
        // TX 9-12: Setup Strategy (through Azorius → Safe)
        // ══════════════════════════════════════════════════════════════════════
        _executeFromModule(vaultAddress, abi.encodeCall(MultistrategyVault.addStrategy, (strategyAddress, true)));
        _executeFromModule(
            vaultAddress,
            abi.encodeCall(MultistrategyVault.updateMaxDebtForStrategy, (strategyAddress, type(uint256).max))
        );
        _executeFromModule(vaultAddress, abi.encodeCall(MultistrategyVault.setDepositLimit, (type(uint256).max, true)));
        _executeFromModule(vaultAddress, abi.encodeCall(MultistrategyVault.setAutoAllocate, (true)));
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

        // TX 13: Approve USDC (through Azorius → Safe)
        _executeFromModule(USDC_TOKEN, abi.encodeCall(IERC20.approve, (address(dragonVault), depositAmount)));

        // TX 14: Deposit USDC (through Azorius → Safe)
        _executeFromModule(
            address(dragonVault),
            abi.encodeCall(MultistrategyVault.deposit, (depositAmount, SHUTTER_TREASURY))
        );

        assertEq(dragonVault.balanceOf(SHUTTER_TREASURY), depositAmount);
        assertEq(dragonVault.totalAssets(), depositAmount);
        assertEq(IERC20(USDC_TOKEN).balanceOf(SHUTTER_TREASURY), 0);
    }

    function test_AutoAllocateDeploysToStrategy() public {
        if (!isForked) return;

        uint256 depositAmount = TREASURY_USDC_BALANCE;

        // Approve + Deposit through Azorius → Safe
        _executeFromModule(USDC_TOKEN, abi.encodeCall(IERC20.approve, (address(dragonVault), depositAmount)));
        _executeFromModule(
            address(dragonVault),
            abi.encodeCall(MultistrategyVault.deposit, (depositAmount, SHUTTER_TREASURY))
        );

        // Check funds moved to Strategy (which deployed to Morpho)
        assertEq(IERC20(USDC_TOKEN).balanceOf(address(strategy)), 0);
        assertApproxEqAbs(IERC4626(address(strategy)).totalAssets(), depositAmount, 1000);

        assertEq(dragonVault.totalDebt(), depositAmount);
        assertEq(dragonVault.totalIdle(), 0);
    }

    function test_KeeperTriggeredAllocation() public {
        if (!isForked) return;

        // Disable auto allocate (through Azorius → Safe)
        _executeFromModule(address(dragonVault), abi.encodeCall(MultistrategyVault.setAutoAllocate, (false)));

        uint256 depositAmount = TREASURY_USDC_BALANCE;

        // Approve + Deposit through Azorius → Safe
        _executeFromModule(USDC_TOKEN, abi.encodeCall(IERC20.approve, (address(dragonVault), depositAmount)));
        _executeFromModule(
            address(dragonVault),
            abi.encodeCall(MultistrategyVault.deposit, (depositAmount, SHUTTER_TREASURY))
        );

        assertEq(dragonVault.totalIdle(), depositAmount);
        assertEq(dragonVault.totalDebt(), 0);

        // Keeper triggers allocation (operational role - direct call, no governance vote)
        vm.prank(keeperBot);
        dragonVault.updateDebt(address(strategy), type(uint256).max, 0);

        assertEq(dragonVault.totalDebt(), depositAmount);
        assertEq(dragonVault.totalIdle(), 0);
        assertApproxEqAbs(IERC4626(address(strategy)).totalAssets(), depositAmount, 1000);
    }

    function test_TreasuryCanWithdrawInstantly() public {
        if (!isForked) return;

        uint256 depositAmount = TREASURY_USDC_BALANCE;

        // Approve + Deposit through Azorius → Safe
        _executeFromModule(USDC_TOKEN, abi.encodeCall(IERC20.approve, (address(dragonVault), depositAmount)));
        _executeFromModule(
            address(dragonVault),
            abi.encodeCall(MultistrategyVault.deposit, (depositAmount, SHUTTER_TREASURY))
        );

        // Use maxWithdraw to account for precision in underlying vault
        address[] memory strategies = new address[](1);
        strategies[0] = address(strategy);
        uint256 maxWithdrawable = dragonVault.maxWithdraw(SHUTTER_TREASURY, 0, strategies);

        // Withdraw through Azorius → Safe
        _executeFromModule(
            address(dragonVault),
            abi.encodeCall(
                MultistrategyVault.withdraw,
                (maxWithdrawable, SHUTTER_TREASURY, SHUTTER_TREASURY, 0, strategies)
            )
        );

        // Verify withdrawal succeeds with minimal precision loss (< 0.01%)
        assertApproxEqRel(IERC20(USDC_TOKEN).balanceOf(SHUTTER_TREASURY), depositAmount, 0.0001e18);
        // Allow dust shares due to underlying vault rounding
        assertApproxEqAbs(dragonVault.balanceOf(SHUTTER_TREASURY), 0, 10);
    }

    function test_TreasuryCanWithdrawFromStrategy() public {
        if (!isForked) return;
        // AutoAllocate is ON by default in setUp

        uint256 depositAmount = TREASURY_USDC_BALANCE;

        // Approve + Deposit through Azorius → Safe
        _executeFromModule(USDC_TOKEN, abi.encodeCall(IERC20.approve, (address(dragonVault), depositAmount)));
        _executeFromModule(
            address(dragonVault),
            abi.encodeCall(MultistrategyVault.deposit, (depositAmount, SHUTTER_TREASURY))
        );

        assertEq(dragonVault.totalDebt(), depositAmount);

        // Use maxWithdraw to account for precision in underlying vault
        address[] memory strategies = new address[](1);
        strategies[0] = address(strategy);
        uint256 maxWithdrawable = dragonVault.maxWithdraw(SHUTTER_TREASURY, 0, strategies);

        // Withdraw through Azorius → Safe
        _executeFromModule(
            address(dragonVault),
            abi.encodeCall(
                MultistrategyVault.withdraw,
                (maxWithdrawable, SHUTTER_TREASURY, SHUTTER_TREASURY, 0, strategies)
            )
        );

        // Verify withdrawal succeeds with minimal precision loss (< 0.01%)
        assertApproxEqRel(IERC20(USDC_TOKEN).balanceOf(SHUTTER_TREASURY), depositAmount, 0.0001e18);
        // Allow dust shares due to underlying vault rounding
        assertApproxEqAbs(dragonVault.balanceOf(SHUTTER_TREASURY), 0, 10);
        assertApproxEqAbs(dragonVault.totalDebt(), 0, 1000);
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

        // Approve + Deposit through Azorius → Safe
        _executeFromModule(USDC_TOKEN, abi.encodeCall(IERC20.approve, (address(dragonVault), depositAmount)));
        _executeFromModule(
            address(dragonVault),
            abi.encodeCall(MultistrategyVault.deposit, (depositAmount, SHUTTER_TREASURY))
        );

        uint256 shares = dragonVault.balanceOf(SHUTTER_TREASURY);
        uint256 halfShares = shares / 2;

        // Transfer shares through Azorius → Safe
        _executeFromModule(address(dragonVault), abi.encodeCall(IERC20.transfer, (shuHolder1, halfShares)));

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

    // === Shutter DAO Specific ===
    address constant SHUTTER_TREASURY = 0x36bD3044ab68f600f6d3e081056F34f2a58432c4;
    string constant STRATEGY_NAME = "SHUGrantPool";

    // === From src/constants.sol ===
    address constant USDC_TOKEN = USDC_MAINNET;
    address constant MORPHO_STRATEGY_FACTORY = MORPHO_STRATEGY_FACTORY_MAINNET;
    address constant TOKENIZED_STRATEGY_ADDRESS = YEARN_TOKENIZED_STRATEGY_MAINNET;

    // === Test Values ===
    uint256 constant TREASURY_USDC_BALANCE = 1_200_000e6;
    uint256 constant PROFIT_MAX_UNLOCK_TIME = 7 days;

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
        address keeperBot = makeAddr("KeeperBot");

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

        PaymentSplitter paymentSplitter;
        {
            // PaymentSplitter configuration: 100% to Dragon Funding Pool
            address[] memory payees = new address[](1);
            payees[0] = makeAddr("DragonFundingPool");
            uint256[] memory shares = new uint256[](1);
            shares[0] = 100;

            PaymentSplitter paymentSplitterImpl = new PaymentSplitter();
            bytes memory initData = abi.encodeCall(PaymentSplitter.initialize, (payees, shares));
            ERC1967Proxy proxy = new ERC1967Proxy(address(paymentSplitterImpl), initData);
            paymentSplitter = PaymentSplitter(payable(address(proxy)));
        }

        uint256 gasAfterFactoryDeploy = gasleft();

        // TX 1: Deploy Strategy via Factory
        // Role assignment: management + emergencyAdmin → Treasury (governance-controlled)
        //                  keeper → Dedicated bot (operational, no governance votes required)
        MorphoCompounderStrategyFactory factory = MorphoCompounderStrategyFactory(MORPHO_STRATEGY_FACTORY);
        vm.prank(SHUTTER_TREASURY);
        address strategyAddress = factory.createStrategy(
            STRATEGY_NAME,
            SHUTTER_TREASURY, // management
            keeperBot, // keeper (CRITICAL: enables autonomous harvesting)
            SHUTTER_TREASURY, // emergencyAdmin
            address(paymentSplitter),
            false,
            TOKENIZED_STRATEGY_ADDRESS
        );
        MorphoCompounderStrategy strategy = MorphoCompounderStrategy(strategyAddress);

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

        // TX 3-6: Configure Vault Roles
        vm.startPrank(SHUTTER_TREASURY);

        // Strategic roles → Treasury (governance-controlled)
        dragonVault.addRole(SHUTTER_TREASURY, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);
        dragonVault.addRole(SHUTTER_TREASURY, IMultistrategyVault.Roles.MAX_DEBT_MANAGER);
        dragonVault.addRole(SHUTTER_TREASURY, IMultistrategyVault.Roles.QUEUE_MANAGER);
        dragonVault.addRole(SHUTTER_TREASURY, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);
        dragonVault.addRole(SHUTTER_TREASURY, IMultistrategyVault.Roles.WITHDRAW_LIMIT_MANAGER);
        // DEBT_MANAGER needed for setAutoAllocate
        dragonVault.addRole(SHUTTER_TREASURY, IMultistrategyVault.Roles.DEBT_MANAGER);

        // Also give keeper DEBT_MANAGER for autonomous debt rebalancing
        dragonVault.addRole(keeperBot, IMultistrategyVault.Roles.DEBT_MANAGER);

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

        emit log_named_uint("Strategy Deploy Cost", gasAfterFactoryDeploy - gasAfterStrategyDeploy);
        emit log_named_uint("Vault Deploy Cost", gasAfterStrategyDeploy - gasAfterVaultDeploy);
        emit log_named_uint("Config Cost", gasAfterVaultDeploy - gasAfterConfig);
        emit log_named_uint("Approve/Deposit Cost", gasAfterConfig - gasEnd);

        emit log_named_uint("=== TOTAL GAS USED (Fork) ===", totalGasUsed);
        emit log_named_uint("=== DAO PROPOSAL GAS (Fork) ===", daoProposalGas);

        assertLt(daoProposalGas, EIP_7825_TX_GAS_LIMIT, "Gas limit exceeded");
    }
}
