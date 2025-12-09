// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import { TestPlus } from "solady-test/utils/TestPlus.sol";
import "src/utils/routers-transformers/Trader.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { HelperConfig } from "script/helpers/HelperConfig.s.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { NATIVE_TOKEN } from "src/constants.sol";

contract TestTraderRandomness is Test, TestPlus {
    MockERC20 public token;

    HelperConfig helperConfig = new HelperConfig(true);

    address owner = makeAddr("owner");
    address beneficiary = makeAddr("beneficiary");
    address swapper = makeAddr("swapper");
    address integrator;
    address oracle = makeAddr("oracle");
    address alt_swapper = makeAddr("alt_swapper");
    address alt_integrator = makeAddr("alt_integrator");
    bool log_spending = false;
    string constant deadlineFn = "./cache/test-artifacts/deadline.csv";

    Trader trader;

    function setUp() public {
        token = new MockERC20(18);

        helperConfig = new HelperConfig(true);
        (, address wethToken, , , , , , , address integrator_, ) = helperConfig.activeNetworkConfig();
        integrator = integrator_;

        trader = new Trader(
            abi.encode(owner, NATIVE_TOKEN, uint24(10_000), token, wethToken, beneficiary, swapper, integrator, oracle)
        );
        token.mint(address(owner), 100 ether);
    }

    receive() external payable {}

    function testConfigurationBasic() public {
        vm.startPrank(owner);
        trader.configurePeriod(block.number, 102);
        trader.setSpending(1 ether, 1 ether, 1 ether);
        vm.stopPrank();
        assertEq(trader.getSafetyBlocks(), 1);
        assertEq(trader.deadline(), block.number + 102);
        assertEq(trader.remainingBlocks(), 101);
        assertTrue(trader.chance() > 0);
        assertTrue(trader.saleValueLow() == 1 ether);
        assertTrue(trader.saleValueHigh() == 1 ether);
    }

    function testConfigurationLowSaleIsTooLow() public {
        vm.startPrank(owner);
        trader.configurePeriod(block.number, 102);
        vm.expectRevert(Trader.Trader__ImpossibleConfigurationSaleValueLowIsTooLow.selector);
        trader.setSpending(1, 1 ether, 1 ether);
        vm.stopPrank();
    }

    function testConfigurationLowIsZero() public {
        vm.startPrank(owner);
        trader.configurePeriod(block.number, 102);
        vm.expectRevert(Trader.Trader__ImpossibleConfigurationSaleValueLowIsZero.selector);
        trader.setSpending(0, 1 ether, 1 ether);
        vm.stopPrank();
    }

    function testNextDeadline() public {
        vm.startPrank(owner);
        trader.configurePeriod(block.number, 100);
        trader.setSpending(1 ether, 1 ether, 1 ether);
        assertEq(trader.deadline(), block.number + 100);
    }

    // sequential call to this function emulate time progression
    function wrapBuy() public returns (bool) {
        vm.roll(block.number + 1);
        try trader.convert(block.number - 1) {
            if (log_spending) {
                string memory currentBudget = vm.toString((trader.budget() - trader.spent()) / 1e15);
                vm.writeLine(deadlineFn, string(abi.encodePacked(vm.toString(block.number), ",", currentBudget)));
            }
            return true;
        } catch (bytes memory) /*lowLevelData*/ {
            return false;
        }
    }

    function test_receivesEth() external {
        (bool sent, ) = payable(address(trader)).call{ value: 100000 }("");
        require(sent, "Failed to send Ether");
    }

    function concat(string memory _a, string memory _b) public pure returns (string memory) {
        return string(abi.encodePacked(_a, _b));
    }

    function test_deadline() external {
        uint256 budget = 1000 ether;
        vm.deal(address(trader), budget);
        if (vm.exists(deadlineFn)) {
            vm.removeFile(deadlineFn);
        }
        uint256 blocks = 10_000;
        vm.startPrank(owner);
        trader.configurePeriod(block.number, blocks);
        trader.setSpending(0.6 ether, 1.4 ether, budget);
        vm.stopPrank();
        assertEq(address(trader).balance, budget);
        assertEq(trader.budget(), budget);
        assertEq(trader.spent(), 0);
        for (uint256 i = 0; i < blocks; i++) {
            wrapBuy();
        }
        assertEq(trader.budget(), trader.spent());
    }

    function test_safety_blocks_value() external {
        uint256 blocks = 1_000_000;
        vm.startPrank(owner);
        trader.configurePeriod(block.number, blocks);
        trader.setSpending(1 ether, 1 ether, 100_000 ether);
        vm.stopPrank();
        assertEq(trader.getSafetyBlocks(), 100_000);
    }

    function test_changeOfSpendingAndDeadline() external {
        uint256 blocks = 1_000;
        vm.deal(address(trader), 100 ether);
        vm.startPrank(owner);
        trader.configurePeriod(block.number, blocks);
        trader.setSpending(1 ether, 1 ether, 100 ether);
        vm.stopPrank();
        for (uint256 i = 0; i < blocks / 2; i++) {
            wrapBuy();
        }
        vm.startPrank(owner);
        // make more smaller trades
        trader.setSpending(0.5 ether, 0.5 ether, 100 ether);
        vm.stopPrank();
        for (uint256 i = 0; i < blocks / 2; i++) {
            wrapBuy();
        }
        assertEq(address(trader).balance, 0);
    }

    function test_emergecy_stop_stop_throws() external {
        vm.startPrank(owner);
        trader.emergencyStop(true);

        vm.expectRevert();
        trader.emergencyStop(true);
        vm.stopPrank();
    }

    function test_emergecy_resume_resume_throws() external {
        vm.startPrank(owner);

        vm.expectEmit(true, false, false, false, address(trader));
        emit Pausable.Paused(owner);
        trader.emergencyStop(true);

        vm.expectEmit(true, false, false, false, address(trader));
        emit Pausable.Unpaused(owner);
        trader.emergencyStop(false);

        vm.expectRevert();
        trader.emergencyStop(false);

        vm.stopPrank();
    }

    function test_emergencyStop() external {
        uint256 blocks = 1_000;
        vm.deal(address(trader), 105 ether);
        vm.startPrank(owner);
        trader.configurePeriod(block.number, blocks);
        trader.setSpending(0.9 ether, 1.1 ether, 100 ether);
        vm.stopPrank();
        for (uint256 i = 0; i < blocks / 3; i++) {
            wrapBuy();
        }
        uint256 oldBalance = address(trader).balance;
        uint256 oldSpent = trader.spent();

        vm.startPrank(owner);
        // stop trading
        trader.emergencyStop(true);
        vm.stopPrank();

        for (uint256 i = 0; i < blocks / 3; i++) {
            wrapBuy();
        }
        assertEq(oldBalance, address(trader).balance);
        assertEq(oldSpent, trader.spent());

        // resume trading
        vm.startPrank(owner);
        trader.emergencyStop(false);
        vm.stopPrank();

        for (uint256 i = 0; i < blocks / 3; i++) {
            wrapBuy();
        }
        assertLt(oldSpent, trader.spent());
        assertEq(trader.spent(), trader.budget());
    }

    function test_spendADay() external {
        uint256 blocks = 1_000_000;
        vm.startPrank(owner);
        trader.configurePeriod(block.number, blocks);
        trader.setSpending(1 ether, 1 ether, 100_000 ether);
        vm.stopPrank();
        assertApproxEqAbs(trader.spendADay(), 720 ether, 0.1 ether);
    }

    function test_reuse_randomness() external {
        uint256 blocks = 1000;
        vm.startPrank(owner);
        trader.configurePeriod(block.number, blocks);
        trader.setSpending(1 ether, 1 ether, 100 ether);
        vm.stopPrank();
        bool traded;
        for (uint256 i = 0; i < blocks; i++) {
            vm.roll(block.number + 1);
            bool canTrade = trader.canTrade(block.number - 1);
            try trader.convert(block.number - 1) {
                traded = true;
            } catch (bytes memory) /*lowLevelData*/ {
                traded = false;
            }
            if (traded) {
                vm.expectRevert(Trader.Trader__RandomnessAlreadyUsed.selector);
                trader.convert(block.number - 1);
            }
            assert(!traded || canTrade); // traded => canTrade;
        }
    }

    function test_unsafe_seed() external {
        uint256 blocks = 1000;
        vm.startPrank(owner);
        trader.configurePeriod(block.number, blocks);
        trader.setSpending(1 ether, 1 ether, 100 ether);
        vm.stopPrank();
        vm.roll(500);
        vm.expectRevert(Trader.Trader__RandomnessUnsafeSeed.selector);
        trader.convert(block.number - 300);
    }

    function test_reconfigure() external {
        uint256 blocks = 1000;
        vm.startPrank(owner);
        trader.configurePeriod(block.number, blocks);
        trader.setSpending(1 ether, 1 ether, 100 ether);
        vm.stopPrank();
        for (uint256 i = 0; i < blocks / 2; i++) {
            wrapBuy();
        }
        vm.startPrank(owner);
        trader.configurePeriod(block.number, blocks);
        trader.setSpending(0.5 ether, 1 ether, address(trader).balance);
        vm.stopPrank();
        for (uint256 i = 0; i < (blocks / 2) + 1; i++) {
            wrapBuy();
        }
        assert(trader.spent() == trader.budget());
    }

    function test_multiple_periods() public {
        vm.deal(address(trader), 1000 ether);
        uint256 blocks = 1000;
        vm.startPrank(owner);
        trader.configurePeriod(block.number, blocks);
        trader.setSpending(1 ether, 1 ether, 100 ether);
        for (uint256 i = 0; i < 5500; i++) {
            wrapBuy();
        }
        assert(trader.deadline() - block.number <= blocks);
        assert(trader.spent() <= 100 ether);
        assert(trader.spent() >= 0);
        assert(trader.budget() <= 100 ether);
        assert(trader.budget() >= 0);
        assert(address(trader).balance < 500 ether);
        assert(address(trader).balance > 100 ether);
    }

    function test_safety_blocks_chance() external {
        uint256 blocks = 1000;
        vm.startPrank(owner);
        trader.configurePeriod(block.number, blocks);
        trader.setSpending(1 ether, 1 ether, 1000 ether);
        vm.stopPrank();
        vm.roll(block.number + blocks - trader.getSafetyBlocks());
        assertEq(type(uint256).max, trader.chance());
        vm.roll(block.number + blocks - 1);
        assertEq(type(uint256).max, trader.chance());
    }

    function test_overspend_protection() external {
        // This test will attempt to overspend, simulating validator griding hash values.
        // Since forge doesn't allow to manipulate blockhash directly, overspending
        // is done by manipulating return value of `chance()` function.
        vm.deal(address(trader), 300 ether);
        uint256 blocks = 1000;
        vm.startPrank(owner);
        uint256 budget_value = 100 ether;
        trader.configurePeriod(block.number, blocks);
        trader.setSpending(1 ether, 1 ether, budget_value);
        vm.stopPrank();

        // mock chance
        vm.mockCall(address(trader), abi.encodeWithSelector(Trader.chance.selector), abi.encode(type(uint256).max - 1));

        // sanity check
        assertEq(type(uint256).max - 1, trader.chance());

        /* run trader */
        for (uint256 i = 0; i < (blocks / 10) * 25; i++) {
            wrapBuy();
        }
        assertLe(trader.spent(), trader.budget() / 2);
        assertGe(address(trader).balance, 49 ether);
    }

    function test_chance_high() external {
        uint256 blocks = 1_000_000;
        vm.startPrank(owner);
        trader.configurePeriod(block.number, blocks);
        trader.setSpending(1 ether, 1 ether, 100_000 ether);
        vm.stopPrank();
        assertLt(trader.chance(), type(uint256).max / 9);
    }

    function test_chance_low() external {
        uint256 blocks = 1_000_000;
        vm.startPrank(owner);
        trader.configurePeriod(block.number, blocks);
        trader.setSpending(1 ether, 1 ether, 100_000 ether);
        vm.stopPrank();
        assertGt(trader.chance(), type(uint256).max / 11);
    }

    function test_avg_sale_chance_high() external {
        uint256 blocks = 1_000_000;
        vm.startPrank(owner);
        trader.configurePeriod(block.number, blocks);
        trader.setSpending(1 ether, 3 ether, 100_000 ether);
        vm.stopPrank();
        assertLt(trader.chance(), type(uint256).max / 18);
    }

    function test_avg_sale_chance_low() external {
        uint256 blocks = 1_000_000;
        vm.startPrank(owner);
        trader.configurePeriod(block.number, blocks);
        trader.setSpending(1 ether, 3 ether, 100_000 ether);
        vm.stopPrank();
        assertGt(trader.chance(), type(uint256).max / 20);
    }

    function test_division() external pure {
        assertLt(0, type(uint256).max / uint256(4000));
        assertLt(type(uint256).max / uint256(4000), type(uint256).max / uint256(3999));
        uint256 maxdiv4096 = 28269553036454149273332760011886696253239742350009903329945699220681916416;
        assertGt(type(uint256).max / uint256(4095), maxdiv4096);
        assertLt(type(uint256).max / uint256(4097), maxdiv4096);
    }

    function test_getUniformInRange_wei() public view {
        runner_getUniformInRange(0, 256);
    }

    function test_getUniformInRange_ether() public view {
        runner_getUniformInRange(100 ether, 200 ether);
    }

    function test_getUniformInRange_highEthers() public view {
        runner_getUniformInRange(1_000_000 ether, 2_000_000 ether);
    }

    function runner_getUniformInRange(uint256 low, uint256 high) public view {
        uint256 counter = 0;
        uint256 val = 0;
        uint256 min = type(uint256).max;
        uint256 max = type(uint256).min;
        uint256 mid = uint256((high + low) / 2);

        for (uint256 i = 0; i < 100_000; i++) {
            val = trader.getUniformInRange(low, high, i);
            if (val < mid) counter = counter + 1;
            if (val > max) max = val;
            if (val < min) min = val;
        }
        assertLt(49_500, counter); // EV(counter) ~= 50_000
        assertLt(counter, 51_500); // EV(counter) ~= 50_000
        if (high - low < 1000) {
            assertEq(min, low);
            assertEq(max, high - 1);
        }
    }

    function test_getUniformInRange_narrow() public view {
        assertEq(1 ether, trader.getUniformInRange(1 ether, 1 ether, 4));
    }

    function test_blockHashValues() public {
        vm.roll(block.number + 20);
        for (uint256 i = 1; i < 11; i++) {
            assert(blockhash(block.number - i) != blockhash(block.number - i - 1));
            assert(trader.getRandomNumber(block.number - i) != trader.getRandomNumber(block.number - i - 1));
        }
    }

    function test_futureBlockHashValues() public {
        vm.roll(block.number + 20);
        assert(blockhash(block.number - 1) != bytes32(0));
        assert(blockhash(block.number) == bytes32(0));
        assert(blockhash(block.number + 1) == bytes32(0));
    }

    function test_setSwapper() public {
        assert(trader.swapper() == swapper);
        assert(trader.integrator() == integrator);
        vm.expectRevert();
        trader.setSwapper(alt_swapper, alt_integrator);
        assert(trader.swapper() == swapper);
        assert(trader.integrator() == integrator);
        vm.startPrank(owner);
        trader.setSwapper(alt_swapper, alt_integrator);
        vm.stopPrank();
        assert(trader.swapper() == alt_swapper);
        assert(trader.integrator() == alt_integrator);
    }
}
