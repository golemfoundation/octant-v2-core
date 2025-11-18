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
7. Payment Splitter Factory (if not deployed)
8. Sky Compounder Strategy Factory (if not deployed)
9. Morpho Compounder Strategy Factory (if not deployed)
10. Regen Staker Factory

*) if not deployed - the script allows to define static addresses for these contracts and skips if found.

## Prerequisites

1. ~~Create your own Virtual TestNet in Tenderly (Mainnet, sync on) (https://docs.tenderly.co/virtual-testnets/quickstart)~~ (not needed, use the provided RPC URL to connect to shared Tenderly TestNet)
2. Create Tenderly Personal accessToken (https://docs.tenderly.co/account/projects/how-to-generate-api-access-token#personal-account-access-tokens) (needed to verify contacts)
3. Send some ETH (your own Mainnet TestNet RPC) to your deployer address (ex. MetaMask account) (https://docs.tenderly.co/virtual-testnets/unlimited-faucet)

## Environment Setup

Create `.env` file:
```
PRIVATE_KEY=(deployer private key ex. MetaMask account)
RPC_URL=https://rpc.ov2sm.octant.build
VERIFIER_URL=$RPC_URL/verify/etherscan
VERIFIER_API_KEY=(your Personal Tenderly accessToken)
MAX_OPEX_SPLIT=5 # to confirm
MIN_METAPOOL_SPLIT=0 # to confirm
```

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
