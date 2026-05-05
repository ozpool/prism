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
  vaultFactory: "0xb99722fdff599c69f37c5f0bcd766139aae15677",
  protocolHook: "0xfab41b25620607718e0baec2fd8aa6c3540005c0",
  bellStrategy: "0x906071f25ddee5cda2825a529d570771229319fa",
  chainlinkAdapter: "0xed00475a2e74b0078b69e21b6b939506d0196e25",
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
