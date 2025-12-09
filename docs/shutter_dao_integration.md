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
| USDC | [`0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`](https://etherscan.io/token/0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48) | Ethereum |
| Morpho Strategy Factory | [`0x052d20B0e0b141988bD32772C735085e45F357c1`](https://etherscan.io/address/0x052d20B0e0b141988bD32772C735085e45F357c1) | Ethereum |
| Tokenized Strategy | [`0xb27064A2C51b8C5b39A5Bb911AD34DB039C3aB9c`](https://etherscan.io/address/0xb27064A2C51b8C5b39A5Bb911AD34DB039C3aB9c) | Ethereum |
| Yearn Strategy USDC | [`0x074134A2784F4F66b6ceD6f68849382990Ff3215`](https://etherscan.io/address/0x074134A2784F4F66b6ceD6f68849382990Ff3215) | Ethereum |

---

## Part 1: Dragon Vault

The Multistrategy Vault manages treasury capital with instant liquidity (no lockup or rage quit required).

### Underlying Strategy

[**Yearn Strategy USDC**](https://etherscan.io/address/0x074134A2784F4F66b6ceD6f68849382990Ff3215) — Deposits into Morpho lending markets via Yearn's aggregator vault.

The `MorphoCompounderStrategyFactory` at `0x052d20B...` deploys strategies that target the Yearn Strategy USDC vault, which optimizes across Morpho lending markets.


### Role Assignments

| Role | Assigned To | Description |
|------|-------------|-------------|
| **Operator** | Shutter DAO Treasury (`0x36bD...32c4`) | Only entity that can deposit/mint shares into the vault |
| **Management** | Shutter DAO Treasury (`0x36bD...32c4`) | Administrative role (add strategies, set keeper, set emergency admin) |
| **Keeper** | Dedicated Bot/EOA | **REQUIRED**: Authorized to call `report()`/`tend()` to harvest yields without governance votes |
| **Emergency Admin** | Shutter DAO Treasury (`0x36bD...32c4`) | Can shutdown the vault and perform emergency withdrawals |

> **Critical**: The Keeper MUST be a dedicated EOA or bot, NOT the Treasury Safe. Assigning Keeper to Treasury would require a governance vote (72-hour voting + 72-hour execution = 144 hours minimum) for every harvest, creating severe operational bottlenecks that defeat the purpose of automated yield generation.

### Yield Distribution

| Destination | Allocation |
|-------------|------------|
| Dragon Funding Pool | 100% |

### Yield Projections (assuming 5% APY)

| Metric | Annual |
|--------|--------|
| Gross Yield | 60,000 USDC |
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
| Azorius Module | [`0xAA6BfA174d2f803b517026E93DBBEc1eBa26258e`](https://etherscan.io/address/0xAA6BfA174d2f803b517026E93DBBEc1eBa26258e) |
| Voting Token | SHU ([`0xe485E2f1bab389C08721B291f6b59780feC83Fd7`](https://etherscan.io/token/0xe485E2f1bab389C08721B291f6b59780feC83Fd7)) |

### Execution Call Chain

When a proposal passes and is executed, the call flow is:

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Step 1: Any EOA calls Azorius to execute passed proposal                │
│          executeProposal(proposalId)                                     │
│                           │                                              │
│                           ▼                                              │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  Azorius Module (0xAA6BfA174d2f803b517026E93DBBEc1eBa26258e)       │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                           │                                              │
│  Step 2: Azorius calls Safe via module interface                         │
│          execTransactionFromModule(to, value, data, operation)           │
│                           │                                              │
│                           ▼                                              │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  DAO Safe / Treasury (0x36bD3044ab68f600f6d3e081056F34f2a58432c4)  │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                           │                                              │
│  Step 3: Safe executes transaction to target contract                    │
│          msg.sender = Safe (0x36bD...)                                   │
│                           │                                              │
│                           ▼                                              │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  Target Contract (Factory / USDC / Strategy)                       │  │
│  └────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────┘
```

> **Critical**: From the target contract's perspective, `msg.sender` is the **Safe address** (`0x36bD...`), NOT the Azorius module. This is why all roles (`management`, `keeper`, `emergencyAdmin`) are assigned to the Treasury Safe address.

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
| Target Contract | `0x052d20B0e0b141988bD32772C735085e45F357c1` (Morpho Strategy Factory) |
| Function | `createStrategy(string,address,address,address,address,bool,address)` |
| `_name` | `SHUGrantPool` |
| `_management` | `0x36bD3044ab68f600f6d3e081056F34f2a58432c4` |
| `_keeper` | `[KEEPER_BOT_ADDRESS]` |
| `_emergencyAdmin` | `0x36bD3044ab68f600f6d3e081056F34f2a58432c4` |
| `_donationAddress` | `[PAYMENT_SPLITTER_ADDRESS]` *(See note below)* |
| `_enableBurning` | `false` |
| `_tokenizedStrategyAddress` | `0xb27064a2c51b8c5b39a5bb911ad34db039c3ab9c` |

> **Note**: The `_donationAddress` should point to a PaymentSplitter configured for 100% distribution to the Dragon Funding Pool. If deploying in a single proposal, this address must be pre-calculated using CREATE2. Alternatively, the Dragon Funding Pool address can be used directly to simplify the deployment.

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

**Strategic Roles (Governance-Controlled):**
1. `ADD_STRATEGY_MANAGER` (0) → `0x36bD...32c4` (Treasury)
2. `MAX_DEBT_MANAGER` (7) → `0x36bD...32c4` (Treasury)
3. `QUEUE_MANAGER` (4) → `0x36bD...32c4` (Treasury)
4. `DEPOSIT_LIMIT_MANAGER` (8) → `0x36bD...32c4` (Treasury)
5. `WITHDRAW_LIMIT_MANAGER` (9) → `0x36bD...32c4` (Treasury)
6. `DEBT_MANAGER` (6) → `0x36bD...32c4` (Treasury) — *Required for `setAutoAllocate()`*

**Operational Role (Autonomous):**
7. `DEBT_MANAGER` (6) → `[KEEPER_BOT_ADDRESS]` (Dedicated EOA/Bot)

> **Note**: DEBT_MANAGER is assigned to **both** Treasury and Keeper. Treasury needs it to call `setAutoAllocate()`, while Keeper needs it for autonomous `updateDebt()` operations without governance votes.

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

> **Note**: Setting `autoAllocate` to `true` ensures that deposits are immediately deployed to the strategy (Yearn Strategy USDC → Morpho) to start earning yield without requiring manual Keeper intervention.

**1.12 — Add Transaction: Set Deposit Limit**

| Field | Value |
|-------|-------|
| Target Contract | `[DRAGON_VAULT_ADDRESS]` |
| Function | `setDepositLimit(uint256 depositLimit, bool depositLimitActive)` |
| `depositLimit` | `type(uint256).max` |
| `depositLimitActive` | `true` |

**1.13 — Add Transaction: Approve USDC**

| Field | Value |
|-------|-------|
| Target Contract | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` (USDC) |
| Function | `approve(address spender, uint256 amount)` |
| `spender` | `[DRAGON_VAULT_ADDRESS]` |
| `amount` | `1200000000000` |

**1.14 — Add Transaction: Deposit USDC**

| Field | Value |
|-------|-------|
| Target Contract | `[DRAGON_VAULT_ADDRESS]` |
| Function | `deposit(uint256 assets, address receiver)` |
| `assets` | `1200000000000` |
| `receiver` | `0x36bD3044ab68f600f6d3e081056F34f2a58432c4` |

**1.15 — Submit Proposal**

Review all details and click "Submit Proposal". Sign the transaction with your wallet.

> ✅ **Gas Verified**: The batched proposal uses ~2.5M gas for the DAO proposal portion (via realistic Azorius module execution), or ~8.7M total gas if everything (including factories) is deployed in one go. Both are well under the 16.7M per-transaction gas limit (EIP-7825). See `ShutterDAOGasProfilingTest` for details.

### Gas Profile Breakdown

| Component | Gas Cost |
|-----------|----------|
| **DAO Proposal (via Azorius)** | **~2,525,882** |
| **Total (incl. factories)** | **~8,689,070** |
| **EIP-7825 Limit** | 16,777,216 |
| **Headroom** | ~85% |

*Note: Gas measured using realistic Azorius → Safe → Target execution path. The module execution overhead (~32k gas) is included in these estimates.*

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

1. **Deploy Morpho Strategy**: Create yield strategy with 100% yield to Dragon Funding Pool
2. **Deploy Dragon Vault**: Create vault with Treasury as role manager
3-9. **Assign Roles**: Add 7 operational roles (6 to Treasury, 1 to Keeper)
10. **Add Strategy**: Register strategy with vault
11. **Set Max Debt**: Allow full allocation to strategy
12. **Set Default Queue**: Configure withdrawal order
13. **Set AutoAllocate**: Enable automatic deployment of deposits to strategy
14. **Set Deposit Limit**: Enable deposits
15. **Approve USDC**: Allow Dragon Vault to spend 1.2M USDC
16. **Deposit USDC**: Deposit 1.2M USDC, receiving shares to Treasury

## Yield Distribution

- 100% → Dragon Funding Pool (Shutter ecosystem grants)

## Risk Considerations

- Strategy: Yearn Strategy USDC (deposits into Morpho lending markets)
- Custody: Treasury retains full share ownership
- Liquidity: Instant withdrawals (no lockup period)

## Links

- [Yearn Strategy USDC](https://etherscan.io/address/0x074134A2784F4F66b6ceD6f68849382990Ff3215)
```

### Prepared Calldata

Complete transaction calldata for all operations, organized by phase.

> **Placeholders**: Replace `[STRATEGY_ADDRESS]`, `[VAULT_ADDRESS]`, `[KEEPER_ADDRESS]`, and `[DONATION_ADDRESS]` with actual deployed addresses.

---

### Section A: Infrastructure Deployment

**TX 1 — Deploy Strategy**

```
Target:   0x052d20B0e0b141988bD32772C735085e45F357c1 (Morpho Strategy Factory)
Function: createStrategy(string,address,address,address,address,bool,address)
Selector: 0x31d89943
Value:    0

Parameters:
  _name:                     "SHUGrantPool"
  _management:               0x36bD3044ab68f600f6d3e081056F34f2a58432c4
  _keeper:                   0x36bD3044ab68f600f6d3e081056F34f2a58432c4 (or dedicated bot)
  _emergencyAdmin:           0x36bD3044ab68f600f6d3e081056F34f2a58432c4
  _donationAddress:          [DONATION_ADDRESS]
  _enableBurning:            false
  _tokenizedStrategyAddress: 0xb27064a2c51b8c5b39a5bb911ad34db039c3ab9c

Calldata (Treasury as all roles, placeholder donation address):
0x31d8994300000000000000000000000000000000000000000000000000000000000000e000000000000000000000000036bd3044ab68f600f6d3e081056f34f2a58432c400000000000000000000000036bd3044ab68f600f6d3e081056f34f2a58432c400000000000000000000000036bd3044ab68f600f6d3e081056f34f2a58432c400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b27064a2c51b8c5b39a5bb911ad34db039c3ab9c000000000000000000000000000000000000000000000000000000000000000c5348554772616e74506f6f6c0000000000000000000000000000000000000000
```

**TX 2 — Deploy Dragon Vault**

```
Target:   [VAULT_FACTORY_ADDRESS] (TBD by Octant)
Function: deployNewVault(address,string,string,address,uint256)
Selector: 0xdf0b04ac
Value:    0

Parameters:
  asset:               0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 (USDC)
  name:                "Shutter Dragon Vault"
  symbol:              "sdUSDC"
  roleManager:         0x36bD3044ab68f600f6d3e081056F34f2a58432c4 (Treasury)
  profitMaxUnlockTime: 604800 (7 days)

Calldata:
0xdf0b04ac
000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48
00000000000000000000000000000000000000000000000000000000000000a0
00000000000000000000000000000000000000000000000000000000000000e0
00000000000000000000000036bd3044ab68f600f6d3e081056f34f2a58432c4
0000000000000000000000000000000000000000000000000000000000093a80
0000000000000000000000000000000000000000000000000000000000000014
5368757474657220447261676f6e205661756c74000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000006
7364555344430000000000000000000000000000000000000000000000000000
```

---

### Section B: Role Assignments

All role assignments target the Dragon Vault.

**TX 3 — Add Role: ADD_STRATEGY_MANAGER → Treasury**

```
Target:   [VAULT_ADDRESS]
Function: addRole(address,uint8)
Selector: 0x44deb6f3
Value:    0

Parameters:
  account: 0x36bD3044ab68f600f6d3e081056F34f2a58432c4
  role:    0 (ADD_STRATEGY_MANAGER)

Calldata:
0x44deb6f300000000000000000000000036bd3044ab68f600f6d3e081056f34f2a58432c40000000000000000000000000000000000000000000000000000000000000000
```

**TX 4 — Add Role: QUEUE_MANAGER → Treasury**

```
Target:   [VAULT_ADDRESS]
Function: addRole(address,uint8)
Selector: 0x44deb6f3
Value:    0

Parameters:
  account: 0x36bD3044ab68f600f6d3e081056F34f2a58432c4
  role:    4 (QUEUE_MANAGER)

Calldata:
0x44deb6f300000000000000000000000036bd3044ab68f600f6d3e081056f34f2a58432c40000000000000000000000000000000000000000000000000000000000000004
```

**TX 5 — Add Role: DEBT_MANAGER → Treasury**

```
Target:   [VAULT_ADDRESS]
Function: addRole(address,uint8)
Selector: 0x44deb6f3
Value:    0

Parameters:
  account: 0x36bD3044ab68f600f6d3e081056F34f2a58432c4
  role:    6 (DEBT_MANAGER)

Calldata:
0x44deb6f300000000000000000000000036bd3044ab68f600f6d3e081056f34f2a58432c40000000000000000000000000000000000000000000000000000000000000006
```

**TX 6 — Add Role: MAX_DEBT_MANAGER → Treasury**

```
Target:   [VAULT_ADDRESS]
Function: addRole(address,uint8)
Selector: 0x44deb6f3
Value:    0

Parameters:
  account: 0x36bD3044ab68f600f6d3e081056F34f2a58432c4
  role:    7 (MAX_DEBT_MANAGER)

Calldata:
0x44deb6f300000000000000000000000036bd3044ab68f600f6d3e081056f34f2a58432c40000000000000000000000000000000000000000000000000000000000000007
```

**TX 7 — Add Role: DEPOSIT_LIMIT_MANAGER → Treasury**

```
Target:   [VAULT_ADDRESS]
Function: addRole(address,uint8)
Selector: 0x44deb6f3
Value:    0

Parameters:
  account: 0x36bD3044ab68f600f6d3e081056F34f2a58432c4
  role:    8 (DEPOSIT_LIMIT_MANAGER)

Calldata:
0x44deb6f300000000000000000000000036bd3044ab68f600f6d3e081056f34f2a58432c40000000000000000000000000000000000000000000000000000000000000008
```

**TX 8 — Add Role: WITHDRAW_LIMIT_MANAGER → Treasury**

```
Target:   [VAULT_ADDRESS]
Function: addRole(address,uint8)
Selector: 0x44deb6f3
Value:    0

Parameters:
  account: 0x36bD3044ab68f600f6d3e081056F34f2a58432c4
  role:    9 (WITHDRAW_LIMIT_MANAGER)

Calldata:
0x44deb6f300000000000000000000000036bd3044ab68f600f6d3e081056f34f2a58432c40000000000000000000000000000000000000000000000000000000000000009
```

**TX 9 — Add Role: DEBT_MANAGER → Keeper**

```
Target:   [VAULT_ADDRESS]
Function: addRole(address,uint8)
Selector: 0x44deb6f3
Value:    0

Parameters:
  account: [KEEPER_BOT_ADDRESS]
  role:    6 (DEBT_MANAGER)

Calldata (replace keeper address):
0x44deb6f3000000000000000000000000[KEEPER_ADDRESS_20_BYTES]0000000000000000000000000000000000000000000000000000000000000006
```

---

### Section C: Strategy Configuration

**TX 10 — Add Strategy to Vault**

```
Target:   [VAULT_ADDRESS]
Function: addStrategy(address,bool)
Selector: 0x6e547742
Value:    0

Parameters:
  newStrategy: [STRATEGY_ADDRESS]
  addToQueue:  true

Calldata (replace strategy address):
0x6e547742
000000000000000000000000[STRATEGY_ADDRESS_20_BYTES]
0000000000000000000000000000000000000000000000000000000000000001
```

**TX 11 — Set Max Debt for Strategy**

```
Target:   [VAULT_ADDRESS]
Function: updateMaxDebtForStrategy(address,uint256)
Selector: 0xf6d7bfa0
Value:    0

Parameters:
  strategy:   [STRATEGY_ADDRESS]
  newMaxDebt: type(uint256).max

Calldata (replace strategy address):
0xf6d7bfa0
000000000000000000000000[STRATEGY_ADDRESS_20_BYTES]
ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
```

**TX 12 — Set Default Queue**

```
Target:   [VAULT_ADDRESS]
Function: setDefaultQueue(address[])
Selector: 0x633f228c
Value:    0

Parameters:
  newDefaultQueue: [[STRATEGY_ADDRESS]]

Calldata (replace strategy address):
0x633f228c
0000000000000000000000000000000000000000000000000000000000000020
0000000000000000000000000000000000000000000000000000000000000001
000000000000000000000000[STRATEGY_ADDRESS_20_BYTES]
```

**TX 13 — Enable AutoAllocate**

```
Target:   [VAULT_ADDRESS]
Function: setAutoAllocate(bool)
Selector: 0x63d56c9a
Value:    0

Parameters:
  autoAllocate: true

Calldata:
0x63d56c9a0000000000000000000000000000000000000000000000000000000000000001
```

**TX 14 — Set Deposit Limit**

```
Target:   [VAULT_ADDRESS]
Function: setDepositLimit(uint256,bool)
Selector: 0xaeb273cf
Value:    0

Parameters:
  depositLimit:   type(uint256).max
  shouldOverride: true

Calldata:
0xaeb273cfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff0000000000000000000000000000000000000000000000000000000000000001
```

---

### Section D: Capital Deployment

**TX 15 — Approve USDC for Vault**

```
Target:   0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 (USDC)
Function: approve(address,uint256)
Selector: 0x095ea7b3
Value:    0

Parameters:
  spender: [VAULT_ADDRESS]
  amount:  1200000000000 (1.2M USDC, 6 decimals)

Calldata (replace vault address):
0x095ea7b3
000000000000000000000000[VAULT_ADDRESS_20_BYTES]
000000000000000000000000000000000000000000000000000001176592e000
```

**TX 16 — Deposit USDC into Vault**

```
Target:   [VAULT_ADDRESS]
Function: deposit(uint256,address)
Selector: 0x6e553f65
Value:    0

Parameters:
  assets:   1200000000000 (1.2M USDC)
  receiver: 0x36bD3044ab68f600f6d3e081056F34f2a58432c4 (Treasury)

Calldata (replace vault address in target):
0x6e553f65000000000000000000000000000000000000000000000000000001176592e00000000000000000000000000036bd3044ab68f600f6d3e081056f34f2a58432c4
```

---

### Section E: Operations (Post-Deployment)

#### Harvest Operation

**Report (Harvest Yield)**

```
Target:   [STRATEGY_ADDRESS]
Function: report()
Selector: 0x2606a10b
Value:    0

Parameters: (none)

Calldata:
0x2606a10b

Note: Called by management or keeper to harvest yield. Returns (uint256 profit, uint256 loss).
```

---

### Section F: Emergency Operations

**Shutdown Strategy**

```
Target:   [STRATEGY_ADDRESS]
Function: shutdownStrategy()
Selector: 0xbe8f1668
Value:    0

Parameters: (none)

Calldata:
0xbe8f1668

Effect: Stops new deposits/mints, allows withdrawals, still allows tend/report.
Access:  management or emergencyAdmin
```

**Emergency Withdraw**

```
Target:   [STRATEGY_ADDRESS]
Function: emergencyWithdraw(uint256)
Selector: 0x5312ea8e
Value:    0

Parameters:
  _amount: 1200000000000 (1.2M USDC - full withdrawal)

Calldata:
0x5312ea8e000000000000000000000000000000000000000000000000000001176592e000

Prerequisite: Strategy must be shutdown first.
Access:       management or emergencyAdmin
```

---

### Quick Reference: Function Selectors

| Function | Selector | Target | Section |
|----------|----------|--------|---------|
| `createStrategy(...)` | `0x31d89943` | Morpho Factory | A |
| `deployNewVault(...)` | `0xdf0b04ac` | Vault Factory | A |
| `addRole(address,uint8)` | `0x44deb6f3` | Vault | B |
| `addStrategy(address,bool)` | `0x6e547742` | Vault | C |
| `updateMaxDebtForStrategy(...)` | `0xf6d7bfa0` | Vault | C |
| `setDefaultQueue(address[])` | `0x633f228c` | Vault | C |
| `setAutoAllocate(bool)` | `0x63d56c9a` | Vault | C |
| `setDepositLimit(uint256,bool)` | `0xaeb273cf` | Vault | C |
| `approve(address,uint256)` | `0x095ea7b3` | USDC | D |
| `deposit(uint256,address)` | `0x6e553f65` | Vault | D |
| `report()` | `0x2606a10b` | Strategy | E |
| `shutdownStrategy()` | `0xbe8f1668` | Strategy | F |
| `emergencyWithdraw(uint256)` | `0x5312ea8e` | Strategy | F |

### Role Reference

| Role | Value | Description |
|------|-------|-------------|
| `ADD_STRATEGY_MANAGER` | 0 | Can add strategies to the vault |
| `QUEUE_MANAGER` | 4 | Can modify withdrawal queue order |
| `DEBT_MANAGER` | 6 | Can update debt allocation to strategies |
| `MAX_DEBT_MANAGER` | 7 | Can set max debt limits per strategy |
| `DEPOSIT_LIMIT_MANAGER` | 8 | Can set deposit limits |
| `WITHDRAW_LIMIT_MANAGER` | 9 | Can set withdraw limits |

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

> ⚠️ **MANDATORY REQUIREMENT**: A dedicated EOA or bot MUST be used for the Keeper role.

**Critical**: Assigning the Treasury Safe as Keeper creates a severe operational bottleneck:
- Every harvest requires a governance vote (72-hour voting + 72-hour execution = 144 hours minimum)
- This introduces ~4-12 proposals per year just for routine harvesting
- Delays yield compounding and defeats the purpose of automated yield generation

A dedicated Keeper address enables:
- Autonomous, gas-efficient harvesting
- No governance bottleneck for routine operations
- Optimal yield compounding
- Faster response to market conditions

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
- [Yearn Strategy USDC (Etherscan)](https://etherscan.io/address/0x074134A2784F4F66b6ceD6f68849382990Ff3215)
- [Shutter DAO Governance (Fractal/Decent)](https://app.decentdao.org/home?dao=eth%3A0x36bD3044ab68f600f6d3e081056F34f2a58432c4)
- [Shutter DAO Treasury (Etherscan)](https://etherscan.io/address/0x36bD3044ab68f600f6d3e081056F34f2a58432c4)

