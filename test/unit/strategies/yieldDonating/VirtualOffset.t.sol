// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.18;

import { Setup } from "./utils/Setup.sol";

contract VirtualOffsetTest is Setup {
    uint256 internal constant TS_BASE = uint256(0x4df8983d84042631e7325fb5ba31b73b056fa9890e796c4c95fbf1e6d76eba00);
    uint256 internal constant TS_TOTAL_SUPPLY_SLOT = TS_BASE + 8;
    uint256 internal constant TS_TOTAL_ASSETS_SLOT = TS_BASE + 9;

    address internal dustHolder = address(0xA11CE);
    address internal depositor = address(0xB0B);

    function setUp() public override {
        super.setUp();
    }

    function test_virtualOffset_preservesHealthyFirstDepositOneToOne() public {
        uint256 assets = 100e18;

        asset.mint(depositor, assets);
        vm.startPrank(depositor);
        asset.approve(address(strategy), assets);
        uint256 shares = strategy.deposit(assets, depositor);
        vm.stopPrank();

        assertEq(shares, assets, "empty healthy vault should still mint 1:1");
        assertEq(strategy.totalAssets(), assets, "total assets");
        assertEq(strategy.totalSupply(), assets, "total supply");
        assertEq(strategy.balanceOf(depositor), assets, "depositor shares");
    }

    function test_virtualOffset_allowsDepositWhenTrackedAssetsZeroAndSupplyDust() public {
        _createZeroAssetDustShareState();

        asset.mint(depositor, 1);
        vm.startPrank(depositor);
        asset.approve(address(strategy), 1);
        uint256 shares = strategy.deposit(1, depositor);
        vm.stopPrank();

        assertEq(shares, 2, "virtual offset should avoid ZERO_SHARES DoS");
        assertEq(strategy.totalAssets(), 1, "total assets after deposit");
        assertEq(strategy.totalSupply(), 3, "dust plus depositor shares");
        assertEq(strategy.maxRedeem(depositor), 2, "depositor shares redeemable");
        assertEq(strategy.convertToAssets(2), 1, "depositor can recover the deposited wei");
    }

    function test_virtualOffset_recoveryReportMintsDragonAndBlocksFinalDustBurn() public {
        _createZeroAssetDustShareState();

        uint256 recoveredAssets = 100e18;
        asset.mint(address(yieldSource), recoveredAssets);

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        assertEq(profit, recoveredAssets, "recovery should be reported as profit");
        assertEq(loss, 0, "no loss on recovery");
        assertEq(strategy.totalAssets(), recoveredAssets, "tracked assets restored");
        assertEq(strategy.balanceOf(donationAddress), recoveredAssets * 2, "dragon gets recovery shares");
        assertEq(strategy.totalSupply(), recoveredAssets * 2 + 1, "dust remains but no longer dominates");

        assertEq(strategy.maxWithdraw(dustHolder), 0, "dust holder cannot withdraw even 1 wei");
        vm.expectRevert("ERC4626: withdraw more than max");
        vm.prank(dustHolder);
        strategy.withdraw(1, dustHolder, dustHolder, MAX_BPS);

        assertGt(strategy.totalSupply(), 0, "supply must not reset to zero");
        assertEq(strategy.totalAssets(), recoveredAssets, "assets remain assigned against dragon supply");
    }

    function test_virtualOffset_bailsecChainCannotReachSupplyZeroAssetsPositive() public {
        _createZeroAssetDustShareState();

        uint256 recoveredAssets = 100e18;
        asset.mint(address(yieldSource), recoveredAssets);

        vm.prank(keeper);
        strategy.report();

        vm.expectRevert("ERC4626: withdraw more than max");
        vm.prank(dustHolder);
        strategy.withdraw(1, dustHolder, dustHolder, MAX_BPS);

        assertGt(strategy.totalSupply(), 0, "final dust burn should be impossible");
        assertEq(strategy.totalAssets(), recoveredAssets, "ghost-collateral state should not form");
    }

    function test_virtualOffset_forcedGhostStateRejectsDustFirstDepositor() public {
        _forceTotals({ totalSupply_: 0, totalAssets_: 100e18 });

        assertEq(strategy.previewDeposit(1), 0, "dust deposit should preview zero shares");

        asset.mint(dustHolder, 1);
        vm.startPrank(dustHolder);
        asset.approve(address(strategy), 1);
        vm.expectRevert("ZERO_SHARES");
        strategy.deposit(1, dustHolder);
        vm.stopPrank();

        assertEq(strategy.totalSupply(), 0, "supply unchanged");
        assertEq(strategy.totalAssets(), 100e18, "tracked assets unchanged");
    }

    function test_virtualOffset_reportAssignsRecoveredAssetsToDragonWhenSupplyIsZero() public {
        uint256 recoveredAssets = 100e18;
        asset.mint(address(yieldSource), recoveredAssets);

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        assertEq(profit, recoveredAssets, "recovery should be reported as profit");
        assertEq(loss, 0, "no loss");
        assertEq(strategy.balanceOf(donationAddress), recoveredAssets, "dragon receives first recovery shares");
        assertEq(strategy.totalSupply(), recoveredAssets, "recovery creates dragon supply");
        assertEq(strategy.totalAssets(), recoveredAssets, "assets tracked");
    }

    function _createZeroAssetDustShareState() internal {
        uint256 initialDeposit = 100e18;

        asset.mint(dustHolder, initialDeposit);
        vm.startPrank(dustHolder);
        asset.approve(address(strategy), initialDeposit);
        strategy.deposit(initialDeposit, dustHolder);
        vm.stopPrank();

        yieldSource.simulateLoss(initialDeposit - 1);

        vm.prank(dustHolder);
        strategy.withdraw(initialDeposit - 1, dustHolder, dustHolder, MAX_BPS);

        assertEq(strategy.totalAssets(), 1, "setup: tracked dust asset");
        assertEq(strategy.totalSupply(), 1, "setup: dust share");
        assertEq(strategy.balanceOf(dustHolder), 1, "setup: holder has one dust share");

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        assertEq(profit, 0, "setup: no profit");
        assertEq(loss, 1, "setup: final loss realized");
        assertEq(strategy.totalAssets(), 0, "setup: zero tracked assets");
        assertEq(strategy.totalSupply(), 1, "setup: positive supply");
        assertEq(strategy.balanceOf(donationAddress), 0, "setup: no dragon shares");
    }

    function _forceTotals(uint256 totalSupply_, uint256 totalAssets_) internal {
        vm.store(address(strategy), bytes32(TS_TOTAL_SUPPLY_SLOT), bytes32(totalSupply_));
        vm.store(address(strategy), bytes32(TS_TOTAL_ASSETS_SLOT), bytes32(totalAssets_));
    }
}
