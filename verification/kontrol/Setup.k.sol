// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import { DragonRouter } from "src/zodiac-core/DragonRouter.sol";
import { SplitChecker } from "src/zodiac-core/SplitChecker.sol";
import { DragonTokenizedStrategy } from "src/zodiac-core/vaults/DragonTokenizedStrategy.sol";

import "@gnosis.pm/safe-contracts/contracts/Safe.sol";

import { YearnPolygonUsdcStrategy } from "src/zodiac-core/modules/YearnPolygonUsdcStrategy.sol";
import { IStrategy } from "src/zodiac-core/interfaces/IStrategy.sol";

import { TestERC20 } from "test/kontrol/TestERC20.k.sol";
import { BaseTest } from "test/kontrol/Base.k.sol";
import { MockYieldSource } from "test/kontrol/MockYieldSource.k.sol";
import "test/kontrol/StrategyStateSlots.k.sol";

import { KontrolTest } from "test/kontrol/KontrolTest.k.sol";

contract Setup is BaseTest, KontrolTest {
    DragonTokenizedStrategy public dragonTokenizedStrategySingleton;
    /// @notice The deployed DragonRouter
    DragonRouter public dragonRouter;

    YearnPolygonUsdcStrategy public polygonStrategy;

    /// @dev Yearn Polygon Aave V3 USDC Lender Vault
    address public YIELD_SOURCE;

    /// @dev USDC Polygon
    address public _asset;

    address internal safeOwner;
    address internal _management;
    address internal _keeper;
    address internal _regenGovernance;
    address internal _emergencyAdmin;

    uint256 maxReportDelay;

    IStrategy strategy;

    uint256 deploymentTimestamp;
    uint256 currentTimestamp;

    function deploySplitChecker() private returns (SplitChecker) {
        /// The deployed SplitChecker implementation
        SplitChecker splitChecker;

        /// Default configuration values
        uint256 DEFAULT_MAX_OPEX_SPLIT = 0.5e18;
        uint256 DEFAULT_MIN_METAPOOL_SPLIT = 0.05e18;

        splitChecker = new SplitChecker();
        splitChecker.initialize(makeAddr("GOVERNANCE"), DEFAULT_MAX_OPEX_SPLIT, DEFAULT_MIN_METAPOOL_SPLIT);

        return splitChecker;
    }

    function deployDragonRouter() private {
        // The deployed DragonRouter implementation
        dragonRouter = new DragonRouter();

        // setup empty strategies and assets
        address[] memory strategies = new address[](0);
        address[] memory assets = new address[](0);

        // Deploy Spli Checker
        SplitChecker splitChecker = deploySplitChecker();

        bytes memory initData = abi.encode(
            msg.sender, // owner
            abi.encode(
                strategies, // initial strategies array
                assets, // initial assets array
                msg.sender, // governance address
                msg.sender, // regen governance address
                address(splitChecker), // split checker address
                msg.sender, // opex vault address
                msg.sender // metapool address
            )
        );

        dragonRouter.setUp(initData);
    }

    function strategySetup() private {
        // Prepare initialization data
        // First encode the strategy initialization parameters

        // TODO: make it symbolic later
        maxReportDelay = 7 days;

        bytes memory strategyParams = abi.encode(
            address(dragonTokenizedStrategySingleton),
            _management,
            _keeper,
            address(dragonRouter),
            maxReportDelay,
            _regenGovernance
        );

        _testTemps(address(polygonStrategy));
        safeOwner = address(safe);

        // Set the initialize storage to 0 to allow initialization
        bytes32 initializeSlot = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
        _clearSlot(address(polygonStrategy), uint256(initializeSlot));
        _clearSlot(address(polygonStrategy), ASSET_SLOT);
        _clearSlot(address(polygonStrategy), NAME_SLOT);

        deploymentTimestamp = freshUInt256Bounded("deploymentTimestamp");
        vm.warp(deploymentTimestamp);
        polygonStrategy.setUp(abi.encode(safeOwner, strategyParams));
        strategy = IStrategy(address(polygonStrategy));
    }

    function etchPolygonAddresses() private {
        TestERC20 erc20ReferenceImplementation = new TestERC20();
        vm.etch(_asset, address(erc20ReferenceImplementation).code);
        // TODO: Make storage symbolic

        // TODO: MockYieldSource is just a model of the YIELD_SOURCE implementation
        MockYieldSource mockYieldferenceImplementation = new MockYieldSource();
        vm.etch(YIELD_SOURCE, address(mockYieldferenceImplementation).code);

        // TODO: Make storage symbolic
        MockYieldSource(YIELD_SOURCE).setUp(_asset);
    }

    function symbolicSetup() private {
        uint256 totalSupply = freshUInt256Bounded("statetotalSupply");
        _storeUInt256(address(polygonStrategy), TOTAL_SUPLLY_SLOT, totalSupply);
        uint256 totalAssets = freshUInt256Bounded("stateTotalAssets");
        _storeUInt256(address(polygonStrategy), TOTAL_ASSETS_SLOT, totalAssets);

        // Emergency admin is concrete to avoid branching on prank cheatcode
        _emergencyAdmin = makeAddr("emergencyAdmin");
        _storeAddress(address(polygonStrategy), EMERGENCY_ADMIN_SLOT, _emergencyAdmin);

        // TODO: Set MINIMUM_LOCKUP_DURATION and RAGE_QUIT_COOLDOWN_PERIOD to symbolic variables and add invariant
        // about their ranges
    }

    function setUp() public {
        vm.assume(msg.sender == address(this));

        YIELD_SOURCE = 0x52367C8E381EDFb068E9fBa1e7E9B2C847042897;
        _asset = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;

        _management = makeAddr("MANAGEMENT");
        _keeper = makeAddr("KEEPER");
        _regenGovernance = makeAddr("REGENGOVERNANCE");

        // NOTE The dragonTokenizedStrategySingleton.initialize method will be called during __BaseStrategy_init
        dragonTokenizedStrategySingleton = new DragonTokenizedStrategy();

        // Deploy Router
        // TODO Check what can be made symbolic in DragonRouter
        deployDragonRouter();

        _configure();

        etchPolygonAddresses();

        // Deploy and set up strategy
        polygonStrategy = new YearnPolygonUsdcStrategy();
        kevm.symbolicStorage(address(polygonStrategy));

        strategySetup();
        symbolicSetup();

        uint256 assetStrategyBalance = freshUInt256Bounded("assetStrategyBalance");
        uint256 yieldSourceStrategyBalance = freshUInt256Bounded("yieldSourceStrategyBalance");
        TestERC20(_asset).mint(address(strategy), assetStrategyBalance);
        TestERC20(_asset).mint(address(this), yieldSourceStrategyBalance);
        TestERC20(_asset).approve(address(YIELD_SOURCE), yieldSourceStrategyBalance);
        MockYieldSource(YIELD_SOURCE).mint(yieldSourceStrategyBalance, address(strategy));

        currentTimestamp = freshUInt256Bounded("currentTimestamp");
        vm.assume(deploymentTimestamp < currentTimestamp);
        vm.warp(currentTimestamp);
    }
}
