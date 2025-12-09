// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/Test.sol";

import "solady/tokens/ERC20.sol";
import "solady/tokens/WETH.sol";

import { HelperConfig } from "../helpers/HelperConfig.s.sol";
import { Trader } from "src/utils/routers-transformers/Trader.sol";
import { NATIVE_TOKEN } from "src/constants.sol";

contract TraderRun is Script {
    Trader trader;

    address ETH;
    address base;
    address quote;

    function max(uint256 a, uint256 b) public pure returns (uint256) {
        if (a > b) return a;
        return b;
    }

    function run() external {
        (, , , uint256 deployerKey, , , , , , ) = new HelperConfig(false).activeNetworkConfig();

        trader = Trader(payable(vm.envAddress("TRADER")));
        ETH = NATIVE_TOKEN;
        base = trader.BASE();
        quote = trader.QUOTE();

        console.log("ChainID:", block.chainid);
        console.log("Trader at", address(trader));
        require(address(trader) != address(0), "Please provide trader address via TRADER env var");

        if (safeBalanceOf(base, address(trader)) != 0) {
            vm.startBroadcast(deployerKey);
            trade_loop();
            vm.stopBroadcast();
        } else {
            console.log("Trader is out of base token");
        }
    }

    function trade_loop() public {
        uint256 scanSince = max(block.number - 255, trader.lastHeight()) + 1;
        console.log("Scanning since", scanSince);
        for (uint256 height = scanSince; height < block.number - 1; height++) {
            if (safeBalanceOf(base, address(trader)) != 0) {
                if (trader.canTrade(height)) {
                    if (!trader.hasOverspent(height)) {
                        console.log("Height YES, has budget YES", height);
                        trader.convert(height);
                        uint256 sellable = safeBalanceOf(base, trader.swapper());
                        trader.callInitFlash(sellable);
                    } else {
                        console.log("Height YES, has budget no ", height);
                    }
                }
            }
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
