// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";

import { MorphoCompounderStrategy } from "src/strategies/yieldDonating/MorphoCompounderStrategy.sol";
import { MorphoCompounderStrategyFactory } from "src/factories/MorphoCompounderStrategyFactory.sol";
import { BaseStrategyFactory } from "src/factories/BaseStrategyFactory.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { ISafe } from "src/zodiac-core/interfaces/Safe.sol";
import { MultiSendCallOnly } from "src/utils/libs/Safe/MultiSendCallOnly.sol";
import { USDC_MAINNET, SAFE_MULTISEND_MAINNET } from "src/constants.sol";

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
    string constant STRATEGY_SYMBOL = "yvSHU";
    uint256 constant DEPOSIT_AMOUNT = 1_200_000e6; // 1.2M USDC

    // === V2 Deployed Contracts (with symbol param support, deployed 2025-01-22) ===
    address constant MORPHO_STRATEGY_FACTORY = 0xd8Df22cB3c3876487961aC2500889664632674d7;
    address constant TOKENIZED_STRATEGY = 0xea648c313b497fECfBC629e73cB61Db34181F067;

    // === From src/constants.sol ===
    address constant USDC_TOKEN = USDC_MAINNET;
    address constant MULTISEND = SAFE_MULTISEND_MAINNET;

    MorphoCompounderStrategyFactory factory;

    function setUp() public {
        // Skip all tests if ETH_RPC_URL is not set
        try vm.envString("ETH_RPC_URL") returns (string memory rpcUrl) {
            vm.createSelectFork(rpcUrl);
        } catch {
            vm.skip(true);
        }

        factory = MorphoCompounderStrategyFactory(MORPHO_STRATEGY_FACTORY);
        deal(USDC_TOKEN, SHUTTER_TREASURY, DEPOSIT_AMOUNT);
    }

    /**
     * @notice Verifies that our CREATE2 address prediction matches the factory's actual deployment.
     * @dev This is CRITICAL - if prediction is wrong, the batched proposal will fail.
     *
     *      The prediction uses the same algorithm as GenerateProposalCalldata.s.sol:
     *      1. Build parameter hash from all constructor args
     *      2. Build strategy bytecode (creationCode + encoded args)
     *      3. Call factory.predictStrategyAddress()
     *      4. Deploy via factory and compare addresses
     */
    function test_PredictedAddressMatchesFactoryDeployment() public {
        // Build strategy parameters (exact same as GenerateProposalCalldata.s.sol)
        address ysUsdc = factory.YS_USDC();
        address usdc = factory.USDC();

        bytes32 parameterHash = keccak256(
            abi.encode(
                ysUsdc,
                usdc,
                STRATEGY_NAME,
                STRATEGY_SYMBOL,
                SHUTTER_TREASURY, // management
                KEEPER_BOT, // keeper
                SHUTTER_TREASURY, // emergencyAdmin
                DRAGON_FUNDING_POOL, // donationAddress
                false, // enableBurning
                TOKENIZED_STRATEGY
            )
        );

        bytes memory strategyBytecode = abi.encodePacked(
            type(MorphoCompounderStrategy).creationCode,
            abi.encode(
                ysUsdc,
                usdc,
                STRATEGY_NAME,
                STRATEGY_SYMBOL,
                SHUTTER_TREASURY,
                KEEPER_BOT,
                SHUTTER_TREASURY,
                DRAGON_FUNDING_POOL,
                false,
                TOKENIZED_STRATEGY
            )
        );

        // Predict address using factory's algorithm
        address predictedAddress = factory.predictStrategyAddress(parameterHash, SHUTTER_TREASURY, strategyBytecode);
        console2.log("Predicted Strategy Address:", predictedAddress);

        // Deploy via factory (simulating Treasury execution)
        vm.prank(SHUTTER_TREASURY);
        address actualAddress = factory.createStrategy(
            STRATEGY_NAME,
            STRATEGY_SYMBOL,
            SHUTTER_TREASURY,
            KEEPER_BOT,
            SHUTTER_TREASURY,
            DRAGON_FUNDING_POOL,
            false,
            TOKENIZED_STRATEGY
        );
        console2.log("Actual Deployed Address:   ", actualAddress);

        // CRITICAL ASSERTION
        assertEq(predictedAddress, actualAddress, "CREATE2 prediction mismatch - proposal will fail!");

        // Verify deployed contract is functional
        assertGt(actualAddress.code.length, 0, "Strategy not deployed");
        assertEq(IERC20Metadata(actualAddress).name(), STRATEGY_NAME);
        assertEq(IERC20Metadata(actualAddress).symbol(), STRATEGY_SYMBOL);
    }

    /**
     * @notice Verifies the complete batched MultiSend calldata executes successfully.
     * @dev Simulates the exact execution path:
     *      Azorius -> Safe.execTransactionFromModule(MultiSend, DELEGATECALL) -> 3 operations
     *
     *      This catches issues like:
     *      - Incorrect encoding
     *      - Permission failures
     *      - Missing approvals
     *      - Deposit reverts
     */
    function test_GeneratedCalldataExecutesSuccessfully() public {
        // Build the exact calldata that would be submitted to the DAO
        address ysUsdc = factory.YS_USDC();
        address usdc = factory.USDC();

        // Predict strategy address (needed for approve/deposit)
        bytes32 parameterHash = keccak256(
            abi.encode(
                ysUsdc,
                usdc,
                STRATEGY_NAME,
                STRATEGY_SYMBOL,
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
                STRATEGY_SYMBOL,
                SHUTTER_TREASURY,
                KEEPER_BOT,
                SHUTTER_TREASURY,
                DRAGON_FUNDING_POOL,
                false,
                TOKENIZED_STRATEGY
            )
        );

        address predictedStrategy = factory.predictStrategyAddress(parameterHash, SHUTTER_TREASURY, strategyBytecode);

        // Build batched MultiSend transactions (same format as GenerateProposalCalldata.s.sol)
        bytes memory tx0 = _encodeMultiSendTx(
            MORPHO_STRATEGY_FACTORY,
            abi.encodeCall(
                MorphoCompounderStrategyFactory.createStrategy,
                (
                    STRATEGY_NAME,
                    STRATEGY_SYMBOL,
                    SHUTTER_TREASURY,
                    KEEPER_BOT,
                    SHUTTER_TREASURY,
                    DRAGON_FUNDING_POOL,
                    false,
                    TOKENIZED_STRATEGY
                )
            )
        );

        bytes memory tx1 = _encodeMultiSendTx(USDC_TOKEN, abi.encodeCall(IERC20.approve, (predictedStrategy, DEPOSIT_AMOUNT)));

        bytes memory tx2 =
            _encodeMultiSendTx(predictedStrategy, abi.encodeCall(IERC4626.deposit, (DEPOSIT_AMOUNT, SHUTTER_TREASURY)));

        bytes memory packedTxs = abi.encodePacked(tx0, tx1, tx2);
        bytes memory multiSendCalldata = abi.encodeCall(MultiSendCallOnly.multiSend, (packedTxs));

        // Record state before
        uint256 treasuryUSDCBefore = IERC20(USDC_TOKEN).balanceOf(SHUTTER_TREASURY);
        assertEq(treasuryUSDCBefore, DEPOSIT_AMOUNT, "Treasury should have USDC before execution");

        // Execute via Azorius -> Safe path (operation=1 for DELEGATECALL)
        vm.prank(AZORIUS_MODULE);
        bool success = ISafe(SHUTTER_TREASURY).execTransactionFromModule(
            MULTISEND,
            0, // value
            multiSendCalldata,
            1 // operation = DELEGATECALL
        );
        assertTrue(success, "MultiSend execution failed");

        // Verify all 3 operations succeeded
        // 1. Strategy deployed at predicted address
        assertGt(predictedStrategy.code.length, 0, "Strategy not deployed at predicted address");

        // 2. Treasury received shares
        uint256 shares = IERC4626(predictedStrategy).balanceOf(SHUTTER_TREASURY);
        assertApproxEqAbs(shares, DEPOSIT_AMOUNT, 1000, "Treasury should hold ~1.2M shares");

        // 3. Treasury USDC balance is 0
        uint256 treasuryUSDCAfter = IERC20(USDC_TOKEN).balanceOf(SHUTTER_TREASURY);
        assertEq(treasuryUSDCAfter, 0, "Treasury USDC should be 0 after deposit");

        // 4. Strategy is properly configured - yield goes to Dragon Pool
        (bool dragonRouterSuccess, bytes memory dragonRouterData) =
            predictedStrategy.staticcall(abi.encodeWithSignature("dragonRouter()"));
        assertTrue(dragonRouterSuccess, "dragonRouter() call failed");
        address dragonRouter = abi.decode(dragonRouterData, (address));
        assertEq(dragonRouter, DRAGON_FUNDING_POOL, "Dragon Pool should be donation recipient");

        console2.log("=== VERIFICATION PASSED ===");
        console2.log("Strategy deployed at:", predictedStrategy);
        console2.log("Treasury shares:     ", shares);
        console2.log("Treasury USDC:       ", treasuryUSDCAfter);
    }

    /**
     * @notice Verifies the 3-transaction fallback works if DELEGATECALL isn't supported.
     * @dev Uses sequential CALL operations instead of batched DELEGATECALL.
     */
    function test_FallbackSeparateTransactionsWork() public {
        // TX 0: Deploy Strategy
        bytes memory deployCalldata = abi.encodeCall(
            MorphoCompounderStrategyFactory.createStrategy,
            (
                STRATEGY_NAME,
                STRATEGY_SYMBOL,
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

        // Verify final state
        uint256 shares = IERC4626(strategyAddress).balanceOf(SHUTTER_TREASURY);
        assertApproxEqAbs(shares, DEPOSIT_AMOUNT, 1000, "Treasury should hold ~1.2M shares");
        assertEq(IERC20(USDC_TOKEN).balanceOf(SHUTTER_TREASURY), 0, "Treasury USDC should be 0");

        console2.log("=== FALLBACK VERIFICATION PASSED ===");
        console2.log("3 separate transactions executed successfully");
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
            STRATEGY_SYMBOL,
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
            STRATEGY_SYMBOL,
            SHUTTER_TREASURY,
            KEEPER_BOT,
            SHUTTER_TREASURY,
            DRAGON_FUNDING_POOL,
            false,
            TOKENIZED_STRATEGY
        );
    }

    /// @notice Encode a single transaction for MultiSend
    function _encodeMultiSendTx(address to, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), to, uint256(0), data.length, data);
    }
}
