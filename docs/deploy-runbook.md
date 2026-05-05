# PRISM Deploy Runbook

End-to-end deploy procedure for the PRISM contract stack on Base Sepolia (testnet) and Base (mainnet, gated on audit completion per ADR-006). The flow is broadcast → post-deploy → verify.

## 1. Prerequisites

Required env vars (same set for both chains; only the RPC differs):

| Variable | Notes |
|---|---|
| `DEPLOYER_PRIVATE_KEY` | Hex-prefixed deployer key. Must hold enough native gas. |
| `POOL_MANAGER` | Uniswap V4 PoolManager address on the target chain. |
| `DEFAULT_OWNER` | Multisig that becomes the owner of every vault deployed by the factory. |
| `CHAINLINK_FEED` | Primary price feed (e.g. ETH/USD on Base). |
| `SEQUENCER_FEED` | L2 sequencer uptime feed (Base sequencer feed). |
| `PRICE_SCALE_NUM` / `PRICE_SCALE_DEN` | Q192 numerator/denominator computed off-chain to convert the Chainlink price into the V4 sqrtPriceX96 scale for the target pool. |
| `BASE_SEPOLIA_RPC_URL` *or* `BASE_RPC_URL` | RPC endpoint. |
| `BASESCAN_API_KEY` | Required for `--verify`. |

Pinned toolchain (CI also enforces these — see `.github/workflows/contracts.yml`):

| Tool | Version |
|---|---|
| Node | `>=18` |
| pnpm | `>=9` (repo declares `packageManager: pnpm@10.18.0`) |
| Foundry | per `foundry.toml` (`solc 0.8.26`, `evm_version cancun`) |

## 2. Pre-deploy gate

Run from the repo root:

```bash
# Contracts
pnpm --filter @prism/contracts test
forge build --root packages/contracts

# Frontend + keeper
pnpm typecheck
pnpm lint
```

Do not proceed if any gate fails.

## 3. Broadcast

```bash
forge script packages/contracts/script/Deploy.s.sol:Deploy \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $BASESCAN_API_KEY
```

`Deploy.s.sol` itself asserts:
- ProtocolHook address bits = `0x05C0` (BEFORE_INITIALIZE | AFTER_INITIALIZE | AFTER_ADD_LIQUIDITY | AFTER_REMOVE_LIQUIDITY).
- VaultFactory CREATE address matches the address used in the hook constructor (no nonce drift).

If either assertion fails the broadcast reverts atomically — nothing is deployed.

## 4. Post-deploy

```bash
pnpm post-deploy --chain base-sepolia
```

This script:
1. Parses `packages/contracts/broadcast/Deploy.s.sol/<chainId>/run-latest.json`.
2. Extracts the four deployed contract addresses + the configured PoolManager.
3. Writes `addresses.json` at the repo root (operator-readable).
4. Updates `packages/shared/src/addresses.ts` (typed app code) — replaces the `PLACEHOLDER` mapping for the target chain with a deployed block bracketed by sentinels so re-runs are clean.
5. Invokes `verify-hook.ts` against the deployed `ProtocolHook`, which:
   - Confirms bytecode is non-empty.
   - Calls `getHookPermissions()` and re-derives the expected address mask.
   - Asserts the mask matches the low 14 bits of the deployed address.

If `verify-hook` fails, the deployment is **broken** — proceed to rollback.

## 5. Verification checklist

- [ ] All four contracts show `Verified` on Basescan.
- [ ] `pnpm verify-hook --chain base-sepolia` exits 0.
- [ ] `addresses.json` committed.
- [ ] `packages/shared/src/addresses.ts` committed.
- [ ] Frontend boots locally with the new addresses (`pnpm --filter @prism/web dev` → wallet connects on Base Sepolia).

## 6. Rollback

The PRISM contracts are immutable (ADR-006). There is no upgrade path; rollback means abandoning the broken deployment and redeploying.

1. **Halt operations.** Pause the keeper service (`fly scale count 0 --app prism-keeper-sepolia`) so it stops trying to rebalance against the broken deploy.
2. **Communicate.** Post in the incident channel with the broken addresses + the broadcast tx hash.
3. **Tag the broken deploy.** Tag the broadcast at `addresses.json@<broken-deploy>` with `--annotated` for forensic later.
4. **Redeploy.** Fix the underlying issue, repeat from §3 with a fresh deployer nonce.
5. **Migrate users.** If the broken vault held real testnet funds, document the recovery path (`withdraw()` is never pausable per invariant 6, so users can always exit, even from a broken vault).

If the issue is purely off-chain (wrong addresses written, frontend out of sync), redeploy is **not** required — re-run `pnpm post-deploy` against the existing broadcast file.

## 7. Mainnet differences

Mainnet (`base`) deploys are gated behind audit sign-off per ADR-006. When that gate is cleared:

- Use `BASE_RPC_URL` and pass `--chain base` to `pnpm post-deploy`.
- The `[CHAIN_IDS.base]: undefined` entry in `addresses.ts` is auto-replaced with the deployed block by the post-deploy script.
- A cold wallet must hold the deployer key. Hardware-wallet signing via Frame or Foundry's `--ledger` is required.
