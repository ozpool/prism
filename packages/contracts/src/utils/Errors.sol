// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title PRISM error library
/// @notice Centralised custom errors for every PRISM contract.
/// @dev Custom errors emit a 4-byte selector + ABI-encoded args (~200 gas)
///      versus 2,000+ gas for revert strings. All state-mutating PRISM
///      contracts revert through this library and never with strings.
///
///      Errors are grouped by domain (access control, vault, strategy,
///      hook, oracle, callback, generic). Adding a new error requires
///      updating this library; downstream contracts import the library
///      and call e.g. `revert Errors.SlippageExceeded(...);`.
///
///      Selector stability matters — third parties index reverts by
///      selector. The selector regression test in
///      `test/utils/Errors.t.sol` snapshots every selector. Changing an
///      error's signature is a breaking change.
library Errors {
    // -------------------------------------------------------------------------
    // Access control
    // -------------------------------------------------------------------------

    /// @notice Caller is not the contract owner.
    error OnlyOwner();

    /// @notice Caller is not the configured keeper.
    error OnlyKeeper();

    /// @notice Caller is not the canonical Uniswap V4 PoolManager.
    /// @dev Guards every IHooks callback and every IUnlockCallback entry.
    error OnlyPoolManager();

    /// @notice Constructor or setter received the zero address where a
    ///         non-zero address is required.
    error ZeroAddress();

    // -------------------------------------------------------------------------
    // Vault — deposit / withdraw / shares
    // -------------------------------------------------------------------------

    /// @notice Realised output of a deposit or withdraw violated the
    ///         user-supplied minimum.
    /// @param actual The smaller of the two amounts that fell below its floor.
    /// @param min The corresponding floor that was violated.
    error SlippageExceeded(uint256 actual, uint256 min);

    /// @notice Deposit would push vault TVL above the configured cap.
    /// @param proposed Total vault notional (in token0 units) after the deposit.
    /// @param cap Current TVL cap.
    error TVLCapExceeded(uint256 proposed, uint256 cap);

    /// @notice `deposit` invoked while deposits are paused by the multisig.
    /// @dev Withdraws and rebalances are unaffected — invariant 6.
    error DepositsPaused();

    /// @notice First-depositor inflation guard: the deposit would mint
    ///         fewer than `MIN_SHARES` shares, which would let the
    ///         depositor capture `MIN_SHARES`-worth of donations from
    ///         later depositors. See ADR-006 / PRD §13.
    error ZeroShares();

    /// @notice Withdraw asked for an invalid (zero or > balance) share count.
    error InvalidShareAmount();

    // -------------------------------------------------------------------------
    // Strategy
    // -------------------------------------------------------------------------

    /// @notice `IStrategy.computePositions` returned weights whose sum is
    ///         not exactly 10_000 basis points (invariant #2).
    /// @param actual The actual weight sum returned by the strategy.
    error WeightsDoNotSum(uint256 actual);

    /// @notice Strategy returned more positions than the vault's
    ///         `MAX_POSITIONS` cap allows (invariant #3).
    /// @param requested The number of positions returned by the strategy.
    error MaxPositionsExceeded(uint256 requested);

    /// @notice Strategy or caller supplied a tick range with `lower >= upper`
    ///         or a tick that is not aligned to `tickSpacing`.
    error InvalidTickRange(int24 lower, int24 upper);

    /// @notice `Vault.rebalance` invoked when `IStrategy.shouldRebalance`
    ///         returns false. Permissionless callers must wait for the
    ///         drift threshold or 24h fallback.
    error RebalanceNotNeeded();

    // -------------------------------------------------------------------------
    // Hook — V4 permission + lifecycle
    // -------------------------------------------------------------------------

    /// @notice Deployed hook address bits do not match
    ///         `getHookPermissions()`. Caught at deploy / pool-init time.
    /// @param expected The permission bits required by the hook bytecode.
    /// @param actual The bits actually encoded in the deployed address.
    error HookNotPermissioned(uint160 expected, uint160 actual);

    // -------------------------------------------------------------------------
    // Oracle
    // -------------------------------------------------------------------------

    /// @notice Oracle round is older than `STALENESS` (1h on mainnet).
    ///         Hook treats this as `healthy = false` rather than
    ///         reverting on the swap path (ADR-003).
    /// @param updatedAt The `updatedAt` timestamp of the stale round.
    error OracleStale(uint256 updatedAt);

    /// @notice Pool sqrt-price has drifted further from the oracle
    ///         reference than the configured deviation threshold.
    ///         v1.0 hook pauses MEV capture; v1.1 may revert backruns
    ///         that would execute outside the threshold.
    /// @param deviation Absolute deviation in basis points (10_000 = 100%).
    error OracleDeviation(uint256 deviation);

    // -------------------------------------------------------------------------
    // Flash-accounting callback (ADR-004)
    // -------------------------------------------------------------------------

    /// @notice `unlockCallback` was invoked with a `CallbackData.op` value
    ///         outside the supported `Op` enum.
    error UnknownOp();

    /// @notice Currency delta did not settle to zero before
    ///         `unlockCallback` returned (invariant #4). Bug, not user
    ///         error — surfaces a missing `take` / `settle` pair.
    error DeltaUnsettled();

    /// @notice Transient reentrancy guard tripped: a second nested
    ///         entry into a `nonReentrantTransient` function was
    ///         attempted in the same transaction.
    error Reentrancy();

    // -------------------------------------------------------------------------
    // Generic
    // -------------------------------------------------------------------------

    /// @notice An arithmetic computation produced a value outside the
    ///         caller's accepted range. Reserved for math helpers that
    ///         do not have a more specific error already.
    error MathOverflow();

    /// @notice A value parameter (typically a basis-point or fee value)
    ///         exceeded the contract's allowed bound.
    /// @param value The offending value.
    /// @param max The contract's documented maximum.
    error ValueOutOfBounds(uint256 value, uint256 max);
}
