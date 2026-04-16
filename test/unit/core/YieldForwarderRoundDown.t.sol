// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { YieldForwarder } from "src/core/YieldForwarder.sol";
import { SwappingYieldForwarder } from "src/core/SwappingYieldForwarder.sol";
import { MockSwapper } from "test/mocks/MockSwapper.sol";

/// @notice Strategy mock whose convertToAssets uses floor((shares * totalAssets) / totalSupply)
///         and whose redeem reverts with ZERO_ASSETS if the preview rounds to zero.
///         Mirrors the real TokenizedStrategy.redeem guard so we can reproduce the pre-fix
///         DoS (1 wei share dust on a loss-impaired strategy bricks reportAndForward).
contract LossImpairedStrategy is ERC20Mock {
    ERC20Mock public immutable underlying;
    uint256 public totalAssetsStored; // test-visible shadow of TokenizedStrategy.totalAssets
    bool public reported;
    bool public redeemCalled;

    constructor(address _underlying) {
        underlying = ERC20Mock(_underlying);
    }

    function asset() external view returns (address) {
        return address(underlying);
    }

    function setTotalAssets(uint256 v) external {
        totalAssetsStored = v;
    }

    function maxRedeem(address) external pure returns (uint256) {
        // Unlimited for these tests -- we only care about the convertToAssets preview.
        return type(uint256).max;
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        uint256 ts = totalSupply();
        if (ts == 0) return shares;
        return (shares * totalAssetsStored) / ts; // floor
    }

    function report() external returns (uint256, uint256) {
        reported = true;
        return (0, 0);
    }

    function redeem(uint256 shares, address receiver, address owner, uint256) external returns (uint256 assets) {
        redeemCalled = true;
        uint256 ts = totalSupply();
        assets = ts == 0 ? shares : (shares * totalAssetsStored) / ts;
        require(assets > 0, "ZERO_ASSETS");
        _burn(owner, shares);
        totalAssetsStored -= assets;
        underlying.mint(receiver, assets);
    }
}

/// @notice Bailsec #61 -- pre-fix, a loss-impaired strategy (totalAssets < totalSupply
///         with enableBurning=false) lets any holder brick reportAndForward by gifting
///         1 wei of strategy share to the forwarder. The inner redeem floors to zero
///         assets, reverts with ZERO_ASSETS, and rolls back the outer report(). Fix:
///         preview convertToAssets; if it floors to zero, skip the redeem and preserve
///         the report() side effects.
contract YieldForwarderRoundDownTest is Test {
    YieldForwarder internal forwarder;
    SwappingYieldForwarder internal swappingForwarder;
    ERC20Mock internal underlying;
    ERC20Mock internal targetAsset;

    address internal receiver = address(0xBEEF);
    address internal keeperEOA = address(0xCAFE);

    function setUp() public {
        underlying = new ERC20Mock();
        targetAsset = new ERC20Mock();

        forwarder = new YieldForwarder(receiver, keeperEOA);

        MockSwapper swapper = new MockSwapper(address(targetAsset), 1e18);
        swappingForwarder = new SwappingYieldForwarder(receiver, keeperEOA, address(targetAsset), address(swapper));
    }

    /// @dev Puts the strategy into totalAssets < totalSupply, with `dust` shares minted
    ///      to the forwarder so convertToAssets(dust) floors to zero.
    function _impair(
        LossImpairedStrategy s,
        address shareholder,
        uint256 shareholderShares,
        address forwarderAddr,
        uint256 dust
    ) internal {
        // Mint a large share float to a shareholder so totalSupply dominates totalAssets.
        s.mint(shareholder, shareholderShares);
        // Give the forwarder the dust balance.
        s.mint(forwarderAddr, dust);
        // Set totalAssets below totalSupply so (dust * totalAssets) / totalSupply rounds to 0.
        s.setTotalAssets(shareholderShares - 1);
    }

    // --- YieldForwarder.reportAndForward ---

    /// @notice Pre-fix DoS reproduction: dust share on a loss-impaired strategy.
    ///         Post-fix: call succeeds, report() commits, dust stays at forwarder,
    ///         receiver gets nothing.
    function test_reportAndForward_dustOnLossImpaired_skipsRedeem() public {
        LossImpairedStrategy s = new LossImpairedStrategy(address(underlying));
        _impair(s, address(0xA11CE), 1_000 ether, address(forwarder), 1);

        assertEq(s.convertToAssets(1), 0, "precondition: dust rounds to zero");

        vm.prank(keeperEOA);
        uint256 assets = forwarder.reportAndForward(address(s), 0);

        assertEq(assets, 0, "no assets forwarded");
        assertEq(s.balanceOf(address(forwarder)), 1, "dust share retained");
        assertEq(underlying.balanceOf(receiver), 0, "receiver gets nothing");
        assertTrue(s.reported(), "report() commits");
        assertFalse(s.redeemCalled(), "redeem must be skipped, not called-and-failed");
    }

    /// @notice Sanity: when convertToAssets does NOT round to zero, the redeem runs normally.
    function test_reportAndForward_nonZeroPreview_redeemsNormally() public {
        LossImpairedStrategy s = new LossImpairedStrategy(address(underlying));
        // Healthy 1:1 state -- shares to assets ratio 1.
        s.mint(address(forwarder), 100 ether);
        s.setTotalAssets(100 ether);

        vm.prank(keeperEOA);
        uint256 assets = forwarder.reportAndForward(address(s), 0);

        assertEq(assets, 100 ether, "full redeem in healthy state");
        assertEq(s.balanceOf(address(forwarder)), 0, "no residual");
        assertEq(underlying.balanceOf(receiver), 100 ether, "receiver got assets");
        assertTrue(s.redeemCalled(), "redeem was exercised");
    }

    // --- SwappingYieldForwarder.reportSwapAndForward (mirror guard) ---

    /// @notice Mirrored guard on the swapping variant: dust on a loss-impaired strategy
    ///         must not revert the outer call. report() commits, no swap is attempted.
    function test_reportSwapAndForward_dustOnLossImpaired_skipsRedeem() public {
        LossImpairedStrategy s = new LossImpairedStrategy(address(underlying));
        _impair(s, address(0xA11CE), 1_000 ether, address(swappingForwarder), 1);

        assertEq(s.convertToAssets(1), 0, "precondition: dust rounds to zero");

        vm.prank(keeperEOA);
        uint256 assetsOut = swappingForwarder.reportSwapAndForward(address(s), 0, 0);

        assertEq(assetsOut, 0, "no swap output");
        assertEq(s.balanceOf(address(swappingForwarder)), 1, "dust share retained");
        assertEq(targetAsset.balanceOf(receiver), 0, "receiver gets nothing");
        assertTrue(s.reported(), "report() commits on swapping variant");
        assertFalse(s.redeemCalled(), "redeem must be skipped, not called-and-failed");
    }
}
