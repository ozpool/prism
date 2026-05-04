import {BaseError, UserRejectedRequestError} from "viem";

export type TxError =
  | {kind: "rejected"; message: string}
  | {kind: "insufficient-funds"; message: string}
  | {kind: "wrong-network"; message: string}
  | {kind: "rpc"; message: string}
  | {kind: "unknown"; message: string};

const INSUFFICIENT_FUNDS_RE = /insufficient (funds|balance)/i;
const WRONG_NETWORK_RE = /chain.*mismatch|unsupported chain|wrong network/i;

export function classifyTxError(err: unknown): TxError {
  if (err instanceof UserRejectedRequestError) {
    return {kind: "rejected", message: "Transaction was rejected in your wallet."};
  }

  if (err instanceof BaseError) {
    const walked = err.walk((e) => e instanceof UserRejectedRequestError);
    if (walked instanceof UserRejectedRequestError) {
      return {kind: "rejected", message: "Transaction was rejected in your wallet."};
    }

    const shortMsg = err.shortMessage ?? err.message;
    if (INSUFFICIENT_FUNDS_RE.test(shortMsg)) {
      return {kind: "insufficient-funds", message: shortMsg};
    }
    if (WRONG_NETWORK_RE.test(shortMsg)) {
      return {kind: "wrong-network", message: shortMsg};
    }
    return {kind: "rpc", message: shortMsg};
  }

  if (err instanceof Error) {
    return {kind: "unknown", message: err.message};
  }

  return {kind: "unknown", message: "An unexpected error occurred."};
}
