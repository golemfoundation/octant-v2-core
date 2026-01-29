// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Module } from "zodiac/core/Module.sol";
import { Enum } from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

contract MockYieldSource is ERC4626Upgradeable {
    function setUp(address _asset) public initializer {
        __ERC4626_init(IERC20(_asset));
    }

    //function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
    //    uint256 withdrawable = Math.min(assets, maxWithdraw(owner));
    //
    //    _withdraw(_msgSender(), receiver, owner, withdrawable, withdrawable);
    //    return withdrawable;
    //}

    // This is the implementation of withdraw deployed in `tokenizedStrategyAddress` of the YIELD_SOURCE address:
    // https://polygonscan.com/address/0x52367C8E381EDFb068E9fBa1e7E9B2C847042897#code#L1127

    // https://polygonscan.com/address/0xdfc8cd9f2f2d306b7c0d109f005df661e14f4ff2#code#L1833
    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256 shares) {
        return withdraw(assets, receiver, owner, 0);
    }

    // https://polygonscan.com/address/0xdfc8cd9f2f2d306b7c0d109f005df661e14f4ff2#code#L1846
    function withdraw(
        uint256 assets,
        address receiver,
        address owner,
        uint256 /* maxLoss */
    ) public returns (uint256 shares) {
        require(assets <= maxWithdraw(owner), "ERC4626: withdraw more than max");
        // Check for rounding error or 0 value.
        //require((shares = previewWithdraw(assets)) != 0, "ZERO_SHARES");
        // Simplification, otherwise we get a smt-solver crash
        // TODO: Fix this later
        shares = assets;

        // Withdraw and track the actual amount withdrawn for loss check.
        // For simplicity I call the internal _withdraw from ERC4626Upgradeable instead of:
        // https://polygonscan.com/address/0xdfc8cd9f2f2d306b7c0d109f005df661e14f4ff2#code#L2185
        //_withdraw(receiver, owner, assets, shares, maxLoss);
        _withdraw(_msgSender(), receiver, owner, assets, shares);
    }

    function availableDepositLimit(address /*_owner*/) public view virtual returns (uint256) {
        return type(uint256).max;
    }
}
