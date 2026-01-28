// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC4626Payable } from "src/zodiac-core/interfaces/IERC4626Payable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title MockYieldStrategy
 * @notice A mock ERC-4626 compliant strategy for testing vault interactions
 */
contract MockYieldStrategy is ERC20, IERC4626Payable {
    address public asset;
    address public vault;
    uint8 private _decimals;
    uint256 public maxDebtLimit;
    bool public allowDeposits = true;

    constructor(address _asset, address _vault) ERC20("Mock Yield Strategy", "mYSTRAT") {
        asset = _asset;
        vault = _vault;
        _decimals = IERC20Metadata(_asset).decimals();
        maxDebtLimit = type(uint256).max;
    }

    // Allow the vault to set this for testing different scenarios
    function setMaxDebt(uint256 newMaxDebt) external {
        maxDebtLimit = newMaxDebt;
    }

    // Toggle deposits on/off for testing
    function setAllowDeposits(bool _allow) external {
        allowDeposits = _allow;
    }

    // Add yield to strategy (simulate earnings)
    function addYield(uint256 amount) external {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
    }

    // Report profits to vault
    function report() external virtual {
        asset = asset; // prevent compiler warning
    }

    // ERC-20 Functions
    function decimals() public view override(ERC20, IERC20Metadata) returns (uint8) {
        return _decimals;
    }

    // ERC-4626 Functions
    function totalAssets() public view virtual override returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return assets;
        }
        return (assets * supply) / totalAssets();
    }

    function convertToAssets(uint256 shares) public view virtual override returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return shares;
        }
        return (shares * totalAssets()) / supply;
    }

    function maxDeposit(address receiver) public view virtual override returns (uint256) {
        if (receiver != vault || !allowDeposits) {
            return 0;
        }
        return maxDebtLimit;
    }
    function maxMint(address receiver) public view override returns (uint256) {
        return convertToShares(maxDeposit(receiver));
    }

    function maxWithdraw(address owner) public view virtual override returns (uint256) {
        return convertToAssets(balanceOf(owner));
    }

    function maxRedeem(address owner) public view virtual override returns (uint256) {
        return balanceOf(owner);
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) public view override returns (uint256) {
        return convertToAssets(shares);
    }

    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0 || totalAssets() == 0) {
            return 0;
        }
        return Math.ceilDiv(assets * supply, totalAssets());
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return convertToAssets(shares);
    }

    function deposit(uint256 assets, address receiver) public payable virtual override returns (uint256) {
        require(assets <= maxDeposit(receiver), "Deposit limit exceeded");
        uint256 shares = previewDeposit(assets);

        // Transfer assets from sender to strategy
        IERC20(asset).transferFrom(msg.sender, address(this), assets);

        // Mint shares to receiver
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
        return shares;
    }

    function mint(uint256 shares, address receiver) public payable override returns (uint256) {
        uint256 assets = previewMint(shares);
        require(assets <= maxDeposit(receiver), "Deposit limit exceeded");

        // Transfer assets from sender to strategy
        IERC20(asset).transferFrom(msg.sender, address(this), assets);

        // Mint shares to receiver
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        uint256 shares = previewWithdraw(assets);

        if (msg.sender != owner) {
            uint256 allowed = allowance(owner, msg.sender);
            if (allowed != type(uint256).max) {
                _approve(owner, msg.sender, allowed - shares);
            }
        }

        _burn(owner, shares);
        IERC20(asset).transfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) public virtual override returns (uint256) {
        uint256 assets = previewRedeem(shares);

        if (msg.sender != owner) {
            uint256 allowed = allowance(owner, msg.sender);
            if (allowed != type(uint256).max) {
                _approve(owner, msg.sender, allowed - shares);
            }
        }

        _burn(owner, shares);
        IERC20(asset).transfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return assets;
    }

    function simulateLoss(uint256 amount) external virtual {
        // Transfer funds out of the strategy to simulate a loss
        // This will make the strategy report less assets than it was allocated
        IERC20(asset).transfer(msg.sender, amount);
    }

    // Permit functions as required by IERC4626Payable
    function permit(address owner, address spender, uint256 value, uint256, uint8, bytes32, bytes32) external {
        // Mock implementation for interface compatibility
        _approve(owner, spender, value);
    }
}
