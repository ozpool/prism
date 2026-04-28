# ADR-001: Solidity Compiler Version

## Status

Accepted — 2026-04-23

## Context

PRISM's `foundry.toml` originally pinned `solc_version = "0.8.25"`, and the
PRD + CLAUDE.md both described "Solidity 0.8.25" as the tech-stack target.

Uniswap v4's pinned submodules (see `README.md#v4-dependency-pins`) require
`pragma solidity 0.8.26` strictly on the top-level contracts that PRISM
imports — notably `PoolManager.sol`, `IPoolManager.sol`, and v4-periphery's
`PositionManager.sol`. Types, interfaces, and libraries with floor pragmas
(`^0.8.0`, `^0.8.24`) still compile under 0.8.25.

Attempting to import `PoolManager` (required starting with issue #26 — the
core Vault) under `solc 0.8.25` fails with a strict-pragma error.

## Decision

Bump `solc_version` from `0.8.25` to `0.8.26` across the project:

1. `packages/contracts/foundry.toml` — `solc_version = "0.8.26"`
2. Every PRISM Solidity file — `pragma solidity 0.8.26;` (strict, no caret)
3. Documentation (CLAUDE.md §Tech Stack, PRD references) — update to match

Alternatives considered and rejected:

- **Floor pragma `^0.8.25`** — more permissive, but the PRD and CLAUDE.md
  both call for a strict pin. Philosophical regression.
- **Stay on 0.8.25 forever** — not viable. Vault (#26) imports
  `PoolManager`, which is 0.8.26-pinned.

## Consequences

- PRISM matches Uniswap's own pragma discipline exactly — no drift.
- Any future contributor adding a new contract file must use
  `pragma solidity 0.8.26;` strictly.
- Some older tooling that pinned to 0.8.25 may need updates; Foundry and
  Slither both support 0.8.26 at pinning time (Apr 2026).
- This ADR does not restrict future bumps to 0.8.27+ — that decision
  remains open.

## References

- Issue #133 (this ADR)
- PR #132 (v4 submodule pinning — surfaced the mismatch)
- Uniswap v4-core `src/PoolManager.sol` pragma line
