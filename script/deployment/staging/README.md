# Dragon Protocol Deployment Guide (Sepolia Mainnet Fork)

This guide explains how to deploy the Dragon Protocol core components in a Staging environment or in your own Tenderly Mainnet Testnet.

## Overview

The DeployProtocol script handles the sequential deployment of:

1. Module Proxy Factory
2. Linear Allowance For Gnosis Safe
3. Dragon Tokenized Strategy Implementation
4. Dragon Router
5. Mock Strategy (for testing)
6. Hats Protocol & Dragon Hatter
7. Payment Splitter Factory (conditional)
8. Sky Compounder Strategy Factory (conditional)
9. Morpho Compounder Strategy Factory (conditional)
10. Regen Staker Factory
11. Allocation Mechanism Factory

### Smart Deployment with Address Reuse

The deployment script uses a centralized address registry (`script/helpers/DeployedAddresses.sol`) that:

- Reads the `DEPLOYMENT_NETWORK` environment variable to select the network
- Loads previously deployed contract addresses for that network
- Skips redeployment for contracts with existing addresses (set to non-zero)
- Deploys fresh instances for contracts with address(0)

**Why explicit network selection?**
- Tenderly staging is a mainnet FORK (chain ID = 1)
- Cannot distinguish between staging and production mainnet by chain ID alone
- Explicit network selection via env var prevents deployment mistakes

**Supported Networks:**
- `mainnet` - Ethereum mainnet (production)
- `sepolia` - Sepolia testnet
- `staging` - Tenderly virtual testnet (mainnet fork)
- `anvil` - Local Anvil testnet

This approach:
- Saves gas by reusing stable factory contracts
- Ensures consistency across deployments
- Makes network-specific configuration maintainable
- Prevents accidental deployments to wrong network

To add addresses for a new network, edit `script/helpers/DeployedAddresses.sol` and add the addresses to the appropriate network function.

## Prerequisites

1. ~~Create your own Virtual TestNet in Tenderly (Mainnet, sync on) (https://docs.tenderly.co/virtual-testnets/quickstart)~~ (not needed, use the provided RPC URL to connect to shared Tenderly TestNet)
2. Create Tenderly Personal accessToken (https://docs.tenderly.co/account/projects/how-to-generate-api-access-token#personal-account-access-tokens) (needed to verify contacts)
3. Send some ETH (your own Mainnet TestNet RPC) to your deployer address (ex. MetaMask account) (https://docs.tenderly.co/virtual-testnets/unlimited-faucet)

## Environment Setup

Create `.env` file:
```
# Network selection (mainnet, sepolia, staging, or anvil)
DEPLOYMENT_NETWORK=staging

# Deployment credentials
PRIVATE_KEY=(deployer private key ex. MetaMask account)
RPC_URL=https://rpc.ov2sm.octant.build
VERIFIER_URL=$RPC_URL/verify/etherscan
VERIFIER_API_KEY=(your Personal Tenderly accessToken)

# Protocol parameters
MAX_OPEX_SPLIT=5 # to confirm
MIN_METAPOOL_SPLIT=0 # to confirm
```

**Important:** Set `DEPLOYMENT_NETWORK` to match your target environment:
- Use `staging` for Tenderly virtual testnet (default if not set)
- Use `mainnet` for production Ethereum mainnet
- Use `sepolia` for Sepolia testnet
- Use `anvil` for local Anvil testnet

## Running the Deployment

### Automatically

```
yarn deploy:tenderly
```

### Manually

1. Load env variables
   ```shell
   source .env
   ```

2. First dry run the deployment:
   ```
   forge script script/deployment/staging/DeployProtocol.s.sol:DeployProtocol --slow --rpc-url $RPC_URL
   ```

3. If the dry run succeeds, execute the actual deployment:
   ```
   forge script script/deployment/staging/DeployProtocol.s.sol:DeployProtocol --slow --rpc-url $RPC_URL --broadcast --verify --verifier custom
   ```

## Post Deployment

The script will output a deployment summary with all contract addresses. Save these addresses for future reference.

## Security Considerations 

- All contract ownership and admin roles are initially assigned to the deployer
- Additional owners and permissions should be configured after successful deployment
- Verify all addresses and permissions manually after deployment

## Next Steps

After successful deployment:
1. Set up extra permissions on hats protocol
2. Deposit into strategy and mint underlying asset token
