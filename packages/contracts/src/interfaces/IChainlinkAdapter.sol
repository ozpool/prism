// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title PRISM oracle adapter interface
/// @notice Wraps a Chainlink price feed (and optional L2 sequencer
///         uptime feed) into the canonical fail-soft return shape that
///         ProtocolHook expects on the swap hot-path.
///
///         Per ADR-003 the adapter NEVER reverts on the swap path. Any
///         failure mode (sequencer down, stale round, negative answer,
///         math overflow) returns `(0, false)` and the hook degrades to
///         the safe path: dynamic fees still update via beforeSwap, but
///         MEV observation in afterSwap is skipped for that round.
interface IChainlinkAdapter {
    /// @notice Read the current oracle reference and report its health.
    /// @dev    Always view, always non-reverting. Implementers must
    ///         catch external-call failures and return `(0, false)`.
    /// @return sqrtPriceX96 V4 sqrt-price (Q64.96) implied by the feed,
    ///                     or `0` if the read was unhealthy.
    /// @return healthy     `true` iff the sequencer is up, the round is
    ///                     fresh, and the conversion did not overflow.
    function read() external view returns (uint160 sqrtPriceX96, bool healthy);
}
