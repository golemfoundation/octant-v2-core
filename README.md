## Prerequisites

- Node.js 22.16.0
- Foundry Stable

## Installation

1. Clone the repository:

```bash
# Clone repository
git clone https://github.com/golemfoundation/octant-v2-core.git
cd octant-v2-core
```

2. Install dependencies:

```bash
# Install Node.js and Foundry dependencies
corepack enable
yarn install
forge soldeer install
```

We're using `soldeer` as dependency manager for Solidity contracts, which allows us to manage Solidity versions and dependencies in a consistent manner.

3. Configure environment:

Setup lint hooks
```bash
yarn init
```

Copy the environment template
```bash
cp .env.template .env

# Edit .env with your configuration
# Required fields:
# - RPC_URL: Your RPC endpoint
# - PRIVATE_KEY: Your wallet private key
# - ETHERSCAN_API_KEY: For contract verification
# - Other fields as needed for your use case
```

## Project File Structure

**Yield Strategies**: Generate yield from external protocols (Lido, Sky, Morpho, etc.)
**Allocation Mechanisms**: Democratic systems for deciding resource distribution
**Dragon Protocol**: Advanced Safe integration for automated cross-protocol operations
**Factories**: Standardized deployment contracts with parameter validation
**Utilities**: Shared libraries and helper contracts

### Data Flow

```

                      Vaults   
                        ↓   
External Protocols → Strategies → → → →
                        ↓              ↓
                    Safe Modules → Dragon Routers →  Allocation Mechanisms
```
### Source Code Organization (`src/`)

#### Core Module (`src/core/`)
The foundational vault and strategy infrastructure:
- **BaseStrategy.sol**: Abstract base class for all yield-generating strategies
- **MultistrategyVault.sol**: Main vault implementation managing multiple strategies with risk distribution
- **MultistrategyLockedVault.sol**: Vault variant with lockup periods and non-transferable shares
- **PaymentSplitter.sol**: Handles proportional distribution of funds among recipients
- **TokenizedStrategy.sol**: ERC-4626 compliant strategy implementation with proxy pattern
- **interfaces/**: Core protocol interfaces
  - `IBaseStrategy.sol`, `IMultistrategyVault.sol`, `ITokenizedStrategy.sol`, etc.
- **libs/**: Core-specific utility libraries
  - `DebtManagementLib.sol`: Vault debt management logic
  - `ERC20SafeLib.sol`: Safe ERC20 operations for vaults
  - `StrategyManagementLib.sol`: Vault strategy management logic

#### Strategy Implementations (`src/strategies/`)
Yield-generating strategy contracts:
- **interfaces/**: Strategy-specific interfaces
  - `IBaseHealthCheck.sol`, `IVault.sol`, `IPSM.sol`, `ISky.sol`
- **periphery/**: Common strategy utilities
  - `BaseHealthCheck.sol`: Health monitoring for strategies
  - `UniswapV3Swapper.sol`: Uniswap V3 integration utilities
- **yieldDonating/**: Strategies that donate generated yield
  - `SkyCompounderStrategy.sol`: Sky protocol yield donation strategy
  - `UsdsFarmerUsdcStrategy.sol`: USDS farming strategy
  - `YieldDonatingTokenizedStrategy.sol`: Generic yield donation base
- **yieldSkimming/**: Strategies that capture yield for protocol benefit
  - `LidoStrategy.sol`: Lido staking strategy
  - `MorphoCompounderStrategy.sol`: Morpho protocol compounding strategy
  - `YieldSkimmingTokenizedStrategy.sol`: Generic yield capture base

#### Factory Contracts (`src/factories/`)
Deployment and creation contracts:
- **LidoStrategyFactory.sol**: Factory for Lido strategy vaults
- **MorphoCompounderStrategyFactory.sol**: Factory for Morpho strategy vaults
- **MultistrategyVaultFactory.sol**: Factory for core multistrategy vaults
- **PaymentSplitterFactory.sol**: Factory for payment splitter contracts
- **SkyCompounderStrategyFactory.sol**: Factory for Sky strategy contracts
- **interfaces/**: Factory-related interfaces
  - `IMultistrategyVaultFactory.sol`

#### Regen Staker (`src/regen/`)
Impact and regenerative finance functionality:
- **RegenEarningPowerCalculator.sol**: Calculates earning power for regen participants
- **RegenStaker.sol**: Staking functionality for regenerative finance
- **interfaces/**: Regen-specific interfaces
  - `IFundingRound.sol`: Funding round interface
  - `IAccessControlledEarningPowerCalculator.sol`: Access-controlled earning power

#### Dragon Protocol (`src/zodiac-core/`)
Advanced Safe integration and cross-protocol operations:
- **BaseStrategy.sol**: Dragon-specific strategy base class
- **DragonRouter.sol**: Central routing and coordination for cross-protocol operations
- **LinearAllowanceExecutor.sol**: Controlled spending limit execution
- **ModuleProxyFactory.sol**: Factory for creating Safe modules
- **SplitChecker.sol**: Validation for fund splitting operations
- **TokenizedStrategy.sol**: Dragon-specific tokenized strategy implementation
- **guards/**: Safe transaction guards
  - `antiLoopHoleGuard.sol`: Prevents malicious transaction patterns
- **interfaces/**: Dragon-specific interfaces
- **modules/**: Safe modules for automated execution
  - `LinearAllowanceSingletonForGnosisSafe.sol`: Linear allowance Safe integration
  - `MethYieldStrategy.sol`: Meth yield strategy module
  - `OctantRewardsSafe.sol`: Octant rewards distribution module
  - `YearnPolygonUsdcStrategy.sol`: Yearn strategy module
- **vaults/**: Dragon-specific vault implementations
  - `DragonBaseStrategy.sol`: Base dragon strategy with router integration
  - `DragonTokenizedStrategy.sol`: Dragon strategy with lockup + non-transferable shares
  - `Passport.sol`: Identity and access management
  - `YieldBearingDragonTokenizedStrategy.sol`: Dragon strategy with yield distribution

#### Utilities (`src/utils/`)
Shared utilities and helper contracts:
- **IAddressSet.sol**: Address set interface for access control
- **AddressSet.sol**: Address set implementation (allowsets and blocksets)
- **interfaces/**: Utility interfaces
- **hats/**: Hats protocol integration utilities
  - `AbstractHatsManager.sol`: Abstract base for hat management
  - `DragonHatter.sol`: Dragon-specific hat management
  - `HatsErrors.sol`: Hat-related error definitions
  - `SimpleEligibilityAndToggle.sol`: Basic hat eligibility logic
  - `interfaces/`: Hat-specific interfaces (`IHatsEligibility.sol`, `IHatsToggle.sol`)
- **libs/**: Utility libraries
  - `Maths/WadRay.sol`: Mathematical operations with WAD/RAY precision
  - `Safe/MultiSendCallOnly.sol`: Safe multi-transaction utilities
- **routers-transformers/**: Trading and transformation utilities
  - `Trader.sol`: DCA trading functionality
  - `TraderBotEntry.sol`: Bot entry point for automated trading
- **vendor/**: Third-party integrations and interfaces
  - `0xSplits/`: 0xSplits protocol interfaces and utilities
  - `shamirlabs/`: Shamir Labs interfaces
  - `uniswap/`: Uniswap protocol interfaces

#### Global Files
- **constants.sol**: Protocol-wide constants and parameters
- **errors.sol**: Shared error definitions for gas efficiency
- **interfaces/**: Global interfaces not specific to any module
  - `IAccountant.sol`, `IDragon.sol`, `IEvents.sol`, `IFactory.sol`, etc.
  - `deprecated/`: Legacy interfaces maintained for compatibility

### Test Organization (`test/`)

#### Unit Tests (`test/unit/`)
Module-specific focused testing:
- **core/**: Core vault and strategy unit tests
  - `vaults/`: MultistrategyVault and related tests
  - `splitter/`: PaymentSplitter tests
- **mechanisms/**: Allocation mechanism tests
  - `voting-strategy/`: Voting mechanism tests
  - `harness/`: Test harness contracts
- **factories/**: Factory contract tests
- **utils/**: Utility contract tests
  - `routers-transformers/`: Trading functionality tests
  - `addressset/`: Address set functionality tests
- **zodiac-core/**: Dragon protocol unit tests
  - `vaults/`: Dragon-specific vault tests
  - `modules/`: Safe module tests

#### Integration Tests (`test/integration/`)
Cross-module workflow testing:
- **Setup.t.sol**: Shared integration test setup
- **core/**: Core protocol integration tests
  - `vaults/`: Vault workflow integration tests
- **factories/**: Factory integration and deployment tests
- **hats/**: Hats protocol integration tests
- **regen/**: Regenerative finance integration tests
- **strategies/**: Strategy integration tests
  - `yieldDonating/`: Yield donation strategy tests
  - `yieldSkimming/`: Yield capture strategy tests
- **zodiac-core/**: Dragon protocol integration tests

#### Mock Contracts (`test/mocks/`)
- **core/**: Core protocol mocks
  - `tokenized-strategies/`: Strategy mocks for testing
- **zodiac-core/**: Dragon protocol mocks

### Contract Inheritance Hierarchy

```
TokenizedStrategy (Implementation)
├── DragonTokenizedStrategy (Adds lockup + non-transferable shares)
└── YieldBearingDragonTokenizedStrategy (Adds yield distribution)

BaseStrategy (Abstract)
├── DragonBaseStrategy (Adds router integration)
├── YieldDonatingTokenizedStrategy (Donates yield)
└── YieldSkimmingTokenizedStrategy (Skims yield)
```
## Development Notes

**Testing Strategy**:
- Unit tests in `test/unit/` focus on individual contract logic
- Integration tests in `test/integration/` test cross-contract workflows
- Mock contracts in `test/mocks/` provide controlled testing environments
- Use `--isolate` flag for accurate gas measurements


## Common Workflows

**Adding New Strategy**:
1. Inherit from appropriate base strategy contract in `src/core/` or `src/zodiac-core/`
2. Implement required abstract functions (`_deployFunds`, `_freeFunds`, etc.)
3. Add strategy-specific tests in `test/unit/core/` or `test/unit/zodiac-core/`
4. Create factory in `src/factories/` if permissionless deployment needed
5. Update documentation with strategy-specific details
