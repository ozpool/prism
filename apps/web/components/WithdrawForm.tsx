"use client";

import {useEffect, useMemo, useState} from "react";
import {erc20Abi, formatUnits, parseUnits, zeroAddress, type Address, type Hex} from "viem";
import {
  useAccount,
  useReadContracts,
  useSimulateContract,
  useWaitForTransactionReceipt,
  useWriteContract,
} from "wagmi";

import {VaultAbi} from "@prism/shared";
import {classifyTxError} from "@/lib/tx-errors";
import {isBusy, statusLabel, type TxFlowStatus} from "@/lib/tx-status";

interface WithdrawFormProps {
  vaultAddress: Address;
  /// Symbol for token0 (display only; preview reads decimals from the
  /// token contract via balance reads on the vault's `getTotalAmounts`).
  token0Symbol: string;
  token1Symbol: string;
  token0Decimals: number;
  token1Decimals: number;
  /// Default slippage as basis points. 50 = 0.5%.
  defaultSlippageBps?: number;
}

/**
 * Withdraw form for a PRISM vault. Single input (shares), proportional
 * preview of expected token outputs, atomic burn. Per invariant 6 the
 * vault never pauses withdrawals — this form is reachable in every
 * vault state for the lifetime of the contract.
 *
 * Preview math (client-side):
 *
 *   amount{0,1}_out = total{0,1} * shares / totalSupply
 *
 * `total{0,1}` come from `vault.getTotalAmounts()`. The on-chain math
 * may differ in dust as positions are removed proportionally; we apply
 * the user's slippage tolerance to the previewed values to bound the
 * acceptable output.
 */
export function WithdrawForm({
  vaultAddress,
  token0Symbol,
  token1Symbol,
  token0Decimals,
  token1Decimals,
  defaultSlippageBps = 50,
}: WithdrawFormProps) {
  const {address: account} = useAccount();

  const [sharesInput, setSharesInput] = useState("");
  const [slippageBps, setSlippageBps] = useState(defaultSlippageBps);
  const [status, setStatus] = useState<TxFlowStatus>({kind: "idle"});

  const placeholderVault = vaultAddress === zeroAddress;

  // Vault shares are 18-decimal ERC-20.
  const sharesDesired = useMemo(() => parseAmountSafe(sharesInput, 18), [sharesInput]);

  // Read user share balance + vault supply + total amounts in one batch.
  const {data: vaultReads, refetch: refetchReads} = useReadContracts({
    contracts: account
      ? [
        {address: vaultAddress, abi: erc20Abi, functionName: "balanceOf", args: [account]},
        {address: vaultAddress, abi: erc20Abi, functionName: "totalSupply"},
        {address: vaultAddress, abi: VaultAbi, functionName: "getTotalAmounts"},
      ]
      : [],
    query: {enabled: !!account && !placeholderVault},
  });

  const userShares = (vaultReads?.[0]?.result as bigint | undefined) ?? 0n;
  const totalSupply = (vaultReads?.[1]?.result as bigint | undefined) ?? 0n;
  const totals = vaultReads?.[2]?.result as readonly [bigint, bigint] | undefined;
  const total0 = totals?.[0] ?? 0n;
  const total1 = totals?.[1] ?? 0n;

  const insufficient = sharesDesired > userShares;

  // Preview proportional outputs. Guarded against div-by-zero when the
  // vault is empty.
  const previewAmount0 = totalSupply === 0n ? 0n : (total0 * sharesDesired) / totalSupply;
  const previewAmount1 = totalSupply === 0n ? 0n : (total1 * sharesDesired) / totalSupply;

  const amount0Min = applySlippage(previewAmount0, slippageBps);
  const amount1Min = applySlippage(previewAmount1, slippageBps);

  const inputsValid = sharesDesired > 0n && !!account && !insufficient;

  const simulate = useSimulateContract({
    address: vaultAddress,
    abi: VaultAbi,
    functionName: "withdraw",
    args: account ? [sharesDesired, amount0Min, amount1Min, account] : undefined,
    query: {enabled: inputsValid && !placeholderVault},
  });

  const {writeContractAsync: writeWithdraw, data: withdrawHash} = useWriteContract();
  const withdrawReceipt = useWaitForTransactionReceipt({hash: withdrawHash});

  useEffect(() => {
    if (withdrawReceipt.isSuccess && withdrawHash) {
      setStatus({kind: "confirmed", hash: withdrawHash});
      void refetchReads();
      setSharesInput("");
    }
  }, [withdrawReceipt.isSuccess, withdrawHash, refetchReads]);

  const submitDisabled =
    !inputsValid ||
    isBusy(status) ||
    simulate.status === "error" ||
    placeholderVault;

  async function onWithdraw() {
    if (!account) return;
    setStatus({kind: "simulating"});
    if (simulate.status !== "success") {
      const reason = simulate.error?.message ?? "Simulation did not produce a request.";
      setStatus({kind: "simulation-failed", reason});
      return;
    }
    setStatus({kind: "awaiting-submit"});
    try {
      const hash = await writeWithdraw(simulate.data.request);
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
          balance={userShares}
          insufficient={insufficient}
          disabled={isBusy(status) || placeholderVault}
        />

        <Preview
          token0Symbol={token0Symbol}
          token1Symbol={token1Symbol}
          token0Decimals={token0Decimals}
          token1Decimals={token1Decimals}
          amount0={previewAmount0}
          amount1={previewAmount1}
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
            : sharesDesired === 0n
            ? "Enter shares"
            : insufficient
            ? "Insufficient shares"
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
  const formattedBalance = formatUnits(balance, 18);
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
      {insufficient ? <span className="text-xs text-danger">Exceeds your share balance.</span> : null}
    </label>
  );
}

function Preview({
  token0Symbol,
  token1Symbol,
  token0Decimals,
  token1Decimals,
  amount0,
  amount1,
}: {
  token0Symbol: string;
  token1Symbol: string;
  token0Decimals: number;
  token1Decimals: number;
  amount0: bigint;
  amount1: bigint;
}) {
  return (
    <div className="rounded-lg border border-border bg-surface-raised px-3 py-2 text-xs">
      <p className="text-text-muted">You will receive</p>
      <p className="mt-1 flex items-baseline justify-between font-mono text-text">
        <span>{formatPreview(amount0, token0Decimals)}</span>
        <span className="text-text-muted">{token0Symbol}</span>
      </p>
      <p className="flex items-baseline justify-between font-mono text-text">
        <span>{formatPreview(amount1, token1Decimals)}</span>
        <span className="text-text-muted">{token1Symbol}</span>
      </p>
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
      <span className="text-text-muted">Min received</span>
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
      {hash ? <p className="mt-1 font-mono text-[11px] text-text-faint">{shortHash(hash)}</p> : null}
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

function formatPreview(amount: bigint, decimals: number): string {
  if (amount === 0n) return "0.0";
  const formatted = formatUnits(amount, decimals);
  // Trim to 6 fractional digits for display.
  const dot = formatted.indexOf(".");
  if (dot === -1) return formatted;
  return formatted.slice(0, dot + 7);
}

function shortHash(h: Hex): string {
  return `${h.slice(0, 10)}…${h.slice(-8)}`;
}
