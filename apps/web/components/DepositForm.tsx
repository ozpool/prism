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

export interface DepositFormToken {
  address: Address;
  symbol: string;
  decimals: number;
}

interface DepositFormProps {
  vaultAddress: Address;
  token0: DepositFormToken;
  token1: DepositFormToken;
  /// Default slippage as basis points. 50 = 0.5%.
  defaultSlippageBps?: number;
}

/**
 * Deposit form for a PRISM vault. Walks the user through:
 *   1. Approve token0 (if allowance < amount0Desired)
 *   2. Approve token1 (if allowance < amount1Desired)
 *   3. Deposit
 *
 * State machine in `status: TxFlowStatus` — see `lib/tx-status.ts`.
 *
 * The simulate hook runs whenever inputs are valid and both allowances
 * cover the desired amounts; its return value drives the submit
 * button's enabled state and surfaces revert reasons before the user
 * pays gas.
 */
export function DepositForm({vaultAddress, token0, token1, defaultSlippageBps = 50}: DepositFormProps) {
  const {address: account, chainId} = useAccount();

  const [amount0, setAmount0] = useState("");
  const [amount1, setAmount1] = useState("");
  const [slippageBps, setSlippageBps] = useState(defaultSlippageBps);
  const [status, setStatus] = useState<TxFlowStatus>({kind: "idle"});

  const placeholderVault = vaultAddress === zeroAddress;

  const amount0Desired = useMemo(
    () => parseAmountSafe(amount0, token0.decimals),
    [amount0, token0.decimals],
  );
  const amount1Desired = useMemo(
    () => parseAmountSafe(amount1, token1.decimals),
    [amount1, token1.decimals],
  );

  const inputsValid = (amount0Desired > 0n || amount1Desired > 0n) && !!account;

  // Read balances + allowances for both tokens in one batch.
  const {data: tokenReads, refetch: refetchTokenReads} = useReadContracts({
    contracts: account
      ? [
        {
          address: token0.address,
          abi: erc20Abi,
          functionName: "balanceOf",
          args: [account],
        },
        {
          address: token0.address,
          abi: erc20Abi,
          functionName: "allowance",
          args: [account, vaultAddress],
        },
        {
          address: token1.address,
          abi: erc20Abi,
          functionName: "balanceOf",
          args: [account],
        },
        {
          address: token1.address,
          abi: erc20Abi,
          functionName: "allowance",
          args: [account, vaultAddress],
        },
      ]
      : [],
    query: {enabled: !!account && !placeholderVault},
  });

  const balance0 = (tokenReads?.[0]?.result as bigint | undefined) ?? 0n;
  const allowance0 = (tokenReads?.[1]?.result as bigint | undefined) ?? 0n;
  const balance1 = (tokenReads?.[2]?.result as bigint | undefined) ?? 0n;
  const allowance1 = (tokenReads?.[3]?.result as bigint | undefined) ?? 0n;

  const needsApproval0 = amount0Desired > allowance0 && amount0Desired > 0n;
  const needsApproval1 = amount1Desired > allowance1 && amount1Desired > 0n;
  const allowancesOk = !needsApproval0 && !needsApproval1;

  // Pre-flight simulate with min=0,0 to discover what the strategy
  // actually consumes. PRISM only consumes 30–60% of desired by
  // design; the contract checks slippage against `amount0Used`, not
  // `amount0Desired`, so naïve min = 0.995 * desired rejects every
  // valid deposit. Re-derive min from the simulated used amounts at
  // submit time below.
  const simulate = useSimulateContract({
    address: vaultAddress,
    abi: VaultAbi,
    functionName: "deposit",
    args: account
      ? [amount0Desired, amount1Desired, 0n, 0n, account]
      : undefined,
    query: {enabled: inputsValid && allowancesOk && !placeholderVault},
  });

  // Vault.deposit returns (shares, amount0Used, amount1Used).
  const simulatedResult = simulate.data?.result as readonly [bigint, bigint, bigint] | undefined;
  const amount0Used = simulatedResult?.[1] ?? 0n;
  const amount1Used = simulatedResult?.[2] ?? 0n;
  const amount0Min = applySlippage(amount0Used, slippageBps);
  const amount1Min = applySlippage(amount1Used, slippageBps);

  // Fire-and-watch pattern: use the non-async writeContract (returns void)
  // and watch the `data: hash` field for the broadcast hash. The async
  // variant of useWriteContract has been observed to leave the promise
  // unresolved after MetaMask actually signs + broadcasts, leaving the
  // form stuck in "awaiting-submit" forever. Watching the hash + receipt
  // bypasses that path entirely.
  const {
    writeContract: writeApprove,
    data: approveHash,
    error: approveError,
    reset: resetApprove,
  } = useWriteContract();
  const {
    writeContract: writeDeposit,
    data: depositHash,
    error: depositError,
    reset: resetDeposit,
  } = useWriteContract();

  const approveReceipt = useWaitForTransactionReceipt({hash: approveHash});
  const depositReceipt = useWaitForTransactionReceipt({hash: depositHash});

  // Approve broadcast → "approving"; receipt → re-read allowances + advance.
  useEffect(() => {
    if (approveHash) setStatus({kind: "approving", token: token0.address, hash: approveHash});
  }, [approveHash, token0.address]);

  useEffect(() => {
    if (approveReceipt.isSuccess) {
      void refetchTokenReads();
      setStatus({kind: "awaiting-submit"});
      resetApprove();
    }
  }, [approveReceipt.isSuccess, refetchTokenReads, resetApprove]);

  // Deposit broadcast → "pending"; receipt → "confirmed".
  useEffect(() => {
    if (depositHash) setStatus({kind: "pending", hash: depositHash});
  }, [depositHash]);

  useEffect(() => {
    if (depositReceipt.isSuccess && depositHash) {
      setStatus({kind: "confirmed", hash: depositHash});
      void refetchTokenReads();
    }
  }, [depositReceipt.isSuccess, depositHash, refetchTokenReads]);

  // Surface wallet rejections / RPC errors back into the form.
  useEffect(() => {
    if (approveError) setStatus({kind: "failed", reason: classifyTxError(approveError).message});
  }, [approveError]);

  useEffect(() => {
    if (depositError) setStatus({kind: "failed", reason: classifyTxError(depositError).message});
  }, [depositError]);

  const insufficient0 = amount0Desired > balance0;
  const insufficient1 = amount1Desired > balance1;
  const insufficientBalance = insufficient0 || insufficient1;

  const submitDisabled =
    !inputsValid ||
    isBusy(status) ||
    insufficientBalance ||
    (allowancesOk && simulate.status === "error") ||
    placeholderVault;

  function onApprove(token: DepositFormToken, amount: bigint) {
    setStatus({kind: "awaiting-approval", token: token.address});
    writeApprove({
      address: token.address,
      abi: erc20Abi,
      functionName: "approve",
      args: [vaultAddress, amount],
    });
  }

  function onDeposit() {
    if (!account) return;

    if (needsApproval0) {
      onApprove(token0, amount0Desired);
      return;
    }
    if (needsApproval1) {
      onApprove(token1, amount1Desired);
      return;
    }

    if (simulate.status !== "success") {
      const reason = simulate.error?.message ?? "Simulation did not produce a request.";
      setStatus({kind: "simulation-failed", reason});
      return;
    }

    setStatus({kind: "awaiting-submit"});
    resetDeposit();
    // Submit with min derived from simulated `amount0Used` / `amount1Used`,
    // not the simulate's request (which carries min=0,0). This is the
    // actual slippage protection.
    writeDeposit({
      address: vaultAddress,
      abi: VaultAbi,
      functionName: "deposit",
      args: [amount0Desired, amount1Desired, amount0Min, amount1Min, account],
    });
  }

  return (
    <section className="rounded-xl border border-border bg-surface p-5 shadow-card" aria-label="Deposit">
      <h2 className="mb-4 text-base font-medium text-text">Deposit</h2>

      <div className="flex flex-col gap-4">
        <AmountInput
          label={token0.symbol}
          value={amount0}
          onChange={setAmount0}
          balance={balance0}
          decimals={token0.decimals}
          insufficient={insufficient0}
          disabled={isBusy(status) || placeholderVault}
        />
        <AmountInput
          label={token1.symbol}
          value={amount1}
          onChange={setAmount1}
          balance={balance1}
          decimals={token1.decimals}
          insufficient={insufficient1}
          disabled={isBusy(status) || placeholderVault}
        />

        {simulate.status === "success" && (amount0Used > 0n || amount1Used > 0n) ? (
          <UsagePreview
            token0={token0}
            token1={token1}
            amount0Desired={amount0Desired}
            amount1Desired={amount1Desired}
            amount0Used={amount0Used}
            amount1Used={amount1Used}
          />
        ) : null}

        <SlippageRow value={slippageBps} onChange={setSlippageBps} disabled={isBusy(status)} />

        <button
          type="button"
          onClick={onDeposit}
          disabled={submitDisabled}
          className="rounded-lg bg-accent px-4 py-3 text-sm font-medium text-canvas transition-base
                     hover:shadow-glow-violet disabled:cursor-not-allowed disabled:opacity-50
                     disabled:hover:shadow-none"
        >
          {placeholderVault
            ? "Vault not deployed"
            : !account
            ? "Connect wallet"
            : insufficientBalance
            ? "Insufficient balance"
            : needsApproval0
            ? `Approve ${token0.symbol}`
            : needsApproval1
            ? `Approve ${token1.symbol}`
            : "Deposit"}
        </button>

        <StatusBanner status={status} />
      </div>
    </section>
  );
}

function AmountInput({
  label,
  value,
  onChange,
  balance,
  decimals,
  insufficient,
  disabled,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
  balance: bigint;
  decimals: number;
  insufficient: boolean;
  disabled?: boolean;
}) {
  const formattedBalance = formatUnits(balance, decimals);
  return (
    <label className="flex flex-col gap-1.5 text-sm">
      <span className="flex items-baseline justify-between text-text-muted">
        <span>{label}</span>
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
      {insufficient ? (
        <span className="text-xs text-danger">Exceeds balance.</span>
      ) : null}
    </label>
  );
}

function UsagePreview({
  token0,
  token1,
  amount0Desired,
  amount1Desired,
  amount0Used,
  amount1Used,
}: {
  token0: DepositFormToken;
  token1: DepositFormToken;
  amount0Desired: bigint;
  amount1Desired: bigint;
  amount0Used: bigint;
  amount1Used: bigint;
}) {
  const refund0 = amount0Desired > amount0Used ? amount0Desired - amount0Used : 0n;
  const refund1 = amount1Desired > amount1Used ? amount1Desired - amount1Used : 0n;
  return (
    <div className="rounded-lg border border-border bg-surface-raised px-3 py-2 text-xs text-text-muted">
      <div className="mb-1 flex items-center justify-between">
        <span>Will be deployed</span>
        <span className="font-mono text-text">
          {formatUnits(amount0Used, token0.decimals)} {token0.symbol}
          {" + "}
          {formatUnits(amount1Used, token1.decimals)} {token1.symbol}
        </span>
      </div>
      {(refund0 > 0n || refund1 > 0n) ? (
        <div className="flex items-center justify-between text-text-faint">
          <span>Refund</span>
          <span className="font-mono">
            {formatUnits(refund0, token0.decimals)} {token0.symbol}
            {" + "}
            {formatUnits(refund1, token1.decimals)} {token1.symbol}
          </span>
        </div>
      ) : null}
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
  const presets = [10, 50, 100] as const; // 0.1%, 0.5%, 1%
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
  // Allow only digits and a single decimal point.
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
  // floor((amount * (10_000 - bps)) / 10_000)
  return (amount * BigInt(10_000 - bps)) / 10_000n;
}

function shortHash(h: Hex): string {
  return `${h.slice(0, 10)}…${h.slice(-8)}`;
}
