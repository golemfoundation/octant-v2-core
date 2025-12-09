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
   - Private key for transaction submission (doesn't need to be a Safe owner)

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

