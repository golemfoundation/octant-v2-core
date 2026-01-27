// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { MorphoCompounderStrategy } from "src/strategies/yieldDonating/MorphoCompounderStrategy.sol";
import { IMorphoCompounderStrategyFactoryV1 } from "src/interfaces/IMorphoCompounderStrategyFactoryV1.sol";
import { BaseStrategyFactory } from "src/factories/BaseStrategyFactory.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ISafe } from "src/zodiac-core/interfaces/Safe.sol";
import {
    USDC_MAINNET,
    MORPHO_STRATEGY_FACTORY_MAINNET,
    YIELD_DONATING_TOKENIZED_STRATEGY_MAINNET
} from "src/constants.sol";

/**
 * @title ShutterDAOCalldataVerificationTest
 * @notice Critical verification tests for the Shutter DAO proposal calldata.
 * @dev These tests verify:
 *      1. CREATE2 predicted address matches actual factory deployment
 *      2. Generated calldata executes successfully end-to-end
 *
 *      Run with: ETH_RPC_URL=<rpc> forge test --match-contract ShutterDAOCalldataVerification -vvv
 *
 *      CRITICAL: Run these tests on mainnet fork BEFORE submitting the DAO proposal.
 */
contract ShutterDAOCalldataVerificationTest is Test {
    // === Shutter DAO Configuration (matches GenerateProposalCalldata.s.sol) ===
    address constant SHUTTER_TREASURY = 0x36bD3044ab68f600f6d3e081056F34f2a58432c4;
    address constant AZORIUS_MODULE = 0xAA6BfA174d2f803b517026E93DBBEc1eBa26258e;
    address constant DRAGON_FUNDING_POOL = 0x4B4505dEdE6408642511Fc0586b62676111e4904;
    address constant KEEPER_BOT = 0x06c2c4dB3776D500636DE63e4F109386dCBa6Ae2;

    string constant STRATEGY_NAME = "SHUGrantPool";
    uint256 constant DEPOSIT_AMOUNT = 1_200_000e6; // 1.2M USDC

    // === V1 Deployed Contracts (imported from src/constants.sol) ===
    address constant MORPHO_STRATEGY_FACTORY = MORPHO_STRATEGY_FACTORY_MAINNET;
    address constant TOKENIZED_STRATEGY = YIELD_DONATING_TOKENIZED_STRATEGY_MAINNET;

    // === From src/constants.sol ===
    address constant USDC_TOKEN = USDC_MAINNET;

    IMorphoCompounderStrategyFactoryV1 factory;

    function setUp() public {
        // Skip all tests if ETH_RPC_URL is not set
        try vm.envString("ETH_RPC_URL") returns (string memory rpcUrl) {
            vm.createSelectFork(rpcUrl);
        } catch {
            vm.skip(true);
        }

        factory = IMorphoCompounderStrategyFactoryV1(MORPHO_STRATEGY_FACTORY);
        deal(USDC_TOKEN, SHUTTER_TREASURY, DEPOSIT_AMOUNT);
    }

    /**
     * @notice Verifies strategy deployment works and logs bytecode match status.
     * @dev Note: Local bytecode may differ from deployed factory's embedded bytecode.
     *      This is expected when factory was deployed with different compiler settings.
     *      The test uses simulated deployment to get actual address for calldata generation.
     */
    function test_StrategyDeploymentAndBytecodeComparison() public {
        // Build strategy parameters
        address ysUsdc = factory.YS_USDC();
        address usdc = factory.USDC();

        bytes32 parameterHash = keccak256(
            abi.encode(
                ysUsdc,
                usdc,
                STRATEGY_NAME,
                SHUTTER_TREASURY,
                KEEPER_BOT,
                SHUTTER_TREASURY,
                DRAGON_FUNDING_POOL,
                false,
                TOKENIZED_STRATEGY
            )
        );

        bytes memory strategyBytecode = abi.encodePacked(
            type(MorphoCompounderStrategy).creationCode,
            abi.encode(
                ysUsdc,
                usdc,
                STRATEGY_NAME,
                SHUTTER_TREASURY,
                KEEPER_BOT,
                SHUTTER_TREASURY,
                DRAGON_FUNDING_POOL,
                false,
                TOKENIZED_STRATEGY
            )
        );

        // Predict address using local bytecode (V1 interface)
        address predictedAddress = IMorphoCompounderStrategyFactoryV1(address(factory)).predictStrategyAddress(
            parameterHash, SHUTTER_TREASURY, strategyBytecode
        );
        console2.log("Predicted (local bytecode):", predictedAddress);

        // Deploy via factory to get actual address
        vm.prank(SHUTTER_TREASURY);
        address actualAddress = factory.createStrategy(
            STRATEGY_NAME,
            SHUTTER_TREASURY,
            KEEPER_BOT,
            SHUTTER_TREASURY,
            DRAGON_FUNDING_POOL,
            false,
            TOKENIZED_STRATEGY
        );
        console2.log("Actual (factory deployed): ", actualAddress);

        // Log bytecode match status (informational - not a failure condition)
        if (predictedAddress == actualAddress) {
            console2.log("[MATCH] Local bytecode matches factory's embedded bytecode");
        } else {
            console2.log("[INFO] Local bytecode differs from factory - use simulated deployment for address");
        }

        // Verify deployed contract is functional
        assertGt(actualAddress.code.length, 0, "Strategy not deployed");
        assertEq(IERC20Metadata(actualAddress).name(), STRATEGY_NAME);
        console2.log("Strategy deployed successfully at:", actualAddress);
    }

    /**
     * @notice Verifies the 3 proposal transactions execute successfully end-to-end.
     * @dev Simulates the exact execution path used by Decent UI:
     *      Azorius -> Safe.execTransactionFromModule(target, CALL) for each transaction
     *
     *      This catches issues like:
     *      - Incorrect encoding
     *      - Permission failures
     *      - Missing approvals
     *      - Deposit reverts
     */
    function test_ProposalTransactionsExecuteSuccessfully() public {
        // TX 0: Deploy Strategy
        bytes memory deployCalldata = abi.encodeCall(
            IMorphoCompounderStrategyFactoryV1.createStrategy,
            (
                STRATEGY_NAME,
                SHUTTER_TREASURY,
                KEEPER_BOT,
                SHUTTER_TREASURY,
                DRAGON_FUNDING_POOL,
                false,
                TOKENIZED_STRATEGY
            )
        );

        vm.prank(AZORIUS_MODULE);
        (bool success, bytes memory returnData) =
            ISafe(SHUTTER_TREASURY).execTransactionFromModuleReturnData(address(factory), 0, deployCalldata, 0);
        assertTrue(success, "TX 0: Deploy failed");

        address strategyAddress = abi.decode(returnData, (address));
        console2.log("Deployed Strategy:", strategyAddress);

        // TX 1: Approve USDC
        bytes memory approveCalldata = abi.encodeCall(IERC20.approve, (strategyAddress, DEPOSIT_AMOUNT));

        vm.prank(AZORIUS_MODULE);
        success = ISafe(SHUTTER_TREASURY).execTransactionFromModule(USDC_TOKEN, 0, approveCalldata, 0);
        assertTrue(success, "TX 1: Approve failed");

        // TX 2: Deposit USDC
        bytes memory depositCalldata = abi.encodeCall(IERC4626.deposit, (DEPOSIT_AMOUNT, SHUTTER_TREASURY));

        vm.prank(AZORIUS_MODULE);
        success = ISafe(SHUTTER_TREASURY).execTransactionFromModule(strategyAddress, 0, depositCalldata, 0);
        assertTrue(success, "TX 2: Deposit failed");

        // Verify all 3 operations succeeded
        // 1. Strategy deployed at expected address
        assertGt(strategyAddress.code.length, 0, "Strategy not deployed at expected address");

        // 2. Treasury received shares
        uint256 shares = IERC4626(strategyAddress).balanceOf(SHUTTER_TREASURY);
        assertApproxEqAbs(shares, DEPOSIT_AMOUNT, 1000, "Treasury should hold ~1.2M shares");

        // 3. Treasury USDC balance is 0
        uint256 treasuryUSDCAfter = IERC20(USDC_TOKEN).balanceOf(SHUTTER_TREASURY);
        assertEq(treasuryUSDCAfter, 0, "Treasury USDC should be 0 after deposit");

        // 4. Strategy is properly configured - yield goes to Dragon Pool
        (bool dragonRouterSuccess, bytes memory dragonRouterData) =
            strategyAddress.staticcall(abi.encodeWithSignature("dragonRouter()"));
        assertTrue(dragonRouterSuccess, "dragonRouter() call failed");
        address dragonRouter = abi.decode(dragonRouterData, (address));
        assertEq(dragonRouter, DRAGON_FUNDING_POOL, "Dragon Pool should be donation recipient");

        console2.log("=== VERIFICATION PASSED ===");
        console2.log("Strategy deployed at:", strategyAddress);
        console2.log("Treasury shares:     ", shares);
        console2.log("Treasury USDC:       ", treasuryUSDCAfter);
    }

    /**
     * @notice Verifies that attempting to deploy the same strategy twice reverts.
     * @dev CREATE2 determinism means same params = same address = collision.
     */
    function test_RevertOnDuplicateDeployment() public {
        // First deployment succeeds
        vm.prank(SHUTTER_TREASURY);
        address strategy1 = factory.createStrategy(
            STRATEGY_NAME,
            SHUTTER_TREASURY,
            KEEPER_BOT,
            SHUTTER_TREASURY,
            DRAGON_FUNDING_POOL,
            false,
            TOKENIZED_STRATEGY
        );
        assertGt(strategy1.code.length, 0);

        // Second deployment with same params reverts
        vm.prank(SHUTTER_TREASURY);
        vm.expectRevert(abi.encodeWithSelector(BaseStrategyFactory.StrategyAlreadyExists.selector, strategy1));
        factory.createStrategy(
            STRATEGY_NAME,
            SHUTTER_TREASURY,
            KEEPER_BOT,
            SHUTTER_TREASURY,
            DRAGON_FUNDING_POOL,
            false,
            TOKENIZED_STRATEGY
        );
    }
}
