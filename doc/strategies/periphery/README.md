# Strategy Periphery

Periphery contracts provide optional strategy helpers that can be composed into concrete strategies.

## Contracts

### `BaseHealthCheck`

`BaseHealthCheck` extends `BaseStrategy` with report-time profit/loss bounds. Strategies can temporarily disable the check for one report, and it automatically re-enables afterward.

Typical users:

- Yield-donating strategies with discrete harvests.
- ERC-4626 wrapper strategies.
- Strategies where unexpected profit/loss should require management intervention.

### `BaseYieldSkimmingHealthCheck`

`BaseYieldSkimmingHealthCheck` applies the same health-check pattern to yield-skimming strategies.

### `UniswapV3Swapper`

`UniswapV3Swapper` is a standalone internal helper for exact-input and exact-output swaps. Inheriting strategies configure `base`, `router`, `minAmountToSell`, and `uniFees` from their own constructor or initializer logic.

## Integration Notes

- Choose the strategy base first, then add only the periphery helpers the concrete strategy needs.
- Configure health-check thresholds during construction or setup.
- Set Uniswap fee routes explicitly for every pair used by the strategy.
- Keep minimum output checks nonzero and derived from a trusted price source or conservative slippage policy.
- Test periphery behavior in forked integration tests when it depends on external protocol state.
