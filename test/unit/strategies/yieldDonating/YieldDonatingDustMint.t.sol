// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import { Setup } from "./utils/Setup.sol";
import { Vm } from "forge-std/Test.sol";
import { TokenizedStrategy } from "src/core/TokenizedStrategy.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

/// @notice Regression suite for the dust-profit donation path: when Floor rounding maps
///         positive profit to zero donation shares, `report()` must skip both the `_mint`
///         and the `DonationMinted` event so the off-chain event stream never sees a
///         donation without a corresponding supply change.
contract YieldDonatingDustMintTest is Setup {
    /// @dev ERC-7201 base slot derived from "octant.tokenized.strategy.storage". Matches the
    ///      `OCTANT_STRATEGY_STORAGE` constant inside `TokenizedStrategy`.
    bytes32 internal constant OCTANT_STRATEGY_STORAGE =
        keccak256(abi.encode(uint256(keccak256("octant.tokenized.strategy.storage")) - 1)) & ~bytes32(uint256(0xff));

    /// @dev StrategyData.totalSupply sits at offset 8 from the base (nonces, balances,
    ///      allowances, asset, name, symbol, cachedDomainSeparator, cachedChainId).
    bytes32 internal constant TOTAL_SUPPLY_SLOT = bytes32(uint256(OCTANT_STRATEGY_STORAGE) + 8);

    /// @dev StrategyData.totalAssets sits one slot after totalSupply.
    bytes32 internal constant TOTAL_ASSETS_SLOT = bytes32(uint256(OCTANT_STRATEGY_STORAGE) + 9);

    bytes32 internal constant DONATION_MINTED_SIG = keccak256("DonationMinted(address,uint256)");

    function setUp() public override {
        super.setUp();
    }

    /// @notice Direct write to the strategy's namespaced storage. Used to construct a
    ///         PPS > 1 state that Floor rounding can map to zero shares without having
    ///         to drive the contract through the long path required to accumulate that
    ///         rounding drift organically.
    function _writeStrategyState(uint256 totalSupply_, uint256 totalAssets_) internal {
        vm.store(address(strategy), TOTAL_SUPPLY_SLOT, bytes32(totalSupply_));
        vm.store(address(strategy), TOTAL_ASSETS_SLOT, bytes32(totalAssets_));
    }

    function _countDonationMintedLogs(Vm.Log[] memory logs) internal view returns (uint256 count) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == address(strategy) &&
                logs[i].topics.length > 0 &&
                logs[i].topics[0] == DONATION_MINTED_SIG
            ) {
                count++;
            }
        }
    }

    /// @notice Dust profit at an extreme PPS still maps to zero donation shares. With the
    ///         6-decimal virtual offset, `_convertToShares(1, Floor)` only rounds to zero
    ///         once `totalAssets + 1 > totalSupply + 1e6`. Fix skips the zero-share mint
    ///         and its event. Pre-fix, `_mint(dragon, 0)` executed and `DonationMinted`
    ///         was emitted with amount 0.
    function test_reportDustProfit_noMintNoEvent() public {
        _writeStrategyState({ totalSupply_: 1, totalAssets_: SHARE_SCALE + 1 });
        asset.mint(address(yieldSource), SHARE_SCALE + 2);

        uint256 supplyBefore = strategy.totalSupply();
        uint256 dragonBalBefore = strategy.balanceOf(donationAddress);

        vm.recordLogs();
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(profit, 1, "profit should be 1 wei");
        assertEq(loss, 0, "no loss on profit path");
        assertEq(strategy.totalSupply(), supplyBefore, "no shares minted on zero-share path");
        assertEq(strategy.balanceOf(donationAddress), dragonBalBefore, "dragon balance unchanged");
        assertEq(strategy.totalAssets(), SHARE_SCALE + 2, "totalAssets still reconciled to yield-source balance");
        assertEq(_countDonationMintedLogs(logs), 0, "no DonationMinted event on zero-share dust");
    }

    /// @notice Sanity check: when profit rounds to a non-zero share amount the mint and the
    ///         DonationMinted event still fire. Protects against over-guarding the dust path.
    function test_reportProfit_emitsDonationMintedWhenSharesRoundUp() public {
        // totalSupply = 2, totalAssets = 2. Profit of 3 uses the virtual-offset formula:
        // 3 * (2 + 1e6) / (2 + 1) = 1,000,002 shares.
        _writeStrategyState({ totalSupply_: 2, totalAssets_: 2 });
        asset.mint(address(yieldSource), 5);

        vm.recordLogs();
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(profit, 3, "profit should be 3 wei");
        assertEq(loss, 0, "no loss on profit path");
        assertEq(_countDonationMintedLogs(logs), 1, "DonationMinted emitted on real share mint");
        assertEq(strategy.balanceOf(donationAddress), SHARE_SCALE + 2, "dragon received scaled shares");
    }
}
