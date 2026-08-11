# Deployment Guide for Octant V2 Core Contracts

This guide explains how to deploy all the tokenized strategies and factory contracts using a Gnosis Safe multisig wallet via the forge-safe integration.

## Overview

The deployment script `DeployAllStrategiesAndFactories.s.sol` deploys the following contracts:

### Tokenized Strategy Implementations

1. **YieldDonatingTokenizedStrategy** - Base implementation for productive assets with discrete harvesting

### Factory Contracts

1. **MorphoCompounderStrategyFactory** - Factory for deploying Morpho yield donating strategies
2. **SkyCompounderStrategyFactory** - Factory for deploying Sky Compounder yield donating strategies
3. **PaymentSplitterFactory** - Factory for deploying PaymentSplitter contracts with minimal proxies
4. **YearnV3StrategyFactory** - Factory for deploying YearnV3 yield donating strategies

## Prerequisites

1. **Gnosis Safe**: You need a deployed Gnosis Safe multisig wallet
2. **forge-safe**: The deployment uses forge-safe for batch transaction creation
3. **Environment Setup**: Ensure you have the following:
   - Foundry/Forge installed
   - Access to the Safe transaction service API
   - Private key for transaction submission (must be a Safe owner or delegate)

## Supported Chains

The deployment script supports the following chains:

- **Ethereum Mainnet** (chainId: 1)
- **Polygon** (chainId: 137)
- **Goerli** (chainId: 5)
- **Sepolia** (chainId: 11155111)
- **Base** (chainId: 8453)
- **Arbitrum** (chainId: 42161)
- **Avalanche** (chainId: 43114)

## Deployment Process

### 1. Set Environment Variables

```bash
# Required: Safe multisig address
export SAFE_ADDRESS=0x... # Your Gnosis Safe address

# Required: Private key for deployment
export PRIVATE_KEY=0x...

# Optional: RPC URL (defaults to chain's RPC from foundry.toml)
export ETH_RPC_URL=https://eth-mainnet.alchemyapi.io/v2/YOUR_API_KEY

# Optional: Etherscan API key for verification
export ETHERSCAN_API_KEY=your_etherscan_api_key
```

### 2. Run the Deployment Script

```bash
# Send to Safe
forge script script/deploy/DeployAllStrategiesAndFactories.s.sol:DeployAllStrategiesAndFactories \
  --rpc-url $ETH_RPC_URL \
  --private-key 0xYOUR_PRIVATE_KEY \
  --ffi
```

#### Example: Deploying on Ethereum

```bash
# Set up for Ethereum deployment
export SAFE_ADDRESS=0x... # Your Safe on Ethereum
export CHAIN=ethereum
export ETH_RPC_URL=https://eth-mainnet.infura.io/v3/YOUR_PROJECT_ID
export PRIVATE_KEY=0x...

# Run deployment with explicit private key
forge script script/deploy/DeployAllStrategiesAndFactories.s.sol:DeployAllStrategiesAndFactories \
  --rpc-url $ETH_RPC_URL \
  --private-key $PRIVATE_KEY \
  --ffi
```

**Important**: The `--ffi` flag is required for the forge-safe integration to work.

If `SAFE_ADDRESS` is not set, the script will prompt you to enter it.
The script signs the Safe transaction once and submits it to the Safe transaction service. It does not execute the Safe transaction on-chain.

### 3. Sign the Transaction in Safe

After running the script:

1. The batch transaction will be sent to the Safe transaction service
2. Safe owners will receive notifications (if configured)
3. Navigate to the Safe web interface or use Safe CLI to sign the transaction
4. Once enough signatures are collected, any owner can execute the transaction

## Deployment Addresses

All contracts are deployed deterministically using CREATE2, which means they will have the same address across different networks if deployed with the same Safe address.

### Deployment Salts

All salts use a date-based format (DDMMYYYY) for versioning:

- YieldDonatingTokenizedStrategy: `keccak256("OCTANT_YIELD_DONATING_STRATEGY_05112025")`
- MorphoCompounderStrategyFactory: `keccak256("MORPHO_COMPOUNDER_FACTORY_05112025")`
- SkyCompounderStrategyFactory: `keccak256("SKY_COMPOUNDER_FACTORY_05112025")`
- PaymentSplitterFactory: `keccak256("PAYMENT_SPLITTER_FACTORY_05112025")`
- YearnV3StrategyFactory: `keccak256("YEARN_V3_STRATEGY_FACTORY_05112025")`

## What the Script Does

1. **Calculates Expected Addresses**: Uses CREATE2 to compute deterministic addresses for all contracts (deployed by CREATE2 factory)
2. **Creates MultiSend Transaction**: Bundles all CREATE2 factory calls into a single MultiSend transaction
3. **Safe Execution Flow**:
   - Safe calls `execTransaction` (once)
   - `execTransaction` calls `MultiSendCallOnly`
   - `MultiSendCallOnly` makes 5 calls to CREATE2 factory at `0x4e59b44847b379578588920cA78FbF26c0B4956C`
   - Each call uses calldata format: `salt (32 bytes) + bytecode`
   - CREATE2 factory deploys each contract deterministically
4. **Sends to Safe Backend**: Submits the transaction to Safe's backend for owner signatures
5. **Logs Deployment Info**: Outputs all expected contract addresses

## Registry

The on-chain **OctantRegistry** (`src/registry/OctantRegistry.sol`) is the source of truth for
production contract addresses. `script/helpers/DeployedAddresses.sol` and any
`deployments/<chainId>.json` file are caches derived from it.

### Atomic register-on-deploy rule

Every Safe deploy batch MUST register the contracts it deploys in the same Safe transaction.
Because all deployments are CREATE2-precomputed, the batch can call
`OctantRegistry.publishBatch(expectedEpoch, updates, releaseLabel)` with the
precomputed addresses right after the deploy calls. Use the `BatchScript` helper:

- `_addRegistryPublication(registry, expectedEpoch, updates, releaseLabel)` —
  appends one atomic registry publication to the batch
- `_startNewBatch()` — clears staged calls so one script run can propose several
  sequential Safe transactions (consecutive nonces, fetched once). Use this when a single
  transaction would exceed the EIP-7825 gas cap (16,777,216): split into multiple batches,
  each pairing its deployments with its own `publishBatch` at the next expected epoch, so
  every batch stays internally atomic and out-of-order execution reverts on the epoch check.

Deploy scripts must assert (against the simulated batch state, before proposing) that every
deployed address resolves in the registry — see `_assertRegistrations()` in
`DeployAaveSparkLidoFactories.s.sol` for the reference pattern. A batch that deploys without
registering must fail the script.

`expectedEpoch` protects a prepared Safe proposal from silently overwriting a newer
publication. The registry computes its manifest hash internally with `RegistryManifest.hash`,
which domain-separates the digest and commits to the chain ID, registry address, expected
epoch, release-label hash, and complete ordered update array. Callers cannot substitute an
unrelated digest. Deploy scripts may compute the same hash before execution for assertions and
review. A successful publication increments the global epoch exactly once and emits one
`EntryPublished` event per update followed by `BatchPublished`.

### Key naming convention

Registry keys are `bytes32` **short-strings** (readable on Etherscan), equal to the CREATE2
salt name WITHOUT the date suffix:

| Salt                                | Registry key                                   |
| ----------------------------------- | ---------------------------------------------- |
| `AAVE_V3_STRATEGY_FACTORY_21072026` | `AAVE_V3_STRATEGY_FACTORY`                     |
| `LIDO_STRATEGY_FACTORY_21072026`    | `LIDO_STRATEGY_FACTORY`                        |
| `OCTANT_REGISTRY_22072026`          | — (the registry itself is not self-registered) |

Keys must fit in 32 bytes. If a salt base name is longer (e.g.
`REGEN_EARNING_POWER_CALCULATOR_FACTORY`, 38 chars), shorten it deterministically and document
the mapping in `src/registry/RegistryKeys.sol` (registered as
`EARNING_POWER_CALCULATOR_FACTORY`). Deploy scripts MUST use the constants from
`RegistryKeys` instead of declaring local key literals.

Keys use uppercase ASCII letters, digits, and underscores with right-zero padding. They are
append-only: a key can be deprecated, disabled, or reactivated, but is never deleted.

### Registry deployment and ownership

The registry is deployed through the same Arachnid CREATE2 factory inside the Safe batch
(salt convention: `OCTANT_REGISTRY_<DDMMYYYY>`). Its CREATE2 address commits to the
constructor arg (`initialOwner`, the Safe). On a future chain where the Safe address differs,
deploy with the configured owner and hand over via `Ownable2Step`
(`transferOwnership` + `acceptOwnership`), keeping the salt/init-code scheme so the address
stays reproducible.

Ownership cannot be renounced. If the registry must be replaced, the owner calls
`setSuccessorOnce(expectedEpoch, successor)`. The successor must implement
`IOctantRegistry`, must itself be current, and setting it permanently freezes publications
on the old registry.

### Entry lifecycle and versioning

Each key stores its current address, semantic type, lifecycle status, per-key bump, last
publication epoch, optional compatibility version, and observed runtime code hash.

- `ACTIVE` entries resolve through `getAddress` and `tryGetAddress`.
- `DEPRECATED` means intentionally superseded; `DISABLED` means explicitly unsupported or
  unsafe. Both retain their address and history but do not resolve as active dependencies.
- Status is a discovery signal only. Disabling an entry does not pause, revoke, or otherwise
  control the registered contract.
- An entry's type (`CONTRACT`, `FACTORY`, or `REGISTRY`) is fixed by its first publication.
- The optional `compatibilityVersion` describes the registered contract's public API. It is
  not the repository package version.
- **Generations**: the canonical key always points at the **latest** deployment of each kind.
  Superseded generations keep versioned keys (`*_V1`, `*_V2`, … in deployment order) so the
  registry reflects the complete production history. Because new keys must start `ACTIVE`,
  a legacy entry registers ACTIVE in the epoch that introduces it and is flipped to
  `DEPRECATED` in a later epoch (see the two-batch flow in
  `DeployAaveSparkLidoFactories.s.sol`).

The `releaseLabel` is human-readable deployment metadata (normally the `package.json`
version). The contract-computed `manifestHash` is the deterministic publication commitment.
Historical state is reconstructed from `EntryPublished` and `BatchPublished` events; only
current state is stored on-chain.

### Regenerating off-chain views

```bash
REGISTRY_ADDRESS=0x... ETH_RPC_URL=https://... yarn registry:export
```

The exporter selects the `finalized` block by default, pins every call to its numeric height,
and verifies the block hash again after all reads. If the height was replaced, it aborts
without overwriting the existing artifact. Set `REGISTRY_SNAPSHOT=safe`, `latest`, or an
explicit block only when fresher state is required; the before/after hash check still applies.
The artifact is written through an atomic rename after verification.

The exporter records the snapshot tag, number, and hash. It exports canonical hexadecimal
keys alongside their decoded labels, complete entry metadata, global epoch, manifest hash,
release label, and registry API version. It fails if the selected registry has a successor so
an obsolete frozen registry cannot overwrite the canonical artifact. Never hand-edit
`deployments/<chainId>.json`; re-run the generator after every deploy batch.
`DeployedAddresses.sol` remains hand-maintained for script convenience, but the on-chain
registry always wins on conflict.
