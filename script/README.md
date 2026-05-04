# Scripts used by Octant v2

This directory contains all scripts used by Octant v2: both Foundry Solidity scripts (`.s.sol`) and bash shell utilities (`.sh`).

There is no separate `scripts/` directory. Everything lives here.

## Solidity script directories

- `demo` - demo and testing scripts
- `deploy` - deployment scripts
- `deployment` - CD environment deployment scripts
- `helpers` - shared helper contracts for scripts
- `prod` - production deployment scripts
- `verify` - contract verification scripts

## Shell utilities

- `check-natspec.sh` - validates NatSpec documentation coverage on public/external functions
- `combine-proxy-abis.sh` - merges strategy + wrapper ABIs for proxy consumption
- `coverage.sh` - runs forge coverage with Hats Protocol patching workaround
