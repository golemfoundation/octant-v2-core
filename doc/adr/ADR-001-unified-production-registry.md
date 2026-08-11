# ADR-001: Use One Canonical Production Registry

## Status

Proposed

## Context

Octant deployment tooling needs an on-chain source of truth for production contract
addresses. The registry must support deterministic Safe deployment batches, factory
replacement, lifecycle signaling, auditability, and reliable off-chain export.

The initial design split these responsibilities between:

- `OctantRegistry`, which stored the latest address for each key; and
- `ReleaseRegistry`, which stored append-only factory release history.

That split made every factory deployment update two independently administered contracts.
The two registries could disagree after a partial or incorrectly ordered transaction, their
version concepts overlapped, and consumers needed policy knowledge to decide which registry
was authoritative.

Three alternatives were considered:

1. Keep the two-registry design and enforce coordination only in deployment scripts.
2. Store an unbounded array of every revision for every key in one contract.
3. Store canonical current state in one contract and use events for complete history.

## Decision

Use one non-upgradeable `OctantRegistry` as the canonical production discovery registry.

An owner publication is an atomic `publishBatch` call with:

- the expected current epoch;
- one or more typed entry updates;
- a human-readable release label.

Every successful batch increments one global epoch. Each entry records its current address,
immutable semantic type, lifecycle status, per-key bump, latest epoch, optional API
compatibility version, and observed runtime code hash. Known keys are append-only.
`DEPRECATED` represents an intentionally superseded entry, while `DISABLED` represents one
that is explicitly unsupported or unsafe. These statuses affect discovery only.

Current state is queryable on-chain. Complete history is emitted through
`EntryPublished` and `BatchPublished` events rather than duplicated in unbounded storage.
Inactive entries remain inspectable but do not resolve through the active-address getters.
The registry computes publication manifests itself using a versioned domain that binds the
chain ID, registry address, expected epoch, release-label hash, and complete ordered update
array. Callers cannot supply or substitute the digest.

The registry is intentionally not a proxy. A validated, one-time successor pointer provides
an explicit migration path and permanently freezes the superseded registry.

## Consequences

Positive consequences:

- A deployment and all of its discovery updates have one atomic consistency boundary.
- There is one authority, one key namespace, and one lifecycle model.
- Stale Safe proposals fail through optimistic epoch concurrency control.
- Event history remains complete without making publication cost grow with history length.
- Runtime code hashes and manifest hashes make off-chain verification deterministic.
- Factory and non-factory contracts use the same discovery and deprecation semantics.

Trade-offs:

- Contracts cannot enumerate historical revisions without reading logs or an indexer.
- Event availability is part of the operational archival model.
- Consumers that require immutable historical proofs must pin a block and retain receipts.
- Migrating the registry changes its address and requires consumers to follow the explicit
  successor pointer.

The repository release label is metadata only. Entry compatibility versions must describe
the registered contract API and must not be inferred from the repository package version.
The canonical exporter reads finalized state by default, verifies the pinned height's block
hash before and after all calls, writes atomically, and rejects superseded registry instances
to prevent inconsistent or stale artifact generation.

## References

- [Pull request #468](https://github.com/golemfoundation/octant-v2-core/pull/468)
- [Registry design review](https://github.com/golemfoundation/octant-v2-core/pull/468#pullrequestreview-4753930432)
