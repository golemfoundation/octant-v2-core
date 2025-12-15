# Shutter DAO 0x36 × Octant v2 Integration Plan


## Overview

Shutter DAO 0x36 will integrate with Octant v2 through the **SHUGrantPool Strategy** — an ERC-4626 yield-donating vault configured with Morpho's "Steakhouse" USDC yield strategy (rated A+ by Credora, ~4-6% APY).

| Component | Purpose | Capital |
|-----------|---------|---------|
| SHUGrantPool Strategy | Generate yield for public goods funding | 1M USDC |

> **Architecture Note**: The strategy IS the ERC-4626 vault. No MultistrategyVault wrapper is needed since only one strategy is approved by the DAO. This simplifies deployment, reduces gas costs, and eliminates unnecessary complexity.

---

## Prerequisites (Pending Items)

The following items must be resolved before executing the DAO proposal:

| Item | Status | Owner | Notes |
|------|--------|-------|-------|
| Dragon Funding Pool address | ⏳ Pending | Shutter DAO | Strategy donation recipient |
| Keeper Bot address | ⏳ Pending | Shutter DAO | Strategy keeper for harvesting |
| Emergency Shutdown Admin address | ⏳ Pending | Shutter DAO | Can shutdown strategy and perform emergency withdrawals |

> ⚠️ **Action Required**: Update this document with actual addresses before submitting the proposal.

---

## Verified On-Chain Addresses

| Entity | Address | Network |
|--------|---------|---------|
| Shutter DAO Treasury | [`0x36bD3044ab68f600f6d3e081056F34f2a58432c4`](https://etherscan.io/address/0x36bD3044ab68f600f6d3e081056F34f2a58432c4) | Ethereum |
| Azorius Module | [`0xAA6BfA174d2f803b517026E93DBBEc1eBa26258e`](https://etherscan.io/address/0xAA6BfA174d2f803b517026E93DBBEc1eBa26258e) | Ethereum |
| SHU Token | [`0xe485E2f1bab389C08721B291f6b59780feC83Fd7`](https://etherscan.io/token/0xe485E2f1bab389C08721B291f6b59780feC83Fd7) | Ethereum |
| USDC | [`0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`](https://etherscan.io/token/0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48) | Ethereum |
| Morpho Strategy Factory | [`0x052d20B0e0b141988bD32772C735085e45F357c1`](https://etherscan.io/address/0x052d20B0e0b141988bD32772C735085e45F357c1) | Ethereum |
| Tokenized Strategy | [`0xb27064A2C51b8C5b39A5Bb911AD34DB039C3aB9c`](https://etherscan.io/address/0xb27064A2C51b8C5b39A5Bb911AD34DB039C3aB9c) | Ethereum |
| Yearn Strategy USDC | [`0x074134A2784F4F66b6ceD6f68849382990Ff3215`](https://etherscan.io/address/0x074134A2784F4F66b6ceD6f68849382990Ff3215) | Ethereum |
| PaymentSplitter Factory | [`0x5711765E0756B45224fc1FdA1B41ab344682bBcb`](https://etherscan.io/address/0x5711765E0756B45224fc1FdA1B41ab344682bBcb) | Ethereum |

---

## Part 1: SHUGrantPool Strategy

The MorphoCompounderStrategy is itself an ERC-4626 vault (via Yearn's TokenizedStrategy). Treasury deposits USDC directly into the strategy.

### Underlying Yield Source

[**Yearn Strategy USDC**](https://etherscan.io/address/0x074134A2784F4F66b6ceD6f68849382990Ff3215) — Deposits into Morpho lending markets via Yearn's aggregator vault.

The `MorphoCompounderStrategyFactory` at `0x052d20B...` deploys strategies that target the Yearn Strategy USDC vault, which optimizes across Morpho lending markets.


### Role Assignments

| Role | Assigned To | Description |
|------|-------------|-------------|
| **Management** | Shutter DAO Treasury (`0x36bD...32c4`) | Administrative role (set keeper, set emergency admin, shutdown) |
| **Keeper** | Dedicated Bot/EOA | **REQUIRED**: Authorized to call `report()`/`tend()` to harvest yields without governance votes |
| **Emergency Admin** | Shutter DAO Treasury (`0x36bD...32c4`) | Can shutdown the strategy and perform emergency withdrawals |

> **Critical**: The Keeper should be a dedicated EOA or bot, NOT the Treasury Safe. Assigning Keeper to Treasury would require a governance vote (72-hour voting + 72-hour execution = 144 hours minimum) for every harvest, creating severe operational bottlenecks that defeat the purpose of automated yield generation.

### Yield Distribution

| Destination | Allocation |
|-------------|------------|
| Dragon Funding Pool | 100% |

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

See current governance parameters on the [Decent DAO App](https://app.decentdao.org/home?dao=eth%3A0x36bD3044ab68f600f6d3e081056F34f2a58432c4).

### Voting Platforms

| Platform | Type | Use Case |
|----------|------|----------|
| [Decent](https://app.decentdao.org/home?dao=eth%3A0x36bD3044ab68f600f6d3e081056F34f2a58432c4) | On-chain | Treasury transactions, contract interactions |
| [Snapshot](https://snapshot.org/#/shutterdao0x36.eth) | Off-chain | Temperature checks, non-binding polls |

Shutter DAO also supports **Shielded Voting** on Snapshot, which encrypts votes until the voting period ends to prevent manipulation.

---

## Execution Playbook

### Phase 1: Strategy Deployment

The entire deployment can be executed in a **single DAO proposal** with **1 batched MultiSend** containing 3 operations:
1. Deploy Strategy via Factory
2. Approve USDC to Strategy (uses precomputed Strategy address)
3. Deposit USDC into Strategy

**Key optimization**: The strategy factory uses CREATE2, allowing address precomputation. This enables batching all 3 operations without waiting for return values. Run the calldata generator script (`partners/shutter_dao_0x36/script/GenerateProposalCalldata.s.sol`) against mainnet to get precomputed addresses.

> **MultiSend requirement**: Execute MultiSend with `operation=DELEGATECALL` (Azorius `execTransactionFromModule(..., operation=1)`). Using CALL makes `msg.sender` the MultiSend contract and will break USDC approvals.
>
> **UI Limitation**: The Safe UI may not support DELEGATECALL directly. Use the Transaction Builder or submit raw transactions via the Azorius module.

<details>
<summary><strong>Fallback: Individual Transactions (if DELEGATECALL batching unavailable)</strong></summary>

If the Decent UI doesn't support DELEGATECALL batching, submit as **3 individual transactions** in a single proposal:

| TX | Target | Function | Notes |
|----|--------|----------|-------|
| 0 | MorphoCompounderStrategyFactory | `createStrategy(name, mgmt, keeper, admin, donationAddr, false, tokenizedStrategy)` | Returns Strategy address |
| 1 | USDC | `approve(strategyAddress, amount)` | Use Strategy address from TX 0 |
| 2 | Strategy | `deposit(amount, treasury)` | Deposits treasury USDC |

Each transaction uses `operation=0` (CALL). The Decent UI should support adding multiple transactions to a single proposal.

</details>

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
| Title | `Deploy Octant SHUGrantPool Strategy and Deposit 1M USDC` |
| Description | See [Proposal Template](#proposal-template) below |

**1.5 — Add Transaction 1: Deploy Strategy**

| Field | Value |
|-------|-------|
| Target Contract | `0x052d20B0e0b141988bD32772C735085e45F357c1` (Morpho Strategy Factory) |
| Function | `createStrategy(string,address,address,address,address,bool,address)` |
| `_name` | `SHUGrantPool` |
| `_management` | `0x36bD3044ab68f600f6d3e081056F34f2a58432c4` |
| `_keeper` | `[KEEPER_BOT_ADDRESS]` |
| `_emergencyAdmin` | `[EMERGENCY_ADMIN_ADDRESS]` |
| `_donationAddress` | `[DRAGON_FUNDING_POOL_ADDRESS]` |
| `_enableBurning` | `false` |
| `_tokenizedStrategyAddress` | `0xb27064a2c51b8c5b39a5bb911ad34db039c3ab9c` |

> **Note**: The strategy IS the ERC-4626 vault. No additional vault wrapper is needed.

**1.6 — Add Transaction 2: Approve USDC**

| Field | Value |
|-------|-------|
| Target Contract | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` (USDC) |
| Function | `approve(address spender, uint256 amount)` |
| `spender` | `[STRATEGY_ADDRESS]` *(from Tx 1)* |
| `amount` | `1000000000000` (1M USDC) |

**1.7 — Add Transaction 3: Deposit USDC**

| Field | Value |
|-------|-------|
| Target Contract | `[STRATEGY_ADDRESS]` *(from Tx 1)* |
| Function | `deposit(uint256 assets, address receiver)` |
| `assets` | `1000000000000` (1M USDC) |
| `receiver` | `0x36bD3044ab68f600f6d3e081056F34f2a58432c4` |

**1.8 — Submit Proposal**

Review all details and click "Submit Proposal". Sign the transaction with your wallet.

> ✅ **Gas Verified**: The simplified proposal (1 batched MultiSend with 3 operations) uses minimal gas - well under the 16.7M per-transaction limit (EIP-7825). See `ShutterDAOGasProfilingTest` for details.

### Gas Profile

| Component | Gas Cost |
|-----------|----------|
| **DAO Proposal (1 batched call, 3 operations)** | **~1M** |
| **EIP-7825 Limit** | 16,777,216 |
| **Headroom** | >92% |

*Note: Direct strategy deposits (no vault wrapper) and batched execution minimize gas costs.*

#### Step 2: Vote

1. Share the proposal link on the [Shutter Forum](https://shutternetwork.discourse.group/) for discussion
2. SHU holders vote during the voting period
3. Proposal passes if quorum is met and majority votes "For"

#### Step 3: Execute

Once the voting period ends and the proposal passes:

1. Return to the proposal page on Decent
2. Click "Execute" (available during the execution window)
3. Sign the execution transaction
4. Verify on Etherscan that all transactions succeeded

#### Step 4: Verify Deployment

After execution, verify:

- [ ] Strategy deployed with correct donation address (Dragon Funding Pool)
- [ ] Treasury received strategy shares
- [ ] USDC deposited and earning yield in Morpho markets

### Proposal Template

```markdown
## Summary

This proposal deploys the Octant SHUGrantPool Strategy and deposits
1,000,000 USDC from Shutter DAO 0x36 treasury as part of the Octant v2 pilot.

## Background

Octant v2 enables DAOs to optimize treasury yield while funding public goods.
See: [Octant v2 Pilot Proposal](https://shutternetwork.discourse.group/t/octant-v2-pilot-to-optimize-treasury-strengthen-ecosystem/760)

## Transactions (3 total)

1. **Deploy Strategy**: Create ERC-4626 yield-donating strategy (yield → Dragon Funding Pool)
2. **Approve USDC**: Allow Strategy to spend 1M USDC
3. **Deposit USDC**: Deposit 1M USDC, receiving shares to Treasury

## Architecture

The MorphoCompounderStrategy IS the ERC-4626 vault (via Yearn's TokenizedStrategy).
No additional vault wrapper is needed since only one strategy is approved by the DAO.

## Yield Distribution

- 100% → Dragon Funding Pool (Shutter ecosystem grants)

## Risk Considerations

- Underlying: Yearn Strategy USDC (deposits into Morpho lending markets)
- Custody: Treasury retains full share ownership
- Liquidity: Instant withdrawals (no lockup period)

## Links

- [Yearn Strategy USDC](https://etherscan.io/address/0x074134A2784F4F66b6ceD6f68849382990Ff3215)
- [Morpho Strategy Factory](https://etherscan.io/address/0x052d20B0e0b141988bD32772C735085e45F357c1)
```

### Prepared Calldata

Complete transaction calldata can be generated programmatically using the provided script:

```bash
forge script partners/shutter_dao_0x36/script/GenerateProposalCalldata.s.sol --fork-url $ETH_RPC_URL -vvvv
```

Before running, update the configuration in the script:
- `DRAGON_FUNDING_POOL` — Actual Dragon Funding Pool address
- `KEEPER_BOT` — Dedicated keeper EOA/bot address
- `EMERGENCY_ADMIN` — Emergency shutdown admin address

The script outputs:
- Precomputed CREATE2 address for Strategy
- Individual calldata for each transaction (TX 0-2)
- Batched MultiSend calldata (recommended for single-proposal execution)

> **Manual Reference**: The transaction parameters below can be used for UI-based proposal creation.

---

### Transaction 1: Deploy Strategy

```
Target:   0x052d20B0e0b141988bD32772C735085e45F357c1 (Morpho Strategy Factory)
Function: createStrategy(string,address,address,address,address,bool,address)
Selector: 0x31d89943
Value:    0

Parameters:
  _name:                     "SHUGrantPool"
  _management:               0x36bD3044ab68f600f6d3e081056F34f2a58432c4
  _keeper:                   [KEEPER_ADDRESS] (dedicated bot)
  _emergencyAdmin:           [EMERGENCY_ADMIN_ADDRESS]
  _donationAddress:          [DRAGON_FUNDING_POOL_ADDRESS]
  _enableBurning:            false
  _tokenizedStrategyAddress: 0xb27064a2c51b8c5b39a5bb911ad34db039c3ab9c
```

### Transaction 2: Approve USDC

```
Target:   0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 (USDC)
Function: approve(address,uint256)
Selector: 0x095ea7b3
Value:    0

Parameters:
  spender: [STRATEGY_ADDRESS] (from Tx 1)
  amount:  1000000000000 (1M USDC with 6 decimals)
```

### Transaction 3: Deposit USDC

```
Target:   [STRATEGY_ADDRESS] (from Tx 1)
Function: deposit(uint256,address)
Selector: 0x6e553f65
Value:    0

Parameters:
  assets:   1000000000000 (1M USDC with 6 decimals)
  receiver: 0x36bD3044ab68f600f6d3e081056F34f2a58432c4 (Treasury)
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
```

---

### Emergency Operations

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

---

### Quick Reference: Function Selectors

| Function | Selector | Target | Purpose |
|----------|----------|--------|---------|
| `createStrategy(...)` | `0x31d89943` | Morpho Factory | Deploy strategy |
| `approve(address,uint256)` | `0x095ea7b3` | USDC | Allow spending |
| `deposit(uint256,address)` | `0x6e553f65` | Strategy | Deposit funds |
| `withdraw(uint256,address,address)` | `0xb460af94` | Strategy | Withdraw funds |
| `report()` | `0x2606a10b` | Strategy | Harvest yield |
| `shutdownStrategy()` | `0xbe8f1668` | Strategy | Emergency shutdown |
| `emergencyWithdraw(uint256)` | `0x5312ea8e` | Strategy | Emergency exit |

---

## Operational Considerations

### Keeper Setup

See [Role Assignments](#role-assignments) for Keeper requirements. A dedicated EOA or bot enables autonomous harvesting without governance votes.

### Emergency Admin

The Treasury serves as Emergency Admin. Emergency actions (shutdown, forced withdrawals) will follow standard DAO voting timelines unless a separate multisig is designated for faster response.

### Withdrawals

The strategy provides instant liquidity (no lockup). Withdrawals are straightforward:
1. Call `withdraw(assets, receiver, owner)` or `redeem(shares, receiver, owner)` on the strategy
2. Receive underlying USDC immediately

The strategy will automatically unwind positions in Morpho markets as needed.

---

## References

- [Shutter DAO Blueprint](https://blog.shutter.network/a-proposed-blueprint-for-launching-a-shutter-dao/)
- [Octant v2 Pilot Proposal (Forum)](https://shutternetwork.discourse.group/t/octant-v2-pilot-to-optimize-treasury-strengthen-ecosystem/760)
- [Yearn Strategy USDC (Etherscan)](https://etherscan.io/address/0x074134A2784F4F66b6ceD6f68849382990Ff3215)
- [Shutter DAO Governance (Fractal/Decent)](https://app.decentdao.org/home?dao=eth%3A0x36bD3044ab68f600f6d3e081056F34f2a58432c4)
- [Shutter DAO Treasury (Etherscan)](https://etherscan.io/address/0x36bD3044ab68f600f6d3e081056F34f2a58432c4)

