# Nouns DAO × Octant v2 Integration Plan


## Overview

Nouns DAO will integrate with Octant v2 through the **Lido Yield Skimming Strategy** — an ERC-4626 vault that captures yield from wstETH exchange rate appreciation (~3-5% APY from ETH staking rewards).

| Component | Purpose | Capital |
|-----------|---------|---------|
| Lido Yield Skimming Strategy | Generate yield for public goods funding | wstETH held by treasury |

> **Architecture Note**: The strategy IS the ERC-4626 vault. No MultistrategyVault wrapper is needed since only one strategy is proposed. This simplifies deployment, reduces gas costs, and eliminates unnecessary complexity.

---

## Prerequisites (Pending Items)

The following items must be resolved before executing the DAO proposal:

| Item | Status | Owner | Notes |
|------|--------|-------|-------|
| Dragon Funding Pool address | ⏳ Pending | Nouns DAO | Strategy donation recipient (PaymentSplitter) |
| Keeper Bot address | ⏳ Pending | Nouns DAO | Strategy keeper for harvesting |
| Emergency Shutdown Admin address | ⏳ Pending | Nouns DAO | Can shutdown strategy and perform emergency withdrawals |
| wstETH deposit amount | ⏳ Pending | Nouns DAO | Amount of wstETH to deposit (treasury holds ~1,725 wstETH) |

> ⚠️ **Action Required**: Update this document with actual addresses before submitting the proposal.

---

## Verified On-Chain Addresses

| Entity | Address | Network |
|--------|---------|---------|
| Nouns DAO Treasury (Executor/Timelock) | [`0xb1a32FC9F9D8b2cf86C068Cae13108809547ef71`](https://etherscan.io/address/0xb1a32FC9F9D8b2cf86C068Cae13108809547ef71) | Ethereum |
| Nouns DAO Governor Proxy | [`0x6f3E6272A167e8AcCb32072d08E0957F9c79223d`](https://etherscan.io/address/0x6f3E6272A167e8AcCb32072d08E0957F9c79223d) | Ethereum |
| Nouns NFT Token | [`0x9C8fF314C9Bc7F6e59A9d9225Fb22946427eDC03`](https://etherscan.io/token/0x9C8fF314C9Bc7F6e59A9d9225Fb22946427eDC03) | Ethereum |
| wstETH | [`0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0`](https://etherscan.io/token/0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0) | Ethereum |
| PaymentSplitter Factory | [`0x5711765E0756B45224fc1FdA1B41ab344682bBcb`](https://etherscan.io/address/0x5711765E0756B45224fc1FdA1B41ab344682bBcb) | Ethereum |
| Tokenized Strategy Implementation | [`0x8cf7246a74704bBE59c9dF614ccB5e3d9717d8Ac`](https://etherscan.io/address/0x8cf7246a74704bBE59c9dF614ccB5e3d9717d8Ac) | Ethereum |

---

## Part 1: Lido Yield Skimming Strategy

The LidoStrategy is an ERC-4626 vault (via Yearn's TokenizedStrategy) that tracks wstETH → stETH exchange rate appreciation. Treasury deposits wstETH directly into the strategy.

### Underlying Yield Source

**[wstETH (Wrapped Staked ETH)](https://etherscan.io/token/0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0)** — Lido's non-rebasing wrapper around stETH.

- **Mechanism**: Exchange rate increases as staking rewards accrue to stETH
- **Rate Source**: `wstETH.stEthPerToken()` (manipulation-resistant, oracle-free)
- **Yield**: ~3-5% APY from ETH validator staking rewards
- **Risk**: ETH validator slashing can reduce exchange rate

### Yield Capture Mechanism

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  1. User deposits 100 wstETH at rate 1.0 (100 stETH value)                   │
│                           │                                                  │
│                           ▼                                                  │
│  2. Exchange rate increases to 1.05 (ETH staking rewards)                    │
│     - Vault value: 100 wstETH × 1.05 = 105 stETH value                       │
│     - User debt: 100 stETH value                                             │
│     - Profit: 5 stETH value                                                  │
│                           │                                                  │
│                           ▼                                                  │
│  3. On report(), strategy mints 5 value-shares to Dragon Router              │
│     - User can still redeem 100 stETH value worth of wstETH                  │
│     - Dragon Router receives yield without diluting user                     │
└──────────────────────────────────────────────────────────────────────────────┘
```


### Role Assignments

| Role | Assigned To | Description |
|------|-------------|-------------|
| **Management** | Nouns DAO Treasury (`0xb1a3...ef71`) | Administrative role (set keeper, set emergency admin, shutdown) |
| **Keeper** | Dedicated Bot/EOA | **REQUIRED**: Authorized to call `report()` to harvest yields without governance votes |
| **Emergency Admin** | Nouns DAO Treasury (`0xb1a3...ef71`) | Can shutdown the strategy and perform emergency withdrawals |

> **Critical**: The Keeper should be a dedicated EOA or bot, NOT the Treasury. Assigning Keeper to Treasury would require a governance vote for every harvest (7+ day minimum voting cycle), creating severe operational bottlenecks that defeat the purpose of automated yield generation.

### Yield Distribution

| Destination | Allocation |
|-------------|------------|
| Dragon Funding Pool | 100% |

---

## Part 2: PaymentSplitter (Dragon Funding Pool)

The PaymentSplitter is deployed via the existing factory and receives yield from the strategy.

### Recommended Configuration

| Payee | Allocation | Purpose |
|-------|------------|---------|
| Nouns Ecosystem Grants | 100% | Public goods funding |

> **Note**: Multiple payees with different allocations can be configured if desired (e.g., 80% grants, 20% operations).

---

## Nouns DAO Governance

### Architecture

Nouns DAO uses a **Governor + Timelock** pattern with NFT-based voting:

| Component | Address / Value |
|-----------|-----------------|
| Governor Proxy | [`0x6f3E6272A167e8AcCb32072d08E0957F9c79223d`](https://etherscan.io/address/0x6f3E6272A167e8AcCb32072d08E0957F9c79223d) |
| Executor (Timelock) | [`0xb1a32FC9F9D8b2cf86C068Cae13108809547ef71`](https://etherscan.io/address/0xb1a32FC9F9D8b2cf86C068Cae13108809547ef71) |
| Voting Token | Nouns NFT ([`0x9C8fF314C9Bc7F6e59A9d9225Fb22946427eDC03`](https://etherscan.io/token/0x9C8fF314C9Bc7F6e59A9d9225Fb22946427eDC03)) |

### Execution Call Chain

When a proposal passes and is executed, the call flow is:

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  Step 1: Any EOA calls Governor to execute passed proposal                   │
│          execute(targets[], values[], calldatas[], descriptionHash)          │
│                           │                                                  │
│                           ▼                                                  │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │  Nouns DAO Governor (0x6f3E6272A167e8AcCb32072d08E0957F9c79223d)       │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                           │                                                  │
│  Step 2: Governor triggers queued transaction on Timelock                    │
│          execute(target, value, data, predecessor, salt)                     │
│                           │                                                  │
│                           ▼                                                  │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │  Executor / Timelock (0xb1a32FC9F9D8b2cf86C068Cae13108809547ef71)      │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                           │                                                  │
│  Step 3: Timelock executes transaction to target contract                    │
│          msg.sender = Timelock (0xb1a3...)                                   │
│                           │                                                  │
│                           ▼                                                  │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │  Target Contract (Factory / wstETH / Strategy)                         │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────┘
```

> **Critical**: From the target contract's perspective, `msg.sender` is the **Executor/Timelock address** (`0xb1a3...`), NOT the Governor. This is why all roles (`management`, `keeper`, `emergencyAdmin`) are assigned to the Executor address.

### Governance Parameters

| Parameter | Value | Notes |
|-----------|-------|-------|
| Voting Power | 1 Noun = 1 Vote | NFT-based governance |
| Proposal Threshold | ~3 Nouns | Must own or be delegated sufficient voting power |
| Voting Delay | ~2 days | Pending period before voting opens |
| Voting Period | ~3 days | Active voting window |
| Quorum | Dynamic (5-20%) | Increases with opposition votes |
| Timelock Delay | ~2 days | Queuing period before execution |

> **Note**: Parameters are set dynamically and may change. Check [nouns.wtf/vote](https://nouns.wtf/vote) for current values.

### Voting Platforms

| Platform | Type | Use Case |
|----------|------|----------|
| [nouns.wtf/vote](https://nouns.wtf/vote) | On-chain | Treasury transactions, contract interactions |
| [Discourse](https://discourse.nouns.wtf/) | Forum | Discussion, temperature checks |

---

## Execution Playbook

### Phase 1: PaymentSplitter Deployment

Deploy a PaymentSplitter to receive yield from the strategy.

#### Transaction 1: Deploy PaymentSplitter

| Field | Value |
|-------|-------|
| Target Contract | `0x5711765E0756B45224fc1FdA1B41ab344682bBcb` (PaymentSplitter Factory) |
| Function | `createPaymentSplitter(address[],string[],uint256[])` |
| `payees` | `[[DRAGON_FUNDING_POOL_ADDRESS]]` |
| `payeeNames` | `["DragonFundingPool"]` |
| `shares` | `[100]` |

### Phase 2: Strategy Deployment

The deployment can be executed in a **single DAO proposal** with **4 batched transactions**:
1. Deploy PaymentSplitter via Factory
2. Deploy LidoStrategy via Factory
3. Approve wstETH to Strategy
4. Deposit wstETH into Strategy

> **Note**: LidoStrategyFactory needs to be deployed to mainnet first. The strategy factory uses CREATE2, allowing address precomputation.

#### Step 1: Create Proposal

**1.1 — Navigate to Nouns DAO**

Open [nouns.wtf/vote](https://nouns.wtf/vote)

**1.2 — Connect Wallet**

Connect a wallet with sufficient voting power (own or delegated Nouns).

**1.3 — Click "Submit Proposal"**

Navigate to the proposals section and initiate a new proposal.

**1.4 — Fill Proposal Details**

| Field | Value |
|-------|-------|
| Title | `Deploy Octant Lido Yield Strategy for wstETH` |
| Description | See [Proposal Template](#proposal-template) below |

**1.5 — Add Transaction 1: Deploy PaymentSplitter**

| Field | Value |
|-------|-------|
| Target Contract | `0x5711765E0756B45224fc1FdA1B41ab344682bBcb` (PaymentSplitter Factory) |
| Function | `createPaymentSplitter(address[],string[],uint256[])` |
| `payees` | `[[GRANT_RECIPIENT_ADDRESS]]` |
| `payeeNames` | `["NounsGrants"]` |
| `shares` | `[100]` |

**1.6 — Add Transaction 2: Deploy Strategy**

| Field | Value |
|-------|-------|
| Target Contract | `[LIDO_STRATEGY_FACTORY_ADDRESS]` |
| Function | `createStrategy(string,address,address,address,address,bool,address)` |
| `_name` | `NounsLidoStrategy` |
| `_management` | `0xb1a32FC9F9D8b2cf86C068Cae13108809547ef71` |
| `_keeper` | `[KEEPER_BOT_ADDRESS]` |
| `_emergencyAdmin` | `[EMERGENCY_ADMIN_ADDRESS]` |
| `_donationAddress` | `[PAYMENT_SPLITTER_ADDRESS]` (from Tx 1) |
| `_enableBurning` | `false` |
| `_tokenizedStrategyAddress` | `0x8cf7246a74704bBE59c9dF614ccB5e3d9717d8Ac` |

**1.7 — Add Transaction 3: Approve wstETH**

| Field | Value |
|-------|-------|
| Target Contract | `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0` (wstETH) |
| Function | `approve(address spender, uint256 amount)` |
| `spender` | `[STRATEGY_ADDRESS]` *(from Tx 2)* |
| `amount` | `[DEPOSIT_AMOUNT]` (e.g., 1000e18 for 1000 wstETH) |

**1.8 — Add Transaction 4: Deposit wstETH**

| Field | Value |
|-------|-------|
| Target Contract | `[STRATEGY_ADDRESS]` *(from Tx 2)* |
| Function | `deposit(uint256 assets, address receiver)` |
| `assets` | `[DEPOSIT_AMOUNT]` (e.g., 1000e18 for 1000 wstETH) |
| `receiver` | `0xb1a32FC9F9D8b2cf86C068Cae13108809547ef71` |

**1.9 — Submit Proposal**

Review all details and submit the proposal.

### Gas Profile

| Component | Gas Cost |
|-----------|----------|
| PaymentSplitter Deployment | ~50k |
| LidoStrategy Deployment | ~3-4M |
| wstETH Approve | ~50k |
| wstETH Deposit | ~200k |
| **Total (batched)** | **~4M** |
| **Block Gas Limit** | 30M |
| **Headroom** | >85% |

#### Step 2: Vote

1. Share the proposal link on [Discourse](https://discourse.nouns.wtf/) for discussion
2. Noun holders vote during the voting period (~3 days)
3. Proposal passes if quorum is met and majority votes "For"

#### Step 3: Queue

Once voting passes, the proposal enters the timelock queue (~2 days).

#### Step 4: Execute

After the timelock delay:

1. Return to the proposal page on nouns.wtf
2. Click "Execute" (available after timelock)
3. Sign the execution transaction
4. Verify on Etherscan that all transactions succeeded

#### Step 5: Verify Deployment

After execution, verify:

- [ ] PaymentSplitter deployed with correct payees
- [ ] Strategy deployed with correct donation address (PaymentSplitter)
- [ ] Treasury received strategy shares
- [ ] wstETH deposited into strategy

### Proposal Template

```markdown
## Summary

This proposal deploys the Octant Lido Yield Skimming Strategy and deposits
[AMOUNT] wstETH from Nouns DAO treasury as part of the Octant v2 pilot.

## Background

Octant v2 enables DAOs to optimize treasury yield while funding public goods.
The Lido strategy captures yield from wstETH exchange rate appreciation
(~3-5% annually from ETH staking rewards) and routes it to designated recipients.

## Transactions (4 total)

1. **Deploy PaymentSplitter**: Create yield distribution splitter for grants
2. **Deploy Strategy**: Create ERC-4626 yield-skimming strategy
3. **Approve wstETH**: Allow Strategy to spend treasury wstETH
4. **Deposit wstETH**: Deposit wstETH, receiving shares to Treasury

## Architecture

The LidoStrategy IS the ERC-4626 vault (via Yearn's TokenizedStrategy).
No additional vault wrapper is needed since only one strategy is approved.

## Yield Distribution

- 100% → Dragon Funding Pool → Nouns Ecosystem Grants

## Risk Considerations

- Underlying: wstETH (Lido wrapped staked ETH)
- Exchange Rate Risk: ETH validator slashing could reduce rate (rare)
- Custody: Treasury retains full share ownership
- Liquidity: Instant withdrawals (no lockup period)

## Links

- [wstETH Token](https://etherscan.io/token/0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0)
- [Nouns Treasury](https://etherscan.io/address/0xb1a32FC9F9D8b2cf86C068Cae13108809547ef71)
- [PaymentSplitter Factory](https://etherscan.io/address/0x5711765E0756B45224fc1FdA1B41ab344682bBcb)
```

---

## Prepared Calldata

Complete transaction calldata can be generated programmatically using the provided script:

```bash
forge script partners/nouns_dao/script/GenerateProposalCalldata.s.sol --fork-url $ETH_RPC_URL -vvvv
```

Before running, update the configuration in the script:
- `DRAGON_FUNDING_POOL` — Actual grant recipient address
- `KEEPER_BOT` — Dedicated keeper EOA/bot address
- `EMERGENCY_ADMIN` — Emergency shutdown admin address
- `DEPOSIT_AMOUNT` — Amount of wstETH to deposit

The script outputs:
- Precomputed CREATE2 address for Strategy
- Individual calldata for each transaction (TX 0-3)
- Formatted parameters for nouns.wtf proposal UI

---

### Transaction 1: Deploy PaymentSplitter

```
Target:   0x5711765E0756B45224fc1FdA1B41ab344682bBcb (PaymentSplitter Factory)
Function: createPaymentSplitter(address[],string[],uint256[])
Selector: 0x... (TBD)
Value:    0

Parameters:
  payees:     [[GRANT_RECIPIENT_ADDRESS]]
  payeeNames: ["NounsGrants"]
  shares:     [100]
```

### Transaction 2: Deploy Strategy

```
Target:   [LIDO_STRATEGY_FACTORY_ADDRESS]
Function: createStrategy(string,address,address,address,address,bool,address)
Selector: 0x... (TBD)
Value:    0

Parameters:
  _name:                     "NounsLidoStrategy"
  _management:               0xb1a32FC9F9D8b2cf86C068Cae13108809547ef71
  _keeper:                   [KEEPER_ADDRESS] (dedicated bot)
  _emergencyAdmin:           [EMERGENCY_ADMIN_ADDRESS]
  _donationAddress:          [PAYMENT_SPLITTER_ADDRESS]
  _enableBurning:            false
  _tokenizedStrategyAddress: 0x8cf7246a74704bBE59c9dF614ccB5e3d9717d8Ac
```

### Transaction 3: Approve wstETH

```
Target:   0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 (wstETH)
Function: approve(address,uint256)
Selector: 0x095ea7b3
Value:    0

Parameters:
  spender: [STRATEGY_ADDRESS] (from Tx 2)
  amount:  [DEPOSIT_AMOUNT] (e.g., 1000000000000000000000 for 1000 wstETH)
```

### Transaction 4: Deposit wstETH

```
Target:   [STRATEGY_ADDRESS] (from Tx 2)
Function: deposit(uint256,address)
Selector: 0x6e553f65
Value:    0

Parameters:
  assets:   [DEPOSIT_AMOUNT] (e.g., 1000000000000000000000 for 1000 wstETH)
  receiver: 0xb1a32FC9F9D8b2cf86C068Cae13108809547ef71 (Treasury)
```

---

## Post-Deployment Operations

#### Harvest Operation

**Report (Harvest Yield)**

```
Target:   [STRATEGY_ADDRESS]
Function: report()
Selector: 0x2606a10b
Value:    0

Parameters: (none)

Note: Called by management or keeper to harvest yield. Returns (uint256 profit, uint256 loss).
Mints profit shares to Dragon Router (PaymentSplitter).
```

#### Release Yield from PaymentSplitter

**Release wstETH shares**

```
Target:   [PAYMENT_SPLITTER_ADDRESS]
Function: release(address token, address account)
Selector: 0x... (TBD)
Value:    0

Parameters:
  token:   [STRATEGY_ADDRESS] (strategy shares)
  account: [PAYEE_ADDRESS]

Note: Payee calls to claim their share of accumulated yield.
```

---

## Emergency Operations

**Shutdown Strategy**

```
Target:   [STRATEGY_ADDRESS]
Function: shutdownStrategy()
Selector: 0xbe8f1668
Value:    0

Parameters: (none)

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
  _amount: Amount to withdraw (up to full balance)

Prerequisite: Strategy must be shutdown first.
Access:       management or emergencyAdmin
```

**Standard Withdraw**

```
Target:   [STRATEGY_ADDRESS]
Function: withdraw(uint256,address,address)
Selector: 0xb460af94
Value:    0

Parameters:
  assets:   Amount of wstETH to withdraw
  receiver: Address to receive wstETH
  owner:    0xb1a32FC9F9D8b2cf86C068Cae13108809547ef71 (Treasury)

Note: Can be called anytime, no lockup period.
```

---

## Quick Reference: Function Selectors

| Function | Selector | Target | Purpose |
|----------|----------|--------|---------|
| `createPaymentSplitter(...)` | TBD | PaymentSplitter Factory | Deploy splitter |
| `createStrategy(...)` | TBD | LidoStrategy Factory | Deploy strategy |
| `approve(address,uint256)` | `0x095ea7b3` | wstETH | Allow spending |
| `deposit(uint256,address)` | `0x6e553f65` | Strategy | Deposit funds |
| `withdraw(uint256,address,address)` | `0xb460af94` | Strategy | Withdraw funds |
| `report()` | `0x2606a10b` | Strategy | Harvest yield |
| `shutdownStrategy()` | `0xbe8f1668` | Strategy | Emergency shutdown |
| `emergencyWithdraw(uint256)` | `0x5312ea8e` | Strategy | Emergency exit |

---

## Operational Considerations

### Keeper Setup

See [Role Assignments](#role-assignments) for Keeper requirements. A dedicated EOA or bot enables autonomous harvesting without governance votes.

**Recommended**: Set up a keeper bot to call `report()` periodically (e.g., weekly or monthly) to:
1. Update accounting
2. Mint yield shares to Dragon Router
3. Keep exchange rate tracking accurate

### Emergency Admin

The Treasury serves as Emergency Admin. Emergency actions (shutdown, forced withdrawals) will follow standard DAO voting timelines (~7 days) unless a separate multisig is designated for faster response.

### Withdrawals

The strategy provides instant liquidity (no lockup). Withdrawals are straightforward:
1. Call `withdraw(assets, receiver, owner)` or `redeem(shares, receiver, owner)` on the strategy
2. Receive underlying wstETH immediately

No unwinding of positions is needed — wstETH is held directly.

### Value Debt Tracking

The strategy uses a dual-debt accounting system:
- **User Debt**: Tracks ETH value owed to depositors
- **Dragon Debt**: Tracks ETH value owed to Dragon Router (yield recipient)

This ensures:
- Users can always redeem their original value
- Dragon Router only receives actual profit
- Insolvency protection: Dragon operations blocked if vault can't cover user debt

---

## Treasury Holdings (Reference)

Current Nouns DAO treasury wstETH holdings (as of snapshot):

| Asset | Amount | Value (USD) |
|-------|--------|-------------|
| wstETH | ~1,725 | ~$6.7M |
| rETH | ~163 | ~$600k |
| USDC | ~726k | ~$726k |
| ETH | ~517 | ~$1.6M |

Source: [Etherscan Treasury](https://etherscan.io/address/0xb1a32FC9F9D8b2cf86C068Cae13108809547ef71)

---

## References

- [Nouns DAO Governance](https://nouns.wtf/vote)
- [Nouns DAO Treasury (Etherscan)](https://etherscan.io/address/0xb1a32FC9F9D8b2cf86C068Cae13108809547ef71)
- [Nouns DAO Governor (Etherscan)](https://etherscan.io/address/0x6f3E6272A167e8AcCb32072d08E0957F9c79223d)
- [wstETH Token (Etherscan)](https://etherscan.io/token/0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0)
- [Lido Finance](https://lido.fi/)
- [PaymentSplitter Factory (Etherscan)](https://etherscan.io/address/0x5711765E0756B45224fc1FdA1B41ab344682bBcb)
- [Nouns Center - Proposals](https://nouns.center/funding/proposals)
