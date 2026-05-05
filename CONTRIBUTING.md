# Contributing to PRISM

Thanks for your interest. PRISM is a permissionless ALM protocol on
Uniswap V4 — small surface, high-stakes code. The contribution process
reflects that: explicit, traceable, never bypassing quality gates.

## Code of conduct

Be civil and direct. We optimise for code that is correct and easy to
review, not for "nice" code that hides risk. If you disagree with an
approach, say so in writing in the PR.

## Development setup

**Prerequisites:**

- Node ≥ 18
- pnpm ≥ 9 (`npm install -g pnpm@10.18.0`)
- Foundry latest (`curl -L https://foundry.paradigm.xyz | bash && foundryup`)
- A Base Sepolia RPC URL

**Initial setup:**

```bash
git clone https://github.com/ozpool/prism.git
cd prism

# Install JS dependencies
pnpm install

# Initialize submodules (v4-core, v4-periphery, permit2)
git submodule update --init --recursive

# Verify everything compiles
pnpm --filter @prism/contracts build
pnpm --filter @prism/web typecheck
```

## Branch naming

Branch names map 1:1 to issues:

```
<layer>/<issue-number>-<short-slug>
```

| Layer prefix | Used for |
|---|---|
| `contracts/` | Solidity in `packages/contracts/` |
| `frontend/` | Anything under `apps/web/` or `packages/shared/` |
| `keeper/` | Anything under `apps/keeper/` |
| `ci/` | `.github/workflows/` |
| `docs/` | Markdown, ADRs, README |
| `adr/` | Files in `docs/adrs/` |
| `design/` | Tokens, palette, contrast docs |
| `chore/` | Tooling, config, dependency bumps |

Examples:
- `contracts/27-vault-deposit`
- `frontend/52-deposit-form`
- `adr/14-gas-budget`

**One issue → one branch → one PR.** Don't bundle unrelated work into a
single PR; reviewers can't reason about it and the git history hides
intent.

## Commit messages

Conventional commits, scoped by layer:

```
<type>(<scope>): <imperative summary> (#<issue>)

<optional body>
```

Types: `feat`, `fix`, `test`, `docs`, `chore`, `build`, `ci`, `refactor`.

Examples:
- `feat(vault): MIN_SHARES burn on first deposit (#27)`
- `fix(hook): clamp dynamic fee to MAX_FEE in EWMA path (#35)`
- `test(strategy): fuzz weight sum invariant across N positions (#39)`
- `docs(adr): gas budget allocation (#14)`

**Do not** include AI-attribution trailers (`Co-Authored-By: Claude`,
`Generated with …`, etc.). The author of a commit is the human who
wrote and reviewed it.

## Pull requests

PR title mirrors the lead commit title.

PR body must include:

1. **Summary** — what changed and why.
2. **Quality gates** — which checks were run locally and their results.
3. **Test plan** — checklist of what was verified.
4. **Dependencies** — upstream PRs (if stacked) and downstream issues unblocked.

Stack PRs when there are tight dependencies (e.g., `Vault.deposit`
depends on `Vault` storage layout). Use the upstream branch as `--base`,
and document the merge order in the PR body.

## Quality gates

Before opening a PR, run the relevant checks locally. CI runs the same
ones on every PR; they must pass before merge.

### Contracts

```bash
cd packages/contracts

forge fmt --check                            # formatting
forge build                                  # compiles
forge test -vvv                              # unit + fuzz + invariants
forge snapshot --check                       # gas snapshot regressions

slither . --config-file slither.config.json  # static analysis
aderyn .                                     # second-opinion static analysis
```

### Web

```bash
pnpm --filter @prism/web typecheck
pnpm --filter @prism/web lint
pnpm --filter @prism/web build
```

For UI work, also run `pnpm --filter @prism/web dev` and exercise the
change in a browser. Type-check passes prove the code compiles, not
that the feature works.

### Keeper

```bash
pnpm --filter @prism/keeper typecheck
pnpm --filter @prism/keeper lint
pnpm --filter @prism/keeper test
```

### Shared

```bash
pnpm --filter @prism/shared typecheck
```

## Review and merge

- Two approvals required for merges that touch `Vault`, `ProtocolHook`,
  `BellStrategy`, `ChainlinkAdapter`, or `VaultFactory`. Single approval
  for everything else.
- All required CI status checks must be green.
- Reviewers: pull the branch and run quality gates locally before
  approving. CI catches most regressions but not all of them.
- After merge, the branch is deleted automatically. Don't keep stale
  branches.

## Security-sensitive changes

If your change touches custody, accounting, hook callbacks, oracle
plumbing, or upgrade paths, open the PR with `security-audit-needed`
in the description and request review from a maintainer with the
security label. Do not self-merge security work.

Vulnerabilities go through the disclosure process in
[`SECURITY.md`](./SECURITY.md), not the public issue tracker.

## ADRs

Architectural decisions live in [`docs/adrs/`](./docs/adrs/). When you
make a decision that constrains future code (a chosen pattern, a
rejected alternative, a hard limit), write an ADR in the same PR that
implements the decision. Number sequentially. Don't edit a merged ADR
to change its decision — write a new one that supersedes it.

## What we don't accept

- PRs that disable CI checks (`--no-verify`, `// slither-disable-next-line`
  without justification, skipping gas snapshots).
- "Cleanup" PRs that touch unrelated code alongside the actual change.
- Speculative abstractions: build the abstraction in the PR that needs
  it, not before.
- Backwards-compat shims for code we control. Just change the call sites.

If you're unsure whether something fits, open a discussion or comment
on the relevant issue before writing code.
