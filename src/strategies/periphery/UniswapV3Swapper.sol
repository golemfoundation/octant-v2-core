// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ISwapRouter } from "@tokenized-strategy-periphery/interfaces/Uniswap/V3/ISwapRouter.sol";

/**
 * @title UniswapV3Swapper
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Uniswap V3 swap utilities for exact input and exact output swaps
 * @dev Address variables default to ETH mainnet. Inheriting contract must set uniFees for token pairs.
 * @custom:origin https://github.com/yearn/tokenized-strategy-periphery/blob/master/src/swappers/UniswapV3Swapper.sol
 */
contract UniswapV3Swapper {
    using SafeERC20 for ERC20;

    // slither-disable-next-line constable-states
    uint256 public minAmountToSell;

    // slither-disable-next-line immutable-states
    address public base = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // slither-disable-next-line constable-states
    address public router = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    mapping(address => mapping(address => uint24)) public uniFees;

    /**
     * @dev Set fees bidirectionally for token pair
     * @param _token0 First token address
     * @param _token1 Second token address
     * @param _fee Pool fee in basis points
     */
    function _setUniFees(address _token0, address _token1, uint24 _fee) internal virtual {
        uniFees[_token0][_token1] = _fee;
        uniFees[_token1][_token0] = _fee;
    }

    /**
     * @dev Exact input swap with automatic routing (direct or via base token)
     * @param _from Token address to swap from
     * @param _to Token address to swap to
     * @param _amountIn Amount of `_from` to swap
     * @param _minAmountOut Minimum amount of `_to` to receive
     * @return _amountOut Actual amount of `_to` received
     */
    // slither-disable-next-line uninitialized-state (set in strategy constructor)
    function _swapFrom(
        address _from,
        address _to,
        uint256 _amountIn,
        uint256 _minAmountOut
    ) internal virtual returns (uint256 _amountOut) {
        if (_amountIn != 0 && _amountIn >= minAmountToSell) {
            _checkAllowance(router, _from, _amountIn);
            if (_from == base || _to == base) {
                ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams(
                    _from,
                    _to,
                    uniFees[_from][_to],
                    address(this),
                    block.timestamp,
                    _amountIn,
                    _minAmountOut,
                    0
                );

                _amountOut = ISwapRouter(router).exactInputSingle(params);
            } else {
                bytes memory path = abi.encodePacked(_from, uniFees[_from][base], base, uniFees[base][_to], _to);

                _amountOut = ISwapRouter(router).exactInput(
                    ISwapRouter.ExactInputParams(path, address(this), block.timestamp, _amountIn, _minAmountOut)
                );
            }
        }
    }

    /**
     * @dev Exact output swap with automatic routing (direct or via base token)
     * @param _from Token address to swap from
     * @param _to Token address to swap to
     * @param _amountTo Amount of `_to` needed out
     * @param _maxAmountFrom Maximum amount of `_from` to swap
     * @return _amountIn Actual amount of `_from` swapped
     */
    // slither-disable-next-line uninitialized-state (set in strategy constructor)
    function _swapTo(
        address _from,
        address _to,
        uint256 _amountTo,
        uint256 _maxAmountFrom
    ) internal virtual returns (uint256 _amountIn) {
        if (_maxAmountFrom != 0 && _maxAmountFrom >= minAmountToSell) {
            _checkAllowance(router, _from, _maxAmountFrom);
            if (_from == base || _to == base) {
                ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams(
                    _from,
                    _to,
                    uniFees[_from][_to],
                    address(this),
                    block.timestamp,
                    _amountTo,
                    _maxAmountFrom,
                    0
                );

                _amountIn = ISwapRouter(router).exactOutputSingle(params);
            } else {
                bytes memory path = abi.encodePacked(_to, uniFees[base][_to], base, uniFees[_from][base], _from);

                _amountIn = ISwapRouter(router).exactOutput(
                    ISwapRouter.ExactOutputParams(path, address(this), block.timestamp, _amountTo, _maxAmountFrom)
                );
            }

            ERC20(_from).forceApprove(router, 0);
        }
    }

    /**
     * @dev Ensure sufficient allowance for contract to spend token
     * @param _contract Address of contract that will move the token
     * @param _token Token address to approve
     * @param _amount Amount to approve
     */
    function _checkAllowance(address _contract, address _token, uint256 _amount) internal virtual {
        if (ERC20(_token).allowance(address(this), _contract) < _amount) {
            ERC20(_token).forceApprove(_contract, _amount);
        }
    }
}
