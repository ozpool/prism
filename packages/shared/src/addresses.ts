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

// <<deployed-baseSepolia>>
const BASESEPOLIA: DeploymentAddresses = {
  vaultFactory: "0x589dfb3dade3c379d38654063d5d8e85e15e39e5",
  protocolHook: "0xe450c5128a5e7d42250a870a7df044902cee85c0",
  bellStrategy: "0xfa60db53c04ca4add6c0cd0df1e8b6ba97d769ce",
  chainlinkAdapter: "0x80466dd3dbe7a2e6910ea6522465adcb75fe2c35",
  poolManager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
};
// <</deployed-baseSepolia>>

export const ADDRESSES: Record<SupportedChainId, DeploymentAddresses | undefined> = {
  [CHAIN_IDS.baseSepolia]: BASESEPOLIA,
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
