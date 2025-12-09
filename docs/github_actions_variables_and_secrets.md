# Variables and Secrets in GitHub Actions

# Variables

| Name                        | Description                                                    |
|-----------------------------|----------------------------------------------------------------|
| `GCP_DOCKER_IMAGE_REGISTRY` | Prefix of GCP Artifact Registry used to store built containers |
| `TENDERLY_MAINNET_RPC_URL`  | RPC URL for Tenderly Mainnet Virtual TestNet                   |

# Secrets

| Name                                         | Description                                                                                                  |
|----------------------------------------------|--------------------------------------------------------------------------------------------------------------|
| `GCP_DOCKER_IMAGES_REGISTRY_SERVICE_ACCOUNT` | Authorization tokens to GCP Artifact Registry                                                                |
| `TENDERLY_API_KEY`                           | Tenderly API key                                                                                             |
| `TESTNET_DEPLOYER_PRIVATE_KEY`               | Private key of wallet used to deploy contracts (wallet address `0xfC9527820A76b515a2c66C22e0575501DEDD8281`) |

# Organization secrets

Organization secrets visible only for selected repos

| Name                                | Description                                                                                     |
|-------------------------------------|-------------------------------------------------------------------------------------------------|
| `HOUSEKEEPER_PAT_OCTANT_V2_PACKAGES` | GitHub private access token connected to housekeepers `ci-cd-octant-v2-packages`                |
