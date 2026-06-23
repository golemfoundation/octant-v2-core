# UniswapV3Swapper

`UniswapV3Swapper` is an internal helper for strategies that need to swap tokens through Uniswap V3. It supports exact-input and exact-output routes, either direct or through a configured base token.

## Current API Shape

- `base`: intermediate token used for two-hop routes. Defaults to WETH mainnet.
- `router`: Uniswap V3 router address. Defaults to the canonical mainnet router.
- `minAmountToSell`: minimum amount threshold before swaps execute.
- `uniFees[tokenA][tokenB]`: configured fee tier for each route leg.
- `_setUniFees(address,address,uint24)`: internal bidirectional fee setup.
- `_swapFrom(address,address,uint256,uint256)`: exact-input swap helper.
- `_swapTo(address,address,uint256,uint256)`: exact-output swap helper.

The helper does not define a constructor or management surface. Concrete strategies are responsible for configuring route state from their own constructor or setup flow.

## Example

```solidity
import { UniswapV3Swapper } from "src/strategies/periphery/UniswapV3Swapper.sol";

contract MyStrategy is BaseHealthCheck, UniswapV3Swapper {
    address public immutable rewardToken;

    constructor(
        address asset,
        string memory name,
        string memory symbol,
        address management,
        address keeper,
        address emergencyAdmin,
        address donationAddress,
        bool enableBurning,
        address tokenizedStrategyAddress,
        address uniswapRouter,
        address routeBase,
        address _rewardToken
    )
        BaseHealthCheck(
            asset,
            name,
            symbol,
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            enableBurning,
            tokenizedStrategyAddress
        )
    {
        router = uniswapRouter;
        base = routeBase;
        rewardToken = _rewardToken;
        minAmountToSell = 1;
        _setUniFees(_rewardToken, routeBase, 3_000);
        _setUniFees(routeBase, asset, 500);
    }

    function _harvestAndReport() internal override returns (uint256 totalAssets) {
        uint256 rewardBalance = ERC20(rewardToken).balanceOf(address(this));
        if (rewardBalance >= minAmountToSell) {
            uint256 minAmountOut = _quoteWithSlippage(rewardBalance);
            _swapFrom(rewardToken, address(asset), rewardBalance, minAmountOut);
        }

        return _totalStrategyAssets();
    }
}
```

## Safety Notes

- Do not use zero `minAmountOut`; derive it from a conservative oracle, TWAP, or operator-supplied bound.
- Configure every route leg before swapping.
- Review default mainnet addresses before deploying on another chain.
- Keep swaps behind the strategy's existing keeper/management controls.
- Cover route configuration and revert behavior in forked integration tests.

## References

- [Uniswap V3 documentation](https://docs.uniswap.org/concepts/protocol/concentrated-liquidity)
- [Yearn V3 Tokenized Strategy documentation](https://docs.yearn.fi/developers/v3/strategy_writing_guide)
- [Yearn tokenized-strategy-periphery](https://github.com/yearn/tokenized-strategy-periphery)
