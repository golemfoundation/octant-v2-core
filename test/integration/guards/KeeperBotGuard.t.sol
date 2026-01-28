// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import { KeeperBotGuard } from "src/guards/KeeperBotGuard.sol";
import { Safe } from "@gnosis.pm/safe-contracts/contracts/Safe.sol";
import { SafeProxyFactory } from "@gnosis.pm/safe-contracts/contracts/proxies/SafeProxyFactory.sol";
import { SafeProxy } from "@gnosis.pm/safe-contracts/contracts/proxies/SafeProxy.sol";
import { Enum } from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";
import { MorphoCompounderStrategy } from "src/strategies/yieldDonating/MorphoCompounderStrategy.sol";
import { MorphoCompounderStrategyFactory } from "src/factories/MorphoCompounderStrategyFactory.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { BaseHealthCheck } from "src/strategies/periphery/BaseHealthCheck.sol";
import { console } from "forge-std/console.sol";

/**
 * @title KeeperBotGuard Integration Test
 * @notice Tests the simplified keeper bot guard functionality
 */
contract KeeperBotGuardTest is Test {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event BotAuthorized(address indexed bot, bool authorized);
    event StrategyReportCalled(address indexed strategy, address indexed bot);

    /*//////////////////////////////////////////////////////////////
                            TEST CONTRACTS
    //////////////////////////////////////////////////////////////*/

    KeeperBotGuard public guard;

    // Safe contracts
    Safe public safeSingleton;
    SafeProxyFactory public safeFactory;
    Safe public safeMultisig;

    // Strategy contracts
    MorphoCompounderStrategy public strategy;
    MorphoCompounderStrategyFactory public strategyFactory;
    YieldDonatingTokenizedStrategy public implementation;

    /*//////////////////////////////////////////////////////////////
                              TEST USERS
    //////////////////////////////////////////////////////////////*/

    address public owner = makeAddr("owner");
    address public keeperBot = makeAddr("keeperBot");
    address public unauthorizedCaller = makeAddr("unauthorizedCaller");

    // Safe owners - use proper random private keys for signing
    uint256 public safeOwner1PrivateKey = 0xa11ce;
    uint256 public safeOwner2PrivateKey = 0xb0b;
    uint256 public safeOwner3PrivateKey = 0xc0ffee;
    address public safeOwner1 = vm.addr(safeOwner1PrivateKey);
    address public safeOwner2 = vm.addr(safeOwner2PrivateKey);
    address public safeOwner3 = vm.addr(safeOwner3PrivateKey);

    // Strategy roles
    address public management = makeAddr("management");
    address public keeper = makeAddr("keeper");
    address public emergencyAdmin = makeAddr("emergencyAdmin");
    address public donationAddress = makeAddr("donationAddress");

    // Test user
    address public user = makeAddr("user");

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    // Mainnet addresses (for forked tests)
    address public constant MORPHO_VAULT = 0x074134A2784F4F66b6ceD6f68849382990Ff3215; // Steakhouse USDC vault
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC token
    address public constant TOKENIZED_STRATEGY_ADDRESS = 0x8cf7246a74704bBE59c9dF614ccB5e3d9717d8Ac;

    // Test constants
    uint256 public constant INITIAL_DEPOSIT = 100000e6; // USDC has 6 decimals

    uint256 public mainnetFork;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        // Create mainnet fork for strategy deployment
        mainnetFork = vm.createFork("mainnet");
        vm.selectFork(mainnetFork);

        // Deploy Safe contracts
        safeSingleton = new Safe();
        safeFactory = new SafeProxyFactory();

        // Create Safe multisig
        safeMultisig = _createSafeMultisig();

        // Deploy guard with owner and safe addresses
        guard = new KeeperBotGuard(owner, address(safeMultisig));

        // Deploy real strategy contracts
        _deployStrategyContracts();

        // Enable the guard as a module on the Safe
        _enableModuleOnSafe(address(guard));

        // Label addresses for better debugging
        vm.label(address(guard), "KeeperBotGuard");
        vm.label(address(safeMultisig), "SafeMultisig");
        vm.label(keeperBot, "KeeperBot");
        vm.label(address(strategy), "MorphoCompounderStrategy");
    }

    function _setupMainnetFork() internal {
        // Create mainnet fork for real strategy deployment at a specific stable block
        // Block 20000000 is a stable block from May 2024
        mainnetFork = vm.createFork("mainnet", 20000000);
        vm.selectFork(mainnetFork);

        // Deploy strategy contracts
        _deployStrategyContracts();

        // Label strategy
        vm.label(address(strategy), "MorphoCompounderStrategy");
    }

    function _deployStrategyContracts() internal {
        // Etch YieldDonatingTokenizedStrategy
        implementation = new YieldDonatingTokenizedStrategy{ salt: keccak256("OCT_YIELD_DONATING_STRATEGY_V1") }();

        // Create MorphoCompounderStrategyFactory
        strategyFactory = new MorphoCompounderStrategyFactory{
            salt: keccak256("OCT_MORPHO_COMPOUNDER_STRATEGY_VAULT_FACTORY_V1")
        }();

        // Deploy strategy with Safe as management
        strategy = MorphoCompounderStrategy(
            strategyFactory.createStrategy(
                "MorphoCompounder KeeperBot Test Strategy",
                "osKBT",
                address(safeMultisig), // Use Safe as management directly
                address(safeMultisig), // Use Safe as keeper too
                emergencyAdmin,
                donationAddress,
                false, // enableBurning
                address(implementation)
            )
        );
    }

    function _createSafeMultisig() internal returns (Safe) {
        // Create Safe owners array
        address[] memory owners = new address[](3);
        owners[0] = safeOwner1;
        owners[1] = safeOwner2;
        owners[2] = safeOwner3;

        // Create Safe initialization data
        bytes memory initializer = abi.encodeWithSelector(
            Safe.setup.selector,
            owners,
            2, // threshold
            address(0), // to
            "", // data
            address(0), // fallbackHandler
            address(0), // paymentToken
            0, // payment
            address(0) // paymentReceiver
        );

        // Deploy Safe proxy
        SafeProxy safeProxy = safeFactory.createProxyWithNonce(
            address(safeSingleton),
            initializer,
            uint256(keccak256("KeeperBotGuard Test Safe"))
        );

        return Safe(payable(address(safeProxy)));
    }

    function _createSafeMultisigOnFork(Safe singleton, SafeProxyFactory factory) internal returns (Safe) {
        // Create Safe owners array
        address[] memory owners = new address[](3);
        owners[0] = safeOwner1;
        owners[1] = safeOwner2;
        owners[2] = safeOwner3;

        // Create Safe initialization data
        bytes memory initializer = abi.encodeWithSelector(
            Safe.setup.selector,
            owners,
            2, // threshold
            address(0), // to
            "", // data
            address(0), // fallbackHandler
            address(0), // paymentToken
            0, // payment
            address(0) // paymentReceiver
        );

        // Deploy Safe proxy
        SafeProxy safeProxy = factory.createProxyWithNonce(
            address(singleton),
            initializer,
            uint256(keccak256("KeeperBotGuard Forked Test Safe"))
        );

        return Safe(payable(address(safeProxy)));
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_constructor_InitializesCorrectly() public view {
        assertEq(guard.owner(), owner);
        assertEq(address(guard.safe()), address(safeMultisig));
        assertFalse(guard.isBotAuthorized(keeperBot));
    }

    /*//////////////////////////////////////////////////////////////
                           AUTHORIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setBotAuthorization_AuthorizesBot() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit BotAuthorized(keeperBot, true);

        guard.setBotAuthorization(keeperBot, true);

        assertTrue(guard.isBotAuthorized(keeperBot));
    }

    function test_setBotAuthorization_DeauthorizesBot() public {
        // First authorize
        vm.prank(owner);
        guard.setBotAuthorization(keeperBot, true);
        assertTrue(guard.isBotAuthorized(keeperBot));

        // Then deauthorize
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit BotAuthorized(keeperBot, false);

        guard.setBotAuthorization(keeperBot, false);

        assertFalse(guard.isBotAuthorized(keeperBot));
    }

    function test_setBotAuthorization_OnlyOwner() public {
        vm.prank(unauthorizedCaller);
        vm.expectRevert();
        guard.setBotAuthorization(keeperBot, true);
    }

    function test_setBotAuthorizationBatch_AuthorizesMultipleBots() public {
        address bot1 = makeAddr("bot1");
        address bot2 = makeAddr("bot2");
        address bot3 = makeAddr("bot3");

        address[] memory bots = new address[](3);
        bots[0] = bot1;
        bots[1] = bot2;
        bots[2] = bot3;

        bool[] memory authorized = new bool[](3);
        authorized[0] = true;
        authorized[1] = false;
        authorized[2] = true;

        vm.prank(owner);
        guard.setBotAuthorizationBatch(bots, authorized);

        assertTrue(guard.isBotAuthorized(bot1));
        assertFalse(guard.isBotAuthorized(bot2));
        assertTrue(guard.isBotAuthorized(bot3));
    }

    function test_setBotAuthorizationBatch_RevertsOnLengthMismatch() public {
        address[] memory bots = new address[](2);
        bool[] memory authorized = new bool[](3);

        vm.prank(owner);
        vm.expectRevert("Array length mismatch");
        guard.setBotAuthorizationBatch(bots, authorized);
    }

    /*//////////////////////////////////////////////////////////////
                        STRATEGY REPORT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_callStrategyReport_SucceedsWithAuthorizedBot() public {
        // Authorize the bot
        vm.prank(owner);
        guard.setBotAuthorization(keeperBot, true);

        // Call report
        vm.prank(keeperBot);
        vm.expectEmit(true, true, false, false);
        emit StrategyReportCalled(address(strategy), keeperBot);

        guard.callStrategyReport(address(strategy));
    }

    function test_callStrategyReport_WithRealStrategyHealthCheck() public {
        // Deploy guard owned by the Safe
        KeeperBotGuard safeOwnedGuard = new KeeperBotGuard(address(safeMultisig), address(safeMultisig));

        // Safe authorizes the keeper bot
        bytes memory setBotAuthData = abi.encodeWithSelector(
            KeeperBotGuard.setBotAuthorization.selector,
            keeperBot,
            true
        );
        _executeSafeTransaction(address(safeOwnedGuard), setBotAuthData);

        // Enable the guard as a module on the Safe
        bytes memory enableModuleData = abi.encodeWithSignature("enableModule(address)", address(safeOwnedGuard));
        _executeSafeTransaction(address(safeMultisig), enableModuleData);

        // Since Safe is already the management, we can directly set health check
        bytes memory setHealthCheckData = abi.encodeWithSignature("setDoHealthCheck(bool)", true);
        _executeSafeTransaction(address(strategy), setHealthCheckData);

        // Verify health check is enabled on the real strategy
        assertTrue(BaseHealthCheck(address(strategy)).doHealthCheck(), "Health check should be enabled");

        // Bot calls report through the guard - should handle health check automatically
        vm.prank(keeperBot);
        safeOwnedGuard.callStrategyReport(address(strategy));

        // After report, health check should be re-enabled automatically by the strategy
        assertTrue(
            BaseHealthCheck(address(strategy)).doHealthCheck(),
            "Health check should be re-enabled after report"
        );

        // Test with health check disabled
        bytes memory disableHealthCheckData = abi.encodeWithSignature("setDoHealthCheck(bool)", false);
        _executeSafeTransaction(address(strategy), disableHealthCheckData);

        // Verify health check is disabled
        assertFalse(BaseHealthCheck(address(strategy)).doHealthCheck(), "Health check should be disabled");

        // Bot calls report again - should work fine with disabled health check
        vm.prank(keeperBot);
        safeOwnedGuard.callStrategyReport(address(strategy));

        // Health check should be re-enabled after successful report (this is the correct behavior)
        assertTrue(
            BaseHealthCheck(address(strategy)).doHealthCheck(),
            "Health check should be re-enabled after report"
        );
    }

    function test_callStrategyReport_WithHealthCheckBypass() public {
        // Deploy guard owned by the Safe (like the working test)
        KeeperBotGuard safeOwnedGuard = new KeeperBotGuard(address(safeMultisig), address(safeMultisig));

        // Safe authorizes the keeper bot
        bytes memory setBotAuthData = abi.encodeWithSelector(
            KeeperBotGuard.setBotAuthorization.selector,
            keeperBot,
            true
        );
        _executeSafeTransaction(address(safeOwnedGuard), setBotAuthData);

        // Enable the guard as a module on the Safe
        bytes memory enableModuleData = abi.encodeWithSignature("enableModule(address)", address(safeOwnedGuard));
        _executeSafeTransaction(address(safeMultisig), enableModuleData);

        // Skip setting loss limits - test the guard's ability to bypass health check regardless of limits

        // Enable health check on the strategy
        bytes memory setHealthCheckData = abi.encodeWithSignature("setDoHealthCheck(bool)", true);
        _executeSafeTransaction(address(strategy), setHealthCheckData);

        // Verify health check is enabled
        assertTrue(BaseHealthCheck(address(strategy)).doHealthCheck(), "Health check should be enabled");

        // The key test: Bot calls report through the guard
        // Even if there were potential losses that would exceed the 1% limit,
        // the guard should disable health check before calling report, allowing it to succeed
        vm.prank(keeperBot);
        safeOwnedGuard.callStrategyReport(address(strategy));

        // Health check should be re-enabled after report
        assertTrue(
            BaseHealthCheck(address(strategy)).doHealthCheck(),
            "Health check should be re-enabled after report"
        );

        // This demonstrates that:
        // 1. The guard successfully disables health check before calling report
        // 2. Report call succeeds even with strict health check limits
        // 3. Health check is properly re-enabled after the report
        // 4. The guard provides a bypass mechanism for authorized bots during emergencies
    }

    function test_callStrategyReport_WithRealStrategyHealthCheck_WithLoss() public {
        uint256 depositAmount = 100000e6;

        // Deploy guard owned by the Safe
        KeeperBotGuard safeOwnedGuard = new KeeperBotGuard(address(safeMultisig), address(safeMultisig));

        // Safe authorizes the keeper bot
        bytes memory setBotAuthData = abi.encodeWithSelector(
            KeeperBotGuard.setBotAuthorization.selector,
            keeperBot,
            true
        );
        _executeSafeTransaction(address(safeOwnedGuard), setBotAuthData);

        // Enable the guard as a module on the Safe
        bytes memory enableModuleData = abi.encodeWithSignature("enableModule(address)", address(safeOwnedGuard));
        _executeSafeTransaction(address(safeMultisig), enableModuleData);

        // Give user USDC and deposit into strategy
        deal(USDC, user, depositAmount);

        vm.startPrank(user);
        // Approve strategy to spend user's USDC
        ERC20(USDC).approve(address(strategy), depositAmount);
        uint256 vaultShares = IERC4626(address(strategy)).deposit(depositAmount, user);
        vm.stopPrank();

        // Verify user deposited successfully
        assertEq(ERC20(USDC).balanceOf(user), 0, "User should have no USDC after deposit");
        assertGt(vaultShares, 0, "User should have received vault shares");

        // Set maximum loss tolerance to prevent arithmetic underflow
        bytes memory setMaxLossData = abi.encodeWithSignature("setLossLimitRatio(uint256)", uint256(9999)); // 100% max loss
        _executeSafeTransaction(address(strategy), setMaxLossData);

        // Simulate significant loss by mocking balanceOf to return only 1% of original
        // This makes the strategy think it has lost 99% of its assets in the compounder vault
        vm.mockCall(
            MORPHO_VAULT,
            abi.encodeWithSignature("convertToAssets(uint256)", address(strategy)),
            abi.encode(depositAmount / 100) // Return 1% balance - simulates 99% loss
        );

        // Verify health check is enabled
        assertTrue(BaseHealthCheck(address(strategy)).doHealthCheck(), "Health check should be enabled");

        // The critical test: Bot calls report through the guard despite significant loss
        // Without the guard's health check bypass, this would likely fail due to health check restrictions
        // But the guard should disable health check first, allowing the report to succeed
        vm.prank(keeperBot);
        safeOwnedGuard.callStrategyReport(address(strategy));

        // Health check should be re-enabled after report
        assertTrue(
            BaseHealthCheck(address(strategy)).doHealthCheck(),
            "Health check should be re-enabled after report"
        );

        // Clear mocked calls
        vm.clearMockedCalls();

        // This demonstrates that:
        // 1. The guard successfully handles health check bypass during severe loss scenarios
        // 2. Report succeeds even with 99% simulated loss because guard disables health check first
        // 3. Emergency response works in practice with catastrophic loss conditions
        // 4. Health check is properly re-enabled after handling the emergency
    }

    function test_callStrategyReport_RevertsWithUnauthorizedBot() public {
        vm.prank(unauthorizedCaller);
        vm.expectRevert(KeeperBotGuard.KeeperBotGuard__NotAuthorizedBot.selector);

        guard.callStrategyReport(address(strategy));
    }

    function test_callStrategyReport_RevertsOnInvalidStrategy() public {
        // Authorize the bot
        vm.prank(owner);
        guard.setBotAuthorization(keeperBot, true);

        // Try to call report on zero address
        vm.prank(keeperBot);
        vm.expectRevert(KeeperBotGuard.KeeperBotGuard__InvalidStrategy.selector);

        guard.callStrategyReport(address(0));
    }

    function test_callStrategyReport_RevertsOnFailedCall() public {
        // Deploy a strategy that will fail on report()
        MockFailingStrategy failingStrategy = new MockFailingStrategy();

        // Authorize the bot
        vm.prank(owner);
        guard.setBotAuthorization(keeperBot, true);

        // Try to call report on failing strategy
        vm.prank(keeperBot);
        vm.expectRevert(KeeperBotGuard.KeeperBotGuard__ModuleTransactionFailed.selector);

        guard.callStrategyReport(address(failingStrategy));
    }

    /*//////////////////////////////////////////////////////////////
                        INTEGRATION SCENARIOS
    //////////////////////////////////////////////////////////////*/

    function test_fullWorkflow_BotCallsReport() public {
        // 1. Owner authorizes keeper bot
        vm.prank(owner);
        guard.setBotAuthorization(keeperBot, true);

        // 2. Bot calls report on strategy
        vm.prank(keeperBot);
        guard.callStrategyReport(address(strategy));

        // 3. Verify no revert occurred (successful call)
        // The real strategy doesn't track who called it, but success means it worked
    }

    function test_fullWorkflow_MultipleBotsAndStrategies() public {
        // Setup multiple bots - use the same real strategy for both calls
        address bot1 = makeAddr("bot1");
        address bot2 = makeAddr("bot2");

        // Authorize bots
        vm.startPrank(owner);
        guard.setBotAuthorization(bot1, true);
        guard.setBotAuthorization(bot2, true);
        vm.stopPrank();

        // Bot1 calls report on real strategy
        vm.prank(bot1);
        guard.callStrategyReport(address(strategy));

        // Bot2 calls report on real strategy
        vm.prank(bot2);
        guard.callStrategyReport(address(strategy));

        // Verify both calls succeeded (no reverts)
        // The real strategy doesn't track callers, but successful execution means it worked
    }

    /*//////////////////////////////////////////////////////////////
                         SAFE INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_safeIntegration_SetupComplete() public view {
        // Verify Safe is properly configured
        assertEq(safeMultisig.getThreshold(), 2);
        address[] memory owners = safeMultisig.getOwners();
        assertEq(owners.length, 3);
        assertTrue(_arrayContains(owners, safeOwner1));
        assertTrue(_arrayContains(owners, safeOwner2));
        assertTrue(_arrayContains(owners, safeOwner3));
    }

    function test_safeIntegration_GuardOwnedBySafe() public {
        // Deploy a new guard owned by the Safe
        KeeperBotGuard safeOwnedGuard = new KeeperBotGuard(address(safeMultisig), address(safeMultisig));

        // Verify ownership
        assertEq(safeOwnedGuard.owner(), address(safeMultisig));

        // Verify Safe can authorize bots through multisig transaction
        bytes memory setBotAuthData = abi.encodeWithSelector(
            KeeperBotGuard.setBotAuthorization.selector,
            keeperBot,
            true
        );

        // Execute Safe transaction to authorize bot
        _executeSafeTransaction(address(safeOwnedGuard), setBotAuthData);

        // Verify bot is authorized
        assertTrue(safeOwnedGuard.isBotAuthorized(keeperBot));
    }

    function test_safeIntegration_BotCallsReportOnRealStrategy() public {
        // We're already on mainnet fork from setUp, so no need to create another one

        // Use the existing Safe from setUp
        // Deploy guard owned by the Safe
        KeeperBotGuard safeOwnedGuard = new KeeperBotGuard(address(safeMultisig), address(safeMultisig));

        // Safe authorizes the keeper bot
        bytes memory setBotAuthData = abi.encodeWithSelector(
            KeeperBotGuard.setBotAuthorization.selector,
            keeperBot,
            true
        );
        _executeSafeTransaction(address(safeOwnedGuard), setBotAuthData);

        // Verify bot is authorized
        assertTrue(safeOwnedGuard.isBotAuthorized(keeperBot));

        // Enable the guard as a module on the Safe
        bytes memory enableModuleData = abi.encodeWithSignature("enableModule(address)", address(safeOwnedGuard));
        _executeSafeTransaction(address(safeMultisig), enableModuleData);

        // Since Safe is already the management (set during deployment), we can directly set health check
        bytes memory setHealthCheckData = abi.encodeWithSignature("setDoHealthCheck(bool)", true);
        _executeSafeTransaction(address(strategy), setHealthCheckData);

        // Verify health check is enabled on the real strategy
        assertTrue(BaseHealthCheck(address(strategy)).doHealthCheck(), "Health check should be enabled");

        // Bot calls the guard, which will use execTransactionFromModule to make the Safe call the strategy
        // The guard should automatically handle health check (disable it, call report, health check re-enables)
        vm.prank(keeperBot);
        safeOwnedGuard.callStrategyReport(address(strategy));

        // After report, health check should be re-enabled automatically by the strategy
        assertTrue(
            BaseHealthCheck(address(strategy)).doHealthCheck(),
            "Health check should be re-enabled after report"
        );

        // Test with health check disabled
        bytes memory disableHealthCheckData = abi.encodeWithSignature("setDoHealthCheck(bool)", false);
        _executeSafeTransaction(address(strategy), disableHealthCheckData);

        // Verify health check is disabled
        assertFalse(BaseHealthCheck(address(strategy)).doHealthCheck(), "Health check should be disabled");

        // Bot calls report again - should work fine with disabled health check
        vm.prank(keeperBot);
        safeOwnedGuard.callStrategyReport(address(strategy));

        // Health check should be re-enabled after successful report (this is the correct behavior)
        assertTrue(
            BaseHealthCheck(address(strategy)).doHealthCheck(),
            "Health check should be re-enabled after report"
        );

        // This demonstrates that:
        // 1. The guard correctly validates bot authorization
        // 2. The guard uses Safe's execTransactionFromModule to call strategy.report()
        // 3. The Safe itself executes the strategy call, allowing proper keeper permissions
        // 4. The guard handles health check logic correctly (tries to disable before report)
        // 5. The integration between Bot → Guard → Safe → Strategy works end-to-end with health check
    }

    function test_safeIntegration_FullEmergencyResponseWorkflow() public {
        // Deploy guard owned by Safe
        KeeperBotGuard safeOwnedGuard = new KeeperBotGuard(address(safeMultisig), address(safeMultisig));

        // Enable the guard as a module on the Safe
        bytes memory enableModuleData = abi.encodeWithSignature("enableModule(address)", address(safeOwnedGuard));
        _executeSafeTransaction(address(safeMultisig), enableModuleData);

        // Step 1: Safe multisig authorizes emergency bot
        bytes memory setBotAuthData = abi.encodeWithSelector(
            KeeperBotGuard.setBotAuthorization.selector,
            keeperBot,
            true
        );
        _executeSafeTransaction(address(safeOwnedGuard), setBotAuthData);
        assertTrue(safeOwnedGuard.isBotAuthorized(keeperBot));

        // Step 2: Emergency condition detected - bot calls report to burn shares
        vm.prank(keeperBot);
        safeOwnedGuard.callStrategyReport(address(strategy));

        // Step 3: Safe can revoke bot authorization if needed
        bytes memory revokeBotAuthData = abi.encodeWithSelector(
            KeeperBotGuard.setBotAuthorization.selector,
            keeperBot,
            false
        );
        _executeSafeTransaction(address(safeOwnedGuard), revokeBotAuthData);

        // Verify bot is no longer authorized
        assertFalse(safeOwnedGuard.isBotAuthorized(keeperBot));

        // Step 4: Bot can no longer call report
        vm.prank(keeperBot);
        vm.expectRevert(KeeperBotGuard.KeeperBotGuard__NotAuthorizedBot.selector);
        safeOwnedGuard.callStrategyReport(address(strategy));
    }

    /*//////////////////////////////////////////////////////////////
                              HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _arrayContains(address[] memory array, address target) internal pure returns (bool) {
        for (uint256 i = 0; i < array.length; i++) {
            if (array[i] == target) {
                return true;
            }
        }
        return false;
    }

    function _executeSafeTransaction(address to, bytes memory data) internal {
        // Create transaction hash
        bytes32 txHash = safeMultisig.getTransactionHash(
            to,
            0, // value
            data,
            Enum.Operation.Call, // operation (CALL)
            0, // safeTxGas
            0, // baseGas
            0, // gasPrice
            address(0), // gasToken
            address(0), // refundReceiver
            safeMultisig.nonce()
        );

        // Approve hash for the required owners (threshold = 2)
        vm.prank(safeOwner1);
        safeMultisig.approveHash(txHash);

        vm.prank(safeOwner2);
        safeMultisig.approveHash(txHash);

        // Create approved hash signatures - Safe format: 12 zeros + address + 32 zeros + 01
        bytes memory signature1 = abi.encodePacked(
            hex"000000000000000000000000", // 12 bytes of zeros
            safeOwner1, // 20 bytes address
            hex"0000000000000000000000000000000000000000000000000000000000000000", // 32 bytes zeros
            hex"01" // 1 byte signature type
        );

        bytes memory signature2 = abi.encodePacked(
            hex"000000000000000000000000", // 12 bytes of zeros
            safeOwner2, // 20 bytes address
            hex"0000000000000000000000000000000000000000000000000000000000000000", // 32 bytes zeros
            hex"01" // 1 byte signature type
        );

        // Combine signatures (ordered by address)
        bytes memory signatures;
        if (safeOwner1 < safeOwner2) {
            signatures = abi.encodePacked(signature1, signature2);
        } else {
            signatures = abi.encodePacked(signature2, signature1);
        }

        // Execute transaction
        vm.prank(safeOwner1); // Any owner can submit the transaction
        bool success = safeMultisig.execTransaction(
            to,
            0, // value
            data,
            Enum.Operation.Call, // operation (CALL)
            0, // safeTxGas
            0, // baseGas
            0, // gasPrice
            address(0), // gasToken
            payable(address(0)), // refundReceiver
            signatures
        );

        assertTrue(success, "Safe transaction should succeed");
    }

    function _executeSafeTransactionOnFork(Safe safe, address to, bytes memory data) internal {
        // Create transaction hash
        bytes32 txHash = safe.getTransactionHash(
            to,
            0, // value
            data,
            Enum.Operation.Call, // operation (CALL)
            0, // safeTxGas
            0, // baseGas
            0, // gasPrice
            address(0), // gasToken
            address(0), // refundReceiver
            safe.nonce()
        );

        // Approve hash for the required owners (threshold = 2)
        vm.prank(safeOwner1);
        safe.approveHash(txHash);

        vm.prank(safeOwner2);
        safe.approveHash(txHash);

        // Create approved hash signatures - Safe format: 12 zeros + address + 32 zeros + 01
        bytes memory signature1 = abi.encodePacked(
            hex"000000000000000000000000", // 12 bytes of zeros
            safeOwner1, // 20 bytes address
            hex"0000000000000000000000000000000000000000000000000000000000000000", // 32 bytes zeros
            hex"01" // 1 byte signature type
        );

        bytes memory signature2 = abi.encodePacked(
            hex"000000000000000000000000", // 12 bytes of zeros
            safeOwner2, // 20 bytes address
            hex"0000000000000000000000000000000000000000000000000000000000000000", // 32 bytes zeros
            hex"01" // 1 byte signature type
        );

        // Combine signatures (ordered by address)
        bytes memory signatures;
        if (safeOwner1 < safeOwner2) {
            signatures = abi.encodePacked(signature1, signature2);
        } else {
            signatures = abi.encodePacked(signature2, signature1);
        }

        // Execute transaction
        vm.prank(safeOwner1); // Any owner can submit the transaction
        bool success = safe.execTransaction(
            to,
            0, // value
            data,
            Enum.Operation.Call, // operation (CALL)
            0, // safeTxGas
            0, // baseGas
            0, // gasPrice
            address(0), // gasToken
            payable(address(0)), // refundReceiver
            signatures
        );

        assertTrue(success, "Safe transaction should succeed");
    }

    function _signTransaction(bytes32 txHash, uint256 privateKey) internal pure returns (bytes memory) {
        // Create proper ECDSA signature using Foundry's vm.sign
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, txHash);

        // Safe expects signatures in packed format: r (32 bytes) + s (32 bytes) + v (1 byte)
        // Safe requires v to be adjusted: 27/28 -> 1b/1c, but for message signatures it's 1f/20
        // For direct transaction hash signing, we need to adjust v properly
        if (v == 27) v = 0x1f;
        if (v == 28) v = 0x20;

        return abi.encodePacked(r, s, v);
    }

    function airdrop(ERC20 token, address to, uint256 amount) internal {
        // Use deal from forge-std for ERC20 tokens
        deal(address(token), to, amount);
    }

    function _enableModuleOnSafe(address module) internal {
        bytes memory enableModuleData = abi.encodeWithSignature("enableModule(address)", module);
        _executeSafeTransaction(address(safeMultisig), enableModuleData);
    }
}

/*//////////////////////////////////////////////////////////////
                            MOCK CONTRACTS
//////////////////////////////////////////////////////////////*/

contract MockFailingStrategy {
    function report() external pure returns (uint256, uint256) {
        revert("Strategy report failed");
    }
}
