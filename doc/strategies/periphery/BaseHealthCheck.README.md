# BaseHealthCheck

`BaseHealthCheck` is a strategy safety helper based on Yearn's health-check pattern. It prevents unexpectedly large profits or losses from being recorded during `report()` without explicit management intervention.

## Key Features

- Configurable profit and loss limits in basis points.
- One-report health-check bypass for planned migrations or unusual harvests.
- Automatic re-enable after a bypassed report.
- Management-only threshold updates.
- Direct integration with the current `BaseStrategy` constructor.

## Usage

```solidity
import { BaseHealthCheck } from "src/strategies/periphery/BaseHealthCheck.sol";

contract MyStrategy is BaseHealthCheck {
    constructor(
        address asset,
        string memory name,
        string memory symbol,
        address management,
        address keeper,
        address emergencyAdmin,
        address donationAddress,
        bool enableBurning,
        address tokenizedStrategyAddress
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
        _setProfitLimitRatio(2_000);
        _setLossLimitRatio(500);
    }

    function _deployFunds(uint256 amount) internal override {
        // Strategy-specific deployment logic.
    }

    function _freeFunds(uint256 amount) internal override {
        // Strategy-specific withdrawal logic.
    }

    function _harvestAndReport() internal override returns (uint256 totalAssets) {
        // Strategy-specific harvesting and accounting logic.
    }
}
```

## Function Reference

- `profitLimitRatio()`: current profit limit in basis points.
- `lossLimitRatio()`: current loss limit in basis points.
- `setProfitLimitRatio(uint256)`: management-only profit limit update.
- `setLossLimitRatio(uint256)`: management-only loss limit update.
- `setDoHealthCheck(bool)`: management-only health-check toggle.
- `_executeHealthCheck(uint256)`: internal validation run during report.

## Operational Notes

- Use tighter limits for lending/staking strategies with stable accounting.
- Use wider limits only when the strategy naturally has volatile harvests.
- Document and monitor any planned report that requires a one-time bypass.
- Keep fork tests for external-protocol integrations that can pause, accrue rewards, or change exchange rates.
