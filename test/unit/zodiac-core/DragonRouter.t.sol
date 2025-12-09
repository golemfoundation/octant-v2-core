// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import "@openzeppelin/contracts/utils/Strings.sol";
import "forge-std/Test.sol";
import "src/zodiac-core/SplitChecker.sol";
import { DragonRouter } from "src/zodiac-core/DragonRouter.sol";
import { MockStrategy } from "test/mocks/zodiac-core/MockStrategy.sol";
import { MockDragonRouterTesting } from "test/mocks/zodiac-core/MockDragonRouterTesting.sol";
import { MockNativeTransformer } from "test/mocks/zodiac-core/MockNativeTransformer.sol";
import { ISplitChecker } from "src/zodiac-core/interfaces/ISplitChecker.sol";
import { ITransformer } from "src/zodiac-core/interfaces/ITransformer.sol";
import { IDragonRouter } from "src/zodiac-core/interfaces/IDragonRouter.sol";
import { MockDragonRouterTesting } from "test/mocks/zodiac-core/MockDragonRouterTesting.sol";
import { MockNativeTransformer } from "test/mocks/zodiac-core/MockNativeTransformer.sol";
import { ISplitChecker } from "src/zodiac-core/interfaces/ISplitChecker.sol";
import { ITransformer } from "src/zodiac-core/interfaces/ITransformer.sol";
import { IDragonRouter } from "src/zodiac-core/interfaces/IDragonRouter.sol";

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts//interfaces/IERC4626.sol";
import { ITokenizedStrategy } from "src/zodiac-core/interfaces/ITokenizedStrategy.sol";
import { DragonRouter } from "src/zodiac-core/DragonRouter.sol";

import { ITransformer } from "src/zodiac-core/interfaces/ITransformer.sol";
import { MockDragonRouterTesting } from "test/mocks/zodiac-core/MockDragonRouterTesting.sol";
import { MockNativeTransformer } from "test/mocks/zodiac-core/MockNativeTransformer.sol";
import { MockStrategy } from "test/mocks/zodiac-core/MockStrategy.sol";
import { ISplitChecker } from "src/zodiac-core/interfaces/ISplitChecker.sol";
import { AccessControl } from "@openzeppelin/contracts//access/AccessControl.sol";
import { DragonTokenizedStrategy } from "src/zodiac-core/vaults/DragonTokenizedStrategy.sol";

import { MockStrategy } from "test/mocks/zodiac-core/MockStrategy.sol";
import { MockYieldSource } from "test/mocks/core/MockYieldSource.sol";
import { NATIVE_TOKEN } from "src/constants.sol";
import { BaseTest } from "./Base.t.sol";
import { console } from "forge-std/console.sol";

contract DragonRouterTest is BaseTest {
    DragonRouter public router;
    MockDragonRouterTesting public routerTesting;
    SplitChecker public splitChecker;
    address public owner;
    address public governance;
    address public regenGovernance;
    address public opexVault;
    address public metapool;
    address[] public strategies;
    address[] public assets;
    address public distributor;
    address public user;
    address public newStrategy;
    address public newAsset;
    address public transformer;

    // Constants for roles
    bytes32 constant ADMIN_ROLE = 0x00; // This is DEFAULT_ADMIN_ROLE
    bytes32 constant GOVERNANCE_ROLE = keccak256("OCTANT_GOVERNANCE_ROLE");
    bytes32 constant REGEN_GOVERNANCE_ROLE = keccak256("REGEN_GOVERNANCE_ROLE");
    bytes32 constant SPLIT_DISTRIBUTOR_ROLE = keccak256("SPLIT_DISTRIBUTOR_ROLE");

    event StrategyAdded(address indexed strategy);
    event StrategyRemoved(address indexed strategy);
    event MetapoolUpdated(address oldMetapool, address newMetapool);
    event OpexVaultUpdated(address oldOpexVault, address newOpexVault);
    event SplitDelayUpdated(uint256 oldDelay, uint256 newDelay);
    event SplitCheckerUpdated(address oldChecker, address newChecker);
    event UserTransformerSet(address indexed user, address indexed strategy, address transformer, address targetToken);
    event SplitClaimed(address indexed caller, address indexed owner, address indexed strategy, uint256 amount);
    event ClaimAutomationSet(address indexed user, address indexed strategy, bool enabled);

    function setUp() public {
        _configure(true, "eth");
        // Use a known address for setup
        address setupActor = address(0x123);

        // Regular addresses for testing
        owner = setupActor; // Same as setup actor
        governance = makeAddr("governance");
        regenGovernance = makeAddr("regenGovernance");
        opexVault = makeAddr("opexVault");
        metapool = makeAddr("metapool");
        distributor = makeAddr("distributor");
        user = makeAddr("user");
        transformer = makeAddr("transformer");
        newStrategy = makeAddr("newStrategy");
        newAsset = makeAddr("newAsset");

        // Deploy SplitChecker
        splitChecker = new SplitChecker();
        splitChecker.initialize(governance, 0.5e18, 0.05e18); // 50% max opex, 5% min metapool

        // Setup mock strategies and assets
        address keeper = makeAddr("keeper");
        address dragonRouter = makeAddr("dragonRouter");
        address management = makeAddr("management");
        for (uint256 i = 0; i < 3; i++) {
            MockStrategy moduleImplementation = new MockStrategy();
            DragonTokenizedStrategy tokenizedStrategyImplementation = new DragonTokenizedStrategy();
            MockYieldSource yieldSource = new MockYieldSource(NATIVE_TOKEN);
            string memory name = "Test Mock Strategy";
            uint256 maxReportDelay = 9;
            testTemps memory temps = _testTemps(
                address(moduleImplementation),
                abi.encode(
                    address(tokenizedStrategyImplementation),
                    NATIVE_TOKEN,
                    address(yieldSource),
                    management,
                    keeper,
                    dragonRouter,
                    maxReportDelay,
                    name,
                    regenGovernance
                )
            );
            DragonTokenizedStrategy module = DragonTokenizedStrategy(payable(temps.module));
            strategies.push(address(module));
            assets.push(NATIVE_TOKEN);
        }

        // Create initialization parameters
        bytes memory initParams = abi.encode(
            owner, // setupActor will get DEFAULT_ADMIN_ROLE
            abi.encode(strategies, governance, regenGovernance, address(splitChecker), opexVault, metapool)
        );

        // Start a prank as the setupActor for ALL operations
        vm.startPrank(setupActor);

        // Create and initialize first router
        router = new DragonRouter();
        router.setUp(initParams);
        router.grantRole(SPLIT_DISTRIBUTOR_ROLE, distributor);

        // Create and initialize testing router
        routerTesting = new MockDragonRouterTesting();
        routerTesting.setUp(initParams);
        routerTesting.grantRole(SPLIT_DISTRIBUTOR_ROLE, distributor);

        // For the tests that need mock data, we'll use vm.mockCall instead of vm.store
        setupTestMocks();

        // End the prank after all setup is complete
        vm.stopPrank();
    }

    // Setup data for tests through direct storage manipulation
    function setupTestMocks() internal {
        // For each strategy, set up basic data for testing
        for (uint256 i = 0; i < strategies.length; i++) {
            // Setup strategy data with an asset and default values
            routerTesting.setStrategyDataForTest(
                strategies[i],
                assets[i], // asset
                1e18, // assetPerShare
                1000, // totalAssets
                1e18 // totalShares (SPLIT_PRECISION)
            );

            // Setup user data with 1 ETH balance for testing
            routerTesting.setUserDataForTest(
                user,
                strategies[i],
                1 ether, // assets (1 ETH balance)
                0, // userAssetPerShare
                1e18, // splitPerShare (100%)
                IDragonRouter.Transformer(ITransformer(address(0)), address(0)), // no transformer
                false // allowBotClaim
            );
        }
    }

    function test_setCooldownPeriod() public {
        uint256 newPeriod = 180 days;

        vm.prank(regenGovernance);
        routerTesting.setCooldownPeriod(newPeriod);

        // Test successful change
        assertEq(routerTesting.coolDownPeriod(), newPeriod);
    }

    function test_setCooldownPeriod_reverts() public {
        uint256 newPeriod = 180 days;

        vm.startPrank(address(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                address(0),
                keccak256("REGEN_GOVERNANCE_ROLE")
            )
        );
        routerTesting.setCooldownPeriod(newPeriod);

        vm.stopPrank();
    }

    function test_addStrategy() public {
        vm.prank(owner);

        // Mock the asset() call on the newStrategy
        vm.mockCall(newStrategy, abi.encodeWithSelector(IERC4626.asset.selector), abi.encode(makeAddr("mockedAsset")));

        vm.expectEmit(true, true, true, true);
        emit StrategyAdded(newStrategy);
        routerTesting.addStrategy(newStrategy);

        // Verify strategy was added
        bool found = false;
        for (uint256 i = 0; i < strategies.length + 1; i++) {
            try routerTesting.strategies(i) returns (address strat) {
                if (strat == newStrategy) {
                    found = true;
                    break;
                }
            } catch {
                break; // End of array
            }
        }
        assertTrue(found, "New strategy not found in strategies array");
    }

    function test_addStrategy_reverts_alreadyAdded() public {
        // We need to set up a distinct new strategy for this test
        address distinctStrategy = makeAddr("distinctStrategy");

        // First set up the strategy data directly using setStrategyDataForTest
        vm.startPrank(owner);
        routerTesting.setStrategyDataForTest(
            distinctStrategy,
            makeAddr("testAsset"), // asset - this is what causes AlreadyAdded to trigger
            0, // assetPerShare
            0, // totalAssets
            1e18 // totalShares (SPLIT_PRECISION)
        );

        // Try to add it again - this should revert with AlreadyAdded because asset is set
        vm.expectRevert(IDragonRouter.AlreadyAdded.selector);
        routerTesting.addStrategy(distinctStrategy);
        vm.stopPrank();
    }

    function test_removeStrategy() public {
        // Use routerTesting instead of router for direct storage manipulation
        vm.startPrank(owner);

        // First add the strategy by setting up its data directly
        address testAsset = makeAddr("testAsset");
        routerTesting.setStrategyDataForTest(
            newStrategy,
            testAsset, // asset
            0, // assetPerShare
            0, // totalAssets
            1e18 // totalShares (SPLIT_PRECISION)
        );

        // Verify the strategy exists
        (address storedAsset, , , ) = routerTesting.strategyData(newStrategy);
        assertEq(storedAsset, testAsset, "Strategy asset should be set before removing");

        // Then remove it
        vm.expectEmit(true, true, true, true);
        emit StrategyRemoved(newStrategy);
        routerTesting.removeStrategy(newStrategy);

        // Verify it was removed
        (storedAsset, , , ) = routerTesting.strategyData(newStrategy);
        assertEq(storedAsset, address(0), "Strategy asset should be zeroed after removal");

        // Mock the asset() call for adding it back
        vm.mockCall(newStrategy, abi.encodeWithSelector(IERC4626.asset.selector), abi.encode(testAsset));

        // Add it again to verify it works (would fail with AlreadyAdded if not properly removed)
        routerTesting.addStrategy(newStrategy);
        vm.stopPrank();
    }

    function test_removeStrategy_reverts_notDefined() public {
        vm.prank(owner);
        vm.expectRevert(IDragonRouter.StrategyNotDefined.selector);
        routerTesting.removeStrategy(makeAddr("nonExistentStrategy"));
    }

    function test_setMetapool() public {
        address newMetapool = makeAddr("newMetapool");

        vm.prank(governance);
        vm.expectEmit(true, true, true, true);
        emit MetapoolUpdated(metapool, newMetapool);
        routerTesting.setMetapool(newMetapool);

        assertEq(routerTesting.metapool(), newMetapool);
    }

    function test_setMetapool_reverts_invalidRole() public {
        address newMetapool = makeAddr("newMetapool");

        vm.prank(owner); // user with DEFAULT_ADMIN_ROLE, not GOVERNANCE_ROLE
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, owner, GOVERNANCE_ROLE)
        );

        routerTesting.setMetapool(newMetapool);
    }

    function test_setOpexVault() public {
        address newOpexVault = makeAddr("newOpexVault");

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit OpexVaultUpdated(opexVault, newOpexVault);
        routerTesting.setOpexVault(newOpexVault);

        assertEq(routerTesting.opexVault(), newOpexVault);
    }

    function test_setSplitDelay() public {
        uint256 newDelay = 7 days;

        // Get the current split delay for emit comparison
        uint256 currentDelay = routerTesting.splitDelay();

        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SplitDelayUpdated(currentDelay, newDelay);
        routerTesting.setSplitDelay(newDelay);

        // Verify the split delay was updated
        assertEq(routerTesting.splitDelay(), newDelay);
    }

    function test_setSplitChecker() public {
        address newSplitChecker = vm.addr(1);
        vm.label(newSplitChecker, "newSplitChecker");

        // Give the governance DEFAULT_ADMIN_ROLE
        vm.prank(owner);
        routerTesting.grantRole(ADMIN_ROLE, governance);

        // Get current split checker for emit comparison
        address currentSplitChecker = address(routerTesting.splitChecker());

        vm.prank(governance);
        vm.expectEmit(true, true, true, true);
        emit SplitCheckerUpdated(currentSplitChecker, newSplitChecker);
        routerTesting.setSplitChecker(newSplitChecker);

        // Verify the split checker was updated
        assertEq(address(routerTesting.splitChecker()), newSplitChecker);
    }

    function test_setTransformer() public {
        address userWithBalance = makeAddr("userWithBalance");
        address targetToken = DragonTokenizedStrategy(strategies[0]).asset();

        // Set up user data with a non-zero balance
        routerTesting.setUserDataForTest(
            userWithBalance,
            strategies[0],
            1000, // assets - non-zero balance to pass NoShares check
            1e18, // userAssetPerShare
            1e18, // splitPerShare
            IDragonRouter.Transformer(ITransformer(address(0)), address(0)), // no transformer initially
            false // allowBotClaim
        );

        // Set up strategy data
        routerTesting.setStrategyDataForTest(
            strategies[0],
            makeAddr("testAsset"),
            1e18, // assetPerShare
            1000, // totalAssets
            1e18 // totalShares
        );

        // Call setTransformerForTest as the user
        vm.prank(userWithBalance);
        routerTesting.setTransformerForTest(strategies[0], transformer, targetToken);

        // Verify that the transformer was set correctly
        (, , , IDragonRouter.Transformer memory userTransformer, ) = routerTesting.userData(
            userWithBalance,
            strategies[0]
        );
        assertEq(address(userTransformer.transformer), transformer, "Transformer address not set correctly");
        assertEq(userTransformer.targetToken, targetToken, "Target token not set correctly");
    }

    function test_setTransformer_reverts_noShares() public {
        // Create a user with zero balance for this specific test
        address zeroBalanceUser = makeAddr("zeroBalanceUser");
        address targetToken = makeAddr("targetToken");

        // Set up user data with zero assets directly
        routerTesting.setUserDataForTest(
            zeroBalanceUser,
            strategies[0],
            0, // assets (zero balance)
            0, // userAssetPerShare
            1e18, // splitPerShare
            IDragonRouter.Transformer(ITransformer(address(0)), address(0)), // no transformer
            false // allowBotClaim
        );

        // Prepare strategy to ensure balanceOf will return 0
        routerTesting.setStrategyDataForTest(
            strategies[0],
            makeAddr("testAsset"),
            0, // assetPerShare
            0, // totalAssets
            1e18 // totalShares
        );

        // Try to set transformer - should revert with NoShares
        vm.prank(zeroBalanceUser);
        vm.expectRevert(IDragonRouter.NoShares.selector);
        routerTesting.setTransformerForTest(strategies[0], transformer, targetToken);
    }

    function test_setClaimAutomation() public {
        // Expect the ClaimAutomationSet event with appropriate parameters
        vm.expectEmit(true, true, true, true, address(routerTesting));
        emit ClaimAutomationSet(user, strategies[0], true);

        vm.prank(user);
        routerTesting.setClaimAutomation(strategies[0], true);

        // Verify claim automation was enabled
        (, , , , bool enabled) = routerTesting.userData(user, strategies[0]);
        assertTrue(enabled);

        // Test disabling
        vm.prank(user);
        routerTesting.setClaimAutomation(strategies[0], false);

        (, , , , enabled) = routerTesting.userData(user, strategies[0]);
        assertFalse(enabled);
    }

    function test_balanceOf() public {
        address userWithBalance = makeAddr("userWithBalance");

        // Set up user data with known balance
        routerTesting.setUserDataForTest(
            userWithBalance,
            strategies[0],
            100, // assets (direct balance)
            1e18, // userAssetPerShare
            1e18, // splitPerShare (100%)
            IDragonRouter.Transformer(ITransformer(address(0)), address(0)), // no transformer
            false // allowBotClaim
        );

        // Set up strategy data with known asset per share
        routerTesting.setStrategyDataForTest(
            strategies[0],
            assets[0], // asset
            1e18 + 50, // assetPerShare (to make claimable = 50)
            100, // totalAssets
            1e18 // totalShares
        );

        // Get the balance
        uint256 balance = routerTesting.balanceOf(userWithBalance, strategies[0]);

        // Check the balance against the actual calculation result
        // The calculation is: user direct assets + (splitPerShare * totalShares * (assetPerShare - userAssetPerShare)) / SPLIT_PRECISION
        // = 100 + (1e18 * 1e18 * 50) / 1e18 = 100 + 50e18
        uint256 expectedDirect = 100;
        uint256 expectedClaimable = 50 * 1e18; // 50 * 1e18 from the calculation
        uint256 expectedTotal = expectedDirect + expectedClaimable;
        assertEq(balance, expectedTotal, "Balance does not match expected total");
    }

    function test_fundFromSource() public {
        // Create asset and deploy mock strategy
        address asset = makeAddr("asset");
        MockStrategy mockStrategy = new MockStrategy();

        // Create a list of strategies and assets including our mock
        address[] memory testStrategies = new address[](1);
        testStrategies[0] = strategies[0];

        address[] memory testAssets = new address[](1);
        testAssets[0] = assets[0];

        // Set up a new router with our strategy already included
        vm.startPrank(owner);
        MockDragonRouterTesting testRouter = new MockDragonRouterTesting();

        // Create initialization parameters with our strategy
        bytes memory initParams = abi.encode(
            owner,
            abi.encode(testStrategies, governance, regenGovernance, address(splitChecker), opexVault, metapool)
        );

        // Initialize router
        testRouter.setUp(initParams);

        // Grant distributor role
        testRouter.grantRole(SPLIT_DISTRIBUTOR_ROLE, distributor);

        // Set up the strategy data directly
        testRouter.setStrategyDataForTest(
            address(mockStrategy),
            asset, // asset
            0, // assetPerShare
            0, // totalAssets
            1e18 // totalShares (SPLIT_PRECISION)
        );

        // Mock the withdraw call on strategy
        vm.mockCall(
            address(mockStrategy),
            abi.encodeWithSelector(ITokenizedStrategy.withdraw.selector),
            abi.encode(1000)
        );
        // Mock the asset transfer call that would happen from the strategy
        vm.mockCall(
            asset,
            abi.encodeWithSelector(IERC20.transfer.selector, address(testRouter), 1000),
            abi.encode(true)
        );

        vm.stopPrank();

        // Verify asset is set correctly in the router
        (address storedAsset, , , uint256 totalShares) = testRouter.strategyData(address(mockStrategy));
        assertEq(storedAsset, asset, "Asset not properly set in strategy data");
        assertEq(totalShares, 1e18, "Total shares should be set to SPLIT_PRECISION (1e18)");

        // Call fundFromSource
        uint256 fundAmount = 1000;
        vm.prank(distributor);
        testRouter.fundFromSource(address(mockStrategy), fundAmount);

        // Verify assetPerShare and totalAssets increased
        (, uint256 assetPerShare, uint256 totalAssets, ) = testRouter.strategyData(address(mockStrategy));
        assertTrue(assetPerShare > 0, "Asset per share should increase");
        assertEq(totalAssets, fundAmount, "Total assets not updated correctly");
    }

    function test_fundFromSource_reverts_zeroAddress() public {
        vm.prank(distributor);
        vm.expectRevert(IDragonRouter.ZeroAddress.selector);
        routerTesting.fundFromSource(makeAddr("nonExistentStrategy"), 1000);
    }

    function test_setSplit() public {
        // Set up a mock split
        address[] memory recipients = new address[](2);
        recipients[0] = opexVault;
        recipients[1] = metapool;

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 30; // 30% to opex
        allocations[1] = 70; // 70% to metapool

        // Need to wait for cooldown period
        uint256 cooldownPeriod = routerTesting.coolDownPeriod();
        vm.warp(block.timestamp + cooldownPeriod + 1);

        // No need to mock - using routerTesting which has real implementation
        vm.startPrank(owner);
        router.setSplit(
            ISplitChecker.Split({ recipients: recipients, allocations: allocations, totalAllocations: 100 })
        );
        vm.stopPrank();

        // Verify the timestamp changed
        assertGt(router.lastSetSplitTime(), block.timestamp - 10);
    }

    function test_setSplit_reverts_cooldownNotPassed() public {
        address[] memory recipients = new address[](2);
        recipients[0] = opexVault;
        recipients[1] = metapool;

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 30;
        allocations[1] = 70;

        vm.prank(owner);
        router.setSplit(
            ISplitChecker.Split({ recipients: recipients, allocations: allocations, totalAllocations: 100 })
        );

        vm.prank(owner);
        vm.expectRevert(IDragonRouter.CooldownPeriodNotPassed.selector);
        router.setSplit(
            ISplitChecker.Split({ recipients: recipients, allocations: allocations, totalAllocations: 100 })
        );
    }

    function test_claimSplit() public {
        address userWithBalance = makeAddr("userWithBalance");
        uint256 balance = 1000;
        uint256 claimAmount = 500;

        // Use routerTesting instead of router to directly manipulate storage
        address testAsset = makeAddr("testAsset");

        // Set up strategy data directly
        routerTesting.setStrategyDataForTest(
            strategies[0],
            testAsset,
            2e18, // assetPerShare
            2000, // totalAssets
            1e18 // totalShares
        );

        // Set up user data directly
        routerTesting.setUserDataForTest(
            userWithBalance,
            strategies[0],
            balance, // assets
            0, // userAssetPerShare
            1e18, // splitPerShare (100%)
            IDragonRouter.Transformer(ITransformer(address(0)), address(0)), // no transformer
            true // allowBotClaim enabled
        );

        // Mock the asset transfer since we can't actually transfer tokens in the test
        vm.mockCall(
            testAsset,
            abi.encodeWithSelector(IERC20.transfer.selector, userWithBalance, claimAmount),
            abi.encode(true)
        );
        // Test claiming by the user
        vm.prank(userWithBalance);
        vm.expectEmit(true, true, true, true);
        emit SplitClaimed(userWithBalance, userWithBalance, strategies[0], claimAmount);
        routerTesting.claimSplit(userWithBalance, strategies[0], claimAmount);
        // Set user data for the second claim (reduced balance after first claim)
        routerTesting.setUserDataForTest(
            userWithBalance,
            strategies[0],
            balance - claimAmount, // assets reduced by first claim
            0, // userAssetPerShare
            1e18, // splitPerShare (100%)
            IDragonRouter.Transformer(ITransformer(address(0)), address(0)), // no transformer
            true // allowBotClaim enabled
        );

        // Mock the asset transfer for the second claim
        uint256 secondClaimAmount = 300;
        vm.mockCall(
            testAsset,
            abi.encodeWithSelector(IERC20.transfer.selector, userWithBalance, secondClaimAmount),
            abi.encode(true)
        );
        // Test claiming by another address (bot)
        address bot = makeAddr("bot");
        vm.prank(bot);
        vm.expectEmit(true, true, true, true);
        emit SplitClaimed(bot, userWithBalance, strategies[0], secondClaimAmount);
        routerTesting.claimSplit(userWithBalance, strategies[0], secondClaimAmount);
    }

    function test_claimSplit_reverts_zeroAmount() public {
        vm.prank(user);
        vm.expectRevert(IDragonRouter.InvalidAmount.selector);
        routerTesting.claimSplit(user, strategies[0], 0);
    }

    function test_claimSplit_reverts_notAllowed() public {
        address userWithBalance = makeAddr("userWithBalance");
        address bot = makeAddr("bot");

        // Set up user data with claim automation disabled
        routerTesting.setUserDataForTest(
            userWithBalance,
            strategies[0],
            1000, // assets
            1e18, // userAssetPerShare
            1e18, // splitPerShare
            IDragonRouter.Transformer(ITransformer(address(0)), address(0)), // no transformer
            false // allowBotClaim explicitly disabled
        );

        // Try claiming from another address (bot)
        vm.prank(bot);
        vm.expectRevert(IDragonRouter.NotAllowed.selector);
        routerTesting.claimSplit(userWithBalance, strategies[0], 100);
    }

    function test_claimSplit_reverts_insufficientBalance() public {
        // Set up strategy data first to make sure asset is set
        address testAsset = makeAddr("testAsset");
        routerTesting.setStrategyDataForTest(
            strategies[0],
            testAsset,
            1e18, // assetPerShare
            1000, // totalAssets
            1e18 // totalShares
        );

        // Set up user data - ensuring total balance is less than what will be claimed
        // With userAssetPerShare = 1e18 and assetPerShare = 1e18,
        // the claimable assets will be 0 due to (assetPerShare - userAssetPerShare) = 0
        routerTesting.setUserDataForTest(
            user,
            strategies[0],
            50, // direct assets = 50
            1e18, // userAssetPerShare = 1e18 (same as strategy assetPerShare)
            1e18, // splitPerShare
            IDragonRouter.Transformer(ITransformer(address(0)), address(0)), // no transformer
            false // allowBotClaim
        );

        // Mock transfer to handle the call but it won't reach this
        vm.mockCall(testAsset, abi.encodeWithSelector(IERC20.transfer.selector, user, 100), abi.encode(true));

        // Try to claim more than available (balance = 50 + 0 claimable = 50)
        vm.prank(user);
        vm.expectRevert(IDragonRouter.InvalidAmount.selector);
        routerTesting.claimSplit(user, strategies[0], 100);
    }

    function test_updateUserSplit() public {
        address userToUpdate = makeAddr("userToUpdate");
        uint256 balance = 1000;
        uint256 amountToUpdate = 300;
        uint256 assetPerShare = 2e18; // Using a higher asset per share to test claimable calculation
        uint256 userAssetPerShare = 1e18; // Initial user asset per share
        address asset = makeAddr("asset");
        // Setup data directly with setStrategyDataForTest and setUserDataForTest
        routerTesting.setStrategyDataForTest(
            strategies[0],
            asset,
            assetPerShare, // assetPerShare
            0, // totalAssets
            1e18 // totalShares
        );

        routerTesting.setUserDataForTest(
            userToUpdate,
            strategies[0],
            balance, // assets
            userAssetPerShare, // userAssetPerShare
            1e18, // splitPerShare
            IDragonRouter.Transformer(ITransformer(address(0)), address(0)), // no transformer
            false // allowBotClaim
        );

        // Calculate expected values
        // Claimable assets = (splitPerShare * totalShares * (assetPerShare - userAssetPerShare)) / SPLIT_PRECISION
        uint256 claimableAssets = (1e18 * 1e18 * (assetPerShare - userAssetPerShare)) / 1e18;
        uint256 originalTotalBalance = balance + claimableAssets;

        // Expected remaining assets after update
        uint256 expectedRemainingTotal = originalTotalBalance - amountToUpdate;

        // Call the exposed internal function
        routerTesting.exposed_updateUserSplit(userToUpdate, strategies[0], amountToUpdate);

        // Verify userData was updated correctly
        (uint256 actualAssets, uint256 actualUserAssetPerShare, , , ) = routerTesting.userData(
            userToUpdate,
            strategies[0]
        );

        // Check that userAssetPerShare was updated correctly
        assertEq(
            actualUserAssetPerShare,
            assetPerShare,
            "UserAssetPerShare should be updated to current assetPerShare"
        );

        // Check that assets were updated correctly
        // Note: actualAssets should equal expectedRemainingTotal because after _updateUserSplit,
        // userData.assets should contain all assets (original + claimable - claimed)
        assertEq(actualAssets, expectedRemainingTotal, "Assets were not updated correctly");
    }

    function test_transferSplit() public {
        address recipient = makeAddr("recipient");
        address asset = makeAddr("asset");
        uint256 amount = 500;

        // Set strategy data directly
        routerTesting.setStrategyDataForTest(
            strategies[0],
            asset, // asset
            0, // assetPerShare
            0, // totalAssets
            1e18 // totalShares
        );

        // Setup mock for IERC20.transfer
        vm.mockCall(asset, abi.encodeWithSelector(IERC20.transfer.selector, recipient, amount), abi.encode(true));

        // Call the exposed internal function
        routerTesting.exposed_transferSplit(recipient, strategies[0], amount);

        // This test passes if no reversion occurs
    }

    function test_transferSplit_withTransformer() public {
        address recipient = makeAddr("recipient");
        address asset = makeAddr("asset");
        address transformerAddr = makeAddr("transformer");
        address targetToken = makeAddr("targetToken");
        uint256 amount = 500;
        uint256 transformedAmount = 450; // Assuming some slippage

        // Set up strategy data directly
        routerTesting.setStrategyDataForTest(
            strategies[0],
            asset, // asset
            0, // assetPerShare
            0, // totalAssets
            1e18 // totalShares
        );

        // Set up user data directly with balance for recipient
        routerTesting.setUserDataForTest(
            recipient,
            strategies[0],
            1000, // assets
            0, // userAssetPerShare
            1e18, // splitPerShare
            IDragonRouter.Transformer(ITransformer(address(0)), address(0)), // No transformer yet
            false // allowBotClaim not used
        );

        // Set up transformer for recipient
        vm.prank(recipient);
        routerTesting.setTransformerForTest(strategies[0], transformerAddr, targetToken);

        // Mock transformer interactions
        vm.mockCall(asset, abi.encodeWithSelector(IERC20.approve.selector, transformerAddr, amount), abi.encode(true));

        // Mock transformer.transform
        vm.mockCall(
            transformerAddr,
            abi.encodeWithSelector(ITransformer.transform.selector, asset, targetToken, amount),
            abi.encode(transformedAmount)
        );

        // Mock target token transfer
        vm.mockCall(
            targetToken,
            abi.encodeWithSelector(IERC20.transfer.selector, recipient, transformedAmount),
            abi.encode(true)
        );

        // Call the exposed internal function
        routerTesting.exposed_transferSplit(recipient, strategies[0], amount);

        // This test passes if no reversion occurs
    }

    function test_claimableAssets() public {
        address userAddress = makeAddr("user");
        uint256 userSplitPerShare = 0.6e18; // 60% allocation
        uint256 stratAssetPerShare = 2e18;
        uint256 userAssetPerShare = 1e18;
        uint256 stratTotalShares = 1e18;

        // Calculate using the formula from DragonRouter._claimableAssets
        uint256 expectedClaimable = (userSplitPerShare * stratTotalShares * (stratAssetPerShare - userAssetPerShare)) /
            1e18;

        // Set up strategy data
        routerTesting.setStrategyDataForTest(
            strategies[0],
            address(0), // asset doesn't matter for calculation
            stratAssetPerShare, // assetPerShare
            0, // totalAssets not used in calculation
            stratTotalShares // totalShares
        );

        // Set up user data
        routerTesting.setUserDataForTest(
            userAddress,
            strategies[0],
            0, // assets not used in calculation
            userAssetPerShare, // userAssetPerShare
            userSplitPerShare, // splitPerShare
            IDragonRouter.Transformer(ITransformer(address(0)), address(0)), // no transformer
            false // allowBotClaim not used in calculation
        );

        // Call the exposed internal function
        uint256 claimable = routerTesting.exposed_claimableAssets(userAddress, strategies[0]);

        // Use exact equality check
        assertEq(claimable, expectedClaimable, "Claimable amount does not match expected value");
    }

    // Test removing a strategy from the middle of the array to hit the branch in
    // the removeStrategy function where it replaces a strategy with the last one
    function test_removeStrategy_middle() public {
        // Set up several strategies to ensure we can test removing a middle one
        address[] memory testStrategies = strategies;

        // Deploy new router with test strategies
        vm.startPrank(owner);
        MockDragonRouterTesting testRouter = new MockDragonRouterTesting();

        // Initialize with test strategies
        address[] memory testAssets = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            testAssets[i] = makeAddr(string.concat("testAsset", vm.toString(i)));
        }
        bytes memory initParams = abi.encode(
            owner,
            abi.encode(testStrategies, governance, regenGovernance, address(splitChecker), opexVault, metapool)
        );

        testRouter.setUp(initParams);

        // Verify strategies were set up correctly
        assertEq(testRouter.strategies(0), testStrategies[0]);
        assertEq(testRouter.strategies(1), testStrategies[1]);
        assertEq(testRouter.strategies(2), testStrategies[2]);
        // Set strategy data directly to be able to remove the strategy
        testRouter.setStrategyDataForTest(
            testStrategies[1], // Middle strategy
            testAssets[1],
            1e18,
            1000,
            1e18
        );
        // Remove the middle strategy
        vm.expectEmit(true, true, true, true);
        emit StrategyRemoved(testStrategies[1]);
        testRouter.removeStrategy(testStrategies[1]);

        // Verify middle strategy was removed and last was swapped into its place
        assertEq(testRouter.strategies(0), testStrategies[0]);
        assertEq(testRouter.strategies(1), testStrategies[2]); // Last element swapped to middle

        // Verify trying to access the 3rd element reverts as the array length decreased
        vm.expectRevert(); // No specific message, array access out of bounds
        testRouter.strategies(2);

        vm.stopPrank();
    }

    // Test the setTransformer function directly (not through the testing mock)
    function test_setTransformer_direct() public {
        // Use the existing MockDragonRouterTesting instead of the main router
        address userWithBalance = makeAddr("userWithBalance");
        address targetToken = makeAddr("targetToken");
        address transformerImpl = makeAddr("transformerImpl");

        // Set up user data with a non-zero balance
        routerTesting.setUserDataForTest(
            userWithBalance,
            strategies[0], // Use first existing strategy
            1000, // assets - non-zero balance
            0, // userAssetPerShare
            1e18, // splitPerShare
            IDragonRouter.Transformer(ITransformer(address(0)), address(0)), // no transformer initially
            false // allowBotClaim
        );

        // Call setTransformer as the user
        vm.prank(userWithBalance);
        vm.expectEmit(true, true, true, true);
        emit UserTransformerSet(userWithBalance, strategies[0], transformerImpl, targetToken);
        routerTesting.setTransformerForTest(strategies[0], transformerImpl, targetToken);

        // Verify the transformer was set correctly
        (, , , IDragonRouter.Transformer memory userTransformer, ) = routerTesting.userData(
            userWithBalance,
            strategies[0]
        );
        assertEq(address(userTransformer.transformer), transformerImpl, "Transformer address not set correctly");
        assertEq(userTransformer.targetToken, targetToken, "Target token not set correctly");
    }

    // Test _transferSplit with native token paths
    function test_transferSplit_nativeToken() public {
        address recipient = makeAddr("recipient");
        uint256 amount = 500;
        address nativeToken = NATIVE_TOKEN;

        // Add ETH to the test contract to handle the transfers
        vm.deal(address(routerTesting), 1000);

        // Set up strategy data using the native token as asset
        routerTesting.setStrategyDataForTest(
            strategies[0],
            nativeToken, // Use the NATIVE_TOKEN address
            0,
            0,
            1e18
        );

        // Call the exposed internal function, should transfer native token directly
        routerTesting.exposed_transferSplit(recipient, strategies[0], amount);

        // Verify the ETH balance of the recipient increased
        assertEq(recipient.balance, amount);
    }

    // Test _transferSplit with native token and transformer
    function test_transferSplit_nativeToken_withTransformer() public {
        address recipient = makeAddr("recipient");
        uint256 amount = 500;
        address nativeToken = NATIVE_TOKEN;
        uint256 transformedAmount = 450; // 90% of original amount (simulating 10% slippage)

        // Deploy a real mock transformer that will handle native ETH
        MockNativeTransformer nativeTransformer = new MockNativeTransformer();

        // Add ETH to the test contract to handle the transfers
        vm.deal(address(routerTesting), 1000);

        // Set up strategy data with native token
        routerTesting.setStrategyDataForTest(
            strategies[0],
            nativeToken, // Use NATIVE_TOKEN address
            0,
            0,
            1e18
        );

        // Set up transformer for recipient
        routerTesting.setUserDataForTest(
            recipient,
            strategies[0],
            0, // No direct assets needed
            0, // No userAssetPerShare needed
            1e18, // Full split share
            IDragonRouter.Transformer(ITransformer(address(nativeTransformer)), nativeToken), // Use native token as target
            false
        );

        // Before the transfer, check recipient has 0 ETH
        assertEq(recipient.balance, 0, "Recipient should start with 0 ETH");

        // Call the exposed internal function - we need to skip internal mockCalls for native token
        vm.mockCall(
            nativeToken,
            abi.encodeWithSelector(IERC20.approve.selector, address(nativeTransformer), amount),
            abi.encode(true)
        );

        // Call the transfer function
        routerTesting.exposed_transferSplit(recipient, strategies[0], amount);

        // Verify the ETH balance of the recipient increased
        assertEq(recipient.balance, transformedAmount, "Recipient should receive 90% of original amount");
    }
}
