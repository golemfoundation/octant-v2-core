// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { MockYieldStrategy } from "../zodiac-core/MockYieldStrategy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockLossyStrategy is MockYieldStrategy {
    uint256 public lossAmount;
    uint256 public withdrawingLoss;
    bool public isExtraYield;
    uint256 public lockedAmount;
    uint256 public unlockTime;
    bool public isERC4626Test;

    constructor(address _asset, address _vault) MockYieldStrategy(_asset, _vault) {}

    function setLoss(uint256 _lossAmount) external {
        lossAmount = _lossAmount;

        // Simulate the loss by transferring out the tokens
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (balance >= _lossAmount) {
            IERC20(asset).transfer(address(1), _lossAmount);
        }
    }

    // Set the ERC4626 test compatibility flag
    function setERC4626TestMode(bool _isERC4626Test) external {
        isERC4626Test = _isERC4626Test;
    }

    // Set loss that happens only during withdrawal
    function setWithdrawingLoss(uint256 _withdrawingLoss) external {
        withdrawingLoss = _withdrawingLoss;
        isExtraYield = false;
    }

    // Set extra yield that happens during withdrawal
    function setWithdrawingExtraYield(uint256 _extraYield) external {
        withdrawingLoss = _extraYield;
        isExtraYield = true;
    }

    // Set funds as locked for a period
    function setLockedFunds(uint256 _amount, uint256 duration) external {
        lockedAmount = _amount;
        unlockTime = block.timestamp + duration;
    }

    // Set permanent loss
    function setLockedFunds(uint256 _amount) external {
        lockedAmount = _amount;
        unlockTime = block.timestamp + 365 days; // Lock for a long time
    }

    function yieldSource() public view returns (address) {
        return address(this);
    }

    // Correctly report total assets
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    // Correctly calculate assets from shares
    function convertToAssets(uint256 shares) public view override returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return shares;
        }

        return (totalAssets() * shares) / supply;
    }

    // Override max withdraw to account for locked funds
    function maxWithdraw(address) public view override returns (uint256) {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (balance <= lockedAmount) {
            return 0;
        }
        return balance - lockedAmount;
    }

    // Handle the division by zero case when all funds are lost
    function maxRedeem(address owner) public view override returns (uint256) {
        // Special handling for ERC4626 compatibility test
        if (isERC4626Test) {
            // In ERC4626 test mode, return all shares owned by the address
            // This matches the behavior expected in the ERC4626 compatibility test
            return balanceOf(owner);
        }

        // Get available withdrawal limit in assets
        uint256 availableAssets = availableWithdrawLimit(owner);

        // If there's no limit or the strategy has no assets but has shares
        if (availableAssets == type(uint256).max || totalAssets() == 0) {
            return balanceOf(owner);
        }

        // Convert available assets to shares with rounding down
        uint256 supply = totalSupply();
        if (supply == 0) return 0;

        uint256 availableShares = (availableAssets * supply) / totalAssets();

        // Return the minimum of available shares and user's balance
        return availableShares < balanceOf(owner) ? availableShares : balanceOf(owner);
    }

    // Implement availableWithdrawLimit to determine how many assets can be withdrawn
    function availableWithdrawLimit(address) public view returns (uint256) {
        // In our case, all assets are in the strategy itself (no separate yieldSource)
        uint256 balance = IERC20(asset).balanceOf(address(this));

        // If funds are locked, reduce available amount
        if (balance <= lockedAmount) {
            return 0;
        }

        return balance - lockedAmount;
    }

    function maxDeposit(address) public view override returns (uint256) {
        isERC4626Test; // used to avoid pure func error
        return type(uint256).max;
    }

    // Handle withdrawals with all types of special conditions
    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        // Limit shares to max available, unless in ERC4626 test mode
        if (!isERC4626Test) {
            uint256 maxShares = maxRedeem(owner);
            if (shares > maxShares && maxShares > 0) {
                shares = maxShares;
            }
        }

        // Calculate assets based on shares proportion
        uint256 totalShares = totalSupply();
        uint256 totalAssetAmount = totalAssets();
        uint256 assets = totalShares > 0 ? (totalAssetAmount * shares) / totalShares : 0;

        if (msg.sender != owner) {
            uint256 allowed = allowance(owner, msg.sender);
            if (allowed != type(uint256).max) {
                _approve(owner, msg.sender, allowed - shares);
            }
        }

        _burn(owner, shares);

        // Apply withdrawal loss
        uint256 actualAssets;
        if (isExtraYield) {
            // Extra yield case
            actualAssets = assets + withdrawingLoss;
            IERC20(asset).transfer(receiver, actualAssets);
        } else {
            // Loss case
            actualAssets = assets > withdrawingLoss ? assets - withdrawingLoss : 0;
            IERC20(asset).transfer(receiver, actualAssets);

            // Apply the loss physically
            if (withdrawingLoss > 0) {
                IERC20(asset).transfer(address(1), withdrawingLoss);
            }
        }

        emit Withdraw(msg.sender, receiver, owner, actualAssets, shares);
        return actualAssets;
    }

    // Optional: Override the simulateLoss method to actually transfer funds when needed
    function simulateLoss(uint256 amount) external override {
        // First set the loss amount
        lossAmount = amount;
        // Then actually transfer the funds out if requested
        // This makes the physical state match the reported state
        IERC20(asset).transfer(msg.sender, amount);
    }
}
