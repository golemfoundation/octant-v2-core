// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";

import { StrategyBaseTest } from "test/kontrol/StrategyBaseTest.k.sol";
import { YDSetup } from "test/kontrol/YDSetup.k.sol";
import "test/kontrol/SharedStateSlots.k.sol";

struct YDProofState {
    uint256 totalAssets;
    uint256 totalSupply;
    uint256 dragonBalance;
}

uint256 constant DECIMALS_OFFSET = 6;

/**
 * @title YDStrategyTest
 * @notice Kontrol formal verification proofs for YieldDonatingTokenizedStrategy
 * @dev Inherits 7 common proofs from StrategyBaseTest and adds 5 YD-specific proofs:
 *      - testReportProfit: OpenZeppelin-style offset shares minted to dragon, virtual PPS non-decreasing
 *      - testReportLossInsufficientDragon: partial burn, PPS impact bounded
 *      - testSharesRedeemableAfterDepositYD: deposit produces redeemable shares
 *      - testConversionConsistencyYD: round-trip does not create value
 *      - testDustLossRecoveryFlowMintsDragonAndBlocksFinalDustBurn:
 *          recovery from totalAssets=0,totalSupply=1 mints dragon shares and traps dust
 */
contract YDStrategyTest is StrategyBaseTest, YDSetup {
    YDProofState private preState;
    YDProofState private postState;

    function setUp() public override(YDSetup) {
        YDSetup.setUp();
    }

    /*//////////////////////////////////////////////////////////////
                    VIRTUAL ACCESSORS
    //////////////////////////////////////////////////////////////*/

    function getStrategy() internal view override returns (ITokenizedStrategy) {
        return iStrategy;
    }

    function getStrategyAddr() internal view override returns (address) {
        return address(strategy);
    }

    function getKeeper() internal view override returns (address) {
        return _keeper;
    }

    function getDragonRouter() internal view override returns (address) {
        return _dragonRouter;
    }

    function getAssetAddr() internal view override returns (address) {
        return _asset;
    }

    function getManagement() internal view override returns (address) {
        return _management;
    }

    /*//////////////////////////////////////////////////////////////
                    VIRTUAL HOOKS
    //////////////////////////////////////////////////////////////*/

    function _setupReportNoChange(uint256 totalAssets) internal override {
        _storeUInt256(address(strategy), MOCK_NEXT_TOTAL_ASSETS_SLOT, totalAssets);
    }

    function _setupLossScenario(uint256 totalAssets) internal override {
        uint256 newTotalAssets = freshUInt256Bounded();
        vm.assume(newTotalAssets < totalAssets);
        _storeUInt256(address(strategy), MOCK_NEXT_TOTAL_ASSETS_SLOT, newTotalAssets);
    }

    function _assertReportNoChangeExtras() internal view override {
        // YD has no extra state to check
    }

    function _assertTendExtras() internal view override {
        // YD has no extra state to check
    }

    /*//////////////////////////////////////////////////////////////
                    HELPERS
    //////////////////////////////////////////////////////////////*/

    function _snapshot() internal view returns (YDProofState memory state) {
        state.totalAssets = _loadUInt256(address(strategy), TS_TOTAL_ASSETS_SLOT);
        state.totalSupply = _loadUInt256(address(strategy), TS_TOTAL_SUPPLY_SLOT);
        state.dragonBalance = _loadMappingUInt256(
            address(strategy),
            TS_BALANCES_SLOT,
            uint256(uint160(_dragonRouter)),
            0
        );
    }

    /*//////////////////////////////////////////////////////////////
                    INVARIANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice OpenZeppelin-style offset PPS does not decrease:
    ///         (totalAssets_new + 1) * (totalSupply_old + 10 ** DECIMALS_OFFSET)
    ///         >= (totalAssets_old + 1) * (totalSupply_new + 10 ** DECIMALS_OFFSET)
    function ppsNonDecreasingInvariant(Mode mode) internal view {
        _establish(
            mode,
            (postState.totalAssets + 1) * (preState.totalSupply + 10 ** DECIMALS_OFFSET) >=
                (preState.totalAssets + 1) * (postState.totalSupply + 10 ** DECIMALS_OFFSET)
        );
    }

    /// @notice totalAssets updated to the expected value
    function totalAssetsUpdatedCorrectly(Mode mode, uint256 expectedTotalAssets) internal view {
        _establish(mode, postState.totalAssets == expectedTotalAssets);
    }

    /// @notice Dragon balance does not exceed totalSupply
    function dragonBalanceBoundedBySupply(Mode mode) internal view {
        _establish(mode, postState.dragonBalance <= postState.totalSupply);
    }

    /*//////////////////////////////////////////////////////////////
                    YD-SPECIFIC: REPORT WITH PROFIT
    //////////////////////////////////////////////////////////////*/

    /// @notice When report harvests a profit, shares are minted to dragon router
    ///         and OpenZeppelin-style offset PPS is preserved (non-decreasing) for regular holders
    function testReportProfit() public {
        _assumeNonReentrant();

        address stratAddr = getStrategyAddr();
        _storeData(stratAddr, HC_SLOT, HC_DO_HEALTH_CHECK_OFFSET, HC_DO_HEALTH_CHECK_WIDTH, 0);

        preState = _snapshot();

        // Valid pre-state
        vm.assume(preState.totalAssets > 0);
        vm.assume(preState.totalSupply > 0);
        vm.assume(preState.dragonBalance <= preState.totalSupply);

        // Profit scenario: newTotalAssets > oldTotalAssets
        uint256 newTotalAssets = freshUInt256Bounded();
        vm.assume(newTotalAssets > preState.totalAssets);
        _storeUInt256(address(strategy), MOCK_NEXT_TOTAL_ASSETS_SLOT, newTotalAssets);

        // Avoid overflow in sharesToMint = profit * (totalSupply + 10 ** DECIMALS_OFFSET) / (totalAssets + 1)
        uint256 profit = newTotalAssets - preState.totalAssets;
        uint256 virtualSupply = preState.totalSupply + 10 ** DECIMALS_OFFSET;
        uint256 virtualAssets = preState.totalAssets + 1;
        _assumeNoOverflow(profit, virtualSupply);

        // Avoid overflow in totalSupply + sharesToMint
        uint256 sharesToMint = (profit * virtualSupply) / virtualAssets;
        _assumeNoOverflow(preState.totalSupply, sharesToMint);

        // Avoid overflow in dragonBalance + sharesToMint
        _assumeNoOverflow(preState.dragonBalance, sharesToMint);

        vm.startPrank(_keeper);
        iStrategy.report();
        vm.stopPrank();

        postState = _snapshot();

        // Assertions
        ppsNonDecreasingInvariant(Mode.Assert);
        totalAssetsUpdatedCorrectly(Mode.Assert, newTotalAssets);
        dragonBalanceBoundedBySupply(Mode.Assert);

        // Dragon received shares
        _establish(Mode.Assert, postState.dragonBalance >= preState.dragonBalance);
        // totalSupply increased
        _establish(Mode.Assert, postState.totalSupply >= preState.totalSupply);
    }

    /*//////////////////////////////////////////////////////////////
                    YD-SPECIFIC: REPORT WITH LOSS (INSUFFICIENT DRAGON)
    //////////////////////////////////////////////////////////////*/

    /// @notice When dragon can't cover the full loss, all its shares are burned
    ///         and the remaining loss reduces PPS
    function testReportLossInsufficientDragon() public {
        _assumeNonReentrant();

        address stratAddr = getStrategyAddr();
        _storeData(stratAddr, HC_SLOT, HC_DO_HEALTH_CHECK_OFFSET, HC_DO_HEALTH_CHECK_WIDTH, 0);

        // Enable burning
        _storeData(address(strategy), TS_FLAGS_SLOT, TS_ENABLE_BURNING_OFFSET, TS_ENABLE_BURNING_WIDTH, 1);

        preState = _snapshot();

        // Valid pre-state
        vm.assume(preState.totalAssets > 0);
        vm.assume(preState.totalSupply > 0);
        vm.assume(preState.dragonBalance > 0);
        vm.assume(preState.dragonBalance <= preState.totalSupply);

        // Loss scenario where dragon can't cover
        uint256 newTotalAssets = freshUInt256Bounded();
        vm.assume(newTotalAssets < preState.totalAssets);
        vm.assume(newTotalAssets > 0);
        _storeUInt256(address(strategy), MOCK_NEXT_TOTAL_ASSETS_SLOT, newTotalAssets);

        uint256 loss = preState.totalAssets - newTotalAssets;
        uint256 virtualSupply = preState.totalSupply + 10 ** DECIMALS_OFFSET;
        uint256 virtualAssets = preState.totalAssets + 1;
        _assumeNoOverflow(loss, virtualSupply);
        uint256 sharesToBurn = Math.mulDiv(loss, virtualSupply, virtualAssets, Math.Rounding.Floor);
        vm.assume(sharesToBurn > preState.dragonBalance);

        vm.startPrank(_keeper);
        iStrategy.report();
        vm.stopPrank();

        postState = _snapshot();

        // totalAssets still updated correctly
        totalAssetsUpdatedCorrectly(Mode.Assert, newTotalAssets);
        // All dragon shares burned
        assertEq(postState.dragonBalance, 0);
        // totalSupply decreased by exactly the dragon balance
        assertEq(postState.totalSupply, preState.totalSupply - preState.dragonBalance);
    }

    /*//////////////////////////////////////////////////////////////
                    YD-SPECIFIC: DEPOSIT PRODUCES REDEEMABLE SHARES
    //////////////////////////////////////////////////////////////*/

    /// @notice After deposit, shares are redeemable (inductive balance bounded proof)
    function testSharesRedeemableAfterDepositYD(uint256 assets, address receiver) public {
        _assumeNonReentrant();

        vm.assume(assets > 0);
        vm.assume(assets < ETH_UPPER_BOUND);
        vm.assume(receiver != address(0));
        vm.assume(receiver != address(strategy));
        vm.assume(receiver != _dragonRouter);

        uint256 totalAssets = _loadUInt256(address(strategy), TS_TOTAL_ASSETS_SLOT);
        uint256 totalSupply = _loadUInt256(address(strategy), TS_TOTAL_SUPPLY_SLOT);
        vm.assume(totalAssets > 0);
        vm.assume(totalSupply > 0);

        uint256 virtualSupply = totalSupply + 10 ** DECIMALS_OFFSET;
        uint256 virtualAssets = totalAssets + 1;
        _assumeNoOverflow(assets, virtualSupply);
        uint256 expectedShares = (assets * virtualSupply) / virtualAssets;
        vm.assume(expectedShares > 0);
        _assumeNoOverflow(totalSupply, expectedShares);
        _assumeNoOverflow(totalAssets, assets);

        // Inductive hypothesis: receiver's balance is bounded by totalSupply pre-deposit.
        uint256 receiverBalance = _loadMappingUInt256(
            address(strategy),
            TS_BALANCES_SLOT,
            uint256(uint160(receiver)),
            0
        );
        vm.assume(receiverBalance <= totalSupply);

        // Not shutdown
        _storeData(address(strategy), TS_FLAGS_SLOT, TS_SHUTDOWN_OFFSET, TS_SHUTDOWN_WIDTH, 0);

        address depositor = makeAddr("DEPOSITOR");
        _storeMappingUInt256(_asset, ERC20_BALANCES_SLOT, uint256(uint160(depositor)), 0, assets);
        vm.prank(depositor);
        (bool ok, ) = _asset.call(abi.encodeWithSignature("approve(address,uint256)", address(strategy), assets));
        require(ok);

        _storeMappingUInt256(_asset, ERC20_BALANCES_SLOT, uint256(uint160(address(strategy))), 0, totalAssets);

        vm.prank(depositor);
        iStrategy.deposit(assets, receiver);

        _assertSharesRedeemable(receiver);
        _assertBalanceBounded(receiver);
    }

    /*//////////////////////////////////////////////////////////////
                    YD-SPECIFIC: CONVERSION CONSISTENCY
    //////////////////////////////////////////////////////////////*/

    /// @notice Conversion round-trip does not create value
    function testConversionConsistencyYD(uint256 amount) public {
        _assumeNonReentrant();

        vm.assume(amount > 0);
        vm.assume(amount < ETH_UPPER_BOUND);

        uint256 totalAssets = _loadUInt256(address(strategy), TS_TOTAL_ASSETS_SLOT);
        uint256 totalSupply = _loadUInt256(address(strategy), TS_TOTAL_SUPPLY_SLOT);
        vm.assume(totalAssets > 0);
        vm.assume(totalSupply > 0);

        // Avoid overflow in mulDiv
        _assumeNoOverflow(amount, totalSupply);
        _assumeNoOverflow(amount, totalAssets);

        _assertConversionConsistency(amount);
    }

    /*//////////////////////////////////////////////////////////////
                    YD-SPECIFIC: DUST LOSS RECOVERY FLOW
    //////////////////////////////////////////////////////////////*/

    /// @notice Regression for the Bailsec dust-loss-recovery chain.
    ///         From totalAssets=0,totalSupply=1, any positive recovery report
    ///         assigns the recovered assets to dragon through the virtual-offset
    ///         converter, and the original dust share cannot withdraw 1 wei afterward.
    function testDustLossRecoveryFlowMintsDragonAndBlocksFinalDustBurn(uint256 recoveredAssets) public {
        _assumeNonReentrant();

        address stratAddr = getStrategyAddr();
        address dustHolder = makeAddr("DUST_HOLDER");

        _storeData(stratAddr, HC_SLOT, HC_DO_HEALTH_CHECK_OFFSET, HC_DO_HEALTH_CHECK_WIDTH, 0);
        _storeData(stratAddr, TS_FLAGS_SLOT, TS_SHUTDOWN_OFFSET, TS_SHUTDOWN_WIDTH, 0);
        _storeData(stratAddr, TS_FLAGS_SLOT, TS_ENABLE_BURNING_OFFSET, TS_ENABLE_BURNING_WIDTH, 0);

        vm.assume(recoveredAssets > 0);
        vm.assume(recoveredAssets < ETH_UPPER_BOUND / 2);

        _storeUInt256(stratAddr, TS_TOTAL_ASSETS_SLOT, 0);
        _storeUInt256(stratAddr, TS_TOTAL_SUPPLY_SLOT, 1);
        _storeMappingUInt256(stratAddr, TS_BALANCES_SLOT, uint256(uint160(dustHolder)), 0, 1);
        _storeMappingUInt256(stratAddr, TS_BALANCES_SLOT, uint256(uint160(_dragonRouter)), 0, 0);
        _storeUInt256(stratAddr, MOCK_NEXT_TOTAL_ASSETS_SLOT, recoveredAssets);

        vm.startPrank(_keeper);
        iStrategy.report();
        vm.stopPrank();

        uint256 expectedDragonShares = recoveredAssets * (1 + 10 ** DECIMALS_OFFSET);
        assertEq(iStrategy.totalAssets(), recoveredAssets);
        assertEq(iStrategy.balanceOf(_dragonRouter), expectedDragonShares);
        assertEq(iStrategy.totalSupply(), expectedDragonShares + 1);
        assertEq(iStrategy.maxWithdraw(dustHolder), 0);
    }
}
