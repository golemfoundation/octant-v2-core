// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";

import { KontrolTest } from "test/kontrol/KontrolTest.k.sol";
import { TestERC20 } from "test/kontrol/TestERC20.k.sol";
import { MockSimpleStrategy } from "test/kontrol/MockSimpleStrategy.k.sol";
import "test/kontrol/YDStateSlots.k.sol";

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

    function setUp() public {
        vm.assume(msg.sender == address(this));

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
        _storeAddress(address(strategy), YD_ASSET_SLOT, _asset);
        _storeAddress(address(strategy), YD_MANAGEMENT_SLOT, _management);
        _storeAddress(address(strategy), YD_KEEPER_SLOT, _keeper);
        _storeAddress(address(strategy), YD_EMERGENCY_ADMIN_SLOT, _emergencyAdmin);
        _storeAddress(address(strategy), YD_DRAGON_ROUTER_SLOT, _dragonRouter);

        // Symbolic totalSupply and totalAssets
        uint256 totalSupply = freshUInt256Bounded();
        _storeUInt256(address(strategy), YD_TOTAL_SUPPLY_SLOT, totalSupply);
        uint256 totalAssets = freshUInt256Bounded();
        _storeUInt256(address(strategy), YD_TOTAL_ASSETS_SLOT, totalAssets);

        // Flags: decimals=18, entered=NOT_ENTERED(1), shutdown=false(0), enableBurning=true(1)
        _storeData(address(strategy), YD_FLAGS_SLOT, YD_DECIMALS_OFFSET, YD_DECIMALS_WIDTH, 18);
        _storeData(address(strategy), YD_FLAGS_SLOT, YD_ENTERED_OFFSET, YD_ENTERED_WIDTH, 1);
        _storeData(address(strategy), YD_FLAGS_SLOT, YD_SHUTDOWN_OFFSET, YD_SHUTDOWN_WIDTH, 0);
        _storeData(address(strategy), YD_FLAGS_SLOT, YD_ENABLE_BURNING_OFFSET, YD_ENABLE_BURNING_WIDTH, 1);

        // Disable health check for core invariant proofs (focus on report logic)
        _storeData(address(strategy), YD_HC_SLOT, YD_HC_DO_HEALTH_CHECK_OFFSET, YD_HC_DO_HEALTH_CHECK_WIDTH, 0);

        // Symbolic dragon router balance
        uint256 dragonBalance = freshUInt256Bounded();
        _storeMappingUInt256(address(strategy), YD_BALANCES_SLOT, uint256(uint160(_dragonRouter)), 0, dragonBalance);

        // Warp to a later timestamp
        currentTimestamp = freshUInt256Bounded();
        vm.assume(deploymentTimestamp < currentTimestamp);
        vm.warp(currentTimestamp);
    }
}
