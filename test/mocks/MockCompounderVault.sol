// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockCompounderVault
 * @notice Mock ERC4626 vault that simulates a Morpho compounder vault for testing
 * @dev Implements minimal ITokenizedStrategy interface for MorphoCompounderStrategy testing
 */
contract MockCompounderVault {
    using SafeERC20 for IERC20;

    address public immutable asset;
    mapping(address => uint256) private _balanceOf;
    uint256 private _totalSupply;
    uint256 public totalAssets;

    // Growth rate per second (1e18 = 100% APY)
    uint256 public growthRate = 3171; // approximately 10% APY when multiplied by seconds in year

    constructor(address _asset) {
        asset = _asset;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), assets);

        shares = convertToShares(assets);
        _balanceOf[receiver] += shares;
        _totalSupply += shares;
        totalAssets += assets;

        return shares;
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner,
        uint256 /*maxLoss*/
    ) external returns (uint256 shares) {
        require(msg.sender == owner, "Unauthorized");

        shares = convertToShares(assets);
        require(_balanceOf[owner] >= shares, "Insufficient balance");

        _balanceOf[owner] -= shares;
        _totalSupply -= shares;
        totalAssets -= assets;

        IERC20(asset).safeTransfer(receiver, assets);

        return shares;
    }

    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        return convertToAssets(_balanceOf[owner]);
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        if (_totalSupply == 0) {
            return assets;
        }
        return (assets * _totalSupply) / totalAssets;
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        if (_totalSupply == 0) {
            return shares;
        }
        return (shares * totalAssets) / _totalSupply;
    }

    // Simulate yield growth
    function simulateYield(uint256 timeElapsed) external {
        uint256 growth = (totalAssets * growthRate * timeElapsed) / 1e18;
        totalAssets += growth;
    }

    // Minimal implementations to work as yield source
    function name() external pure returns (string memory) {
        return "Mock Compounder";
    }
    function symbol() external pure returns (string memory) {
        return "MCOMP";
    }
    function decimals() external pure returns (uint8) {
        return 18;
    }
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }
    function balanceOf(address account) external view returns (uint256) {
        return _balanceOf[account];
    }
}
