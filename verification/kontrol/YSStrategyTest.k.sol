// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";

import { WadRayMath } from "src/utils/libs/Maths/WadRay.sol";

import { StrategyBaseTest } from "test/kontrol/StrategyBaseTest.k.sol";
import { YSSetup } from "test/kontrol/YSSetup.k.sol";
import "test/kontrol/SharedStateSlots.k.sol";

struct YSProofState {
    uint256 totalAssets;
    uint256 totalSupply;
    uint256 dragonBalance;
    uint256 userDebt;
    uint256 dragonDebt;
}

/**
 * @title YSStrategyTest
 * @notice Kontrol formal verification proofs for YieldSkimmingTokenizedStrategy
 * @dev Inherits 4 common proofs from StrategyBaseTest (testTend, testReportNoChange,
 *      testReportLossNoBurning, testReportByManagement) and adds 11 YS-specific proofs.
 *
 *      Strategy-agnostic proofs (testReportOnlyKeeper, testShutdownBlocks, testBalanceBounded)
 *      run only under YDStrategyTest to avoid duplication.
 */
contract YSStrategyTest is StrategyBaseTest, YSSetup {
    using Math for uint256;
    using WadRayMath for uint256;

    YSProofState private preState;
    YSProofState private postState;

    function setUp() public override(YSSetup) {
        YSSetup.setUp();
    }

    /*//////////////////////////////////////////////////////////////
                    VIRTUAL ACCESSORS
    //////////////////////////////////////////////////////////////*/

    function getStrategy() internal view override returns (ITokenizedStrategy) {
        return iYSStrategy;
    }

    function getStrategyAddr() internal view override returns (address) {
        return address(ysStrategy);
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
        _storeUInt256(address(ysStrategy), MOCK_NEXT_TOTAL_ASSETS_SLOT, totalAssets);
        _storeMappingUInt256(_asset, ERC20_BALANCES_SLOT, uint256(uint160(address(ysStrategy))), 0, totalAssets);

        uint256 mockRate = _loadUInt256(address(ysStrategy), MOCK_YS_EXCHANGE_RATE_SLOT);
        vm.assume(mockRate > 0);

        _assumeNoOverflow(totalAssets, mockRate);
        uint256 currentValue = totalAssets.mulDiv(mockRate, WadRayMath.RAY);

        uint256 userDebt = _loadUInt256(address(ysStrategy), YS_TOTAL_DEBT_OWED_TO_USER_SLOT);
        uint256 dragonDebt = _loadUInt256(address(ysStrategy), YS_DRAGON_ROUTER_DEBT_SLOT);
        _assumeNoOverflow(userDebt, dragonDebt);
        vm.assume(currentValue == userDebt + dragonDebt);
    }

    function _setupLossScenario(uint256 totalAssets) internal override {
        _storeUInt256(address(ysStrategy), MOCK_NEXT_TOTAL_ASSETS_SLOT, totalAssets);
        _storeMappingUInt256(_asset, ERC20_BALANCES_SLOT, uint256(uint160(address(ysStrategy))), 0, totalAssets);

        uint256 mockRate = _loadUInt256(address(ysStrategy), MOCK_YS_EXCHANGE_RATE_SLOT);
        vm.assume(mockRate > 0);

        _assumeNoOverflow(totalAssets, mockRate);
        uint256 currentValue = totalAssets.mulDiv(mockRate, WadRayMath.RAY);

        uint256 userDebt = _loadUInt256(address(ysStrategy), YS_TOTAL_DEBT_OWED_TO_USER_SLOT);
        uint256 dragonDebt = _loadUInt256(address(ysStrategy), YS_DRAGON_ROUTER_DEBT_SLOT);
        _assumeNoOverflow(userDebt, dragonDebt);
        vm.assume(currentValue < userDebt + dragonDebt);
    }

    function _assertReportNoChangeExtras() internal view override {
        uint256 postUserDebt = _loadUInt256(address(ysStrategy), YS_TOTAL_DEBT_OWED_TO_USER_SLOT);
        uint256 postDragonDebt = _loadUInt256(address(ysStrategy), YS_DRAGON_ROUTER_DEBT_SLOT);
        assertEq(postUserDebt, preState.userDebt);
        assertEq(postDragonDebt, preState.dragonDebt);
    }

    function _assertTendExtras() internal view override {
        uint256 postUserDebt = _loadUInt256(address(ysStrategy), YS_TOTAL_DEBT_OWED_TO_USER_SLOT);
        uint256 postDragonDebt = _loadUInt256(address(ysStrategy), YS_DRAGON_ROUTER_DEBT_SLOT);
        assertEq(postUserDebt, preState.userDebt);
        assertEq(postDragonDebt, preState.dragonDebt);
    }

    /*//////////////////////////////////////////////////////////////
                    OVERRIDDEN COMMON TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Tend should not change any state (including YS debt)
    function testTend() public override {
        _assumeNonReentrant();

        preState = _snapshot();

        vm.startPrank(_keeper);
        iYSStrategy.tend();
        vm.stopPrank();

        postState = _snapshot();

        assertEq(postState.totalAssets, preState.totalAssets);
        assertEq(postState.totalSupply, preState.totalSupply);

        _assertTendExtras();
    }

    /// @notice When currentValue == totalDebt, no shares minted or burned, debts unchanged
    function testReportNoChange() public override {
        _assumeNonReentrant();

        address stratAddr = getStrategyAddr();
        _storeData(stratAddr, HC_SLOT, HC_DO_HEALTH_CHECK_OFFSET, HC_DO_HEALTH_CHECK_WIDTH, 0);

        preState = _snapshot();

        vm.assume(preState.totalAssets > 0);
        vm.assume(preState.totalSupply > 0);

        _setupReportNoChange(preState.totalAssets);

        vm.startPrank(_keeper);
        iYSStrategy.report();
        vm.stopPrank();

        postState = _snapshot();

        assertEq(postState.totalSupply, preState.totalSupply);
        assertEq(postState.dragonBalance, preState.dragonBalance);

        _assertReportNoChangeExtras();
    }

    /*//////////////////////////////////////////////////////////////
                    HELPERS
    //////////////////////////////////////////////////////////////*/

    function _snapshot() internal view returns (YSProofState memory state) {
        state.totalAssets = _loadUInt256(address(ysStrategy), TS_TOTAL_ASSETS_SLOT);
        state.totalSupply = _loadUInt256(address(ysStrategy), TS_TOTAL_SUPPLY_SLOT);
        state.dragonBalance = _loadMappingUInt256(
            address(ysStrategy),
            TS_BALANCES_SLOT,
            uint256(uint160(_dragonRouter)),
            0
        );
        state.userDebt = _loadUInt256(address(ysStrategy), YS_TOTAL_DEBT_OWED_TO_USER_SLOT);
        state.dragonDebt = _loadUInt256(address(ysStrategy), YS_DRAGON_ROUTER_DEBT_SLOT);
    }

    function _setOneToOneState(
        uint256 totalAssets,
        uint256 totalSupply,
        uint256 userDebt,
        uint256 dragonDebt,
        uint256 dragonBalance
    ) internal {
        _storeUInt256(address(ysStrategy), TS_TOTAL_ASSETS_SLOT, totalAssets);
        _storeUInt256(address(ysStrategy), TS_TOTAL_SUPPLY_SLOT, totalSupply);
        _storeMappingUInt256(address(ysStrategy), TS_BALANCES_SLOT, uint256(uint160(_dragonRouter)), 0, dragonBalance);
        _storeUInt256(address(ysStrategy), MOCK_YS_EXCHANGE_RATE_SLOT, WadRayMath.RAY);
        _storeUInt256(address(ysStrategy), YS_TOTAL_DEBT_OWED_TO_USER_SLOT, userDebt);
        _storeUInt256(address(ysStrategy), YS_DRAGON_ROUTER_DEBT_SLOT, dragonDebt);
        _storeMappingUInt256(_asset, ERC20_BALANCES_SLOT, uint256(uint160(address(ysStrategy))), 0, totalAssets);
    }

    /*//////////////////////////////////////////////////////////////
                    YS-SPECIFIC: REPORT WITH PROFIT
    //////////////////////////////////////////////////////////////*/

    /// @notice When report detects profit (currentValue > userDebt + dragonDebt),
    ///         shares are minted to dragon, dragon debt increases, user debt unchanged
    function testReportProfitYS() public {
        _assumeNonReentrant();

        address stratAddr = getStrategyAddr();
        _storeData(stratAddr, HC_SLOT, HC_DO_HEALTH_CHECK_OFFSET, HC_DO_HEALTH_CHECK_WIDTH, 0);

        preState = _snapshot();

        // Valid pre-state
        vm.assume(preState.totalAssets > 0);
        vm.assume(preState.totalSupply > 0);
        vm.assume(preState.dragonBalance <= preState.totalSupply);

        // Mock harvest returns totalAssets (no change in asset balance, profit comes from rate)
        _storeUInt256(address(ysStrategy), MOCK_NEXT_TOTAL_ASSETS_SLOT, preState.totalAssets);

        // Give strategy enough asset balance
        _storeMappingUInt256(
            _asset,
            ERC20_BALANCES_SLOT,
            uint256(uint160(address(ysStrategy))),
            0,
            preState.totalAssets
        );

        // Load mock exchange rate
        uint256 mockRate = _loadUInt256(address(ysStrategy), MOCK_YS_EXCHANGE_RATE_SLOT);
        vm.assume(mockRate > 0);

        // currentValue = totalAssets * rate / RAY
        _assumeNoOverflow(preState.totalAssets, mockRate);
        uint256 currentValue = preState.totalAssets.mulDiv(mockRate, WadRayMath.RAY);

        // Profit scenario: currentValue > userDebt + dragonDebt
        _assumeNoOverflow(preState.userDebt, preState.dragonDebt);
        uint256 totalDebt = preState.userDebt + preState.dragonDebt;
        vm.assume(currentValue > totalDebt);

        uint256 profitValue = currentValue - totalDebt;

        // Avoid overflow in dragonBalance + profitValue (shares minted = profitValue)
        _assumeNoOverflow(preState.dragonBalance, profitValue);
        _assumeNoOverflow(preState.totalSupply, profitValue);
        _assumeNoOverflow(preState.dragonDebt, profitValue);

        vm.startPrank(_keeper);
        iYSStrategy.report();
        vm.stopPrank();

        postState = _snapshot();

        // Dragon received shares equal to profitValue
        assertEq(postState.dragonBalance, preState.dragonBalance + profitValue);
        // Dragon debt increased by profitValue
        assertEq(postState.dragonDebt, preState.dragonDebt + profitValue);
        // User debt unchanged
        assertEq(postState.userDebt, preState.userDebt);
        // totalSupply increased by profitValue
        assertEq(postState.totalSupply, preState.totalSupply + profitValue);
    }

    /*//////////////////////////////////////////////////////////////
                    YS-SPECIFIC: REPORT WITH LOSS (BURNING, SUFFICIENT DRAGON)
    //////////////////////////////////////////////////////////////*/

    /// @notice When report detects loss and dragon has sufficient shares,
    ///         dragon balance and debt decrease
    function testReportLossWithBurningYS() public {
        _assumeNonReentrant();

        address stratAddr = getStrategyAddr();
        _storeData(stratAddr, HC_SLOT, HC_DO_HEALTH_CHECK_OFFSET, HC_DO_HEALTH_CHECK_WIDTH, 0);

        // Enable burning
        _storeData(address(ysStrategy), TS_FLAGS_SLOT, TS_ENABLE_BURNING_OFFSET, TS_ENABLE_BURNING_WIDTH, 1);

        preState = _snapshot();

        vm.assume(preState.totalAssets > 0);
        vm.assume(preState.totalSupply > 0);
        vm.assume(preState.dragonBalance > 0);
        vm.assume(preState.dragonBalance <= preState.totalSupply);

        _storeUInt256(address(ysStrategy), MOCK_NEXT_TOTAL_ASSETS_SLOT, preState.totalAssets);
        _storeMappingUInt256(
            _asset,
            ERC20_BALANCES_SLOT,
            uint256(uint160(address(ysStrategy))),
            0,
            preState.totalAssets
        );

        uint256 mockRate = _loadUInt256(address(ysStrategy), MOCK_YS_EXCHANGE_RATE_SLOT);
        vm.assume(mockRate > 0);

        _assumeNoOverflow(preState.totalAssets, mockRate);
        uint256 currentValue = preState.totalAssets.mulDiv(mockRate, WadRayMath.RAY);

        // Loss scenario: currentValue < userDebt + dragonDebt
        _assumeNoOverflow(preState.userDebt, preState.dragonDebt);
        uint256 totalDebt = preState.userDebt + preState.dragonDebt;
        vm.assume(currentValue < totalDebt);
        vm.assume(currentValue > 0);

        uint256 lossValue = totalDebt - currentValue;

        // Dragon can cover loss: dragonBalance >= lossValue
        vm.assume(preState.dragonBalance >= lossValue);
        vm.assume(preState.dragonDebt >= lossValue);

        vm.startPrank(_keeper);
        iYSStrategy.report();
        vm.stopPrank();

        postState = _snapshot();

        // Dragon shares burned by lossValue
        assertEq(postState.dragonBalance, preState.dragonBalance - lossValue);
        // Dragon debt decreased by lossValue
        assertEq(postState.dragonDebt, preState.dragonDebt - lossValue);
        // User debt unchanged
        assertEq(postState.userDebt, preState.userDebt);
    }

    /*//////////////////////////////////////////////////////////////
                    YS-SPECIFIC: REPORT WITH LOSS (INSUFFICIENT DRAGON)
    //////////////////////////////////////////////////////////////*/

    /// @notice When dragon can't cover the full loss, all dragon shares are burned
    function testReportLossInsufficientDragonYS() public {
        _assumeNonReentrant();

        address stratAddr = getStrategyAddr();
        _storeData(stratAddr, HC_SLOT, HC_DO_HEALTH_CHECK_OFFSET, HC_DO_HEALTH_CHECK_WIDTH, 0);

        _storeData(address(ysStrategy), TS_FLAGS_SLOT, TS_ENABLE_BURNING_OFFSET, TS_ENABLE_BURNING_WIDTH, 1);

        preState = _snapshot();

        vm.assume(preState.totalAssets > 0);
        vm.assume(preState.totalSupply > 0);
        vm.assume(preState.dragonBalance > 0);
        vm.assume(preState.dragonBalance <= preState.totalSupply);

        _storeUInt256(address(ysStrategy), MOCK_NEXT_TOTAL_ASSETS_SLOT, preState.totalAssets);
        _storeMappingUInt256(
            _asset,
            ERC20_BALANCES_SLOT,
            uint256(uint160(address(ysStrategy))),
            0,
            preState.totalAssets
        );

        uint256 mockRate = _loadUInt256(address(ysStrategy), MOCK_YS_EXCHANGE_RATE_SLOT);
        vm.assume(mockRate > 0);

        _assumeNoOverflow(preState.totalAssets, mockRate);
        uint256 currentValue = preState.totalAssets.mulDiv(mockRate, WadRayMath.RAY);

        _assumeNoOverflow(preState.userDebt, preState.dragonDebt);
        uint256 totalDebt = preState.userDebt + preState.dragonDebt;
        vm.assume(currentValue < totalDebt);

        uint256 lossValue = totalDebt - currentValue;

        // Dragon can't cover: dragonBalance < lossValue
        vm.assume(lossValue > preState.dragonBalance);
        vm.assume(preState.dragonDebt >= preState.dragonBalance);

        vm.startPrank(_keeper);
        iYSStrategy.report();
        vm.stopPrank();

        postState = _snapshot();

        // All dragon shares burned
        assertEq(postState.dragonBalance, 0);
        // Dragon debt decreased by dragonBalance (the amount burned)
        assertEq(postState.dragonDebt, preState.dragonDebt - preState.dragonBalance);
        // totalSupply decreased by dragonBalance
        assertEq(postState.totalSupply, preState.totalSupply - preState.dragonBalance);
    }

    /*//////////////////////////////////////////////////////////////
                    YS-SPECIFIC: SOLVENCY TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit reverts when vault is insolvent
    function testDepositBlockedDuringInsolvency() public {
        _assumeNonReentrant();

        preState = _snapshot();
        vm.assume(preState.totalAssets > 0);
        vm.assume(preState.totalSupply > 0);

        uint256 mockRate = _loadUInt256(address(ysStrategy), MOCK_YS_EXCHANGE_RATE_SLOT);
        vm.assume(mockRate > 0);

        _assumeNoOverflow(preState.totalAssets, mockRate);
        uint256 currentValue = preState.totalAssets.mulDiv(mockRate, WadRayMath.RAY);

        // Set up insolvency: vault value < user debt (matches _isVaultInsolvent definition)
        vm.assume(preState.userDebt > 0);
        vm.assume(currentValue < preState.userDebt);

        // Not shutdown
        _storeData(address(ysStrategy), TS_FLAGS_SLOT, TS_SHUTDOWN_OFFSET, TS_SHUTDOWN_WIDTH, 0);

        address depositor = makeAddr("DEPOSITOR");
        uint256 depositAmount = 1 ether;
        _storeMappingUInt256(_asset, ERC20_BALANCES_SLOT, uint256(uint160(depositor)), 0, depositAmount);
        vm.prank(depositor);
        (bool ok, ) = _asset.call(
            abi.encodeWithSignature("approve(address,uint256)", address(ysStrategy), depositAmount)
        );
        require(ok);

        vm.prank(depositor);
        vm.expectRevert("Cannot operate when vault is insolvent");
        iYSStrategy.deposit(depositAmount, depositor);
    }

    /// @notice Dragon redeem reverts during insolvency
    function testDragonBlockedDuringInsolvency() public {
        _assumeNonReentrant();

        uint256 totalAssets = 100 ether;
        uint256 totalSupply = 100 ether;
        _storeUInt256(address(ysStrategy), TS_TOTAL_ASSETS_SLOT, totalAssets);
        _storeUInt256(address(ysStrategy), TS_TOTAL_SUPPLY_SLOT, totalSupply);
        _storeMappingUInt256(address(ysStrategy), TS_BALANCES_SLOT, uint256(uint160(_dragonRouter)), 0, 1);

        // Concrete insolvent state: currentValue = totalAssets, while user debt is higher.
        _storeUInt256(address(ysStrategy), MOCK_YS_EXCHANGE_RATE_SLOT, WadRayMath.RAY);
        _storeUInt256(address(ysStrategy), YS_TOTAL_DEBT_OWED_TO_USER_SLOT, 101 ether);
        _storeUInt256(address(ysStrategy), YS_DRAGON_ROUTER_DEBT_SLOT, 0);

        // Set lastReport to now (no lockup)
        _storeData(address(ysStrategy), TS_KEEPER_SLOT, TS_LAST_REPORT_OFFSET, TS_LAST_REPORT_WIDTH, block.timestamp);

        vm.prank(_dragonRouter);
        vm.expectRevert("Transfer would cause vault insolvency");
        iYSStrategy.redeem(1, _dragonRouter, _dragonRouter);
    }

    /// @notice Deposit to dragon router always reverts
    function testDepositBlockedForDragon() public {
        _assumeNonReentrant();

        preState = _snapshot();
        vm.assume(preState.totalAssets > 0);
        vm.assume(preState.totalSupply > 0);

        uint256 mockRate = _loadUInt256(address(ysStrategy), MOCK_YS_EXCHANGE_RATE_SLOT);
        vm.assume(mockRate > 0);

        // Ensure solvent (so the only revert reason is "Dragon cannot deposit")
        _assumeNoOverflow(preState.totalAssets, mockRate);
        uint256 currentValue = preState.totalAssets.mulDiv(mockRate, WadRayMath.RAY);
        _assumeNoOverflow(preState.userDebt, preState.dragonDebt);
        vm.assume(currentValue >= preState.userDebt + preState.dragonDebt);

        // Not shutdown
        _storeData(address(ysStrategy), TS_FLAGS_SLOT, TS_SHUTDOWN_OFFSET, TS_SHUTDOWN_WIDTH, 0);

        address depositor = makeAddr("DEPOSITOR");
        uint256 depositAmount = 1 ether;
        _storeMappingUInt256(_asset, ERC20_BALANCES_SLOT, uint256(uint160(depositor)), 0, depositAmount);
        vm.prank(depositor);
        (bool ok, ) = _asset.call(
            abi.encodeWithSignature("approve(address,uint256)", address(ysStrategy), depositAmount)
        );
        require(ok);

        vm.prank(depositor);
        vm.expectRevert("Dragon cannot deposit");
        iYSStrategy.deposit(depositAmount, _dragonRouter);
    }

    /*//////////////////////////////////////////////////////////////
                    YS-SPECIFIC: VALUE DEBT TRACKING
    //////////////////////////////////////////////////////////////*/

    /// @notice After deposit, userDebt increases by shares (= assets * rate / RAY)
    function testDepositValueDebtYS(uint256 assets, address /* receiver */) public {
        _assumeNonReentrant();

        vm.assume(assets > 0);
        vm.assume(assets < ETH_UPPER_BOUND);

        address receiver = makeAddr("YS_DEPOSIT_RECEIVER");
        uint256 initialValue = 100 ether;
        _assumeNoOverflow(initialValue, assets);
        _setOneToOneState(initialValue, initialValue, initialValue, 0, 0);
        _storeMappingUInt256(address(ysStrategy), TS_BALANCES_SLOT, uint256(uint160(receiver)), 0, 0);

        preState = _snapshot();

        uint256 expectedShares = assets;

        // Not shutdown
        _storeData(address(ysStrategy), TS_FLAGS_SLOT, TS_SHUTDOWN_OFFSET, TS_SHUTDOWN_WIDTH, 0);

        // Depositor setup
        address depositor = makeAddr("DEPOSITOR");
        _storeMappingUInt256(_asset, ERC20_BALANCES_SLOT, uint256(uint160(depositor)), 0, assets);
        vm.prank(depositor);
        (bool ok, ) = _asset.call(abi.encodeWithSignature("approve(address,uint256)", address(ysStrategy), assets));
        require(ok);

        vm.prank(depositor);
        iYSStrategy.deposit(assets, receiver);

        postState = _snapshot();

        // User debt increased by shares
        assertEq(postState.userDebt, preState.userDebt + expectedShares);

        // Balance bounded by totalSupply after deposit (inductive step)
        _establish(Mode.Assert, iYSStrategy.balanceOf(receiver) <= iYSStrategy.totalSupply());
    }

    /*//////////////////////////////////////////////////////////////
                    YS-SPECIFIC: TRANSFER DEBT REBALANCING
    //////////////////////////////////////////////////////////////*/

    /// @notice Dragon transfers to user: dragonDebt decreases, userDebt increases
    function testTransferDragonToUser(address /* to */, uint256 amount) public {
        _assumeNonReentrant();

        vm.assume(amount > 0);
        vm.assume(amount < ETH_UPPER_BOUND);

        address to = makeAddr("YS_TRANSFER_RECEIVER");
        _setOneToOneState(amount + 1, amount, 0, amount, amount);

        preState = _snapshot();

        vm.prank(_dragonRouter);
        (bool ok, ) = address(ysStrategy).call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(ok, "transfer failed");

        postState = _snapshot();

        // Dragon debt decreased
        assertEq(postState.dragonDebt, preState.dragonDebt - amount);
        // User debt increased
        assertEq(postState.userDebt, preState.userDebt + amount);
    }

    /// @notice User transfers to dragon: userDebt decreases, dragonDebt increases
    function testTransferUserToDragon(address /* from */, uint256 amount) public {
        _assumeNonReentrant();

        vm.assume(amount > 0);
        vm.assume(amount < ETH_UPPER_BOUND);

        address from = makeAddr("YS_TRANSFER_SENDER");
        _setOneToOneState(amount + 1, amount, amount, 0, 0);

        preState = _snapshot();

        // Give `from` enough shares
        _storeMappingUInt256(address(ysStrategy), TS_BALANCES_SLOT, uint256(uint160(from)), 0, amount);

        vm.prank(from);
        (bool ok, ) = address(ysStrategy).call(
            abi.encodeWithSignature("transfer(address,uint256)", _dragonRouter, amount)
        );
        require(ok, "transfer failed");

        postState = _snapshot();

        // User debt decreased
        assertEq(postState.userDebt, preState.userDebt - amount);
        // Dragon debt increased
        assertEq(postState.dragonDebt, preState.dragonDebt + amount);
    }

    /*//////////////////////////////////////////////////////////////
                    YS-SPECIFIC: CONVERSION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice When solvent, conversion uses rate: shares = assets * rate / RAY
    function testConversionSolventYS(uint256 amount) public {
        _assumeNonReentrant();

        vm.assume(amount > 0);
        vm.assume(amount < ETH_UPPER_BOUND);

        _setOneToOneState(amount + 1, amount + 1, 0, 0, 0);

        uint256 expectedShares = amount;
        uint256 actualShares = iYSStrategy.convertToShares(amount);
        assertEq(actualShares, expectedShares);
    }

    /// @notice When insolvent, conversion falls back to proportional (base TokenizedStrategy logic)
    function testConversionFallbackInsolventYS(uint256 amount) public {
        _assumeNonReentrant();

        vm.assume(amount > 0);
        vm.assume(amount < ETH_UPPER_BOUND);

        uint256 totalAssets = amount + 1;
        uint256 totalSupply = amount + 2;
        _setOneToOneState(totalAssets, totalSupply, amount + 2, 0, 0);

        // Proportional: shares = amount * totalSupply / totalAssets (base logic)
        uint256 expectedShares = amount.mulDiv(totalSupply, totalAssets);
        uint256 actualShares = iYSStrategy.convertToShares(amount);
        assertEq(actualShares, expectedShares);
    }
}
