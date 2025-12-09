// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.18;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { NATIVE_TOKEN } from "src/constants.sol";

contract MockYieldSource {
    address public asset;

    constructor(address _asset) {
        asset = _asset;
    }

    function deposit(uint256 _amount) public payable {
        if (asset != NATIVE_TOKEN) ERC20(asset).transferFrom(msg.sender, address(this), _amount);
    }

    function withdraw(uint256 _amount) public {
        uint256 _balance = asset == NATIVE_TOKEN ? address(this).balance : ERC20(asset).balanceOf(address(this));
        _amount = _amount > _balance ? _balance : _amount;
        if (asset == NATIVE_TOKEN) {
            (bool success, ) = msg.sender.call{ value: _amount }("");
            require(success, "Transfer Failed");
            return;
        }
        ERC20(asset).transfer(msg.sender, _amount);
    }

    function balance() public view returns (uint256) {
        return asset == NATIVE_TOKEN ? address(this).balance : ERC20(asset).balanceOf(address(this));
    }

    function simulateHarvestRewards(uint256 _amount) public {
        if (asset == NATIVE_TOKEN) {
            (bool success, ) = msg.sender.call{ value: _amount }("");
            require(success, "Transfer Failed");
            return;
        }
        ERC20(asset).transfer(msg.sender, _amount);
    }

    function simulateLoss(uint256 _amount) public {
        ERC20(asset).transfer(msg.sender, _amount);
    }

    function simulateProfit(uint256 _amount) public {
        // This would typically be called by the strategy to add profit
        // In a real scenario, this might mint new tokens or add to balance
        // For testing, we assume the caller provides the profit tokens
        if (asset != NATIVE_TOKEN) {
            ERC20(asset).transferFrom(msg.sender, address(this), _amount);
        }
    }
}
