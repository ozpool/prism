import {createPublicClient, http, type Address} from "viem";
import {baseSepolia} from "viem/chains";
import {ADDRESSES, CHAIN_IDS} from "@prism/shared";

/**
 * Vault list state — discriminated union per the design spec
 * (`docs/design/vault-list.md`). Forces every consumer to handle all
 * four states at type level.
 */
export type VaultListState =
  | {kind: "loading"}
  | {kind: "empty"}
  | {kind: "error"; error: Error; retry: () => void}
  | {kind: "active"; vaults: VaultSummary[]};

export interface VaultSummary {
  address: Address;
  pairName: string;
  versionLabel: string;
  tvlUsd: bigint;
  apr24hBps: number;
  sharePriceUsd: bigint;
}

/**
 * Format a USDC-scaled bigint (6 decimals) as a human-readable USD string.
 *
 *   formatUsd(1234567890000n) === "$1,234,567.89"
 */
export function formatUsd(amount: bigint): string {
  const whole = amount / 1_000_000n;
  const cents = (amount % 1_000_000n) / 10_000n; // 2 decimals
  const wholeStr = whole.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  const centsStr = cents.toString().padStart(2, "0");
  return `$${wholeStr}.${centsStr}`;
}

/**
 * Format basis points as a percent. `1240` → `"12.40%"`.
 */
export function formatBps(bps: number): string {
  return `${(bps / 100).toFixed(2)}%`;
}

const FACTORY_ABI = [
  {
    type: "function",
    name: "allVaultsLength",
    stateMutability: "view",
    inputs: [],
    outputs: [{name: "", type: "uint256"}],
  },
  {
    type: "function",
    name: "allVaults",
    stateMutability: "view",
    inputs: [{name: "i", type: "uint256"}],
    outputs: [{name: "", type: "address"}],
  },
] as const;

const VAULT_ABI = [
  {type: "function", name: "name", stateMutability: "view", inputs: [], outputs: [{name: "", type: "string"}]},
  {type: "function", name: "symbol", stateMutability: "view", inputs: [], outputs: [{name: "", type: "string"}]},
  {type: "function", name: "totalSupply", stateMutability: "view", inputs: [], outputs: [{name: "", type: "uint256"}]},
] as const;

/**
 * Reads the live VaultFactory on Base Sepolia and returns one summary
 * per registered vault. Until per-vault TVL/APR plumbing lands the
 * card numbers are zeroed — the card still renders with its real
 * pair name + symbol so users can click into the detail page.
 */
export async function fetchVaultSummaries(): Promise<VaultSummary[]> {
  const addrs = ADDRESSES[CHAIN_IDS.baseSepolia];
  if (!addrs || addrs.vaultFactory === "0x0000000000000000000000000000000000000000") {
    return [];
  }

  const rpcUrl = process.env.NEXT_PUBLIC_BASE_SEPOLIA_RPC_URL;
  const client = createPublicClient({
    chain: baseSepolia,
    transport: rpcUrl ? http(rpcUrl) : http(),
  });

  const length = (await client.readContract({
    address: addrs.vaultFactory,
    abi: FACTORY_ABI,
    functionName: "allVaultsLength",
  })) as bigint;

  if (length === 0n) return [];

  const vaults: VaultSummary[] = [];
  for (let i = 0n; i < length; i++) {
    const vaultAddr = (await client.readContract({
      address: addrs.vaultFactory,
      abi: FACTORY_ABI,
      functionName: "allVaults",
      args: [i],
    })) as Address;

    const [name, symbol] = await Promise.all([
      client.readContract({address: vaultAddr, abi: VAULT_ABI, functionName: "name"}) as Promise<string>,
      client.readContract({address: vaultAddr, abi: VAULT_ABI, functionName: "symbol"}) as Promise<string>,
    ]);

    vaults.push({
      address: vaultAddr,
      pairName: name,
      versionLabel: `${symbol} · v1.0`,
      tvlUsd: 0n,
      apr24hBps: 0,
      sharePriceUsd: 1_000_000n, // $1.00 placeholder until totals plumbing lands
    });
  }

  return vaults;
}
