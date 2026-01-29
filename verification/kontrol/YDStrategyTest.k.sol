// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";

import { YDSetup } from "test/kontrol/YDSetup.k.sol";
import "test/kontrol/YDStateSlots.k.sol";

struct YDProofState {
    uint256 totalAssets;
    uint256 totalSupply;
    uint256 dragonBalance;
}

/**
 * @title YDStrategyTest
 * @notice Kontrol formal verification proofs for YieldDonatingTokenizedStrategy
 * @dev Proves key invariants of the yield-donating report mechanism:
 *      - PPS (price-per-share) is non-decreasing for regular holders after report with profit
 *      - PPS is non-decreasing after report with loss when dragon has sufficient balance
 *      - totalAssets is always updated to newTotalAssets after report
 *      - Dragon shares are minted on profit and burned on loss (when burning enabled)
 *      - Access control: only keepers/management can call report
 *      - Tend does not change PPS or totalAssets
 */
contract YDStrategyTest is YDSetup {
    YDProofState private preState;
    YDProofState private postState;

    function _snapshot() internal view returns (YDProofState memory state) {
        state.totalAssets = _loadUInt256(address(strategy), YD_TOTAL_ASSETS_SLOT);
        state.totalSupply = _loadUInt256(address(strategy), YD_TOTAL_SUPPLY_SLOT);
        state.dragonBalance = _loadMappingUInt256(
            address(strategy),
            YD_BALANCES_SLOT,
            uint256(uint160(_dragonRouter)),
            0
        );
    }

    function assumeNonReentrant() internal {
        _storeData(address(strategy), YD_FLAGS_SLOT, YD_ENTERED_OFFSET, YD_ENTERED_WIDTH, 1);
    }

    function disableHealthCheck() internal {
        _storeData(address(strategy), YD_HC_SLOT, YD_HC_DO_HEALTH_CHECK_OFFSET, YD_HC_DO_HEALTH_CHECK_WIDTH, 0);
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
                    REPORT WITH PROFIT
    //////////////////////////////////////////////////////////////*/

    /// @notice When report harvests a profit, shares are minted to dragon router
    ///         and PPS is preserved (non-decreasing) for regular holders
    function testReportProfit() public {
        assumeNonReentrant();
        disableHealthCheck();

        preState = _snapshot();

        // Valid pre-state
        vm.assume(preState.totalAssets > 0);
        vm.assume(preState.totalSupply > 0);
        vm.assume(preState.dragonBalance <= preState.totalSupply);

        // Profit scenario: newTotalAssets > oldTotalAssets
        uint256 newTotalAssets = freshUInt256Bounded();
        vm.assume(newTotalAssets > preState.totalAssets);
        _storeUInt256(address(strategy), YD_MOCK_NEXT_TOTAL_ASSETS_SLOT, newTotalAssets);

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

    /*//////////////////////////////////////////////////////////////
                    REPORT WITH LOSS (BURNING ENABLED, SUFFICIENT DRAGON)
    //////////////////////////////////////////////////////////////*/

    /// @notice When report harvests a loss with burning enabled and the dragon
    ///         has enough shares, shares are burned and PPS is preserved
    function testReportLossWithBurning() public {
        assumeNonReentrant();
        disableHealthCheck();

        // Enable burning
        _storeData(address(strategy), YD_FLAGS_SLOT, YD_ENABLE_BURNING_OFFSET, YD_ENABLE_BURNING_WIDTH, 1);

        preState = _snapshot();

        // Valid pre-state
        vm.assume(preState.totalAssets > 0);
        vm.assume(preState.totalSupply > 0);
        vm.assume(preState.dragonBalance <= preState.totalSupply);

        // Loss scenario: newTotalAssets < oldTotalAssets
        uint256 newTotalAssets = freshUInt256Bounded();
        vm.assume(newTotalAssets < preState.totalAssets);
        vm.assume(newTotalAssets > 0);
        _storeUInt256(address(strategy), YD_MOCK_NEXT_TOTAL_ASSETS_SLOT, newTotalAssets);

        // Dragon has enough shares to cover the loss burn
        uint256 loss = preState.totalAssets - newTotalAssets;
        _assumeNoOverflow(loss, preState.totalSupply);
        uint256 sharesToBurn = Math.ceilDiv(loss * preState.totalSupply, preState.totalAssets);
        vm.assume(preState.dragonBalance >= sharesToBurn);

        vm.startPrank(_keeper);
        iStrategy.report();
        vm.stopPrank();

        postState = _snapshot();

        // Assertions
        ppsNonDecreasingInvariant(Mode.Assert);
        totalAssetsUpdatedCorrectly(Mode.Assert, newTotalAssets);

        // Dragon shares were burned
        _establish(Mode.Assert, postState.dragonBalance <= preState.dragonBalance);
        // totalSupply decreased
        _establish(Mode.Assert, postState.totalSupply <= preState.totalSupply);
    }

    /*//////////////////////////////////////////////////////////////
                    REPORT WITH LOSS (INSUFFICIENT DRAGON)
    //////////////////////////////////////////////////////////////*/

    /// @notice When dragon can't cover the full loss, all its shares are burned
    ///         and the remaining loss reduces PPS
    function testReportLossInsufficientDragon() public {
        assumeNonReentrant();
        disableHealthCheck();

        // Enable burning
        _storeData(address(strategy), YD_FLAGS_SLOT, YD_ENABLE_BURNING_OFFSET, YD_ENABLE_BURNING_WIDTH, 1);

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
        _storeUInt256(address(strategy), YD_MOCK_NEXT_TOTAL_ASSETS_SLOT, newTotalAssets);

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
                    REPORT WITH NO CHANGE
    //////////////////////////////////////////////////////////////*/

    /// @notice When harvest returns same totalAssets, no shares minted or burned
    function testReportNoChange() public {
        assumeNonReentrant();
        disableHealthCheck();

        preState = _snapshot();

        vm.assume(preState.totalAssets > 0);
        vm.assume(preState.totalSupply > 0);

        // Set mock to return current totalAssets (no profit, no loss)
        _storeUInt256(address(strategy), YD_MOCK_NEXT_TOTAL_ASSETS_SLOT, preState.totalAssets);

        vm.startPrank(_keeper);
        iStrategy.report();
        vm.stopPrank();

        postState = _snapshot();

        // No change
        assertEq(postState.totalAssets, preState.totalAssets);
        assertEq(postState.totalSupply, preState.totalSupply);
        assertEq(postState.dragonBalance, preState.dragonBalance);
    }

    /*//////////////////////////////////////////////////////////////
                    REPORT WITH LOSS (BURNING DISABLED)
    //////////////////////////////////////////////////////////////*/

    /// @notice When burning is disabled, loss reduces totalAssets but totalSupply
    ///         and dragon balance stay unchanged
    function testReportLossNoBurning() public {
        assumeNonReentrant();
        disableHealthCheck();

        // Disable burning
        _storeData(address(strategy), YD_FLAGS_SLOT, YD_ENABLE_BURNING_OFFSET, YD_ENABLE_BURNING_WIDTH, 0);

        preState = _snapshot();

        vm.assume(preState.totalAssets > 0);
        vm.assume(preState.totalSupply > 0);
        vm.assume(preState.dragonBalance <= preState.totalSupply);

        // Loss scenario
        uint256 newTotalAssets = freshUInt256Bounded();
        vm.assume(newTotalAssets < preState.totalAssets);
        _storeUInt256(address(strategy), YD_MOCK_NEXT_TOTAL_ASSETS_SLOT, newTotalAssets);

        vm.startPrank(_keeper);
        iStrategy.report();
        vm.stopPrank();

        postState = _snapshot();

        // totalAssets decreased
        totalAssetsUpdatedCorrectly(Mode.Assert, newTotalAssets);
        // No shares burned — totalSupply and dragon balance unchanged
        assertEq(postState.totalSupply, preState.totalSupply);
        assertEq(postState.dragonBalance, preState.dragonBalance);
    }

    /*//////////////////////////////////////////////////////////////
                    TEND (NO STATE CHANGE)
    //////////////////////////////////////////////////////////////*/

    /// @notice Tend should not change totalAssets or totalSupply
    function testTend() public {
        assumeNonReentrant();

        preState = _snapshot();

        vm.startPrank(_keeper);
        iStrategy.tend();
        vm.stopPrank();

        postState = _snapshot();

        assertEq(postState.totalAssets, preState.totalAssets);
        assertEq(postState.totalSupply, preState.totalSupply);
    }

    /*//////////////////////////////////////////////////////////////
                    ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    /// @notice Non-keeper/non-management address cannot call report
    function testReportOnlyKeeper() public {
        assumeNonReentrant();
        disableHealthCheck();

        _storeUInt256(address(strategy), YD_MOCK_NEXT_TOTAL_ASSETS_SLOT, freshUInt256Bounded());

        address nonKeeper = makeAddr("NON_KEEPER");

        vm.startPrank(nonKeeper);
        vm.expectRevert("!keeper");
        iStrategy.report();
        vm.stopPrank();
    }

    /// @notice Management can also call report (management has keeper privileges)
    function testReportByManagement() public {
        assumeNonReentrant();
        disableHealthCheck();

        preState = _snapshot();
        vm.assume(preState.totalAssets > 0);
        vm.assume(preState.totalSupply > 0);

        _storeUInt256(address(strategy), YD_MOCK_NEXT_TOTAL_ASSETS_SLOT, preState.totalAssets);

        vm.startPrank(_management);
        iStrategy.report();
        vm.stopPrank();
        // Should succeed without revert
    }

    /// @notice Emergency admin can shutdown but not call report
    function testReportNotEmergencyAdmin() public {
        assumeNonReentrant();
        disableHealthCheck();

        _storeUInt256(address(strategy), YD_MOCK_NEXT_TOTAL_ASSETS_SLOT, freshUInt256Bounded());

        vm.startPrank(_emergencyAdmin);
        vm.expectRevert("!keeper");
        iStrategy.report();
        vm.stopPrank();
    }
}
