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
  vaultFactory: "0xc7971d8e0856f7e287968257352a5588bbf6c64c",
  protocolHook: "0x5f293d39afb11066b7018199865d973c240485c0",
  bellStrategy: "0x8621557ebc7cc5bbbb7254eca39fcc21fc9bd68c",
  chainlinkAdapter: "0x8ae80adfc0713c47e331418d1874ced8383a3ec1",
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
