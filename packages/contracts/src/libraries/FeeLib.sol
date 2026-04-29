// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title FeeLib
/// @notice EWMA-based volatility estimator and dynamic-fee formula
///         consumed by `ProtocolHook.beforeSwap` to override the swap
///         fee on every swap through a PRISM pool.
/// @dev Tick deltas between successive swaps drive a short-window and a
///      long-window EWMA of squared tick movement (a proxy for
///      variance). The dynamic fee scales with the ratio
///      `ewmaShort / ewmaLong` — when short-term volatility outpaces
///      the long-term baseline, fees rise; when it lags, fees fall.
///      Output is clamped to `[MIN_FEE, MAX_FEE]`.
///
///      Gas budget: PRD §Day 4 caps `beforeSwap` at 12k gas. The
///      `update` function performs:
///        - 4 SLOADs (lastTick, lastTimestamp, ewmaShort, ewmaLong),
///        - O(10) arithmetic ops in pure-EVM math,
///        - 4 SSTOREs (warm storage on subsequent swaps).
///      `calculate` is `view` and pure arithmetic — no storage writes.
///      Combined hot-path overhead under 10k gas after the first swap;
///      the first swap on a pool pays the SSTORE-init cost (~22k for
///      4 zero→nonzero slots) but happens once per pool's lifetime.
///
///      Pure library — `update` mutates a caller-supplied storage
///      pointer; the library has no storage of its own.
library FeeLib {
    /// @notice Lower bound on the dynamic fee (1 bp = 100 pip in V4
    ///         ABI; minimum here = 0.01%).
    uint24 internal constant MIN_FEE = 100;

    /// @notice Upper bound on the dynamic fee (10%).
    uint24 internal constant MAX_FEE = 100_000;

    /// @notice Baseline fee — equal to V3's standard 0.30% pool tier.
    uint24 internal constant BASE_FEE = 3000;

    /// @notice Fixed-point precision for EWMA arithmetic (1e18).
    uint256 internal constant PRECISION = 1e18;

    /// @notice Smoothing parameter for the short-window EWMA. Half-life
    ///         ≈ 20 swaps. Higher α = faster reaction.
    uint256 internal constant SHORT_ALPHA = 5e16; // 0.05

    /// @notice Smoothing parameter for the long-window EWMA. Half-life
    ///         ≈ 200 swaps; provides the slowly-moving variance baseline
    ///         the short window is compared against.
    uint256 internal constant LONG_ALPHA = 5e15; // 0.005

    /// @notice Per-pool volatility state. Held by the hook keyed by
    ///         `PoolId` (one struct per pool).
    /// @param lastTick Pool tick observed at the previous swap.
    /// @param lastTimestamp `block.timestamp` of the previous swap;
    ///        emitted for analytics, not consumed by the math.
    /// @param ewmaShort Short-window EWMA of squared tick deltas
    ///        (Q-style 18-decimal fixed point).
    /// @param ewmaLong Long-window EWMA — the slow baseline.
    struct VolatilityState {
        int24 lastTick;
        uint256 lastTimestamp;
        uint256 ewmaShort;
        uint256 ewmaLong;
    }

    /// @notice Update both EWMAs given the current pool tick.
    /// @dev Squared-delta calculation is unchecked-safe: max
    ///      `|currentTick - lastTick|` is `MAX_TICK - MIN_TICK ≈ 1.77e6`,
    ///      so `dt * dt ≤ 3.14e12`; multiplied by `PRECISION (1e18)` and
    ///      then by `SHORT_ALPHA (5e16)` keeps the largest intermediate
    ///      product below 2^256 with billions of headroom. Solidity 0.8
    ///      checked math is left enabled for defence-in-depth — the
    ///      cost is a few hundred gas, well within budget.
    /// @param s Storage reference to the pool's volatility state.
    /// @param currentTick The pool's tick *after* the swap that
    ///        triggered this update.
    function update(VolatilityState storage s, int24 currentTick) internal {
        int256 dt = int256(currentTick) - int256(s.lastTick);
        uint256 sqr = uint256(dt * dt) * PRECISION;

        s.ewmaShort = (SHORT_ALPHA * sqr + (PRECISION - SHORT_ALPHA) * s.ewmaShort) / PRECISION;
        s.ewmaLong = (LONG_ALPHA * sqr + (PRECISION - LONG_ALPHA) * s.ewmaLong) / PRECISION;
        s.lastTick = currentTick;
        s.lastTimestamp = block.timestamp;
    }

    /// @notice Compute the dynamic fee for the next swap from the
    ///         current EWMA state.
    /// @dev Formula: `fee = BASE_FEE * (ewmaShort / ewmaLong)`, clamped
    ///      to `[MIN_FEE, MAX_FEE]`. When `ewmaLong == 0` (cold state,
    ///      no prior swap recorded), returns `BASE_FEE` so the very
    ///      first swap pays the V3-equivalent.
    /// @param s Storage reference to the pool's volatility state.
    /// @return fee Dynamic fee in pip (1e-6 units; 3_000 = 0.30%).
    function calculate(VolatilityState storage s) internal view returns (uint24 fee) {
        if (s.ewmaLong == 0) return BASE_FEE;

        uint256 ratio = s.ewmaShort * PRECISION / s.ewmaLong;
        uint256 raw = uint256(BASE_FEE) * ratio / PRECISION;

        if (raw < MIN_FEE) return MIN_FEE;
        if (raw > MAX_FEE) return MAX_FEE;
        return uint24(raw);
    }
}
