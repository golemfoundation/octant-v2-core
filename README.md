# Octant V2 Core

[![Lines](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/housekeeper-bot/3d581c9545c040ac95fdd354e69f9bc8/raw/coverage-lines.json)](https://github.com/golemfoundation/octant-v2-core)
[![Branches](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/housekeeper-bot/3d581c9545c040ac95fdd354e69f9bc8/raw/coverage-branches.json)](https://github.com/golemfoundation/octant-v2-core)
[![Functions](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/housekeeper-bot/3d581c9545c040ac95fdd354e69f9bc8/raw/coverage-functions.json)](https://github.com/golemfoundation/octant-v2-core)

Core Solidity contracts, deployment tooling, tests, and formal-verification support for Octant V2.

## Prerequisites

- Node.js 22.16.0
- Foundry stable
- Yarn through Corepack

## Installation

```bash
git clone https://github.com/golemfoundation/octant-v2-core.git
cd octant-v2-core
corepack enable
yarn install
forge soldeer install
yarn init
```

Copy `.env.template` to `.env` when running scripts that need RPC endpoints, private keys, or explorer API keys.

## Common Commands

```bash
yarn build                # Compile production contracts
yarn build:contracts      # Compile and combine proxy ABIs
forge test                # Run the full Foundry test suite
yarn test:ci              # Run tests with JUnit output
yarn lint                 # Solhint checks
yarn format:check         # Prettier check
yarn coverage:summary     # Coverage summary
yarn semver:check         # Contract API/storage semver check
```

## Repository Layout

| Path | Purpose |
| --- | --- |
| `src/` | Production Solidity contracts |
| `script/` | Foundry scripts and shell utilities |
| `scripts/` | Node.js repository tooling |
| `test/` | Unit, integration, invariant, PoC, and proof-of-fix tests |
| `verification/` | Kontrol proof sources and lemmas |
| `doc/` | Committed operational, architecture, and protocol notes |
| `docs/` | Generated Forge documentation output, ignored by git |
| `partners/` | Partner-specific proposal calldata, plans, and verification tests |
| `audits/` | Published external audit reports |
| `dependencies/` | Soldeer-managed Solidity dependencies |

## Source Inventory

### Core (`src/core/`)

- `MultistrategyVault.sol` and `MultistrategyLockedVault.sol`: ERC-4626 vault implementations.
- `TokenizedStrategy.sol` and `BaseStrategy.sol`: strategy tokenization and strategy callback framework.
- `YieldForwarder.sol` and `SwappingYieldForwarder.sol`: report-and-forward helpers.
- `PaymentSplitter.sol` and `Privileged.sol`: shared accounting and access-control utilities.
- `interfaces/` and `libs/`: core interfaces and vault helper libraries.

### Strategies (`src/strategies/`)

- `yieldDonating/`: Aave V3, ERC-4626, Morpho, Sky, Spark, Yearn V3, and privileged yield-donating strategies.
- `yieldSkimming/`: Lido, Rocket Pool, base yield-skimming, and privileged yield-skimming strategies.
- `periphery/`: health checks and Uniswap V3 helper logic for strategies.
- `interfaces/`: protocol and strategy interfaces used by strategy implementations.

### Factories (`src/factories/`)

Factories cover multistrategy vaults, payment splitters, address sets, regen stakers, yield forwarders, ERC-4626 strategies, and protocol-specific strategy deployments.

### Allocation Mechanisms (`src/mechanisms/`)

The allocation module contains factory logic, base/tokenized allocation machinery, Octant QF, quadratic voting, and ProperQF voting-strategy code.

### Regen (`src/regen/`)

Regen contracts implement staking, earning-power calculation, delegation/no-delegation staking variants, and the access-controlled earning-power interface. See `src/regen/README.md`.

### Swappers and Guards

- `src/swappers/`: Curve, PSM, Uniswap V3, and Uniswap V4 swap adapters.
- `src/guards/`: keeper-bot guard logic.

### Safe/Zodiac Compatibility (`src/zodiac-core/`)

The remaining Zodiac-compatible code contains the linear allowance executor, Safe interface, and `LinearAllowanceSingletonForGnosisSafe` module.

### Utilities (`src/utils/`)

Shared address-set utilities, math/Safe libraries, and vendored third-party protocol interfaces live under `src/utils/`.

## Tests and Verification

- `test/unit/`: focused unit tests by module.
- `test/integration/`: fork/integration flows for vaults, factories, strategies, swappers, guards, partner calldata, regen, and Zodiac compatibility.
- `test/invariants/`: invariant suites.
- `test/proof-of-concepts/`: executable demonstrations of reported issues.
- `test/proof-of-fixes/`: regression tests for external-audit findings.
- `test/kontrol`: symlink to `verification/kontrol` for Foundry/Kontrol compatibility.
- `verification/kontrol/`: Kontrol proofs, setup contracts, and lemmas.

## Documentation

- `CONTRIBUTING.md`: contribution, testing, NatSpec, and semver standards.
- `.github/code-review.md`: reviewer security checklist.
- `doc/ops/`: environment and GitHub Actions configuration notes.
- `doc/adr/`: architecture decision record template.
- `src/core/README.md`, `src/regen/README.md`, and `src/mechanisms/`: module-level notes.

## Adding a Strategy

1. Inherit from the current strategy base (`BaseHealthCheck`, `BaseYieldSkimmingStrategy`, or another established local base).
2. Implement `_deployFunds`, `_freeFunds`, and `_harvestAndReport`.
3. Add focused unit tests under `test/unit/strategies/` and fork/integration coverage under `test/integration/strategies/` when the strategy depends on an external protocol.
4. Add or reuse a factory when permissionless deployment is required.
5. Update module docs and run `yarn semver:check` for versioned contract changes.
