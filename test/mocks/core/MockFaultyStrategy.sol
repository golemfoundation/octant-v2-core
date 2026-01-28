// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { MockYieldStrategy } from "../zodiac-core/MockYieldStrategy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockFaultyStrategy is MockYieldStrategy {
    constructor(address _asset, address _vault) MockYieldStrategy(_asset, _vault) {}

    // Override deposit to only take half the assets
    function deposit(uint256 assets, address receiver) public payable override returns (uint256) {
        // Only accept half the assets
        uint256 actualAssets = assets / 2;
        uint256 shares = previewDeposit(actualAssets);

        // Transfer only half the assets
        IERC20(asset).transferFrom(msg.sender, address(this), actualAssets);

        // Mint shares to the receiver
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, actualAssets, shares);

        return shares;
    }
}
