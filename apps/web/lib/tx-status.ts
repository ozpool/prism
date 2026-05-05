import type {Address, Hex} from "viem";

/**
 * Discriminated union covering the full deposit / withdraw transaction
 * lifecycle. Each `kind` carries exactly the fields the UI needs at
 * that step — no shared optional bag — so the renderer pattern-matches
 * cleanly on `status.kind` without nullable-everything drift.
 *
 * Flow shape:
 *
 *   idle
 *     ↓ (user clicks submit)
 *   simulating              ← wagmi useSimulateContract
 *     ↓ (sim ok)
 *   awaiting-approval *     ← only if ERC-20 allowance < amount; one
 *                             entry per token that needs approving.
 *     ↓ (user signs)
 *   approving *
 *     ↓ (approval mined)
 *   awaiting-submit
 *     ↓ (user signs)
 *   submitting
 *     ↓ (tx broadcast)
 *   pending
 *     ↓ (receipt mined)
 *   confirmed | failed
 *
 *   * Withdraw skips both approval steps (it burns shares the user
 *     already owns).
 */
export type TxFlowStatus =
  | {kind: "idle"}
  | {kind: "simulating"}
  | {kind: "simulation-failed"; reason: string}
  | {kind: "awaiting-approval"; token: Address}
  | {kind: "approving"; token: Address; hash: Hex}
  | {kind: "awaiting-submit"}
  | {kind: "submitting"}
  | {kind: "pending"; hash: Hex}
  | {kind: "confirmed"; hash: Hex}
  | {kind: "failed"; reason: string; hash?: Hex};

/// True when the user has work to do — wallet prompt open or the form
/// should be locked because something is in flight.
export function isBusy(s: TxFlowStatus): boolean {
  switch (s.kind) {
    case "simulating":
    case "awaiting-approval":
    case "approving":
    case "awaiting-submit":
    case "submitting":
    case "pending":
      return true;
    case "idle":
    case "simulation-failed":
    case "confirmed":
    case "failed":
      return false;
  }
}

/// Human-readable label for the status banner.
export function statusLabel(s: TxFlowStatus): string {
  switch (s.kind) {
    case "idle":
      return "Ready";
    case "simulating":
      return "Simulating…";
    case "simulation-failed":
      return `Simulation failed — ${s.reason}`;
    case "awaiting-approval":
      return "Waiting for approval signature…";
    case "approving":
      return "Approving token…";
    case "awaiting-submit":
      return "Waiting for transaction signature…";
    case "submitting":
      return "Submitting transaction…";
    case "pending":
      return "Transaction pending…";
    case "confirmed":
      return "Transaction confirmed";
    case "failed":
      return `Transaction failed — ${s.reason}`;
  }
}
