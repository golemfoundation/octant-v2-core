// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";
import { TokenizedStrategy__FinalWithdrawLeavesAssets } from "src/errors.sol";

import { StrategyBaseTest } from "test/kontrol/StrategyBaseTest.k.sol";
import { YDSetup } from "test/kontrol/YDSetup.k.sol";
import "test/kontrol/SharedStateSlots.k.sol";

struct YDProofState {
    uint256 totalAssets;
    uint256 totalSupply;
    uint256 dragonBalance;
}

/**
 * @title YDStrategyTest
 * @notice Kontrol formal verification proofs for YieldDonatingTokenizedStrategy
 * @dev Inherits common proofs from StrategyBaseTest and adds YD-specific proofs:
 *      - testReportProfit: shares minted to dragon, PPS non-decreasing
 *      - testReportZeroAssetRecoveryMintsOnlySurplusDragonShares: recovered surplus mints dragon shares
 *      - testWithdrawFinalShareCannotLeaveTrackedAssets: final-share withdraw cannot strand assets
 *      - testDepositBlockedWhenSupplyZeroAssetsPositive: stranded-asset state blocks first deposits
 *      - testReportLossInsufficientDragon: partial burn, PPS impact bounded
 *      - testSharesRedeemableAfterDepositYD: deposit produces redeemable shares
 *      - testConversionConsistencyYD: round-trip does not create value
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

    /// @notice PPS does not decrease: totalAssets_new * totalSupply_old >= totalAssets_old * totalSupply_new
    function ppsNonDecreasingInvariant(Mode mode) internal view {
        _establish(mode, postState.totalAssets * preState.totalSupply >= preState.totalAssets * postState.totalSupply);
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
    ///         and PPS is preserved (non-decreasing) for regular holders
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

        // Avoid overflow in sharesToMint = profit * totalSupply / totalAssets
        uint256 profit = newTotalAssets - preState.totalAssets;
        _assumeNoOverflow(profit, preState.totalSupply);

        // Avoid overflow in totalSupply + sharesToMint
        uint256 sharesToMint = (profit * preState.totalSupply) / preState.totalAssets;
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

    /// @notice If totalAssets is zero while supply remains nonzero, later recovery
    ///         must preserve existing share principal first and mint only recovered
    ///         surplus to dragon.
    function testReportZeroAssetRecoveryMintsOnlySurplusDragonShares() public {
        _assumeNonReentrant();

        address stratAddr = getStrategyAddr();
        _storeData(stratAddr, HC_SLOT, HC_DO_HEALTH_CHECK_OFFSET, HC_DO_HEALTH_CHECK_WIDTH, 0);

        uint256 oldSupply = freshUInt256Bounded();
        vm.assume(oldSupply > 0);
        uint256 dragonBalance = freshUInt256Bounded();
        vm.assume(dragonBalance <= oldSupply);

        _storeUInt256(stratAddr, TS_TOTAL_ASSETS_SLOT, 0);
        _storeUInt256(stratAddr, TS_TOTAL_SUPPLY_SLOT, oldSupply);
        _storeMappingUInt256(stratAddr, TS_BALANCES_SLOT, uint256(uint160(_dragonRouter)), 0, dragonBalance);

        uint256 recoveredAssets = freshUInt256Bounded();
        vm.assume(recoveredAssets > oldSupply);
        _assumeNoOverflow(dragonBalance, recoveredAssets);
        _storeUInt256(stratAddr, MOCK_NEXT_TOTAL_ASSETS_SLOT, recoveredAssets);

        uint256 surplusShares = recoveredAssets - oldSupply;

        vm.startPrank(_keeper);
        iStrategy.report();
        vm.stopPrank();

        assertEq(_loadUInt256(stratAddr, TS_TOTAL_ASSETS_SLOT), recoveredAssets);
        assertEq(_loadUInt256(stratAddr, TS_TOTAL_SUPPLY_SLOT), recoveredAssets);
        assertEq(
            _loadMappingUInt256(stratAddr, TS_BALANCES_SLOT, uint256(uint160(_dragonRouter)), 0),
            dragonBalance + surplusShares
        );
    }

    /// @notice After surplus recovery refills totalSupply to totalAssets,
    ///         principal and surplus shares redeem 1:1.
    function testReportZeroAssetRecoverySurplusRedeemableOneToOne() public {
        _assumeNonReentrant();

        address stratAddr = getStrategyAddr();
        uint256 oldSupply = 100 ether;
        uint256 recoveredAssets = 150 ether;
        uint256 surplusShares = recoveredAssets - oldSupply;

        _storeData(stratAddr, HC_SLOT, HC_DO_HEALTH_CHECK_OFFSET, HC_DO_HEALTH_CHECK_WIDTH, 0);
        _storeUInt256(stratAddr, TS_TOTAL_ASSETS_SLOT, 0);
        _storeUInt256(stratAddr, TS_TOTAL_SUPPLY_SLOT, oldSupply);
        _storeMappingUInt256(stratAddr, TS_BALANCES_SLOT, uint256(uint160(_dragonRouter)), 0, 0);
        _storeUInt256(stratAddr, MOCK_NEXT_TOTAL_ASSETS_SLOT, recoveredAssets);

        vm.startPrank(_keeper);
        iStrategy.report();
        vm.stopPrank();

        assertEq(iStrategy.convertToAssets(oldSupply), oldSupply);
        assertEq(iStrategy.convertToAssets(surplusShares), surplusShares);
    }

    /// @notice If recovery is at or below outstanding supply, existing holders
    ///         keep the recovered principal and dragon receives no new shares.
    function testReportZeroAssetRecoveryPreservesPrincipalWhenRecoveryAtOrBelowSupply() public {
        _assumeNonReentrant();

        address stratAddr = getStrategyAddr();
        address lossHolder = makeAddr("LOSS_HOLDER");
        _storeData(stratAddr, HC_SLOT, HC_DO_HEALTH_CHECK_OFFSET, HC_DO_HEALTH_CHECK_WIDTH, 0);

        uint256 oldSupply = freshUInt256Bounded();
        vm.assume(oldSupply > 0);
        uint256 recoveredAssets = freshUInt256Bounded();
        vm.assume(recoveredAssets > 0);
        vm.assume(recoveredAssets <= oldSupply);

        _storeUInt256(stratAddr, TS_TOTAL_ASSETS_SLOT, 0);
        _storeUInt256(stratAddr, TS_TOTAL_SUPPLY_SLOT, oldSupply);
        _storeMappingUInt256(stratAddr, TS_BALANCES_SLOT, uint256(uint160(lossHolder)), 0, oldSupply);
        _storeMappingUInt256(stratAddr, TS_BALANCES_SLOT, uint256(uint160(_dragonRouter)), 0, 0);
        _storeUInt256(stratAddr, MOCK_NEXT_TOTAL_ASSETS_SLOT, recoveredAssets);

        vm.startPrank(_keeper);
        iStrategy.report();
        vm.stopPrank();

        assertEq(_loadUInt256(stratAddr, TS_TOTAL_ASSETS_SLOT), recoveredAssets);
        assertEq(_loadUInt256(stratAddr, TS_TOTAL_SUPPLY_SLOT), oldSupply);
        assertEq(_loadMappingUInt256(stratAddr, TS_BALANCES_SLOT, uint256(uint160(lossHolder)), 0), oldSupply);
        assertEq(_loadMappingUInt256(stratAddr, TS_BALANCES_SLOT, uint256(uint160(_dragonRouter)), 0), 0);
        assertEq(iStrategy.convertToAssets(oldSupply), recoveredAssets);
    }

    /// @notice A withdraw that burns the final share must remove all tracked assets.
    ///         Otherwise the strategy would enter totalSupply == 0 && totalAssets > 0.
    function testWithdrawFinalShareCannotLeaveTrackedAssets() public {
        _assumeNonReentrant();

        address stratAddr = getStrategyAddr();
        address owner = makeAddr("FINAL_SHARE_OWNER");

        uint256 trackedAssets = freshUInt256Bounded();
        vm.assume(trackedAssets > 1);

        _storeUInt256(stratAddr, TS_TOTAL_ASSETS_SLOT, trackedAssets);
        _storeUInt256(stratAddr, TS_TOTAL_SUPPLY_SLOT, 1);
        _storeMappingUInt256(stratAddr, TS_BALANCES_SLOT, uint256(uint160(owner)), 0, 1);
        _storeMappingUInt256(_asset, ERC20_BALANCES_SLOT, uint256(uint160(stratAddr)), 0, trackedAssets);

        vm.startPrank(owner);
        vm.expectRevert(TokenizedStrategy__FinalWithdrawLeavesAssets.selector);
        iStrategy.withdraw(1, owner, owner, 0);
        vm.stopPrank();
    }

    /// @notice If a zero-supply/positive-assets state is ever present, deposits
    ///         are blocked instead of being priced as first deposits.
    function testDepositBlockedWhenSupplyZeroAssetsPositive() public {
        _assumeNonReentrant();

        address stratAddr = getStrategyAddr();
        address depositor = makeAddr("STRANDED_ASSET_DEPOSITOR");

        uint256 strandedAssets = freshUInt256Bounded();
        vm.assume(strandedAssets > 0);

        _storeUInt256(stratAddr, TS_TOTAL_ASSETS_SLOT, strandedAssets);
        _storeUInt256(stratAddr, TS_TOTAL_SUPPLY_SLOT, 0);

        assertEq(iStrategy.convertToShares(1), 0);
        assertEq(iStrategy.convertToAssets(1), 0);
        assertEq(iStrategy.maxDeposit(depositor), 0);
        assertEq(iStrategy.maxMint(depositor), 0);
        assertEq(iStrategy.previewDeposit(1), 0);
        assertEq(iStrategy.previewMint(1), 0);

        _storeMappingUInt256(_asset, ERC20_BALANCES_SLOT, uint256(uint160(depositor)), 0, 1);
        vm.prank(depositor);
        (bool ok, ) = _asset.call(abi.encodeWithSignature("approve(address,uint256)", stratAddr, 1));
        require(ok);

        vm.startPrank(depositor);
        vm.expectRevert("ERC4626: deposit more than max");
        iStrategy.deposit(1, depositor);
        vm.stopPrank();

        vm.startPrank(depositor);
        vm.expectRevert("ERC4626: mint more than max");
        iStrategy.mint(1, depositor);
        vm.stopPrank();
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
        _assumeNoOverflow(loss, preState.totalSupply);
        uint256 sharesToBurn = Math.ceilDiv(loss * preState.totalSupply, preState.totalAssets);
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

        _assumeNoOverflow(assets, totalSupply);
        uint256 expectedShares = (assets * totalSupply) / totalAssets;
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
}
