// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/Test.sol";

import "solady/tokens/ERC20.sol";

import { HelperConfig } from "../helpers/HelperConfig.s.sol";
import { Trader } from "src/utils/routers-transformers/Trader.sol";
import { NATIVE_TOKEN } from "src/constants.sol";

contract TraderStatus is Script, Test {
    address ETH;

    function run() external {
        address traderAddress = vm.envAddress("TRADER");

        emit log_named_uint("ChainID", block.chainid);
        require(traderAddress != address(0), "Please provide trader address via TRADER env var");
        emit log_named_address("Trader at", traderAddress);
        emit log_named_uint("Height", block.number);

        Trader trader = Trader(payable(traderAddress));
        address base = trader.BASE();
        address quote = trader.QUOTE();
        ETH = NATIVE_TOKEN;
        console.log("Selling (base):", getTicker(base), base);
        console.log("Buying (quote):", getTicker(quote), quote);
        uint256 chance = trader.chance();
        if (chance == 0) {
            emit log("Trade every (blocks): never");
        } else {
            uint256 tradeEveryNBlocks = type(uint256).max / chance;
            emit log_named_uint("Trade every (blocks)", tradeEveryNBlocks);
        }
        if (trader.canTrade(block.number - 1)) {
            emit log("Can trade: yes");
        } else {
            emit log("Can trade: no");
        }

        uint256 spent = trader.spent();
        emit log_named_decimal_uint("Spent (base)", spent, 18);

        uint256 height = block.number - trader.spentResetBlock();
        emit log_named_uint("Configured for (blocks)", height);

        emit log_named_decimal_uint("Contract balance (base)", safeBalanceOf(base, traderAddress), 18);

        int256 spendable = int256(
            (block.number - trader.spentResetBlock()) * (trader.spendADay() / trader.BLOCKS_PER_DAY())
        ) - int256(spent);
        emit log_named_decimal_int("Spendable (base)", spendable, 18);

        emit log_named_decimal_uint("Min trade (base)", trader.saleValueLow(), 18);
        emit log_named_decimal_uint("Max trade (base)", trader.saleValueHigh(), 18);
    }

    function getTicker(address token) public view returns (string memory result) {
        if (token == NATIVE_TOKEN) {
            result = "ETH";
        } else {
            result = ERC20(token).symbol();
        }
    }

    function safeBalanceOf(address token, address owner) private view returns (uint256) {
        if (token == NATIVE_TOKEN) {
            return owner.balance;
        } else {
            return ERC20(token).balanceOf(owner);
        }
    }
}
