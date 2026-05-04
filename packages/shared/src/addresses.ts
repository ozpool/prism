import type { Address } from "viem";

export const CHAIN_IDS = {
  baseSepolia: 84_532,
  base: 8_453,
} as const satisfies Record<string, number>;

export type SupportedChainId = (typeof CHAIN_IDS)[keyof typeof CHAIN_IDS];

export interface DeploymentAddresses {
  vaultFactory: Address;
  protocolHook: Address;
  bellStrategy: Address;
  chainlinkAdapter: Address;
  poolManager: Address;
}

const ZERO: Address = "0x0000000000000000000000000000000000000000";

const PLACEHOLDER: DeploymentAddresses = {
  vaultFactory: ZERO,
  protocolHook: ZERO,
  bellStrategy: ZERO,
  chainlinkAdapter: ZERO,
  poolManager: ZERO,
};

export const ADDRESSES: Record<SupportedChainId, DeploymentAddresses | undefined> = {
  [CHAIN_IDS.baseSepolia]: PLACEHOLDER,
  // Mainnet deployment is gated on M5 audit completion. See ADR-006.
  [CHAIN_IDS.base]: undefined,
};

export function getAddresses(chainId: number): DeploymentAddresses | undefined {
  if (chainId !== CHAIN_IDS.baseSepolia && chainId !== CHAIN_IDS.base) {
    return undefined;
  }
  return ADDRESSES[chainId as SupportedChainId];
}

export function isSupportedChain(chainId: number): chainId is SupportedChainId {
  return chainId === CHAIN_IDS.baseSepolia || chainId === CHAIN_IDS.base;
}
