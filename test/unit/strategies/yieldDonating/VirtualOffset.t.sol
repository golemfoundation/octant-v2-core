// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.18;

import { Setup } from "./utils/Setup.sol";

contract VirtualOffsetTest is Setup {
    uint256 internal constant DECIMALS_OFFSET = 6;
    uint256 internal constant TS_BASE = uint256(0x4df8983d84042631e7325fb5ba31b73b056fa9890e796c4c95fbf1e6d76eba00);
    uint256 internal constant TS_BALANCES_SLOT = TS_BASE + 1;
    uint256 internal constant TS_TOTAL_SUPPLY_SLOT = TS_BASE + 8;
    uint256 internal constant TS_TOTAL_ASSETS_SLOT = TS_BASE + 9;

    address internal dustHolder = address(0xA11CE);
    address internal depositor = address(0xB0B);

    function setUp() public override {
        super.setUp();
    }

    function test_openZeppelinStyleOffset_formulaMatchesConversions() public {
        _forceTotals({ totalSupply_: 10e18, totalAssets_: 5e18 });

        uint256 assets = 2e18;
        uint256 shares = 3e18;

        assertEq(
            strategy.convertToShares(assets),
            (assets * (10e18 + 10 ** DECIMALS_OFFSET)) / (5e18 + 1),
            "convertToShares should match OZ-style virtual offset"
        );
        assertEq(
            strategy.convertToAssets(shares),
            (shares * (5e18 + 1)) / (10e18 + 10 ** DECIMALS_OFFSET),
            "convertToAssets should match OZ-style virtual offset"
        );
    }

    function test_virtualOffset_preservesHealthyFirstDepositOneToOne() public {
        uint256 assets = 100e18;

        asset.mint(depositor, assets);
        vm.startPrank(depositor);
        asset.approve(address(strategy), assets);
        uint256 shares = strategy.deposit(assets, depositor);
        vm.stopPrank();

        uint256 expectedShares = assets * SHARE_SCALE;

        assertEq(shares, expectedShares, "empty healthy vault should mint at the offset scale");
        assertEq(strategy.totalAssets(), assets, "total assets");
        assertEq(strategy.totalSupply(), expectedShares, "total supply");
        assertEq(strategy.balanceOf(depositor), expectedShares, "depositor shares");
    }

    function test_virtualOffset_allowsDepositWhenTrackedAssetsZeroAndSupplyDust() public {
        _createZeroAssetDustShareState();

        asset.mint(depositor, 1);
        vm.startPrank(depositor);
        asset.approve(address(strategy), 1);
        uint256 shares = strategy.deposit(1, depositor);
        vm.stopPrank();

        uint256 expectedShares = SHARE_SCALE + 1;

        assertEq(shares, expectedShares, "virtual offset should avoid ZERO_SHARES DoS");
        assertEq(strategy.totalAssets(), 1, "total assets after deposit");
        assertEq(strategy.totalSupply(), SHARE_SCALE + 2, "dust plus depositor shares");
        assertEq(strategy.maxRedeem(depositor), expectedShares, "depositor shares redeemable");
        assertEq(strategy.convertToAssets(expectedShares), 1, "depositor can recover the deposited wei");
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
        uint256 expectedDragonShares = recoveredAssets * (SHARE_SCALE + 1);
        assertEq(strategy.balanceOf(donationAddress), expectedDragonShares, "dragon gets all recovery shares");
        assertEq(strategy.totalSupply(), expectedDragonShares + 1, "dust remains but no longer dominates");
        assertEq(strategy.maxWithdraw(donationAddress), recoveredAssets, "dragon owns the recovered assets");

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

    function test_virtualOffset_zeroAssetRecoveryFullyBelongsToDragonEvenWithNonDustSupply() public {
        address lossHolder = address(0xCAFE);
        uint256 oldSupply = 100e18 * SHARE_SCALE;
        uint256 recoveredAssets = 100e18;

        _forceTotals({ totalSupply_: oldSupply, totalAssets_: 0 });
        _forceBalance(lossHolder, oldSupply);
        asset.mint(address(yieldSource), recoveredAssets);

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        uint256 expectedDragonShares = recoveredAssets * (oldSupply + SHARE_SCALE);

        assertEq(profit, recoveredAssets, "recovery should be reported as profit");
        assertEq(loss, 0, "no loss on recovery");
        assertEq(strategy.balanceOf(donationAddress), expectedDragonShares, "dragon receives the full recovery claim");
        assertEq(strategy.maxWithdraw(donationAddress), recoveredAssets, "dragon can withdraw recovered assets");
        assertEq(strategy.maxWithdraw(lossHolder), 0, "old zero-asset supply has no recovery claim");
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
        uint256 expectedDragonShares = recoveredAssets * SHARE_SCALE;
        assertEq(strategy.balanceOf(donationAddress), expectedDragonShares, "dragon receives first recovery shares");
        assertEq(strategy.totalSupply(), expectedDragonShares, "recovery creates dragon supply");
        assertEq(strategy.totalAssets(), recoveredAssets, "assets tracked");
        assertEq(strategy.maxWithdraw(donationAddress), recoveredAssets, "dragon owns the recovered assets");
    }

    function _createZeroAssetDustShareState() internal {
        _forceTotals({ totalSupply_: 1, totalAssets_: 0 });
        _forceBalance(dustHolder, 1);

        assertEq(strategy.totalAssets(), 0, "setup: zero tracked assets");
        assertEq(strategy.totalSupply(), 1, "setup: dust share");
        assertEq(strategy.balanceOf(dustHolder), 1, "setup: holder has one dust share");
    }

    function _forceTotals(uint256 totalSupply_, uint256 totalAssets_) internal {
        vm.store(address(strategy), bytes32(TS_TOTAL_SUPPLY_SLOT), bytes32(totalSupply_));
        vm.store(address(strategy), bytes32(TS_TOTAL_ASSETS_SLOT), bytes32(totalAssets_));
    }

    function _forceBalance(address account, uint256 balance) internal {
        vm.store(address(strategy), keccak256(abi.encode(account, bytes32(TS_BALANCES_SLOT))), bytes32(balance));
    }
}
