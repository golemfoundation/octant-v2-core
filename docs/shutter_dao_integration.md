# Shutter DAO 0x36 × Octant v2 Integration Plan


## Overview

Shutter DAO 0x36 will integrate with Octant v2 through **two distinct components**:

1. **Dragon Vault** — A Multistrategy Vault for treasury capital deployment (no lockup)
2. **Regen Staker** — A staking contract for SHU tokens enabling public goods funding with matched rewards

| Component | Purpose | Capital |
|-----------|---------|---------|
| Dragon Vault | Generate yield to fund Regen Staker rewards | 1.2M USDC |
| Regen Staker | Public goods funding (matched rewards) | SHU tokens |

---

## Verified On-Chain Addresses

| Entity | Address | Network |
|--------|---------|---------|
| Shutter DAO Treasury | [`0x36bD3044ab68f600f6d3e081056F34f2a58432c4`](https://etherscan.io/address/0x36bD3044ab68f600f6d3e081056F34f2a58432c4) | Ethereum |
| SHU Token | [`0xe485E2f1bab389C08721B291f6b59780feC83Fd7`](https://etherscan.io/token/0xe485E2f1bab389C08721B291f6b59780feC83Fd7) | Ethereum |
| Morpho Steakhouse USDC | [`0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB`](https://app.morpho.org/ethereum/vault/0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB/steakhouse-usdc) | Ethereum |
| USDC | [`0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`](https://etherscan.io/token/0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48) | Ethereum |

---

## Part 1: Dragon Vault

The Multistrategy Vault manages treasury capital with instant liquidity (no lockup or rage quit required).

### Underlying Strategy

[**Morpho Steakhouse USDC Vault**](https://app.morpho.org/ethereum/vault/0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB/steakhouse-usdc)
- Credora Rating: A+


### Role Assignments

| Role | Assigned To | Description |
|------|-------------|-------------|
| **Operator** | Shutter DAO Treasury (`0x36bD...32c4`) | Only entity that can deposit/mint shares into the vault |
| **Management** | Shutter DAO Treasury (`0x36bD...32c4`) | Administrative role (add strategies, set keeper, set emergency admin). Can delegate to a sub-DAO/multisig later if needed. |
| **Keeper** | Dedicated Bot/EOA *(Recommended)* | Authorized to call `report()`/`tend()` to harvest yields. See [Operational Considerations](#operational-considerations). |
| **Emergency Admin** | Shutter DAO Treasury | Can shutdown the vault and perform emergency withdrawals. Note: Emergency actions follow standard DAO voting timeline. |

### Yield Distribution

| Destination | Allocation |
|-------------|------------|
| Ethereum Sustainability Fund (ESF) | 0% (Excluded from PaymentSplitter configuration to prevent revert) |
| Dragon Funding Pool | 100% |

### Yield Projections (assuming 5% APY)

| Metric | Annual |
|--------|--------|
| Gross Yield | 60,000 USDC |
| To ESF | 0 USDC |
| To Dragon Funding Pool | 60,000 USDC |
| Epochs Supported | ~3 per year (~20,000 USDC each) |

---

## Part 2: Regen Staker

The Regen Staker allows SHU holders to stake their tokens and direct their staking rewards toward public goods funding, which Octant matches. Rewards are distributed from an external source (e.g., Dragon Vault yield).

### Key Features

- **Public Goods Funding**: Stakers allocate their rewards to projects in Octant funding rounds
- **Matched Rewards**: Contributions are matched by Octant's matching pool
- **Delegation Preserved**: Stakers retain Shutter DAO voting power via delegation surrogates

### Voting Power (Shutter DAO)

| Action | Shutter DAO Voting |
|--------|------------|
| Stake SHU in Regen Staker | ✓ (via delegation surrogate) |
| Stake in Shutter Keyper Contract | Keyper Incentives (separate system) |

### How Delegation Works

1. User stakes SHU tokens in the Regen Staker
2. Tokens are held by a **Delegation Surrogate** contract (deployed deterministically via CREATE2)
3. The surrogate delegates Shutter DAO voting power to the user's chosen delegatee
4. User's staking rewards can be directed to public goods funding

---

## Shutter DAO Governance

### Architecture

Shutter DAO 0x36 uses **Fractal (Decent)** for on-chain governance, built on Safe:

| Component | Address / Value |
|-----------|-----------------|
| Safe (Treasury) | [`0x36bD3044ab68f600f6d3e081056F34f2a58432c4`](https://etherscan.io/address/0x36bD3044ab68f600f6d3e081056F34f2a58432c4) |
| Governance Module | Azorius + LinearERC20Voting |
| Voting Token | SHU ([`0xe485E2f1bab389C08721B291f6b59780feC83Fd7`](https://etherscan.io/token/0xe485E2f1bab389C08721B291f6b59780feC83Fd7)) |

### Governance Parameters

| Parameter | Value | Notes |
|-----------|-------|-------|
| Voting Period | 72 hours (3 days) | Time window for SHU holders to vote |
| Quorum | 3% of total supply | Minimum participation required |
| Execution Period | 72 hours (3 days) | Window to execute after passing |
| Proposal Threshold | TBD | Minimum SHU to create proposal |

> **Note**: Parameters should be verified on-chain via the Azorius module. Values above are based on typical Fractal deployments.

### Voting Platforms

| Platform | Type | Use Case |
|----------|------|----------|
| [Decent](https://app.decentdao.org/home?dao=eth%3A0x36bD3044ab68f600f6d3e081056F34f2a58432c4) | On-chain | Treasury transactions, contract interactions |
| [Snapshot](https://snapshot.org/#/shutterdao0x36.eth) | Off-chain | Temperature checks, non-binding polls |

Shutter DAO also supports **Shielded Voting** on Snapshot, which encrypts votes until the voting period ends to prevent manipulation.

---

## Execution Playbook

### Phase 1: Dragon Vault Deployment

The entire deployment can be executed in a **single DAO proposal** with batched transactions. This approach:
- Deploys all contracts atomically
- Sets up roles and permissions
- Deposits treasury capital
- Must fit within 16.7M gas (EIP-7825 per-transaction gas limit)

#### Step 1: Create Fractal Proposal (UI Walkthrough)

**1.1 — Navigate to Shutter DAO on Decent**

Open [app.decentdao.org/home?dao=eth:0x36bD3044ab68f600f6d3e081056F34f2a58432c4](https://app.decentdao.org/home?dao=eth%3A0x36bD3044ab68f600f6d3e081056F34f2a58432c4)

**1.2 — Connect Wallet**

Connect a wallet holding SHU tokens (required to meet proposal threshold).

**1.3 — Click "Create Proposal"**

Navigate to the Proposals tab and click the "Create Proposal" button.

**1.4 — Fill Proposal Details**

| Field | Value |
|-------|-------|
| Title | `Deploy Octant Dragon Vault and Deposit 1.2M USDC` |
| Description | See [Proposal Template](#proposal-template) below |

**1.5 — Add Transaction 1: Deploy Morpho Strategy**

| Field | Value |
|-------|-------|
| Target Contract | `[STRATEGY_FACTORY_ADDRESS]` *(TBD by Octant)* |
| Function | `deployMorphoStrategy(...)` |
| Parameters | See [Technical Calldata](#technical-calldata-for-verification) |

> **Note**: The strategy deployment includes the donation address (Dragon Router) and payment splitter configuration for yield distribution. The Ethereum Sustainability Fund (ESF) is excluded from the PaymentSplitter payees array because a 0 share allocation would cause the deployment to revert.

**1.6 — Add Transaction 2: Deploy Dragon Vault**

| Field | Value |
|-------|-------|
| Target Contract | `[VAULT_FACTORY_ADDRESS]` *(TBD by Octant)* |
| Function | `deployNewVault(address asset, string name, string symbol, address roleManager, uint256 profitMaxUnlockTime)` |
| `asset` | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` (USDC) |
| `name` | `Shutter Dragon Vault` |
| `symbol` | `sdUSDC` |
| `roleManager` | `0x36bD3044ab68f600f6d3e081056F34f2a58432c4` (Treasury) |
| `profitMaxUnlockTime` | `604800` (7 days) |

**1.7 — Add Transactions: Assign Roles**

The vault requires role assignments to function. Add these as separate transactions in the proposal (or batch them if supported).

| Field | Value |
|-------|-------|
| Target Contract | `[DRAGON_VAULT_ADDRESS]` *(from Tx 2)* |
| Function | `addRole(address account, uint8 role)` |

Add the following role assignments:

1. `ADD_STRATEGY_MANAGER` (0) → `0x36bD...32c4` (Treasury)
2. `QUEUE_MANAGER` (4) → `0x36bD...32c4` (Treasury)
3. `DEBT_MANAGER` (6) → `0x36bD...32c4` (Treasury)
4. `MAX_DEBT_MANAGER` (7) → `0x36bD...32c4` (Treasury)
5. `DEPOSIT_LIMIT_MANAGER` (8) → `0x36bD...32c4` (Treasury)
6. `WITHDRAW_LIMIT_MANAGER` (9) → `0x36bD...32c4` (Treasury)
7. `DEBT_MANAGER` (6) → `[KEEPER_ADDRESS]` (Dedicated EOA/Bot)

> **Note**: These roles are critical for managing strategies, debt, and limits.

**1.8 — Add Transaction: Add Strategy to Vault**

| Field | Value |
|-------|-------|
| Target Contract | `[DRAGON_VAULT_ADDRESS]` |
| Function | `addStrategy(address strategy)` |
| `strategy` | `[STRATEGY_ADDRESS]` *(from Tx 1)* |

**1.9 — Add Transaction: Set Strategy Max Debt**

| Field | Value |
|-------|-------|
| Target Contract | `[DRAGON_VAULT_ADDRESS]` |
| Function | `updateMaxDebtForStrategy(address strategy, uint256 newMaxDebt)` |
| `strategy` | `[STRATEGY_ADDRESS]` |
| `newMaxDebt` | `type(uint256).max` |

**1.10 — Add Transaction: Set Default Queue**

| Field | Value |
|-------|-------|
| Target Contract | `[DRAGON_VAULT_ADDRESS]` |
| Function | `setDefaultQueue(address[] calldata newDefaultQueue)` |
| `newDefaultQueue` | `[[STRATEGY_ADDRESS]]` |

**1.11 — Add Transaction: Set AutoAllocate Mode**

| Field | Value |
|-------|-------|
| Target Contract | `[DRAGON_VAULT_ADDRESS]` |
| Function | `setAutoAllocate(bool autoAllocate)` |
| `autoAllocate` | `true` |

> **Note**: Setting `autoAllocate` to `true` ensures that deposits are immediately deployed to the strategy (Morpho Steakhouse USDC) to start earning yield without requiring manual Keeper intervention.

**1.12 — Add Transaction: Set Deposit Limit**

| Field | Value |
|-------|-------|
| Target Contract | `[DRAGON_VAULT_ADDRESS]` |
| Function | `setDepositLimit(uint256 depositLimit, bool depositLimitActive)` |
| `depositLimit` | `type(uint256).max` |
| `depositLimitActive` | `true` |

**1.12 — Add Transaction: Approve USDC**

| Field | Value |
|-------|-------|
| Target Contract | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` (USDC) |
| Function | `approve(address spender, uint256 amount)` |
| `spender` | `[DRAGON_VAULT_ADDRESS]` |
| `amount` | `1200000000000` |

**1.13 — Add Transaction: Deposit USDC**

| Field | Value |
|-------|-------|
| Target Contract | `[DRAGON_VAULT_ADDRESS]` |
| Function | `deposit(uint256 assets, address receiver)` |
| `assets` | `1200000000000` |
| `receiver` | `0x36bD3044ab68f600f6d3e081056F34f2a58432c4` |

**1.13 — Submit Proposal**

Review all details and click "Submit Proposal". Sign the transaction with your wallet.

> ✅ **Gas Verified**: The batched proposal uses ~2.22M gas for the DAO proposal portion, or ~11.5M total gas if everything (including factories) is deployed in one go. Both are well under the 16.7M per-transaction gas limit (EIP-7825). See `ShutterDAOGasProfilingTest` for details.

### Gas Profile Breakdown

| Component | Gas Cost |
|-----------|----------|
| **Strategy Deploy** | ~1,002,478 |
| **Vault Deploy** | ~185,086 |
| **Configuration** | ~249,102 |
| **Approve/Deposit** | ~780,131 |
| **Total (Fork)** | **~11,501,894** |
| **DAO Proposal** | **~2,216,797** |

*Note: "DAO Proposal" gas assumes factory deployments are separate or pre-existing, consistent with the batched proposal structure. Even in a worst-case scenario (full deployment in one tx), ~11.5M gas is comfortably within the 16.7M transaction limit (~69% usage).*

#### Step 2: Vote

1. Share the proposal link on the [Shutter Forum](https://shutternetwork.discourse.group/) for discussion
2. SHU holders vote during the 72-hour voting period
3. Proposal passes if quorum (3%) is met and majority votes "For"

#### Step 3: Execute

Once the voting period ends and the proposal passes:

1. Return to the proposal page on Decent
2. Click "Execute" (available during the 72-hour execution window)
3. Sign the execution transaction
4. Verify on Etherscan that all transactions succeeded

#### Step 4: Verify Deployment

After execution, verify:

- [ ] Dragon Vault deployed at expected address
- [ ] Strategy deployed with correct donation address
- [ ] Treasury received vault shares
- [ ] Funds deployed to underlying strategy (if autoAllocate enabled) OR idle in vault (if keeper must allocate)

### Proposal Template

```markdown
## Summary

This proposal deploys the Octant Dragon Vault infrastructure and deposits 
1,200,000 USDC from Shutter DAO 0x36 treasury as part of the Octant v2 pilot.

## Background

Octant v2 enables DAOs to optimize treasury yield while funding public goods. 
See: [Octant v2 Pilot Proposal](https://shutternetwork.discourse.group/t/octant-v2-pilot-to-optimize-treasury-strengthen-ecosystem/760)

## Transactions (16 total)

1. **Deploy Morpho Strategy**: Create yield strategy with donation configuration
2. **Deploy Dragon Vault**: Create vault with Treasury as role manager
3. **Assign Roles**: Add 7 operational roles to Treasury and Keeper
4. **Add Strategy**: Register strategy with vault
5. **Set Max Debt**: Allow full allocation to strategy
6. **Set Default Queue**: Configure withdrawal order
7. **Set AutoAllocate**: Enable automatic deployment of deposits to strategy
8. **Set Deposit Limit**: Enable deposits
9. **Approve USDC**: Allow Dragon Vault to spend 1.2M USDC
10. **Deposit USDC**: Deposit 1.2M USDC, receiving shares to Treasury

## Yield Distribution

- 0% → Ethereum Sustainability Fund (Excluded from configuration)
- 100% → Dragon Funding Pool (Shutter ecosystem grants)

## Risk Considerations

- Strategy: Morpho Steakhouse USDC (Credora A+ rated)
- Custody: Treasury retains full share ownership
- Liquidity: Instant withdrawals (no lockup period)

## Links

- [Morpho Strategy](https://app.morpho.org/ethereum/vault/0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB/steakhouse-usdc)
```

### Technical Calldata (for verification)

Use this to verify transaction encoding matches the UI:

**Transaction 12 — Set AutoAllocate**

```
Function: setAutoAllocate(bool)
Selector: 0xc4456947
Parameters:
  autoAllocate: true (1)

Encoded:
0xc4456947
  0000000000000000000000000000000000000000000000000000000000000001
```

**Transaction 15 — Approve USDC**

```
Function: approve(address,uint256)
Selector: 0x095ea7b3
Parameters:
  spender: [DRAGON_VAULT_ADDRESS]
  amount:  1200000000000 (0x1176592e000)

Encoded (with placeholder vault 0x1234...5678):
0x095ea7b3
  0000000000000000000000001234567890123456789012345678901234567890  // spender
  000000000000000000000000000000000000000000000000000001176592e000 // amount
```

**Transaction 16 — Deposit USDC**

```
Function: deposit(uint256,address)
Selector: 0x6e553f65
Parameters:
  assets:   1200000000000 (0x1176592e000)
  receiver: 0x36bD3044ab68f600f6d3e081056F34f2a58432c4

Encoded:
0x6e553f65
  000000000000000000000000000000000000000000000000000001176592e000 // assets
  00000000000000000000000036bd3044ab68f600f6d3e081056f34f2a58432c4  // receiver
```

---

### Phase 2: Regen Staker Setup

Once the Regen Staker is deployed by Octant:

#### Verification Checklist

- [ ] Admin address matches Treasury (`0x36bD3044ab68f600f6d3e081056F34f2a58432c4`)
- [ ] `STAKE_TOKEN()` returns SHU address (`0xe485E2f1bab389C08721B291f6b59780feC83Fd7`)
- [ ] Delegation surrogates deploy correctly (test with small stake)

#### User Flow

1. SHU holder approves tokens for Regen Staker contract
2. Calls `stake(amount, delegatee)` 
3. Delegatee receives Shutter DAO voting power via surrogate
4. Staker can direct their rewards to public goods projects in Octant funding rounds

---

## Operational Considerations

### Keeper Setup

> ⚠️ **Recommendation**: Use a dedicated EOA or bot for the Keeper role.

If the Treasury is set as Keeper, a DAO vote is required for every yield harvest — introducing delays and governance overhead. A dedicated Keeper address enables:
- Automated, gas-efficient harvesting
- No governance bottleneck for routine operations
- Faster yield compounding

### AutoAllocate vs Manual Allocation

The vault supports two modes for deploying deposited funds to strategies:

| Mode | Behavior | Use Case |
|------|----------|----------|
| **AutoAllocate ON** | Deposits automatically deployed to `defaultQueue[0]` | Set-and-forget, higher gas per deposit |
| **AutoAllocate OFF** | Deposits remain idle until Keeper calls `updateDebt()` | Lower deposit gas, requires active management |

> **Recommendation**: Enable autoAllocate for simplicity. The Keeper can still call `updateDebt()` to rebalance between strategies.

### Emergency Admin

The Treasury serves as Emergency Admin. Emergency actions (shutdown, forced withdrawals) will follow standard DAO voting timelines unless a separate multisig is designated for faster response.

### Withdrawals

The Dragon Vault uses the base `MultistrategyVault` (no lockup). Withdrawals are instant:
1. Call `withdraw(assets, receiver, owner)` or `redeem(shares, receiver, owner)`
2. Receive underlying assets immediately

If funds are deployed to strategies, the vault automatically withdraws from the default queue.

---

## References

- [Shutter DAO Blueprint](https://blog.shutter.network/a-proposed-blueprint-for-launching-a-shutter-dao/)
- [Octant v2 Pilot Proposal (Forum)](https://shutternetwork.discourse.group/t/octant-v2-pilot-to-optimize-treasury-strengthen-ecosystem/760)
- [Morpho Steakhouse USDC Vault](https://app.morpho.org/ethereum/vault/0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB/steakhouse-usdc)
- [Shutter DAO Governance (Fractal/Decent)](https://app.decentdao.org/home?dao=eth%3A0x36bD3044ab68f600f6d3e081056F34f2a58432c4)
- [Shutter DAO Treasury (Etherscan)](https://etherscan.io/address/0x36bD3044ab68f600f6d3e081056F34f2a58432c4)

