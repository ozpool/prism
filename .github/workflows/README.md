# CI workflows

Pre-merge gates for `ozpool/prism`.

## `contracts.yml`

Runs on every PR that touches `packages/contracts/**` (or the workflow
itself), and on every push to `main` with the same path filter.

Four jobs run in parallel:

| Job | Tool | Action |
|---|---|---|
| `build-and-test` | Foundry | `forge build --sizes` + `forge test -vvv` + `forge snapshot --check` |
| `slither` | Slither (Python) | static analysis — `--fail-medium` blocks merge |
| `aderyn` | Aderyn (Rust) | second static analyser, complementary rule set |
| `fmt` | Foundry | `forge fmt --check` |

### Pinned versions

All toolchain versions are pinned at the top of the workflow file. Bump
deliberately:

| Tool | Pin | How to bump |
|---|---|---|
| Foundry | nightly SHA | edit `FOUNDRY_VERSION`; verify with `foundryup --version $sha` locally |
| Slither | semver | edit `SLITHER_VERSION` |
| Aderyn | git tag | edit `ADERYN_VERSION` |
| Python (Slither runtime) | minor | edit `PYTHON_VERSION` |

### Submodule cache

`packages/contracts/lib/` is cached keyed by `hashFiles('.gitmodules')`
so submodule bumps invalidate cleanly. Manually invalidate by editing
the cache key or deleting the cache from the Actions UI.

## Required-status-checks (manual setup)

Repository-level branch protection on `main` MUST require all four
jobs from `contracts.yml`:

- `build-and-test`
- `slither`
- `aderyn`
- `fmt`

Set under **Settings → Branches → main → Require status checks to pass
before merging**. This is not configurable from the workflow itself —
ozpool needs to flip the toggle once.

## Rollback

If a CI change breaks main:

1. Revert the offending commit on `main` (or temporarily disable the
   workflow by adding `if: false` to the affected job).
2. Open a follow-up PR that fixes forward.

If a tool pin starts producing false positives that block legitimate
PRs:

1. Pin the tool back to the previous known-good version in `env`.
2. File an issue in the repo describing the regression.
3. Bump again deliberately when the upstream tool releases a fix.
