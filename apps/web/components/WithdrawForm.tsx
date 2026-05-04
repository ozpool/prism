"use client";

import {useEffect, useMemo, useState} from "react";
import {formatUnits, parseUnits, zeroAddress, type Address, type Hex} from "viem";
import {useAccount, useReadContracts, useSimulateContract, useWaitForTransactionReceipt, useWriteContract} from "wagmi";

import {VaultAbi} from "@prism/shared";
import {classifyTxError} from "@/lib/tx-errors";
import {isBusy, statusLabel, type TxFlowStatus} from "@/lib/tx-status";

/// Vault shares are 18-decimal ERC-20s regardless of underlying tokens
/// (matches ERC-4626 convention). See `Vault.decimals()` in contracts.
const SHARE_DECIMALS = 18;

interface WithdrawFormProps {
  vaultAddress: Address;
  /// Token0 / token1 metadata — used only to label the expected-output
  /// hint. Withdraw itself takes no token-side approvals.
  token0Symbol: string;
  token0Decimals: number;
  token1Symbol: string;
  token1Decimals: number;
  /// Default slippage applied to the *expected* output amounts. 50 = 0.5%.
  defaultSlippageBps?: number;
}

/**
 * Withdraw form — burns vault shares and pays out a proportional slice
 * of every active position plus idle balance. No approvals needed
 * (burning shares the user already holds), so the state machine
 * collapses to: idle → simulating → awaiting-submit → pending →
 * confirmed | failed. Reuses the shared `TxFlowStatus` discriminated
 * union from the deposit form.
 *
 * Expected outputs are computed off-chain from `totalSupply` +
 * `getTotalAmounts`; slippage is applied to those estimates and
 * passed as `amount0Min` / `amount1Min` to the contract. The
 * pre-flight simulate is the canonical revert source, but the
 * estimate is what the user actually sees.
 */
export function WithdrawForm({
  vaultAddress,
  token0Symbol,
  token0Decimals,
  token1Symbol,
  token1Decimals,
  defaultSlippageBps = 50,
}: WithdrawFormProps) {
  const {address: account} = useAccount();

  const [sharesInput, setSharesInput] = useState("");
  const [slippageBps, setSlippageBps] = useState(defaultSlippageBps);
  const [status, setStatus] = useState<TxFlowStatus>({kind: "idle"});

  const placeholderVault = vaultAddress === zeroAddress;

  const shares = useMemo(() => parseAmountSafe(sharesInput, SHARE_DECIMALS), [sharesInput]);

  const {data: vaultReads, refetch: refetchVaultReads} = useReadContracts({
    contracts: account
      ? [
        {address: vaultAddress, abi: VaultAbi, functionName: "balanceOf", args: [account]},
        {address: vaultAddress, abi: VaultAbi, functionName: "totalSupply"},
        {address: vaultAddress, abi: VaultAbi, functionName: "getTotalAmounts"},
      ]
      : [],
    query: {enabled: !!account && !placeholderVault},
  });

  const shareBalance = (vaultReads?.[0]?.result as bigint | undefined) ?? 0n;
  const totalSupply = (vaultReads?.[1]?.result as bigint | undefined) ?? 0n;
  const totalAmounts = vaultReads?.[2]?.result as readonly [bigint, bigint] | undefined;
  const total0 = totalAmounts?.[0] ?? 0n;
  const total1 = totalAmounts?.[1] ?? 0n;

  const expected0 = totalSupply > 0n ? (shares * total0) / totalSupply : 0n;
  const expected1 = totalSupply > 0n ? (shares * total1) / totalSupply : 0n;

  const amount0Min = applySlippage(expected0, slippageBps);
  const amount1Min = applySlippage(expected1, slippageBps);

  const insufficient = shares > shareBalance;
  const inputsValid = shares > 0n && !insufficient && !!account;

  const simulate = useSimulateContract({
    address: vaultAddress,
    abi: VaultAbi,
    functionName: "withdraw",
    args: account ? [shares, amount0Min, amount1Min, account] : undefined,
    query: {enabled: inputsValid && !placeholderVault},
  });

  const {writeContractAsync, data: txHash} = useWriteContract();
  const txReceipt = useWaitForTransactionReceipt({hash: txHash});

  useEffect(() => {
    if (txReceipt.isSuccess && txHash) {
      setStatus({kind: "confirmed", hash: txHash});
      void refetchVaultReads();
    }
  }, [txReceipt.isSuccess, txHash, refetchVaultReads]);

  const submitDisabled =
    !inputsValid ||
    isBusy(status) ||
    simulate.status === "error" ||
    placeholderVault;

  async function onWithdraw() {
    if (!account || !inputsValid) return;

    setStatus({kind: "simulating"});
    if (simulate.status !== "success") {
      const reason = simulate.error?.message ?? "Simulation did not produce a request.";
      setStatus({kind: "simulation-failed", reason});
      return;
    }

    setStatus({kind: "awaiting-submit"});
    try {
      const hash = await writeContractAsync(simulate.data.request);
      setStatus({kind: "pending", hash});
    } catch (err) {
      const e = classifyTxError(err);
      setStatus({kind: "failed", reason: e.message});
    }
  }

  return (
    <section className="rounded-xl border border-border bg-surface p-5 shadow-card" aria-label="Withdraw">
      <h2 className="mb-4 text-base font-medium text-text">Withdraw</h2>

      <div className="flex flex-col gap-4">
        <SharesInput
          value={sharesInput}
          onChange={setSharesInput}
          balance={shareBalance}
          insufficient={insufficient}
          disabled={isBusy(status) || placeholderVault}
        />

        <ExpectedRow
          label={token0Symbol}
          amount={expected0}
          decimals={token0Decimals}
          minAmount={amount0Min}
        />
        <ExpectedRow
          label={token1Symbol}
          amount={expected1}
          decimals={token1Decimals}
          minAmount={amount1Min}
        />

        <SlippageRow value={slippageBps} onChange={setSlippageBps} disabled={isBusy(status)} />

        <button
          type="button"
          onClick={() => void onWithdraw()}
          disabled={submitDisabled}
          className="rounded-lg bg-accent px-4 py-3 text-sm font-medium text-canvas transition-base
                     hover:shadow-glow-violet disabled:cursor-not-allowed disabled:opacity-50
                     disabled:hover:shadow-none"
        >
          {placeholderVault
            ? "Vault not deployed"
            : !account
            ? "Connect wallet"
            : insufficient
            ? "Exceeds share balance"
            : shares === 0n
            ? "Enter share amount"
            : "Withdraw"}
        </button>

        <StatusBanner status={status} />
      </div>
    </section>
  );
}

function SharesInput({
  value,
  onChange,
  balance,
  insufficient,
  disabled,
}: {
  value: string;
  onChange: (v: string) => void;
  balance: bigint;
  insufficient: boolean;
  disabled?: boolean;
}) {
  const formattedBalance = formatUnits(balance, SHARE_DECIMALS);
  return (
    <label className="flex flex-col gap-1.5 text-sm">
      <span className="flex items-baseline justify-between text-text-muted">
        <span>Shares</span>
        <button
          type="button"
          onClick={() => onChange(formattedBalance)}
          disabled={disabled || balance === 0n}
          className="font-mono text-xs text-text-faint hover:text-text disabled:cursor-not-allowed
                     disabled:opacity-60"
        >
          balance {formattedBalance}
        </button>
      </span>
      <input
        type="text"
        inputMode="decimal"
        value={value}
        onChange={(e) => onChange(sanitizeAmount(e.target.value))}
        disabled={disabled}
        placeholder="0.0"
        className={`rounded-lg border bg-surface-raised px-3 py-2 font-mono text-base text-text
                    outline-none transition-base disabled:cursor-not-allowed disabled:opacity-60
                    ${insufficient ? "border-danger/60" : "border-border focus:border-border-strong"}`}
      />
      {insufficient ? <span className="text-xs text-danger">Exceeds share balance.</span> : null}
    </label>
  );
}

function ExpectedRow({
  label,
  amount,
  decimals,
  minAmount,
}: {
  label: string;
  amount: bigint;
  decimals: number;
  minAmount: bigint;
}) {
  return (
    <div className="flex items-baseline justify-between text-sm">
      <span className="text-text-muted">You receive ({label})</span>
      <span className="font-mono text-text" aria-label={`Expected ${label} output`}>
        {formatUnits(amount, decimals)}
        <span className="ml-2 text-xs text-text-faint">min {formatUnits(minAmount, decimals)}</span>
      </span>
    </div>
  );
}

function SlippageRow({
  value,
  onChange,
  disabled,
}: {
  value: number;
  onChange: (bps: number) => void;
  disabled?: boolean;
}) {
  const presets = [10, 50, 100] as const;
  return (
    <div className="flex items-center justify-between text-sm">
      <span className="text-text-muted">Max slippage</span>
      <div className="flex gap-1">
        {presets.map((p) => (
          <button
            key={p}
            type="button"
            onClick={() => onChange(p)}
            disabled={disabled}
            className={`rounded-md border px-2 py-1 font-mono text-xs transition-base
                        disabled:cursor-not-allowed disabled:opacity-60
                        ${value === p ? "border-accent bg-accent/10 text-accent" : "border-border text-text-muted"}`}
          >
            {(p / 100).toFixed(2)}%
          </button>
        ))}
      </div>
    </div>
  );
}

function StatusBanner({status}: {status: TxFlowStatus}) {
  if (status.kind === "idle") return null;

  const tone =
    status.kind === "confirmed"
      ? "border-success/40 bg-success/10 text-success"
      : status.kind === "failed" || status.kind === "simulation-failed"
      ? "border-danger/40 bg-danger/10 text-danger"
      : "border-border bg-surface-raised text-text-muted";

  const hash = "hash" in status ? status.hash : undefined;
  return (
    <div className={`rounded-lg border px-3 py-2 text-xs ${tone}`} role="status">
      <p>{statusLabel(status)}</p>
      {hash ? (
        <p className="mt-1 font-mono text-[11px] text-text-faint">{shortHash(hash)}</p>
      ) : null}
    </div>
  );
}

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

function sanitizeAmount(input: string): string {
  const cleaned = input.replace(/[^0-9.]/g, "");
  const firstDot = cleaned.indexOf(".");
  if (firstDot === -1) return cleaned;
  return cleaned.slice(0, firstDot + 1) + cleaned.slice(firstDot + 1).replace(/\./g, "");
}

function parseAmountSafe(value: string, decimals: number): bigint {
  if (!value || value === ".") return 0n;
  try {
    return parseUnits(value, decimals);
  } catch {
    return 0n;
  }
}

function applySlippage(amount: bigint, bps: number): bigint {
  if (amount === 0n) return 0n;
  return (amount * BigInt(10_000 - bps)) / 10_000n;
}

function shortHash(h: Hex): string {
  return `${h.slice(0, 10)}…${h.slice(-8)}`;
}
