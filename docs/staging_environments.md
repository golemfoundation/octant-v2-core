# Staging environments

We have staging environment for testing the Octant v2 Core built on fork of Mainnet.

This environment is used for development, testing and staging as blockchain can be used with multiple instances of contracts.

We're using [Tenderly Virtual TestNets] and Kubernetes cluster deployed in Google Cloud Platform.

Access to environments is limited to VPN, Kubernetes cluster and CI/CD runners.

## Deployed services

- Ethereum RPC node (proxied Tenderly Virtual Testnet RPC endpoint)
- Graph-node
- Gnosis Safe infrastructure

## Endpoints 

| Service                    | Endpoint                                    |
|----------------------------|---------------------------------------------|
| RPC node                   | `https://virtual-mainnet.rpc.octant.build/` |
| Safe frontend              | `https://safe.ov2sm.octant.build/`          |
| Safe config service        | `https://cfg.ov2sm.octant.build/`           |
| Graph node client endpoint | `https://graph.ov2sm.octant.build/`         |
| Graph node admin endpoint  | `https://graph-admin.ov2sm.octant.build/`   |


[Tenderly Virtual TestNets]: https://docs.tenderly.co/virtual-testnets
