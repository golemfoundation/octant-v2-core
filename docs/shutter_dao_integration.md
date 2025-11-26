# Shutter DAO 0x36 × Octant v2 Integration Guide


## Overview

Shutter DAO 0x36 will integrate with Octant v2 through **two distinct components**:

1. **Dragon Vault (MSLV)** — A Multistrategy Locked Vault for treasury capital deployment
2. **Regen Staker** — A staking contract for SHU tokens enabling public goods funding with matched rewards

| Component | Purpose | Capital |
|-----------|---------|---------|
| Dragon Vault | Generate yield to fund Regen Staker rewards | 1.5M USDC |
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

## Part 1: Dragon Vault (MSLV)

The Multistrategy Locked Vault manages treasury capital with custody-based rage quit protection.

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
| **Regen Governance** | Octant Governance *(Default)* | Controls economic parameters (lockup, rage quit cooldowns). Aligns with Octant's public goods funding. |

### Yield Distribution

| Destination | Allocation |
|-------------|------------|
| Ethereum Sustainability Fund (ESF) | 5% |
| Dragon Funding Pool | 95% |

### Yield Projections (assuming 5% APY)

| Metric | Annual |
|--------|--------|
| Gross Yield | 75,000 USDC |
| To ESF | 3,750 USDC |
| To Dragon Funding Pool | 71,250 USDC |
| Epochs Supported | ~3 per year (~23,750 USDC each) |

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

#### Step 1: Octant Deploys Vault

The Octant team deploys and configures the Dragon Vault (MSLV) instance for Shutter DAO.

**Output**: `DRAGON_VAULT_ADDRESS` *(to be provided post-deployment)*

#### Step 2: Create Fractal Proposal (UI Walkthrough)

**2.1 — Navigate to Shutter DAO on Decent**

Open [app.decentdao.org/home?dao=eth:0x36bD3044ab68f600f6d3e081056F34f2a58432c4](https://app.decentdao.org/home?dao=eth%3A0x36bD3044ab68f600f6d3e081056F34f2a58432c4)

**2.2 — Connect Wallet**

Connect a wallet holding SHU tokens (required to meet proposal threshold).

**2.3 — Click "Create Proposal"**

Navigate to the Proposals tab and click the "Create Proposal" button.

**2.4 — Fill Proposal Details**

| Field | Value |
|-------|-------|
| Title | `Deposit 1.5M USDC into Octant Dragon Vault` |
| Description | See [Proposal Template](#proposal-template) below |

**2.5 — Add Transaction 1 (Approve USDC)**

Click "Add Transaction" and fill in:

| Field | Value |
|-------|-------|
| Target Contract | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` (USDC) |
| Function | `approve(address spender, uint256 amount)` |
| `spender` | `[DRAGON_VAULT_ADDRESS]` |
| `amount` | `1500000000000` |

**2.6 — Add Transaction 2 (Deposit USDC)**

Click "Add Transaction" again:

| Field | Value |
|-------|-------|
| Target Contract | `[DRAGON_VAULT_ADDRESS]` |
| Function | `deposit(uint256 assets, address receiver)` |
| `assets` | `1500000000000` |
| `receiver` | `0x36bD3044ab68f600f6d3e081056F34f2a58432c4` |

**2.7 — Submit Proposal**

Review all details and click "Submit Proposal". Sign the transaction with your wallet.

#### Step 3: Vote

1. Share the proposal link on the [Shutter Forum](https://shutternetwork.discourse.group/) for discussion
2. SHU holders vote during the 72-hour voting period
3. Proposal passes if quorum (3%) is met and majority votes "For"

#### Step 4: Execute

Once the voting period ends and the proposal passes:

1. Return to the proposal page on Decent
2. Click "Execute" (available during the 72-hour execution window)
3. Sign the execution transaction
4. Verify on Etherscan that both transactions succeeded

### Proposal Template

```markdown
## Summary

This proposal authorizes Shutter DAO 0x36 to deposit 1,500,000 USDC into the 
Octant Dragon Vault as part of the Octant v2 pilot integration.

## Background

Octant v2 enables DAOs to optimize treasury yield while funding public goods. 
See: [Octant v2 Pilot Proposal](https://shutternetwork.discourse.group/t/octant-v2-pilot-to-optimize-treasury-strengthen-ecosystem/760)

## Transactions

1. **Approve USDC**: Allow Dragon Vault to spend 1.5M USDC
2. **Deposit USDC**: Deposit 1.5M USDC into Dragon Vault, receiving shares to Treasury

## Yield Distribution

- 5% → Ethereum Sustainability Fund
- 95% → Dragon Funding Pool (Shutter ecosystem grants)

## Risk Considerations

- Strategy: Morpho Steakhouse USDC (Credora A+ rated)
- Custody: Treasury retains share ownership with rage quit rights
- Lockup: 7-day cooldown for withdrawals

## Links

- [Dragon Vault Address]: `[DRAGON_VAULT_ADDRESS]`
- [Morpho Strategy](https://app.morpho.org/ethereum/vault/0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB/steakhouse-usdc)
```

### Technical Calldata (for verification)

Use this to verify transaction encoding matches the UI:

**Transaction 1 — USDC Approve**

```
Function: approve(address,uint256)
Selector: 0x095ea7b3
Parameters:
  spender: [DRAGON_VAULT_ADDRESS]
  amount:  1500000000000 (0x15d3ef79800)

Encoded (with placeholder vault 0x1234...5678):
0x095ea7b3
  0000000000000000000000001234567890123456789012345678901234567890  // spender
  00000000000000000000000000000000000000000000000000000015d3ef79800 // amount
```

**Transaction 2 — Deposit**

```
Function: deposit(uint256,address)
Selector: 0x6e553f65
Parameters:
  assets:   1500000000000 (0x15d3ef79800)
  receiver: 0x36bD3044ab68f600f6d3e081056F34f2a58432c4

Encoded:
0x6e553f65
  00000000000000000000000000000000000000000000000000000015d3ef79800 // assets
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

### Emergency Admin

The Treasury serves as Emergency Admin. Emergency actions (shutdown, forced withdrawals) will follow standard DAO voting timelines unless a separate multisig is designated for faster response.

### Rage Quit Mechanism

Withdrawals from the Dragon Vault require:
1. **Initiate Rage Quit** — Lock shares for withdrawal
2. **Wait Cooldown Period** — Default: 7 days
3. **Execute Withdrawal** — Receive underlying assets

This protects against flash loan attacks and ensures orderly exits. Locked shares cannot be transferred during the cooldown period.

---

## References

- [Shutter DAO Blueprint](https://blog.shutter.network/a-proposed-blueprint-for-launching-a-shutter-dao/)
- [Octant v2 Pilot Proposal (Forum)](https://shutternetwork.discourse.group/t/octant-v2-pilot-to-optimize-treasury-strengthen-ecosystem/760)
- [Morpho Steakhouse USDC Vault](https://app.morpho.org/ethereum/vault/0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB/steakhouse-usdc)
- [Shutter DAO Governance (Fractal/Decent)](https://app.decentdao.org/home?dao=eth%3A0x36bD3044ab68f600f6d3e081056F34f2a58432c4)
- [Shutter DAO Treasury (Etherscan)](https://etherscan.io/address/0x36bD3044ab68f600f6d3e081056F34f2a58432c4)

