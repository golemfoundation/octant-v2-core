# Octant v2 Production Deployment

`DeployProtocol.s.sol` encodes the complete Octant v2 mainnet deployment as a sequence of Gnosis Safe
transactions. Every contract is deployed through Nick's CREATE2 factory
(`0x4e59b44847b379578588920cA78FbF26c0B4956C`), so addresses depend only on the salt and the creation
code — never on the Safe nonce.

The script does not broadcast. It simulates, asserts each deployment lands on its precomputed address,
and (with `SEND=true`) proposes the batch to the Safe transaction service for owner signatures.

## Structure — 8 Safe transactions

**Phase A — 13 factory/implementation contracts.** Split into four batches only because of the
EIP-7825 per-transaction gas limit of ~16.78M.

| Tx | Entry point | Contracts |
|---|---|---|
| 1 | `phaseA_batch1()` | YieldSkimmingTokenizedStrategy, YieldDonatingTokenizedStrategy, PaymentSplitterFactory, LidoStrategyFactory, MorphoCompounderStrategyFactory |
| 2 | `phaseA_batch2()` | SkyCompounderStrategyFactory, YearnV3StrategyFactory |
| 3 | `phaseA_batch3()` | AddressSetFactory, RegenEarningPowerCalculatorFactory, RegenStakerFactory |
| 4 | `phaseA_batch4()` | SparkStrategyFactory, AaveV3StrategyFactory, RocketPoolStrategyFactory |

**Phase B — 5 instance contracts.** Requires Phase A to be executed on-chain first.

| Tx | Entry point | Contracts |
|---|---|---|
| 5 | `phaseB_addressSets()` | allocationMechanismAllowset, stakerAllowset, stakerBlockset |
| 6 | `phaseB_calculator()` | RegenEarningPowerCalculator |
| 7 | `phaseB_staker()` | RegenStakerWithoutDelegateSurrogateVotes |
| 8 | `phaseB_stakerAccessSets()` | Assigns the staker's allowset/blockset via admin setters |

The staker is constructed with `address(0)` for its allowset and blockset and `accessMode = NONE`, so
the sets are inactive until Tx 8 assigns them.

## Environment

```
SAFE_ADDRESS     required  -- target Gnosis Safe
SALT_TIMESTAMP   optional  -- suffix for all CREATE2 salts; auto-generated as HH_DDMMYYYY via FFI
SEND             optional  -- set to true to submit to the Safe API (default: simulate only)
CHAIN            e.g. mainnet
WALLET_TYPE      local | ledger
PRIVATE_KEY      required for WALLET_TYPE=local
```

Reusing the same `SALT_TIMESTAMP` reproduces the same addresses; changing it produces a fresh set.
Pin it explicitly when replaying a deployment across the hour boundary.

> ⚠️ The salt preimage prefixes here are identical to the pinned constants in
> `script/deploy/DeployNewStrategiesAndFactories.s.sol`. Pinning `SALT_TIMESTAMP=11022026` (or
> `07072026`) reproduces that script's exact addresses, so every CREATE2 reverts if those contracts
> already exist. Let the timestamp auto-generate as `HH_DDMMYYYY` unless you are deliberately
> replaying an in-flight deployment.

## Running

Preview all 18 deterministic addresses without proposing anything:

```bash
SAFE_ADDRESS=0x... forge script script/prod/DeployProtocol.s.sol:DeployProtocol \
  --sig "computeAllAddresses()" --ffi
```

Simulate one batch against a fork:

```bash
CHAIN=mainnet WALLET_TYPE=local PRIVATE_KEY=0x... SAFE_ADDRESS=0x... \
forge script script/prod/DeployProtocol.s.sol:DeployProtocol \
  --sig "phaseA_batch4()" --rpc-url $FORK_RPC --ffi
```

Propose to the Safe by adding `SEND=true`. Run the batches in order and let each one execute on-chain
before proposing the next — Phase B reads addresses that Phase A must have produced.

Before signing, diff the addresses in the batch output against the `computeAllAddresses()` output.

## Source verification

```bash
SAFE_ADDRESS=0x... SALT_TIMESTAMP=... ETHERSCAN_API_KEY=... \
forge script script/prod/DeployProtocol.s.sol:VerifyProtocolSourceCode --sig "verifyEtherscan()" --ffi

SAFE_ADDRESS=0x... SALT_TIMESTAMP=... \
forge script script/prod/DeployProtocol.s.sol:VerifyProtocolSourceCode --sig "verifySourcify()" --ffi
```

## Post-deployment verification

`VerifyProtocolDeployment` is a fork test suite covering all deployed contracts: code existence,
factory constants, ownership, address-set determinism, calculator behaviour, and a staker
stake/withdraw cycle. It is excluded from the default Foundry profile.

```bash
FOUNDRY_PROFILE=mainnet forge test --match-contract VerifyProtocolDeployment --fork-url <mainnet-rpc>
```

Addresses default to the production deployment and can each be overridden via `EXPECTED_*` env vars to
verify a testbed instead. The batch 4 factories (Spark, Aave V3, Rocket Pool) have no production
default yet: supply `EXPECTED_SPARK_FACTORY`, `EXPECTED_AAVE_V3_FACTORY`, and
`EXPECTED_ROCKET_POOL_FACTORY` to bring them under verification. The suite logs
`[NOT CONFIGURED]` for any it skips.

## Security notes

- All ownership and admin roles are assigned to the Safe, never to the deploying EOA
- Address assertions run before a batch is proposed, so a salt or bytecode drift fails locally rather
  than producing a Safe payload whose logged addresses are wrong
- Verify all addresses and permissions manually after execution

## Related

- Staging / testbed Safe path and salt tables: [`../deploy/DEPLOYMENT_GUIDE.md`](../deploy/DEPLOYMENT_GUIDE.md)
- EOA staging path: [`../deployment/staging/README.md`](../deployment/staging/README.md)
- CI coverage for the deployment scripts: `test/unit/script/DeploymentScripts.t.sol`
