#!/usr/bin/env node
// Post-deploy orchestrator. Reads the latest Foundry broadcast for
// `Deploy.s.sol` on a given chain, extracts the deployed contract
// addresses, writes them to `addresses.json` (operator-readable) and
// updates `packages/shared/src/addresses.ts` (typed app code), then
// runs `verify-hook.ts` against the deployed ProtocolHook.
//
// Run:
//   tsx scripts/post-deploy.ts --chain base-sepolia
//
// The Foundry broadcast file is written automatically by
// `forge script ... --broadcast` to:
//   packages/contracts/broadcast/Deploy.s.sol/<chainId>/run-latest.json

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, "..");

interface BroadcastTx {
  contractName?: string;
  contractAddress?: string;
  transactionType?: string;
}

interface BroadcastFile {
  transactions: BroadcastTx[];
}

interface ChainConfig {
  name: string;
  chainId: number;
  recordKey: "baseSepolia" | "base";
}

const CHAINS: Record<string, ChainConfig> = {
  "base-sepolia": { name: "base-sepolia", chainId: 84532, recordKey: "baseSepolia" },
  base: { name: "base", chainId: 8453, recordKey: "base" },
};

interface Deployed {
  vaultFactory: string;
  protocolHook: string;
  bellStrategy: string;
  chainlinkAdapter: string;
  poolManager: string;
}

function parseArgs(): { chain: string; poolManager: string | null; skipVerify: boolean } {
  const argv = process.argv.slice(2);
  let chain = "base-sepolia";
  let poolManager: string | null = null;
  let skipVerify = false;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--chain") chain = argv[++i] ?? chain;
    else if (a === "--pool-manager") poolManager = argv[++i] ?? null;
    else if (a === "--skip-verify") skipVerify = true;
  }
  return { chain, poolManager, skipVerify };
}

function extractAddresses(broadcastPath: string, poolManagerOverride: string | null): Deployed {
  const data = JSON.parse(readFileSync(broadcastPath, "utf8")) as BroadcastFile;
  const creates = data.transactions.filter((t) => t.transactionType === "CREATE" || t.transactionType === "CREATE2");

  const find = (name: string): string => {
    const tx = creates.find((t) => t.contractName === name);
    if (!tx?.contractAddress) {
      throw new Error(`No CREATE/CREATE2 transaction found for ${name} in ${broadcastPath}`);
    }
    return tx.contractAddress;
  };

  const poolManager =
    poolManagerOverride ?? process.env.POOL_MANAGER ?? "0x0000000000000000000000000000000000000000";

  return {
    bellStrategy: find("BellStrategy"),
    chainlinkAdapter: find("ChainlinkAdapter"),
    protocolHook: find("ProtocolHook"),
    vaultFactory: find("VaultFactory"),
    poolManager,
  };
}

function writeAddressesJson(chainId: number, deployed: Deployed) {
  const path = join(REPO_ROOT, "addresses.json");
  let existing: Record<string, Deployed> = {};
  if (existsSync(path)) {
    existing = JSON.parse(readFileSync(path, "utf8")) as Record<string, Deployed>;
  }
  existing[String(chainId)] = deployed;
  writeFileSync(path, JSON.stringify(existing, null, 2) + "\n", "utf8");
  console.log(`addresses.json updated for chainId=${chainId}`);
}

function updateSharedAddressesTs(recordKey: "baseSepolia" | "base", deployed: Deployed) {
  const path = join(REPO_ROOT, "packages", "shared", "src", "addresses.ts");
  const src = readFileSync(path, "utf8");

  const block = `const ${recordKey.toUpperCase()}: DeploymentAddresses = {
  vaultFactory: "${deployed.vaultFactory}",
  protocolHook: "${deployed.protocolHook}",
  bellStrategy: "${deployed.bellStrategy}",
  chainlinkAdapter: "${deployed.chainlinkAdapter}",
  poolManager: "${deployed.poolManager}",
};`;

  // Re-emit the file with a deployed block above ADDRESSES, replacing
  // any prior emitted block for this chain. We mark our blocks with
  // a sentinel comment so they can be cleanly re-rewritten.
  const sentinelStart = `// <<deployed-${recordKey}>>`;
  const sentinelEnd = `// <</deployed-${recordKey}>>`;
  const replacement = `${sentinelStart}\n${block}\n${sentinelEnd}`;

  let next: string;
  if (src.includes(sentinelStart)) {
    next = src.replace(new RegExp(`${sentinelStart}[\\s\\S]*?${sentinelEnd}`), replacement);
  } else {
    next = src.replace("export const ADDRESSES", `${replacement}\n\nexport const ADDRESSES`);
  }

  // Swap the placeholder reference for the deployed reference.
  const placeholderRef = `[CHAIN_IDS.${recordKey}]: PLACEHOLDER`;
  const deployedRef = `[CHAIN_IDS.${recordKey}]: ${recordKey.toUpperCase()}`;
  if (next.includes(placeholderRef)) {
    next = next.replace(placeholderRef, deployedRef);
  } else {
    // Already pointed at deployed, or undefined. Only flip from
    // undefined to deployed for base if the user explicitly deploys.
    next = next.replace(`[CHAIN_IDS.${recordKey}]: undefined`, deployedRef);
  }

  writeFileSync(path, next, "utf8");
  console.log(`packages/shared/src/addresses.ts updated for ${recordKey}`);
}

function main() {
  const { chain, poolManager, skipVerify } = parseArgs();
  const cfg = CHAINS[chain];
  if (!cfg) throw new Error(`Unsupported chain '${chain}'. Use 'base-sepolia' or 'base'.`);

  const broadcastPath = join(
    REPO_ROOT,
    "packages",
    "contracts",
    "broadcast",
    "Deploy.s.sol",
    String(cfg.chainId),
    "run-latest.json",
  );
  if (!existsSync(broadcastPath)) {
    throw new Error(
      `Broadcast file not found at ${broadcastPath}. Run \`forge script Deploy --broadcast --rpc-url <chain>\` first.`,
    );
  }

  const deployed = extractAddresses(broadcastPath, poolManager);
  console.log("Deployed addresses:");
  for (const [k, v] of Object.entries(deployed)) console.log(`  ${k.padEnd(18)} ${v}`);

  writeAddressesJson(cfg.chainId, deployed);
  updateSharedAddressesTs(cfg.recordKey, deployed);

  if (!skipVerify) {
    console.log("\nRunning verify-hook.ts...");
    execFileSync("tsx", [join(REPO_ROOT, "scripts", "verify-hook.ts"), "--chain", cfg.name], {
      stdio: "inherit",
    });
  }

  console.log("\nPost-deploy complete.");
}

try {
  main();
} catch (err) {
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
}
