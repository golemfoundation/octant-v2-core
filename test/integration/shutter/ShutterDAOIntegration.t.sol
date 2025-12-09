// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { PaymentSplitter } from "src/core/PaymentSplitter.sol";

import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { AccessMode } from "src/constants.sol";

import { MorphoCompounderStrategy } from "src/strategies/yieldDonating/MorphoCompounderStrategy.sol";
import { MorphoCompounderStrategyFactory } from "src/factories/MorphoCompounderStrategyFactory.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Staking } from "staker/interfaces/IERC20Staking.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ISafe } from "src/zodiac-core/interfaces/Safe.sol";
import { PaymentSplitterFactory } from "src/factories/PaymentSplitterFactory.sol";
import { MultiSendCallOnly } from "src/utils/libs/Safe/MultiSendCallOnly.sol";
import { USDC_MAINNET, MORPHO_STRATEGY_FACTORY_MAINNET, YEARN_TOKENIZED_STRATEGY_MAINNET, EIP_7825_TX_GAS_LIMIT } from "src/constants.sol";

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
    address constant MORPHO_STRATEGY_FACTORY = MORPHO_STRATEGY_FACTORY_MAINNET;
    address constant TOKENIZED_STRATEGY_ADDRESS = YEARN_TOKENIZED_STRATEGY_MAINNET;

    string constant STRATEGY_NAME = "SHUGrantPool";

    // === Constants ===
    uint256 constant TREASURY_USDC_BALANCE = 1_200_000e6;
    uint256 constant SHU_HOLDER_BALANCE = 100_000e18;
    uint256 constant REWARD_DURATION = 90 days;

    // === System Contracts ===
    PaymentSplitterFactory paymentSplitterFactory;
    MultiSendCallOnly multiSend;
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
        _deployStrategy();
        _deployRegenStaker();
    }

    function _deployInfrastructure() internal {
        vm.prank(octantGovernance);
        paymentSplitterFactory = new PaymentSplitterFactory();

        multiSend = new MultiSendCallOnly();
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

    /// @notice Encode a single transaction for MultiSend
    /// @dev Format: operation (1 byte) + to (20 bytes) + value (32 bytes) + dataLength (32 bytes) + data
    function _encodeMultiSendTx(address to, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), to, uint256(0), data.length, data);
    }

    /// @notice Execute batched transactions via MultiSend through Azorius → Safe
    function _executeBatchFromModule(bytes memory packedTransactions) internal {
        bytes memory multiSendData = abi.encodeCall(MultiSendCallOnly.multiSend, (packedTransactions));
        _executeFromModule(address(multiSend), multiSendData);
    }

    function _deployStrategy() internal {
        // ══════════════════════════════════════════════════════════════════════
        // TX 0: Deploy PaymentSplitter via Factory
        // ══════════════════════════════════════════════════════════════════════
        address[] memory payees = new address[](1);
        payees[0] = makeAddr("DragonFundingPool");
        string[] memory payeeNames = new string[](1);
        payeeNames[0] = "DragonFundingPool";
        uint256[] memory shares = new uint256[](1);
        shares[0] = 100;

        bytes memory returnData = _executeFromModuleReturnData(
            address(paymentSplitterFactory),
            abi.encodeCall(PaymentSplitterFactory.createPaymentSplitter, (payees, payeeNames, shares))
        );
        paymentSplitter = PaymentSplitter(payable(abi.decode(returnData, (address))));

        // ══════════════════════════════════════════════════════════════════════
        // TX 1: Deploy MorphoCompounderStrategy via Factory
        // Strategy IS the vault (ERC-4626 compliant via TokenizedStrategy)
        // ══════════════════════════════════════════════════════════════════════
        returnData = _executeFromModuleReturnData(
            MORPHO_STRATEGY_FACTORY,
            abi.encodeCall(
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
            )
        );
        strategy = MorphoCompounderStrategy(abi.decode(returnData, (address)));
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

    function test_TreasuryDepositsUSDCIntoStrategy() public {
        if (!isForked) return;

        uint256 depositAmount = TREASURY_USDC_BALANCE;

        // TX 2: Approve USDC to Strategy (through Azorius → Safe)
        _executeFromModule(USDC_TOKEN, abi.encodeCall(IERC20.approve, (address(strategy), depositAmount)));

        // TX 3: Deposit USDC into Strategy (through Azorius → Safe)
        _executeFromModule(address(strategy), abi.encodeCall(IERC4626.deposit, (depositAmount, SHUTTER_TREASURY)));

        assertApproxEqAbs(IERC4626(address(strategy)).balanceOf(SHUTTER_TREASURY), depositAmount, 1000);
        assertApproxEqAbs(IERC4626(address(strategy)).totalAssets(), depositAmount, 1000);
        assertEq(IERC20(USDC_TOKEN).balanceOf(SHUTTER_TREASURY), 0);
    }

    function test_TreasuryCanWithdraw() public {
        if (!isForked) return;

        uint256 depositAmount = TREASURY_USDC_BALANCE;

        // Approve + Deposit through Azorius → Safe
        _executeFromModule(USDC_TOKEN, abi.encodeCall(IERC20.approve, (address(strategy), depositAmount)));
        _executeFromModule(address(strategy), abi.encodeCall(IERC4626.deposit, (depositAmount, SHUTTER_TREASURY)));

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
        _executeFromModule(USDC_TOKEN, abi.encodeCall(IERC20.approve, (address(strategy), depositAmount)));
        _executeFromModule(address(strategy), abi.encodeCall(IERC4626.deposit, (depositAmount, SHUTTER_TREASURY)));

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
    address constant MORPHO_STRATEGY_FACTORY = MORPHO_STRATEGY_FACTORY_MAINNET;
    address constant TOKENIZED_STRATEGY_ADDRESS = YEARN_TOKENIZED_STRATEGY_MAINNET;

    // === Test Values ===
    uint256 constant TREASURY_USDC_BALANCE = 1_200_000e6;

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

    function _encodeMultiSendTx(address to, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), to, uint256(0), data.length, data);
    }

    function _executeBatchFromModule(MultiSendCallOnly multiSendContract, bytes memory packedTransactions) internal {
        bytes memory multiSendData = abi.encodeCall(MultiSendCallOnly.multiSend, (packedTransactions));
        _executeFromModule(address(multiSendContract), multiSendData);
    }

    function test_SimplifiedProposalGasProfile() public {
        if (!isForked) return;

        address keeperBot = makeAddr("KeeperBot");

        // === PRE-DEPLOYED BY OCTANT (not part of DAO proposal) ===
        PaymentSplitterFactory splitterFactory = new PaymentSplitterFactory();
        MultiSendCallOnly multiSendContract = new MultiSendCallOnly();

        uint256 gasStart = gasleft();

        // ══════════════════════════════════════════════════════════════════════
        // DAO PROPOSAL: 3 module calls (2 factory deploys + 1 MultiSend batch)
        // No MultistrategyVault needed - Strategy IS the ERC-4626 vault
        // ══════════════════════════════════════════════════════════════════════

        // TX 0: Deploy PaymentSplitter via Factory
        address paymentSplitterAddr;
        {
            address[] memory payees = new address[](1);
            payees[0] = makeAddr("DragonFundingPool");
            string[] memory payeeNames = new string[](1);
            payeeNames[0] = "DragonFundingPool";
            uint256[] memory shares = new uint256[](1);
            shares[0] = 100;

            paymentSplitterAddr = abi.decode(
                _executeFromModuleReturnData(
                    address(splitterFactory),
                    abi.encodeCall(PaymentSplitterFactory.createPaymentSplitter, (payees, payeeNames, shares))
                ),
                (address)
            );
        }

        // TX 1: Deploy Strategy via Factory (Strategy IS the vault - ERC-4626)
        address strategyAddress = abi.decode(
            _executeFromModuleReturnData(
                MORPHO_STRATEGY_FACTORY,
                abi.encodeCall(
                    MorphoCompounderStrategyFactory.createStrategy,
                    (
                        STRATEGY_NAME,
                        SHUTTER_TREASURY,
                        keeperBot,
                        SHUTTER_TREASURY,
                        paymentSplitterAddr,
                        false,
                        TOKENIZED_STRATEGY_ADDRESS
                    )
                )
            ),
            (address)
        );

        // TX 2: BATCHED via MultiSend - Approve + Deposit only (no vault config needed!)
        bytes memory batchedTxs = abi.encodePacked(
            _encodeMultiSendTx(USDC_TOKEN, abi.encodeCall(IERC20.approve, (strategyAddress, TREASURY_USDC_BALANCE))),
            _encodeMultiSendTx(
                strategyAddress,
                abi.encodeCall(IERC4626.deposit, (TREASURY_USDC_BALANCE, SHUTTER_TREASURY))
            )
        );
        _executeBatchFromModule(multiSendContract, batchedTxs);

        uint256 daoProposalGas = gasStart - gasleft();

        emit log_named_uint("=== DAO PROPOSAL GAS (3 module calls) ===", daoProposalGas);
        assertLt(daoProposalGas, EIP_7825_TX_GAS_LIMIT, "Gas exceeds 16.7M per-tx limit");
    }
}
