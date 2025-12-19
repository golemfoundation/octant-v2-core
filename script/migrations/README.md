# Migrations

One-time scripts for on-chain state changes.

## SetEpochPropsForMarch2026

Sets the Octant epoch to end on March 4, 2026 via the Octant multisig.

### Prerequisites

- Signer on the Octant multisig (`0xa40FcB633d0A6c0d27aA9367047635Ff656229B0`)

### Environment Variables

| Variable | Description |
|----------|-------------|
| `ETH_RPC_URL` | Ethereum mainnet RPC endpoint |
| `CHAIN` | Must be `mainnet` |
| `WALLET_TYPE` | Wallet type (see options below) |
| `MNEMONIC_INDEX` | Account index for hardware wallets (e.g., `0`) |

### Wallet Options

#### Ledger Hardware Wallet

```bash
CHAIN=mainnet \
WALLET_TYPE=ledger \
MNEMONIC_INDEX=0 \
forge script script/migrations/SetEpochPropsForMarch2026.s.sol \
  --fork-url $ETH_RPC_URL \
  --ffi
```

#### Trezor Hardware Wallet

```bash
CHAIN=mainnet \
WALLET_TYPE=trezor \
MNEMONIC_INDEX=0 \
forge script script/migrations/SetEpochPropsForMarch2026.s.sol \
  --fork-url $ETH_RPC_URL \
  --ffi
```

#### Private Key (not recommended for production)

```bash
CHAIN=mainnet \
WALLET_TYPE=private_key \
PRIVATE_KEY=0x... \
forge script script/migrations/SetEpochPropsForMarch2026.s.sol \
  --fork-url $ETH_RPC_URL \
  --ffi
```

### What It Does

1. Verifies on-chain state matches expected values
2. Displays current epoch state and proposed changes
3. Prompts for confirmation (type `yes` to proceed)
4. Submits batched transaction to Safe transaction service
5. Safe signers must approve the transaction

### Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| `_epochDuration` | 4,885,200 (56 days) | Duration from Jan 6, 2026 to March 4, 2026 |
| `_decisionWindow` | 1,209,600 (14 days) | Decision window for the new epoch |

### Behavior

- **Immediate**: `epochPropsIndex` increments from 1 to 2
- **Deferred**: New duration/window activate after epoch 10 ends (Jan 6, 2026)

### Tests

```bash
forge test --match-path script/migrations/OctantEpochs.t.sol -vvv
```
