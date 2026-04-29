// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";

import { KontrolTest } from "test/kontrol/KontrolTest.k.sol";
import { TestERC20 } from "test/kontrol/TestERC20.k.sol";
import { MockSimpleStrategy } from "test/kontrol/MockSimpleStrategy.k.sol";
import "test/kontrol/SharedStateSlots.k.sol";

/**
 * @title YDSetup
 * @notice Symbolic setup for formal verification of YieldDonatingTokenizedStrategy
 * @dev Deploys a MockSimpleStrategy using YieldDonatingTokenizedStrategy as the
 *      delegatecall implementation. Makes storage symbolic, then restores concrete
 *      addresses for roles to avoid excessive branching in the symbolic executor.
 */
contract YDSetup is KontrolTest {
    YieldDonatingTokenizedStrategy public implementation;
    MockSimpleStrategy public strategy;
    ITokenizedStrategy public iStrategy;

    address public _asset;
    address internal _management;
    address internal _keeper;
    address internal _emergencyAdmin;
    address internal _dragonRouter;

    uint256 deploymentTimestamp;
    uint256 currentTimestamp;

    function setUp() public virtual {
        // Concrete role addresses (avoid symbolic branching on prank)
        _management = makeAddr("MANAGEMENT");
        _keeper = makeAddr("KEEPER");
        _emergencyAdmin = makeAddr("EMERGENCY_ADMIN");
        _dragonRouter = makeAddr("DRAGON_ROUTER");

        // Deploy mock ERC20 asset
        TestERC20 erc20 = new TestERC20();
        _asset = address(erc20);

        // Deploy the YieldDonatingTokenizedStrategy implementation
        implementation = new YieldDonatingTokenizedStrategy();

        // Deploy mock strategy (BaseStrategy constructor calls initialize via delegatecall)
        deploymentTimestamp = freshUInt256Bounded();
        vm.warp(deploymentTimestamp);

        strategy = new MockSimpleStrategy(
            _asset,
            "Test YD Strategy",
            "tYDS",
            _management,
            _keeper,
            _emergencyAdmin,
            _dragonRouter,
            true, // enableBurning
            address(implementation)
        );

        iStrategy = ITokenizedStrategy(address(strategy));

        // ============================================
        // MAKE STORAGE SYMBOLIC
        // ============================================
        kevm.symbolicStorage(address(strategy));

        // ============================================
        // RESTORE CONCRETE VALUES
        // ============================================
        // Addresses must be concrete to avoid excessive branching on
        // prank cheatcode and access control checks.
        _storeAddress(address(strategy), TS_ASSET_SLOT, _asset);
        _storeAddress(address(strategy), TS_MANAGEMENT_SLOT, _management);
        _storeAddress(address(strategy), TS_KEEPER_SLOT, _keeper);
        _storeAddress(address(strategy), TS_EMERGENCY_ADMIN_SLOT, _emergencyAdmin);
        _storeAddress(address(strategy), TS_DRAGON_ROUTER_SLOT, _dragonRouter);

        // Symbolic totalSupply and totalAssets, preserving the locked protocol seed.
        uint256 seedBalance = implementation.MINIMUM_PROTOCOL_POSITION();
        uint256 totalSupply = seedBalance + freshUInt256Bounded();
        _storeUInt256(address(strategy), TS_TOTAL_SUPPLY_SLOT, totalSupply);
        uint256 totalAssets = freshUInt256Bounded();
        _storeUInt256(address(strategy), TS_TOTAL_ASSETS_SLOT, totalAssets);
        _storeMappingUInt256(address(strategy), TS_BALANCES_SLOT, uint256(uint160(address(strategy))), 0, seedBalance);

        // Flags: decimals=18, entered=NOT_ENTERED(1), shutdown=false(0), enableBurning=true(1)
        _storeData(address(strategy), TS_FLAGS_SLOT, TS_DECIMALS_OFFSET, TS_DECIMALS_WIDTH, 18);
        _storeData(address(strategy), TS_FLAGS_SLOT, TS_ENTERED_OFFSET, TS_ENTERED_WIDTH, 1);
        _storeData(address(strategy), TS_FLAGS_SLOT, TS_SHUTDOWN_OFFSET, TS_SHUTDOWN_WIDTH, 0);
        _storeData(address(strategy), TS_FLAGS_SLOT, TS_ENABLE_BURNING_OFFSET, TS_ENABLE_BURNING_WIDTH, 1);

        // Disable health check for core invariant proofs (focus on report logic)
        _storeData(address(strategy), HC_SLOT, HC_DO_HEALTH_CHECK_OFFSET, HC_DO_HEALTH_CHECK_WIDTH, 0);

        // Symbolic dragon router balance
        uint256 dragonBalance = freshUInt256Bounded();
        vm.assume(dragonBalance <= totalSupply - seedBalance);
        _storeMappingUInt256(address(strategy), TS_BALANCES_SLOT, uint256(uint160(_dragonRouter)), 0, dragonBalance);

        // Warp to a later timestamp
        currentTimestamp = freshUInt256Bounded();
        vm.assume(deploymentTimestamp < currentTimestamp);
        vm.warp(currentTimestamp);
    }
}
