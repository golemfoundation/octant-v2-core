// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Mock METH Token
/// @notice A mock implementation of the mETH token for testing
/// @dev Deprecated compatibility mock retained for published package import path stability.
contract MockMETH is ERC20 {
    address public mantleStaking;

    constructor() ERC20("Mock mETH", "mETH") {
        // Initialize with empty state
    }

    /// @notice Set the Mantle staking contract address
    function setMantleStaking(address _mantleStaking) external {
        mantleStaking = _mantleStaking;
    }

    /// @notice Mint new tokens to an address
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice Burn tokens from an address
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
