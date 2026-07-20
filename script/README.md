# Scripts used by Octant v2

This directory contains Foundry Solidity scripts (`.s.sol`) and bash shell
utilities (`.sh`) used by Octant v2. Node.js repository tooling lives under
`../scripts/`.

## Solidity script directories

- `demo` - demo and testing scripts
- `deploy` - deployment scripts
- `deployment` - CD environment deployment scripts
- `helpers` - shared helper contracts for scripts
- `prod` - production deployment scripts
- `verify` - contract verification scripts

## Deployment entry points

There are three distinct deployment paths. They deploy overlapping contract sets with
different CREATE2 salts, so they produce **different addresses** — pick one per environment.

| Path | Entry point | Deploys via |
|---|---|---|
| Production (Safe) | `prod/DeployProtocol.s.sol` — `phaseA_batch1..4`, `phaseB_*` | Nick's CREATE2 factory, salts suffixed by `SALT_TIMESTAMP` |
| Staging / testbed (Safe) | `deploy/DeployNewStrategiesAndFactories.s.sol` — `run()` or `runBatch1..4()` | Nick's CREATE2 factory, pinned date salts |
| Staging (EOA) | `deployment/staging/DeployProtocol.s.sol` — `run()` | Deployer EOA, composes the standalone `deploy/Deploy*Factory.sol` scripts |

`deploy/DeployAllStrategiesAndFactories.s.sol` (salts `05112025`) and
`deploy/DeployYieldSkimmingStrategiesAndFactories.s.sol` (salts `18012026`) cover subsets of the same
contracts with their own salts. They are still live entry points, so take care not to mix them with the
paths above in the same environment.

Full instructions: [`deploy/DEPLOYMENT_GUIDE.md`](deploy/DEPLOYMENT_GUIDE.md).
CI coverage for these scripts: `test/unit/script/DeploymentScripts.t.sol`.

## Shell utilities

- `check-natspec.sh` - validates NatSpec documentation coverage on public/external functions
- `combine-proxy-abis.sh` - merges strategy + wrapper ABIs for proxy consumption
- `coverage.sh` - runs forge coverage with Hats Protocol patching workaround
