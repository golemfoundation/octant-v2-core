# Contract Verification Guide

This guide explains how to verify the deployed Octant V2 Core contracts on Ethereum mainnet using the verification script.

## Overview

The verification script (`VerifyDeployedContracts.s.sol`) automates the process of verifying all 5 contracts deployed by the `DeployAllStrategiesAndFactories.s.sol` script:

### Contracts to Verify
1. **YieldDonatingTokenizedStrategy** - Base implementation for productive assets
2. **MorphoCompounderStrategyFactory** - Factory for Morpho yield donating strategies
3. **SkyCompounderStrategyFactory** - Factory for Sky Compounder yield donating strategies
4. **PaymentSplitterFactory** - Factory for PaymentSplitter contracts
5. **YearnV3StrategyFactory** - Factory for YearnV3 yield donating strategies

## Prerequisites

1. **Deployed Contracts**: All contracts must be successfully deployed on Ethereum mainnet
2. **Etherscan API Key**: Required for contract verification
3. **Contract Addresses**: You'll need the deployed address of each contract
4. **Foundry/Forge**: Must be installed and available in your PATH
5. **Internet Connection**: Required for Etherscan API calls

## Environment Setup

### 1. Set Required Environment Variables

```bash
# Required: Etherscan API key for verification
export ETHERSCAN_API_KEY=your_etherscan_api_key_here

# Required: Ethereum RPC URL
export ETH_RPC_URL=https://eth-mainnet.alchemyapi.io/v2/YOUR_API_KEY

# Optional: Set chain ID (defaults to 1 for mainnet)
export CHAIN_ID=1
```

### 2. Get Your Etherscan API Key

1. Go to [Etherscan.io](https://etherscan.io)
2. Create an account or log in
3. Navigate to API Keys section
4. Generate a new API key
5. Copy the API key for use in the script

## Running the Verification Script

### 1. Basic Command

```bash
forge script script/verify/VerifyDeployedContracts.s.sol:VerifyDeployedContracts \
  --rpc-url $ETH_RPC_URL \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --ffi
```

### 2. Interactive Process

When you run the script, it will prompt you for each contract address:

```
=== CONTRACT VERIFICATION SETUP ===
Please provide the deployed contract addresses:

Enter YieldDonatingTokenizedStrategy address: 0x98E0708F33Cf8f6B8d39f4b9A590f2a220FfFd9a
[OK] YieldDonatingTokenizedStrategy: 0x98E0708F33Cf8f6B8d39f4b9A590f2a220FfFd9a

Enter MorphoCompounderStrategyFactory address: 0x1Cef490f733A30736a1c5Cecf1C177fb27391D32
[OK] MorphoCompounderStrategyFactory: 0x1Cef490f733A30736a1c5Cecf1C177fb27391D32

... (continues for all 5 contracts)
```

### 3. Expected Output

```
=== STARTING CONTRACT VERIFICATION ===

Verifying YieldDonatingTokenizedStrategy at 0x98E0708F33Cf8f6B8d39f4b9A590f2a220FfFd9a
[SUCCESS] YieldDonatingTokenizedStrategy verification initiated
   Result: Start verifying contract `0x98E0708F33Cf8f6B8d39f4b9A590f2a220FfFd9a` deployed on mainnet

Verifying MorphoCompounderStrategyFactory at 0x1Cef490f733A30736a1c5Cecf1C177fb27391D32
[SUCCESS] MorphoCompounderStrategyFactory verification initiated
   Result: Start verifying contract `0x1Cef490f733A30736a1c5Cecf1C177fb27391D32` deployed on mainnet

... (continues for all contracts)
```

## What the Script Does

1. **Prompts for Addresses**: Interactively collects all 5 contract addresses
2. **Validates Addresses**: Ensures each address is a valid Ethereum address
3. **Submits Verification**: Uses `forge verify-contract` for each contract
4. **Provides Feedback**: Shows success/failure status for each verification
5. **Logs Summary**: Displays final summary of all verification attempts

## Address Collection Tips

### Where to Find Contract Addresses

1. **From Deployment Logs**: Check the output of your deployment script
2. **From Safe Transaction**: Look at the Safe transaction details after execution
3. **From Block Explorer**: Check the transactions that deployed the contracts
4. **From CREATE2 Calculator**: Use the same salts to calculate expected addresses

### Address Format

- All addresses should be in checksum format (0x followed by 40 hexadecimal characters)
- Example: `0x1Cef490f733A30736a1c5Cecf1C177fb27391D32`
- The script will validate addresses and show an error for invalid formats

## Verification Process

### How Verification Works

1. **Source Code Compilation**: Forge compiles your contract source code
2. **Bytecode Comparison**: Compares compiled bytecode with deployed bytecode
3. **Etherscan Submission**: Submits source code and metadata to Etherscan
4. **Async Processing**: Etherscan processes verification in the background

### Verification Status

- **[SUCCESS]**: Verification was submitted successfully
- **[FAILED]**: Verification submission failed (check error message)
- **Pending**: Verification is processing on Etherscan (check manually)

