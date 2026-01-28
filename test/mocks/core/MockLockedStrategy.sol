// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { MockYieldStrategy } from "../zodiac-core/MockYieldStrategy.sol";

contract MockLockedStrategy is MockYieldStrategy {
    uint256 public lockedFunds;
    uint256 public unlockTime;

    constructor(address _asset, address _vault) MockYieldStrategy(_asset, _vault) {}

    function freeLockedFunds() external {
        lockedFunds = 0;
    }

    function setLockedFunds(uint256 _lockedFunds, uint256 _unlockTime) external {
        lockedFunds = _lockedFunds;
        unlockTime = block.timestamp + _unlockTime;
    }

    // Override to limit withdrawable funds
    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 totalShares = balanceOf(owner);
        if (block.timestamp < unlockTime) {
            uint256 lockedShares = convertToShares(lockedFunds);
            return totalShares > lockedShares ? totalShares - lockedShares : 0;
        }
        return totalShares;
    }
}
