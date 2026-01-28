// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { AccessMode } from "src/constants.sol";

import { MorphoCompounderStrategy } from "src/strategies/yieldDonating/MorphoCompounderStrategy.sol";
import { IMorphoCompounderStrategyFactoryV1 } from "src/interfaces/IMorphoCompounderStrategyFactoryV1.sol";
import { BaseStrategyFactory } from "src/factories/BaseStrategyFactory.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Staking } from "staker/interfaces/IERC20Staking.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ISafe } from "src/zodiac-core/interfaces/Safe.sol";
import {
    USDC_MAINNET,
    EIP_7825_TX_GAS_LIMIT,
    MORPHO_STRATEGY_FACTORY_MAINNET,
    YIELD_DONATING_TOKENIZED_STRATEGY_MAINNET
} from "src/constants.sol";

/**
 * @title ShutterDAOIntegrationTest
 * @notice Integration tests for Shutter DAO 0x36 deployment using mainnet fork.
 * @dev Tests use real mainnet state (Treasury Safe, SHU token, Morpho strategies).
 *      Run with: ETH_RPC_URL=<rpc> forge test --match-contract ShutterDAOIntegrationTest
 */
contract ShutterDAOIntegrationTest is Test {
    using SafeERC20 for IERC20;

    // === Shutter DAO Specific Addresses ===
    address constant SHUTTER_TREASURY = 0x36bD3044ab68f600f6d3e081056F34f2a58432c4;
    address constant AZORIUS_MODULE = 0xAA6BfA174d2f803b517026E93DBBEc1eBa26258e;
    address constant SHU_TOKEN = 0xe485E2f1bab389C08721B291f6b59780feC83Fd7;

    // === From src/constants.sol ===
    address constant USDC_TOKEN = USDC_MAINNET;

    // === V1 Deployed Contracts (imported from src/constants.sol) ===
    address constant MORPHO_STRATEGY_FACTORY_V1 = MORPHO_STRATEGY_FACTORY_MAINNET;
    address constant TOKENIZED_STRATEGY_V1 = YIELD_DONATING_TOKENIZED_STRATEGY_MAINNET;

    IMorphoCompounderStrategyFactoryV1 morphoStrategyFactory;
    address tokenizedStrategyImpl;

    string constant STRATEGY_NAME = "SHUGrantPool";

    // === Constants ===
    uint256 constant TREASURY_USDC_BALANCE = 1_200_000e6;
    uint256 constant SHU_HOLDER_BALANCE = 100_000e18;
    uint256 constant REWARD_DURATION = 90 days;

    // === System Contracts ===
    MorphoCompounderStrategy strategy;

    RegenStaker regenStaker;
    RegenEarningPowerCalculator calculator;
    AddressSet allowset;

    // === Roles ===
    address octantGovernance;
    address keeperBot;
    address dragonFundingPool;
    address shuHolder1;
    address shuHolder2;
    address shuHolder3;

    function setUp() public {
        // Skip all tests if ETH_RPC_URL is not set (shows as "skipped" in test output)
        try vm.envString("ETH_RPC_URL") returns (string memory rpcUrl) {
            vm.createSelectFork(rpcUrl);
        } catch {
            vm.skip(true);
        }

        octantGovernance = makeAddr("OctantGovernance");
        keeperBot = makeAddr("KeeperBot");
        dragonFundingPool = makeAddr("DragonFundingPool");
        shuHolder1 = makeAddr("SHUHolder1");
        shuHolder2 = makeAddr("SHUHolder2");
        shuHolder3 = makeAddr("SHUHolder3");

        // Use real mainnet V1 contracts
        morphoStrategyFactory = IMorphoCompounderStrategyFactoryV1(MORPHO_STRATEGY_FACTORY_V1);
        tokenizedStrategyImpl = TOKENIZED_STRATEGY_V1;

        // Setup balances
        deal(USDC_TOKEN, SHUTTER_TREASURY, TREASURY_USDC_BALANCE);
        deal(SHU_TOKEN, shuHolder1, SHU_HOLDER_BALANCE);
        deal(SHU_TOKEN, shuHolder2, SHU_HOLDER_BALANCE);
        deal(SHU_TOKEN, shuHolder3, SHU_HOLDER_BALANCE);

        _deployStrategy();
        _deployRegenStaker();
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

    function _deployStrategy() internal {
        // ══════════════════════════════════════════════════════════════════════
        // DEPLOY + FUND: 3 separate CALL transactions (mirrors Decent UI execution)
        // ══════════════════════════════════════════════════════════════════════

        // TX 0: Deploy Strategy via factory (returns address)
        bytes memory deployCalldata = abi.encodeCall(
            IMorphoCompounderStrategyFactoryV1.createStrategy,
            (
                STRATEGY_NAME,
                SHUTTER_TREASURY,
                keeperBot,
                SHUTTER_TREASURY,
                dragonFundingPool,
                false,
                tokenizedStrategyImpl
            )
        );
        bytes memory returnData = _executeFromModuleReturnData(address(morphoStrategyFactory), deployCalldata);
        address strategyAddress = abi.decode(returnData, (address));

        // TX 1: Approve USDC
        _executeFromModule(USDC_TOKEN, abi.encodeCall(IERC20.approve, (strategyAddress, TREASURY_USDC_BALANCE)));

        // TX 2: Deposit USDC
        _executeFromModule(strategyAddress, abi.encodeCall(IERC4626.deposit, (TREASURY_USDC_BALANCE, SHUTTER_TREASURY)));

        // Store deployed contract
        strategy = MorphoCompounderStrategy(strategyAddress);

        // Verify deployment succeeded
        require(strategyAddress.code.length > 0, "Strategy not deployed");
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

    function test_TreasuryDepositsUSDCIntoStrategy() public view {
        // Deposit already happened in _deployStrategy()
        // Verify the deposit succeeded
        uint256 depositAmount = TREASURY_USDC_BALANCE;

        assertApproxEqAbs(IERC4626(address(strategy)).balanceOf(SHUTTER_TREASURY), depositAmount, 1000);
        assertApproxEqAbs(IERC4626(address(strategy)).totalAssets(), depositAmount, 1000);
        assertEq(IERC20(USDC_TOKEN).balanceOf(SHUTTER_TREASURY), 0);
    }

    function test_TreasuryCanWithdraw() public {
        // Funds already deposited in _deployStrategy()
        uint256 depositAmount = TREASURY_USDC_BALANCE;

        // Use maxWithdraw to account for precision in underlying vault
        uint256 maxWithdrawable = IERC4626(address(strategy)).maxWithdraw(SHUTTER_TREASURY);

        // Withdraw through Azorius → Safe
        _executeFromModule(
            address(strategy),
            abi.encodeCall(IERC4626.withdraw, (maxWithdrawable, SHUTTER_TREASURY, SHUTTER_TREASURY))
        );

        // Verify withdrawal succeeds with minimal precision loss (< 0.01%)
        assertApproxEqRel(IERC20(USDC_TOKEN).balanceOf(SHUTTER_TREASURY), depositAmount, 0.0001e18);
        // Allow dust shares due to underlying vault rounding
        assertApproxEqAbs(IERC4626(address(strategy)).balanceOf(SHUTTER_TREASURY), 0, 10);
    }

    function test_SHUHoldersCanDelegateVotingPower() public {
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
        // Funds already deposited in _deployStrategy()
        uint256 shares = IERC4626(address(strategy)).balanceOf(SHUTTER_TREASURY);
        uint256 halfShares = shares / 2;

        // Transfer shares through Azorius → Safe
        _executeFromModule(address(strategy), abi.encodeCall(IERC20.transfer, (shuHolder1, halfShares)));

        assertApproxEqAbs(IERC4626(address(strategy)).balanceOf(SHUTTER_TREASURY), halfShares, 1000);
        assertApproxEqAbs(IERC4626(address(strategy)).balanceOf(shuHolder1), halfShares, 1000);
    }
}

/**
 * @title ShutterDAOGasProfilingTest
 * @notice Gas profiling test using realistic Azorius → Safe → Target execution path.
 * @dev Measures actual gas costs that will be incurred during DAO proposal execution.
 *      Simplified architecture: Strategy IS the vault (no MultistrategyVault wrapper).
 */
contract ShutterDAOGasProfilingTest is Test {
    using SafeERC20 for IERC20;

    // === Shutter DAO Specific ===
    address constant SHUTTER_TREASURY = 0x36bD3044ab68f600f6d3e081056F34f2a58432c4;
    address constant AZORIUS_MODULE = 0xAA6BfA174d2f803b517026E93DBBEc1eBa26258e;
    string constant STRATEGY_NAME = "SHUGrantPool";

    // === From src/constants.sol ===
    address constant USDC_TOKEN = USDC_MAINNET;

    // === V1 Deployed Contracts (imported from src/constants.sol) ===
    address constant MORPHO_STRATEGY_FACTORY_V1 = MORPHO_STRATEGY_FACTORY_MAINNET;
    address constant TOKENIZED_STRATEGY_V1 = YIELD_DONATING_TOKENIZED_STRATEGY_MAINNET;

    IMorphoCompounderStrategyFactoryV1 morphoStrategyFactory;
    address tokenizedStrategyImpl;

    // === Test Values ===
    uint256 constant TREASURY_USDC_BALANCE = 1_200_000e6;

    function setUp() public {
        // Skip all tests if ETH_RPC_URL is not set (shows as "skipped" in test output)
        try vm.envString("ETH_RPC_URL") returns (string memory rpcUrl) {
            vm.createSelectFork(rpcUrl);
        } catch {
            vm.skip(true);
        }

        // Use real mainnet V1 contracts
        morphoStrategyFactory = IMorphoCompounderStrategyFactoryV1(MORPHO_STRATEGY_FACTORY_V1);
        tokenizedStrategyImpl = TOKENIZED_STRATEGY_V1;

        deal(USDC_TOKEN, SHUTTER_TREASURY, TREASURY_USDC_BALANCE);
    }

    function _executeFromModule(address to, bytes memory data) internal {
        vm.prank(AZORIUS_MODULE);
        bool success = ISafe(SHUTTER_TREASURY).execTransactionFromModule(to, 0, data, 0);
        require(success, "Module execution failed");
    }

    function _executeFromModuleReturnData(address to, bytes memory data) internal returns (bytes memory) {
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

    function test_SimplifiedProposalGasProfile() public {
        address keeperBot = makeAddr("KeeperBot");
        address dragonFundingPool = makeAddr("DragonFundingPool");

        // ══════════════════════════════════════════════════════════════════════
        // GAS PROFILING: 3 separate CALL transactions (mirrors Decent UI execution)
        // ══════════════════════════════════════════════════════════════════════

        uint256 gasStart = gasleft();

        // TX 0: Deploy Strategy via factory (returns address)
        bytes memory deployCalldata = abi.encodeCall(
            IMorphoCompounderStrategyFactoryV1.createStrategy,
            (
                STRATEGY_NAME,
                SHUTTER_TREASURY,
                keeperBot,
                SHUTTER_TREASURY,
                dragonFundingPool,
                false,
                tokenizedStrategyImpl
            )
        );
        bytes memory returnData = _executeFromModuleReturnData(address(morphoStrategyFactory), deployCalldata);
        address strategyAddress = abi.decode(returnData, (address));

        // TX 1: Approve USDC
        _executeFromModule(USDC_TOKEN, abi.encodeCall(IERC20.approve, (strategyAddress, TREASURY_USDC_BALANCE)));

        // TX 2: Deposit USDC
        _executeFromModule(strategyAddress, abi.encodeCall(IERC4626.deposit, (TREASURY_USDC_BALANCE, SHUTTER_TREASURY)));

        uint256 totalGas = gasStart - gasleft();

        emit log_named_uint("=== TOTAL GAS (3 separate transactions) ===", totalGas);
        assertLt(totalGas, EIP_7825_TX_GAS_LIMIT, "Gas exceeds 16.7M per-tx limit");

        assertGt(strategyAddress.code.length, 0, "Strategy not deployed");
        assertApproxEqAbs(IERC4626(strategyAddress).balanceOf(SHUTTER_TREASURY), TREASURY_USDC_BALANCE, 1000);
    }
}
