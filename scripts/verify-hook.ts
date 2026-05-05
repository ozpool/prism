#!/usr/bin/env node
// Off-chain post-deploy verification of the ProtocolHook address.
//
// V4 hooks must have their address bits match the permission flags
// returned by `getHookPermissions()`. The deploy script asserts this
// at deploy time; this script re-verifies the deployed contract on
// the target chain so that operators can run the check independently
// of the deploy run.
//
// Permission bit layout (least-significant nibble groups, per V4):
//   bit  6  BEFORE_INITIALIZE
//   bit  7  AFTER_INITIALIZE
//   bit  8  BEFORE_ADD_LIQUIDITY
//   bit  9  AFTER_ADD_LIQUIDITY
//   bit 10  BEFORE_REMOVE_LIQUIDITY
//   bit 11  AFTER_REMOVE_LIQUIDITY
//   bit 12  BEFORE_SWAP
//   bit 13  AFTER_SWAP
//   bit 14  BEFORE_DONATE
//   bit 15  AFTER_DONATE
//   bit 16  BEFORE_SWAP_RETURN_DELTA
//   bit 17  AFTER_SWAP_RETURN_DELTA
//   bit 18  AFTER_ADD_LIQUIDITY_RETURN_DELTA
//   bit 19  AFTER_REMOVE_LIQUIDITY_RETURN_DELTA
//
// PRISM's hook sets bits 6, 7, 9, 11 of the lowest byte mask =>
// address & 0x3FFF == 0x05C0. (See ProtocolHook.getHookPermissions.)
//
// Run:
//   tsx scripts/verify-hook.ts --chain base-sepolia
// or:
//   tsx scripts/verify-hook.ts --hook 0x... --rpc https://...

import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, http, type Address, type Hex } from "viem";
import { baseSepolia, base } from "viem/chains";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, "..");

const CHAIN_IDS = { baseSepolia: 84532, base: 8453 } as const;
type SupportedChainId = (typeof CHAIN_IDS)[keyof typeof CHAIN_IDS];

interface DeployedSet {
  vaultFactory: Address;
  protocolHook: Address;
  bellStrategy: Address;
  chainlinkAdapter: Address;
  poolManager: Address;
}

function loadAddressesFromJson(chainId: SupportedChainId): DeployedSet | null {
  const path = join(REPO_ROOT, "addresses.json");
  if (!existsSync(path)) return null;
  const data = JSON.parse(readFileSync(path, "utf8")) as Record<string, DeployedSet>;
  return data[String(chainId)] ?? null;
}

interface HookPermissions {
  beforeInitialize: boolean;
  afterInitialize: boolean;
  beforeAddLiquidity: boolean;
  afterAddLiquidity: boolean;
  beforeRemoveLiquidity: boolean;
  afterRemoveLiquidity: boolean;
  beforeSwap: boolean;
  afterSwap: boolean;
  beforeDonate: boolean;
  afterDonate: boolean;
  beforeSwapReturnDelta: boolean;
  afterSwapReturnDelta: boolean;
  afterAddLiquidityReturnDelta: boolean;
  afterRemoveLiquidityReturnDelta: boolean;
}

const HOOK_FLAGS: Array<{ flag: keyof HookPermissions; bit: number }> = [
  { flag: "beforeInitialize", bit: 13 },
  { flag: "afterInitialize", bit: 12 },
  { flag: "beforeAddLiquidity", bit: 11 },
  { flag: "afterAddLiquidity", bit: 10 },
  { flag: "beforeRemoveLiquidity", bit: 9 },
  { flag: "afterRemoveLiquidity", bit: 8 },
  { flag: "beforeSwap", bit: 7 },
  { flag: "afterSwap", bit: 6 },
  { flag: "beforeDonate", bit: 5 },
  { flag: "afterDonate", bit: 4 },
  { flag: "beforeSwapReturnDelta", bit: 3 },
  { flag: "afterSwapReturnDelta", bit: 2 },
  { flag: "afterAddLiquidityReturnDelta", bit: 1 },
  { flag: "afterRemoveLiquidityReturnDelta", bit: 0 },
];

const GET_HOOK_PERMISSIONS_ABI = [
  {
    inputs: [],
    name: "getHookPermissions",
    outputs: [
      {
        components: HOOK_FLAGS.map(({ flag }) => ({ name: flag, type: "bool" })),
        name: "permissions",
        type: "tuple",
      },
    ],
    stateMutability: "pure",
    type: "function",
  },
] as const;

function parseArgs(): { chain: string | null; hook: Address | null; rpc: string | null } {
  const argv = process.argv.slice(2);
  let chain: string | null = null;
  let hook: Address | null = null;
  let rpc: string | null = null;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--chain") chain = argv[++i] ?? null;
    else if (a === "--hook") hook = (argv[++i] ?? null) as Address | null;
    else if (a === "--rpc") rpc = argv[++i] ?? null;
  }
  return { chain, hook, rpc };
}

function chainConfigFor(name: string): { chainId: SupportedChainId; viemChain: typeof baseSepolia | typeof base } {
  if (name === "base-sepolia") return { chainId: CHAIN_IDS.baseSepolia, viemChain: baseSepolia };
  if (name === "base") return { chainId: CHAIN_IDS.base, viemChain: base };
  throw new Error(`Unsupported chain '${name}'. Use 'base-sepolia' or 'base'.`);
}

function permissionsToAddressMask(p: HookPermissions): number {
  let mask = 0;
  for (const { flag, bit } of HOOK_FLAGS) {
    if (p[flag]) mask |= 1 << bit;
  }
  return mask;
}

function lowMaskOf(addr: Address): number {
  // Lowest 14 bits — covers all hook permission flags.
  return Number(BigInt(addr) & 0x3fffn);
}

async function main() {
  const args = parseArgs();

  let hookAddress: Address;
  let rpcUrl: string;
  let viemChain: typeof baseSepolia | typeof base;

  if (args.hook && args.rpc) {
    hookAddress = args.hook;
    rpcUrl = args.rpc;
    viemChain = baseSepolia;
  } else {
    const chainName = args.chain ?? "base-sepolia";
    const { chainId, viemChain: vc } = chainConfigFor(chainName);
    const addrs = loadAddressesFromJson(chainId);
    if (!addrs) {
      throw new Error(
        `No addresses.json entry for chainId=${chainId}. Run \`pnpm post-deploy --chain ${chainName}\` first, or pass --hook + --rpc.`,
      );
    }
    hookAddress = addrs.protocolHook;
    if (hookAddress === "0x0000000000000000000000000000000000000000") {
      throw new Error(`ProtocolHook address is zero for ${chainName}.`);
    }
    const envRpc =
      chainId === CHAIN_IDS.baseSepolia ? process.env.BASE_SEPOLIA_RPC_URL : process.env.BASE_RPC_URL;
    if (!envRpc) {
      throw new Error(
        `Set ${chainId === CHAIN_IDS.baseSepolia ? "BASE_SEPOLIA_RPC_URL" : "BASE_RPC_URL"} or pass --rpc.`,
      );
    }
    rpcUrl = envRpc;
    viemChain = vc;
  }

  const client = createPublicClient({ chain: viemChain, transport: http(rpcUrl) });

  // 1. Bytecode must be non-empty.
  const code: Hex = await client.getBytecode({ address: hookAddress }) ?? "0x";
  if (code === "0x" || code.length <= 2) {
    console.error(`FAIL: no bytecode at ${hookAddress}`);
    process.exit(1);
  }

  // 2. Read getHookPermissions() and compute the expected address mask.
  const perms = (await client.readContract({
    address: hookAddress,
    abi: GET_HOOK_PERMISSIONS_ABI,
    functionName: "getHookPermissions",
  })) as HookPermissions;

  const expectedMask = permissionsToAddressMask(perms);
  const actualMask = lowMaskOf(hookAddress);

  console.log(`hook        : ${hookAddress}`);
  console.log(`bytecode    : ${(code.length - 2) / 2} bytes`);
  console.log(`expected    : 0x${expectedMask.toString(16).padStart(4, "0")}`);
  console.log(`actual      : 0x${actualMask.toString(16).padStart(4, "0")}`);

  if (expectedMask !== actualMask) {
    console.error("FAIL: address bits do not match getHookPermissions().");
    for (const { flag, bit } of HOOK_FLAGS) {
      const expected = perms[flag];
      const actual = (actualMask & (1 << bit)) !== 0;
      if (expected !== actual) console.error(`  ${flag.padEnd(34)} expected=${expected} actual=${actual}`);
    }
    process.exit(1);
  }

  console.log("OK: hook permissions match address bits.");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
