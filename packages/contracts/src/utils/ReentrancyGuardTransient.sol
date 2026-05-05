// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Errors} from "./Errors.sol";

/// @title Reentrancy guard backed by EIP-1153 transient storage
/// @notice `nonReentrantTransient` modifier costing ~100 gas per call.
/// @dev Compared to the storage-slot guard (e.g. OpenZeppelin's
///      `ReentrancyGuard`):
///        - storage version: ~2,100 gas per entry (warm SSTORE) plus a
///          5,000-gas slot init cost on first use.
///        - transient version: ~100 gas (TSTORE + TLOAD), no slot init,
///          and the slot clears automatically at end-of-transaction so
///          there is no "reset to zero on exit" SSTORE either.
///
///      EIP-1153 requires the Cancun fork, which Base supports and
///      `foundry.toml` pins via `evm_version = "cancun"`.
///
///      Solidity 0.8.26 does not yet expose the `transient` storage
///      keyword for state variables (added in 0.8.28); we drop to inline
///      assembly using the canonical `_REENTRANCY_GUARD_SLOT`.
///
///      Slot derivation: `keccak256("PRISM.ReentrancyGuard")`. Using a
///      named-derived slot rather than slot 0 avoids accidental aliasing
///      with future transient state in derived contracts. The slot is a
///      constant; transient storage is per-contract and per-transaction,
///      so different contracts using the same constant do not collide.
///
///      Lifetime: the slot is scoped to the *transaction*, not the call.
///      A nested call inside the same tx sees the busy flag set,
///      regardless of intermediate contracts.
///
///      Inheritance: contracts inherit and apply the modifier on every
///      external state-mutating entry point that could be re-entered
///      via a PoolManager callback, hook, or token transfer hook. Pure
///      / view functions do not need it.
///
///      Failure mode: a nested entry reverts with `Errors.Reentrancy()`.
abstract contract ReentrancyGuardTransient {
    /// @dev Transient slot identifier. `keccak256("PRISM.ReentrancyGuard")`
    ///      computed at compile time so the slot is a pure constant.
    bytes32 private constant _REENTRANCY_GUARD_SLOT = keccak256("PRISM.ReentrancyGuard");

    /// @notice Reverts with `Errors.Reentrancy()` if a function marked
    ///         `nonReentrantTransient` is already on the call stack
    ///         within this transaction.
    modifier nonReentrantTransient() {
        bytes32 slot = _REENTRANCY_GUARD_SLOT;
        uint256 entered;
        assembly ("memory-safe") {
            entered := tload(slot)
        }
        if (entered != 0) revert Errors.Reentrancy();
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }
}
