# Cleanup Backlog

Remaining cleanup items after Priority 1 (dead code removal) and Priority 2 (structural dedup) were completed.

---

## Priority 3 — Test Organization

### Two invariant directories
- `test/invariant/` has 1 file (`PlamenInvariant.t.sol`)
- `test/invariants/` has 2 files (`LockedVaultCustodyInvariant.t.sol`, `TwoStepCooldownChangeInvariant.t.sol`)
- **Action**: Merge into `test/invariants/` (Foundry default prefix is `invariant`, but plural is already the majority)

### Three PoC directories
- `test/poc/` — 2 files (generic severity-based PoCs)
- `test/proof-of-concepts/` — 8 files (named regression PoCs)
- `test/proof-of-fixes/` — cantina competition fix tests
- **Action**: Consolidate `test/poc/` into `test/proof-of-concepts/`; keep `test/proof-of-fixes/` separate since it has a different purpose

### Orphaned `test/yieldSkimming/`
- Contains a single file: `YieldSkimmingInvariantsAndPoC.t.sol`
- **Action**: Move to `test/invariants/` or `test/unit/strategies/yieldSkimming/`

### 22 test files missing `.t.sol` extension
- All under `test/unit/mechanisms/allocation/` and sibling directories
- Files like `QuadraticVotingBasicTimelockTest.sol`, `OctantQFMechanismTest.sol`, etc.
- **Action**: Rename `*Test.sol` → `*.t.sol` for Foundry convention consistency

---

## Priority 4 — Script Hygiene

### 9 deploy scripts missing `.s.sol` extension
All under `script/deploy/`:
- `DeployAllocationMechanismFactory.sol`
- `DeployLidoStrategyFactory.sol`
- `DeployLinearAllowanceSingletonForGnosisSafe.sol`
- `DeployMorphoCompounderStrategyFactory.sol`
- `DeployPaymentSplitter.sol`
- `DeployPaymentSplitterFactory.sol`
- `DeployRocketPoolStrategyFactory.sol`
- `DeploySafe.sol`
- `DeploySkyCompounderStrategyFactory.sol`
- **Action**: Rename to `*.s.sol`

### 2 deploy scripts extend `Test` instead of `Script`
- `script/deploy/DeploySafe.sol` — `contract DeploySafe is Test`
- `script/deploy/DeployLinearAllowanceSingletonForGnosisSafe.sol` — extends `Test`
- **Action**: Change to extend `Script`; replace `forge-std/Test.sol` import with `forge-std/Script.sol`

### Stale Goerli reference
- `script/helpers/HelperConfig.s.sol` references Goerli (chain ID 5) — deprecated testnet
- Also has a logic issue: `if (block.chainid == 11155111)` inside `if (block.chainid == 1)` block
- **Action**: Remove Goerli references; fix the chainid branching logic

### Two parallel deploy directories
- `script/deploy/` — older deploy scripts
- `script/deployment/staging/` — newer staging deploy scripts
- **Action**: Document the distinction clearly, or consolidate if they serve overlapping purposes

---

## Priority 5 — Pragma & Import Consistency

### 8 different pragma versions
First-party contracts that should use `^0.8.25` but don't:

| File | Current Pragma |
|------|---------------|
| `src/mechanisms/mechanism/QuadraticVotingMechanism.sol` | `^0.8.20` |
| `src/mechanisms/TokenizedAllocationMechanism.sol` | `^0.8.20` |
| `src/mechanisms/AllocationMechanismFactory.sol` | `^0.8.20` |
| `src/mechanisms/BaseAllocationMechanism.sol` | `^0.8.20` |
| `src/core/TokenizedStrategy.sol` | `>=0.8.18` |
| `src/strategies/yieldDonating/ERC4626Strategy.sol` | `^0.8.0` |
| `src/strategies/yieldDonating/SkyCompounderStrategy.sol` | `^0.8.0` |
| `src/zodiac-core/modules/LinearAllowanceSingletonForGnosisSafe.sol` | `^0.8.0` |

Vendored/ported code (TokenizedStrategy, SkyCompounderStrategy, LinearAllowanceSingleton) may intentionally retain original pragmas. First-party `mechanisms/` contracts should be updated.

- **Action**: Update all first-party `mechanisms/` contracts to `^0.8.25`

### 72 wildcard imports in test files
- Concentrated in `test/unit/mechanisms/` (~25 files use `import "forge-std/Test.sol"`)
- **Action**: Convert to named imports (`import { Test } from "forge-std/Test.sol"`)

---

## Priority 6 — Config & Build

### EVM version mismatch between Foundry and Kontrol
- `foundry.toml`: `evm_version = "prague"`
- `kontrol.toml`: `schedule = 'CANCUN'`
- Prague opcodes (transient storage EIP-1153, blob opcodes) won't be covered by formal proofs
- **Action**: Align Kontrol to Prague, or document the gap

### Stale `.storage-layout`
- References `src/capital-providers/PgEtherToken.sol:PgEtherToken` — contract no longer exists
- **Action**: Regenerate with `yarn storage:generate` or delete stale entries

### Suppressed compiler warning 3860
- `ignored_error_codes` includes `3860` (initcode too large)
- Could mask contracts exceeding the 49KB deployment limit
- **Action**: Remove `3860` from `ignored_error_codes` and fix any resulting warnings, or document why it's suppressed

### Unused `solady-test/` remapping *(done — removed in Priority 2)*

---

## Priority 7 — Gas Optimization (Low Urgency)

### `MultistrategyVault.sol` bool packing
4 `bool` state variables each occupy a full 32-byte storage slot:
- `useDefaultQueue` (line 122)
- `autoAllocate` (line 127)
- `_shutdown` (line 232)
- `_locked` (line 270)

These could be packed into a single slot (e.g., a `uint8` bitmask) or packed alongside adjacent `address` variables, saving ~3 SLOADs on frequent paths.

**Caveat**: This changes the storage layout, which requires careful migration if contracts are upgradeable or if storage layout snapshots are in use.

### `UniswapV3Swapper.sol` — mutable WETH address
- `address public base = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` (line 23)
- If this is always WETH, make it `immutable` or `constant` to save 1 SLOAD per swap
- **Note**: This is ported code from Yearn; the mutability may be intentional for multi-chain support

---

## Priority 8 — Safety Flag

### `AaveV3Strategy.sol` marked "UNAUDITED" but has a production factory
- `src/strategies/yieldDonating/AaveV3Strategy.sol:43` contains:
  ```
  WARNING: THIS CONTRACT IS UNAUDITED AND NOT INTENDED FOR PRODUCTION USE.
  ```
- Yet `src/factories/AaveV3StrategyFactory.sol` exists and is fully implemented
- **Action**: Either audit the strategy, or add a matching warning to the factory and gate deployment behind a flag

---

## Noted but Not Actionable

### `DeployedAddresses.sol` vs `constants.sol` version drift
- `constants.sol` defines V2 addresses (`MORPHO_STRATEGY_FACTORY_V2_MAINNET`, `YIELD_DONATING_TOKENIZED_STRATEGY_V2_MAINNET`)
- `DeployedAddresses.sol` struct only has V1 entries
- This is feature work (adding struct fields) — track in product backlog, not cleanup

### Vendored `MultiSendCallOnly.sol` is a deliberate fork
- `src/utils/libs/Safe/MultiSendCallOnly.sol` differs from the dependency version
- Contains security enhancements: improved revert propagation, `address(0) → address(this)` default
- **Leave as-is** — this is intentional
