import {getDefaultConfig} from "@rainbow-me/rainbowkit";
import {http} from "viem";
import {baseSepolia} from "viem/chains";

/**
 * wagmi config — Base Sepolia only in v1.0 (chain id 84532).
 *
 * Mainnet (Base, chain id 8453) ships post-audit and is intentionally
 * excluded here so a user with mainnet selected gets a clear "wrong
 * network" prompt instead of attempting to interact with non-existent
 * contracts.
 *
 * `walletConnectProjectId` is read from `NEXT_PUBLIC_WC_PROJECT_ID` at
 * build time. The placeholder fallback keeps the bundle building in
 * environments that have not been provisioned yet (CI smoke tests),
 * but RainbowKit will warn at runtime if the placeholder is used.
 */
export const wagmiConfig = getDefaultConfig({
  appName: "PRISM",
  projectId: process.env.NEXT_PUBLIC_WC_PROJECT_ID ?? "PRISM_DEV_PLACEHOLDER",
  chains: [baseSepolia],
  transports: {
    [baseSepolia.id]: http(process.env.NEXT_PUBLIC_BASE_SEPOLIA_RPC_URL),
  },
  ssr: true,
});
