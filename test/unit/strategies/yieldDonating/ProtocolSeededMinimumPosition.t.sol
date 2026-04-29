// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.25;

import { IMockStrategy } from "test/mocks/core/IMockStrategy.sol";
import { MockStrategy } from "test/mocks/core/tokenized-strategies/MockStrategy.sol";
import { MockYieldSource } from "test/mocks/core/tokenized-strategies/MockYieldSource.sol";
import { Setup } from "./utils/Setup.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

/// @notice Regression coverage for Bailsec's protocol-seeded minimum-position mitigation.
contract ProtocolSeededMinimumPositionTest is Setup {
    address internal attacker = address(0xA77A);
    address internal victim = address(0xB0B);

    function _deployUnseededStrategy()
        internal
        returns (IMockStrategy unseededStrategy, MockYieldSource freshYieldSource)
    {
        freshYieldSource = new MockYieldSource(address(asset));
        unseededStrategy = IMockStrategy(
            address(
                new MockStrategy(
                    address(asset),
                    address(freshYieldSource),
                    management,
                    keeper,
                    emergencyAdmin,
                    donationAddress,
                    address(implementation)
                )
            )
        );

        vm.startPrank(management);
        unseededStrategy.setKeeper(keeper);
        unseededStrategy.setEmergencyAdmin(emergencyAdmin);
        unseededStrategy.setPendingManagement(management);
        unseededStrategy.acceptManagement();
        vm.stopPrank();
    }

    function testSeedMinimumPositionLocksStrategyOwnedShares() public {
        (IMockStrategy unseededStrategy, MockYieldSource freshYieldSource) = _deployUnseededStrategy();

        assertEq(unseededStrategy.maxDeposit(user), 0, "deposits should stay closed before seed");
        assertEq(unseededStrategy.maxMint(user), 0, "mints should stay closed before seed");

        asset.mint(user, 1 ether);
        vm.startPrank(user);
        asset.approve(address(unseededStrategy), 1 ether);
        vm.expectRevert("MINIMUM_POSITION_UNSEEDED");
        unseededStrategy.deposit(1 ether, user);
        vm.stopPrank();

        asset.mint(management, minimumProtocolPosition);
        vm.startPrank(management);
        asset.approve(address(unseededStrategy), minimumProtocolPosition);
        uint256 seededShares = YieldDonatingTokenizedStrategy(address(unseededStrategy)).seedMinimumPosition();
        vm.stopPrank();

        assertEq(seededShares, minimumProtocolPosition, "seed shares");
        assertEq(unseededStrategy.totalSupply(), minimumProtocolPosition, "seeded supply");
        assertEq(unseededStrategy.totalAssets(), minimumProtocolPosition, "seeded assets");
        assertEq(unseededStrategy.balanceOf(address(unseededStrategy)), minimumProtocolPosition, "locked shares");
        assertEq(asset.balanceOf(address(freshYieldSource)), minimumProtocolPosition, "seed deployed");
        assertEq(unseededStrategy.balanceOf(management), 0, "management should not hold redeemable seed shares");
        assertEq(unseededStrategy.maxDeposit(user), type(uint256).max, "deposits open after seed");
        assertEq(unseededStrategy.maxMint(user), type(uint256).max, "mints open after seed");
    }

    function testSeedMinimumPositionCannotRunAfterVaultIsLive() public {
        asset.mint(management, minimumProtocolPosition);
        vm.startPrank(management);
        asset.approve(address(strategy), minimumProtocolPosition);
        vm.expectRevert("MINIMUM_POSITION_LATE");
        YieldDonatingTokenizedStrategy(address(strategy)).seedMinimumPosition();
        vm.stopPrank();
    }

    function testBailsecDustHolderCannotResetSupplyOrInflateVictimDeposit() public {
        uint256 attackerDeposit = 100 ether;
        uint256 recovery = 100 ether;
        uint256 victimDeposit = 150 ether;

        asset.mint(attacker, attackerDeposit);
        vm.startPrank(attacker);
        asset.approve(address(strategy), attackerDeposit);
        strategy.deposit(attackerDeposit, attacker);
        vm.stopPrank();

        assertEq(strategy.balanceOf(attacker), attackerDeposit, "attacker starts at 1:1 PPS");
        assertEq(strategy.totalSupply(), minimumProtocolPosition + attackerDeposit, "seed plus attacker supply");
        assertEq(strategy.totalAssets(), minimumProtocolPosition + attackerDeposit, "seed plus attacker assets");

        yieldSource.simulateLoss(minimumProtocolPosition + 1);

        vm.prank(attacker);
        uint256 burnedShares = strategy.withdraw(attackerDeposit - 1, attacker, attacker);

        assertEq(burnedShares, attackerDeposit - 1, "stale withdraw burns requested assets at 1:1");
        assertEq(strategy.balanceOf(attacker), 1, "attacker leaves one dust share");
        assertEq(strategy.totalAssets(), minimumProtocolPosition + 1, "tracked assets stale until report");

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        assertEq(profit, 0, "loss report profit");
        assertEq(loss, minimumProtocolPosition + 1, "loss report realizes seed plus dust shortfall");
        assertEq(strategy.totalAssets(), 0, "assets can still hit zero");
        assertEq(strategy.totalSupply(), minimumProtocolPosition + 1, "locked seed keeps supply non-zero");

        asset.mint(address(yieldSource), recovery);

        vm.prank(keeper);
        (profit, loss) = strategy.report();

        assertEq(profit, recovery, "recovery report profit");
        assertEq(loss, 0, "recovery report loss");
        assertEq(strategy.totalAssets(), recovery, "recovery tracked");
        assertEq(strategy.balanceOf(donationAddress), 0, "zero-asset recovery still mints no dragon shares");
        assertEq(strategy.totalSupply(), minimumProtocolPosition + 1, "recovery cannot reset supply");

        uint256 attackerRedeemable = strategy.maxWithdraw(attacker);

        vm.prank(attacker);
        uint256 attackerRecovered = strategy.redeem(1, attacker, attacker);

        assertEq(attackerRecovered, attackerRedeemable, "attacker only receives dust pro-rata recovery");
        assertLt(attackerRecovered, recovery / 1_000_000, "attacker recovery must be economically dust");
        assertEq(strategy.balanceOf(attacker), 0, "attacker dust burned");
        assertEq(strategy.totalSupply(), minimumProtocolPosition, "locked seed remains after attacker exits");
        assertGt(strategy.totalAssets(), 0, "recovered assets remain backed by locked seed");

        asset.mint(attacker, 1);
        vm.startPrank(attacker);
        asset.approve(address(strategy), 1);
        vm.expectRevert("ZERO_SHARES");
        strategy.deposit(1, attacker);
        vm.stopPrank();

        asset.mint(victim, victimDeposit);
        vm.startPrank(victim);
        asset.approve(address(strategy), victimDeposit);
        uint256 victimShares = strategy.deposit(victimDeposit, victim);
        vm.stopPrank();

        assertGt(victimShares, 1, "victim should not be floored to one dust share");
        assertApproxEqAbs(
            strategy.convertToAssets(victimShares),
            victimDeposit,
            strategy.convertToAssets(1) + 1,
            "victim deposit should price at current PPS"
        );
        assertEq(strategy.balanceOf(attacker), 0, "attacker has no claim after dust redeem");
    }
}
