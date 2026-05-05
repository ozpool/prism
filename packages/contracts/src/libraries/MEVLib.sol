// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Errors} from "../utils/Errors.sol";

/// @title MEVLib — price deviation + backrun decision (v1.1 stub)
/// @notice In v1.0 PRISM only *observes* MEV via `SwapObserved` events
///         emitted from `ProtocolHook.afterSwap`. There is no on-chain
///         backrun execution.
/// @dev    This library exists to lock in the math + decision shape that
///         v1.1 will use, so the v1.0 hook can already compute the same
///         deviation values and emit them in `SwapObserved` for off-chain
///         analytics. When v1.1 ships, the same numbers feed
///         `MEVLib.shouldBackrun(...)` and the hook gains a new branch.
///
///         The functions here are `pure` — no storage, no external calls.
///         All deviation math is in basis points (10_000 = 100%) using
///         `sqrtPriceX96` Q64.96 inputs, mirroring V4's PoolManager.
library MEVLib {
    /// @dev 10_000 basis points = 100%.
    uint256 internal constant BPS_DENOM = 10_000;

    /// @dev Default v1.1 backrun threshold in basis points. Below this,
    ///      a backrun is unlikely to clear gas + slippage. Subject to
    ///      revision in the v1.1 ADR.
    uint256 internal constant DEFAULT_BACKRUN_THRESHOLD_BPS = 50; // 0.50%

    /// @dev Hard cap — deviations above this almost always indicate a
    ///      stale oracle, sandbox glitch, or first-block-of-pool
    ///      condition where `sqrtPriceX96` jumps. Disable backrun.
    uint256 internal constant MAX_PLAUSIBLE_DEVIATION_BPS = 1000; // 10%

    /// @notice Absolute price deviation between pool and oracle in basis points.
    /// @dev    Both inputs are sqrtPriceX96 (Q64.96). Comparing sqrt-prices
    ///         directly avoids a square step and the precision loss that
    ///         comes with it. The basis-point ratio of two sqrt-prices
    ///         equals the basis-point ratio of two square-prices when the
    ///         deviation is small (< 10%), which is the only regime
    ///         where a backrun matters.
    /// @param  poolSqrtPriceX96   Current sqrtPriceX96 from PoolManager.
    /// @param  oracleSqrtPriceX96 Reference sqrtPriceX96 from
    ///                            ChainlinkAdapter (already converted from
    ///                            the `int256 answer` feed).
    /// @return bps                Absolute deviation in basis points.
    function deviationBps(uint160 poolSqrtPriceX96, uint160 oracleSqrtPriceX96) internal pure returns (uint256 bps) {
        if (oracleSqrtPriceX96 == 0) revert Errors.MathOverflow();

        uint256 pool = uint256(poolSqrtPriceX96);
        uint256 oracle = uint256(oracleSqrtPriceX96);

        unchecked {
            uint256 diff = pool > oracle ? pool - oracle : oracle - pool;
            // (diff * 10_000) is bounded: diff < 2^160, multiplier < 2^14,
            // so the product fits in 2^174 — well under uint256.
            bps = (diff * BPS_DENOM) / oracle;
        }
    }

    /// @notice v1.1 backrun decision (stub). v1.0 callers SHOULD pass the
    ///         result through to telemetry but MUST NOT execute backruns.
    /// @dev    Backrun makes sense when:
    ///           - oracle is healthy,
    ///           - pool drifted past `thresholdBps`, AND
    ///           - drift is below `MAX_PLAUSIBLE_DEVIATION_BPS` (else
    ///             likely a stale oracle / first-block edge case).
    ///         Returns `false` for v1.0 callers regardless — the v1.0
    ///         deployment never sets `oracleHealthy = true` for this
    ///         path because v1.0 hooks do not include a backrun branch.
    function shouldBackrun(
        bool oracleHealthy,
        uint256 currentDeviationBps,
        uint256 thresholdBps
    )
        internal
        pure
        returns (bool)
    {
        if (!oracleHealthy) return false;
        if (currentDeviationBps < thresholdBps) return false;
        if (currentDeviationBps >= MAX_PLAUSIBLE_DEVIATION_BPS) return false;
        return true;
    }
}
