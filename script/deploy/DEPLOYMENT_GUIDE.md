# Deployment Guide for Octant V2 Core Contracts

This guide explains how to deploy the tokenized strategy implementations, strategy factories, and
RegenStaker infrastructure through a Gnosis Safe multisig using the forge-safe integration.

## Which script do I run?

| Target | Script | Notes |
|---|---|---|
| Production mainnet | `script/prod/DeployProtocol.s.sol` | 8 Safe transactions (Phase A: 4 factory batches, Phase B: 4 instance batches). Salts are parameterized by `SALT_TIMESTAMP`. Asserts every deployed address against its precomputation before proposing. |
| Staging / testbed via Safe | `script/deploy/DeployNewStrategiesAndFactories.s.sol` | 4 Safe transactions. Salts are pinned date constants. |
| Staging via EOA (no Safe) | `script/deployment/staging/DeployProtocol.s.sol` | Composes the standalone `Deploy*StrategyFactory` scripts and skips anything already listed in `script/helpers/DeployedAddresses.sol`. |
| One factory only | `script/deploy/Deploy<Name>StrategyFactory.sol` | CREATE2 from the deployer EOA, not from Nick's factory — addresses differ from the Safe path by design. |

Two older Safe scripts overlap with the table above and have **not** been retired:
`DeployAllStrategiesAndFactories.s.sol` (salts `05112025`) and
`DeployYieldSkimmingStrategiesAndFactories.s.sol` (salts `18012026`). Because salts differ, running one
of them alongside the canonical paths deploys a second on-chain copy of the same contracts at a
different address. Pick one path per environment and record which addresses are canonical in
`script/helpers/DeployedAddresses.sol`.

## Contracts deployed by the Safe batches

`DeployNewStrategiesAndFactories.s.sol` deploys 13 contracts. Batches exist because of the EIP-7825
per-transaction gas limit of 16,777,216 gas (2^24), not for logical grouping.

**Batch 1** (~12.9M gas of contract creation, measured — the tightest batch) — implementations plus
the first factory group:

1. `YieldSkimmingTokenizedStrategy` — implementation for rebasing/appreciating assets
2. `YieldDonatingTokenizedStrategy` — implementation for productive assets with discrete harvesting
3. `PaymentSplitterFactory` — PaymentSplitter contracts via minimal proxies
4. `LidoStrategyFactory` — Lido (wstETH) yield skimming strategies
5. `MorphoCompounderStrategyFactory` — Morpho yield donating strategies

**Batch 2** — remaining yield donating factories:

6. `SkyCompounderStrategyFactory` — Sky Compounder yield donating strategies
7. `YearnV3StrategyFactory` — Yearn V3 yield donating strategies

**Batch 3** (~3M gas) — RegenStaker infrastructure:

8. `AddressSetFactory`
9. `RegenEarningPowerCalculatorFactory`
10. `RegenStakerFactory` — constructor takes the canonical RegenStaker bytecode hashes

**Batch 4** (~6.8M gas of contract creation, measured) — Spark, Aave V3, and Rocket Pool factories:

11. `SparkStrategyFactory` — Spark ERC4626 yield donating strategies with airdrop sweep
12. `AaveV3StrategyFactory` — Aave V3 yield donating strategies
13. `RocketPoolStrategyFactory` — Rocket Pool (rETH) yield skimming strategies

All three batch 4 factories take no constructor arguments and receive the tokenized strategy
implementation as a `createStrategy()` parameter, so batch 4 has no ordering dependency on batch 1.

## Prerequisites

1. **Gnosis Safe**: a deployed Safe multisig on the target chain
2. **forge-safe**: used for batch transaction creation (requires `--ffi`)
3. **Environment**: Foundry installed, access to the Safe transaction service API, and a private key
   belonging to a Safe owner or delegate

## Deployment process

### 1. Set environment variables

```bash
export SAFE_ADDRESS=0x...        # target Gnosis Safe
export CHAIN=mainnet
export WALLET_TYPE=local         # or ledger
export PRIVATE_KEY=0x...         # required for WALLET_TYPE=local
export SENDER=0x...              # must be a Safe owner or delegate
export ETH_RPC_URL=https://...
export SEND=true                 # omit to simulate only (see below)
```

If `SAFE_ADDRESS` is unset the script prompts for it.

**Both Safe scripts simulate by default.** Without `SEND=true` a run executes the full batch against
the fork — including every address assertion — and proposes nothing. Always do a simulation run
first; a salt or bytecode drift fails there instead of producing a Safe payload with wrong addresses.

### 2. Run the deployment

Deploy all four batches — four Safe proposals in sequence at nonce N, N+1, N+2, N+3:

```bash
forge script script/deploy/DeployNewStrategiesAndFactories.s.sol \
  --rpc-url $ETH_RPC_URL --ffi --sender $SENDER
```

Or propose one batch at a time:

```bash
forge script script/deploy/DeployNewStrategiesAndFactories.s.sol \
  --sig "runBatch1()" --rpc-url $ETH_RPC_URL --ffi --sender $SENDER
# ... likewise runBatch2(), runBatch3(), runBatch4()
```

For production, use the prod script's phase entry points instead:

```bash
forge script script/prod/DeployProtocol.s.sol:DeployProtocol \
  --sig "phaseA_batch4()" --rpc-url $ETH_RPC_URL --ffi
```

The prod script simulates only by default; set `SEND=true` to submit to the Safe API.

**Important**: `--ffi` is required for forge-safe. The script signs the Safe transaction once and
submits it to the Safe transaction service — it does not execute it on-chain.

### 3. Sign and execute in Safe

1. The batch is sent to the Safe transaction service
2. Safe owners sign via the Safe web interface or Safe CLI
3. Once the threshold is met, any owner executes
4. Execute batch 1, then 2, then 3, then 4 — nonces must land in order

Before signing, compare the addresses printed in the batch summary against
`forge script ... --sig "computeAllAddresses()"` (prod script) output.

## Deterministic addresses

Every contract in the Safe batches is deployed through Nick's CREATE2 factory at
`0x4e59b44847b379578588920cA78FbF26c0B4956C`, so the address depends only on the salt and the
creation code — not on the Safe address or the nonce.

### Salts

`DeployNewStrategiesAndFactories.s.sol` uses pinned date-based constants (`DDMMYYYY`):

| Contract | Salt preimage |
|---|---|
| YieldSkimmingTokenizedStrategy | `OCTANT_YIELD_SKIMMING_STRATEGY_11022026` |
| YieldDonatingTokenizedStrategy | `OCTANT_YIELD_DONATING_STRATEGY_11022026` |
| PaymentSplitterFactory | `PAYMENT_SPLITTER_FACTORY_11022026` |
| LidoStrategyFactory | `LIDO_STRATEGY_FACTORY_11022026` |
| MorphoCompounderStrategyFactory | `MORPHO_COMPOUNDER_FACTORY_11022026` |
| SkyCompounderStrategyFactory | `SKY_COMPOUNDER_FACTORY_11022026` |
| YearnV3StrategyFactory | `YEARN_V3_STRATEGY_FACTORY_11022026` |
| AddressSetFactory | `ADDRESS_SET_FACTORY_11022026` |
| RegenEarningPowerCalculatorFactory | `REGEN_EARNING_POWER_CALCULATOR_FACTORY_11022026` |
| RegenStakerFactory | `REGEN_STAKER_FACTORY_11022026` |
| SparkStrategyFactory | `SPARK_STRATEGY_FACTORY_07072026` |
| AaveV3StrategyFactory | `AAVE_V3_STRATEGY_FACTORY_07072026` |
| RocketPoolStrategyFactory | `ROCKET_POOL_STRATEGY_FACTORY_07072026` |

`script/prod/DeployProtocol.s.sol` builds its salts from the **same preimage prefixes** with
`SALT_TIMESTAMP` appended. The two scripts are therefore not isolated from each other:

> ⚠️ Setting `SALT_TIMESTAMP=11022026` in the prod script reproduces byte-identical salts — and
> therefore byte-identical addresses — for all ten batch-1..3 contracts above (likewise `07072026`
> for batch 4). If those contracts are already deployed, every CREATE2 call reverts, and it reverts
> only after the batch has been built and reviewed.

In normal use the prod script auto-generates `SALT_TIMESTAMP` as `HH_DDMMYYYY`, which cannot collide
with a `DDMMYYYY` constant, so the two paths produce different addresses. The collision is only
reachable by pinning `SALT_TIMESTAMP` to one of the dates above — do not do that to "reproduce known
addresses". To verify existing deployments, read them from `script/helpers/DeployedAddresses.sol`.

Changing a contract's source changes its creation code and therefore its address. A salt may only be
reused with byte-identical creation code; otherwise bump the date.

### On-chain state of these salts (mainnet, checked 2026-07-20)

Batches are not all unexecuted. Verify before proposing — a CREATE2 call against an occupied address
reverts, and it reverts only after the whole batch has been built.

| Salt target | Mainnet | Consequence |
|---|---|---|
| `YieldSkimmingTokenizedStrategy` → `0x64E0fC6899b38756A29F601cB148148347d49B4A` | **deployed** (runtime bytecode matches current source exactly) | `runBatch1()` reverts today |
| `YieldDonatingTokenizedStrategy` → `0x21543116c58FCC8880bD7a7D9DaA5fCCfF8C8b8A` | empty | a separate YieldDonating implementation exists at `0xb27064A2C51b8C5b39A5Bb911AD34DB039C3aB9c` (see `DeployedAddresses.sol`) |
| Batch 4: Spark / Aave V3 / Rocket Pool | all empty | batch 4 is proposable as-is |

To re-check:

```bash
cast code <address> --rpc-url $ETH_RPC_URL   # "0x" means free
```

## What the Safe batch script does

1. **Precomputes addresses** via CREATE2 for every contract in the batch
2. **Queues each deployment** as a call to the CREATE2 factory with calldata `salt (32 bytes) + creation code`
3. **Asserts** that each simulated deployment lands on the precomputed address, so signers never
   approve a payload while reading an address that will not be produced
4. **Bundles** the calls into one MultiSend transaction (`execTransaction` → `MultiSendCallOnly` → CREATE2 factory)
5. **Submits** the batch to the Safe backend for signatures
6. **Logs** a per-batch summary of every address

## Tests

`test/unit/script/DeploymentScripts.t.sol` guards these scripts in CI: salt uniqueness, address
collision-freedom, that every contract in the batch actually deploys through Nick's factory, that the
script's precomputed addresses match the real deployments, and that the standalone factory scripts and
the staging orchestrator are wired correctly.

```bash
forge test --match-path "test/unit/script/DeploymentScripts.t.sol"
```

The prod script's own fork verification suite (`VerifyProtocolDeployment`) is excluded from the default
profile; run it with `FOUNDRY_PROFILE=mainnet forge test --match-contract VerifyProtocolDeployment
--fork-url <mainnet-rpc>`.
