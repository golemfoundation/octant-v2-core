// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.23;

import { Trader } from "./Trader.sol";
import { DragonRouter } from "src/zodiac-core/DragonRouter.sol";

/**
 * @title TraderBotEntry
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Helper contract for automated split claiming via Trader
 * @dev Stateless helper that atomically claims and trades user splits
 *
 *      FLOW:
 *      1. Query trader.findSaleValue(max(saleValueHigh, user's balance))
 *      2. Call router.claimSplit(user, strategy, amount)
 *      3. Claimed amount goes through user's transformer (if set)
 *
 *      USE CASE:
 *      Enables bots to claim optimal amounts for users without
 *      requiring users to know sale values in advance
 */
contract TraderBotEntry {
    /// @notice Initialize stateless helper
    constructor() {}

    /**
     * @notice Atomically claims and trades user's split via Trader
     * @dev Calculates optimal claim amount from Trader's findSaleValue
     *
     * @param _router DragonRouter address
     * @param user User address to claim for
     * @param strategy Strategy address to claim from
     * @param _trader Trader contract address for execution
     */
    function flash(address _router, address user, address strategy, address _trader) public {
        Trader trader = Trader(payable(_trader));
        DragonRouter router = DragonRouter(payable(_router));
        uint256 amount = trader.findSaleValue(max(trader.saleValueHigh(), router.balanceOf(user, strategy)));
        router.claimSplit(user, strategy, amount);
    }

    /// @notice Returns the maximum of two values
    function max(uint256 a, uint256 b) private pure returns (uint256 maximum) {
        if (a > b) return a;
        else return b;
    }
}
