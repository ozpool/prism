// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Errors} from "../../src/utils/Errors.sol";
import {ReentrancyGuardTransient} from "../../src/utils/ReentrancyGuardTransient.sol";

/// @notice Test fixture exposing two protected entry points that can
///         optionally call back into themselves via the same external
///         interface — exercising both single-function and cross-function
///         reentrancy attempts.
contract Guarded is ReentrancyGuardTransient {
    /// @dev Reentrancy attempts route through this address; we set it
    ///      to `address(this)` so the contract can call itself.
    address public callback;

    /// @notice Tracks whether the protected body executed at least once.
    bool public touched;

    function setCallback(address c) external {
        callback = c;
    }

    function protectedA() external nonReentrantTransient {
        touched = true;
        if (callback != address(0)) {
            // Solidity returns bubbled revert data on failure, which is
            // what `vm.expectRevert(selector)` matches against.
            Guarded(callback).protectedA();
        }
    }

    function protectedB() external nonReentrantTransient {
        if (callback != address(0)) {
            Guarded(callback).protectedA();
        }
    }
}

/// @notice Behaviour tests for the EIP-1153 reentrancy guard.
contract ReentrancyGuardTransientTest is Test {
    Guarded internal g;

    function setUp() public {
        g = new Guarded();
    }

    // -------------------------------------------------------------------------
    // Happy path
    // -------------------------------------------------------------------------

    function test_nonReentrant_singleCall_succeeds() external {
        g.protectedA();
        assertTrue(g.touched(), "body did not execute");
    }

    function test_nonReentrant_sequentialCalls_succeed() external {
        // Across two separate top-level calls, the transient flag has
        // cleared between them, so the guard does not trip.
        g.protectedA();
        g.protectedA();
        assertTrue(g.touched());
    }

    // -------------------------------------------------------------------------
    // Reentrancy reverts
    // -------------------------------------------------------------------------

    function test_nonReentrant_directReentry_reverts() external {
        g.setCallback(address(g));
        vm.expectRevert(Errors.Reentrancy.selector);
        g.protectedA();
    }

    /// @dev Cross-function reentrancy: `protectedB` calls into
    ///      `protectedA`. Both are guarded by the same modifier and
    ///      share `_entered`, so the second guard MUST trip.
    function test_nonReentrant_crossFunctionReentry_reverts() external {
        g.setCallback(address(g));
        vm.expectRevert(Errors.Reentrancy.selector);
        g.protectedB();
    }

    // -------------------------------------------------------------------------
    // Transient slot lifecycle
    // -------------------------------------------------------------------------

    /// @dev After a successful protected call returns, `_entered` must
    ///      be cleared so the next call in the same transaction can
    ///      enter freely. We exercise that by chaining two top-level
    ///      calls inside one test (= one transaction) without
    ///      reentering, then a third that DOES reenter.
    function test_transient_clearsBetweenSiblingCalls() external {
        g.protectedA();
        g.protectedA();
        g.setCallback(address(g));
        vm.expectRevert(Errors.Reentrancy.selector);
        g.protectedA();
    }

    /// @dev After a reverted reentrant call, the next top-level call
    ///      from a fresh entry must succeed: `_entered` was set to
    ///      true mid-call, the revert unwound the storage write, and
    ///      the transient slot resets at transaction end. Foundry
    ///      treats every test invocation as a separate transaction
    ///      via `vm.expectRevert` semantics, so we verify by calling
    ///      again inside the SAME test after clearing the callback.
    function test_transient_recoverable_afterRevert() external {
        g.setCallback(address(g));
        try g.protectedA() {
            revert("expected reentrancy revert");
        } catch (bytes memory data) {
            // Confirm the revert was the reentrancy selector.
            assertEq(bytes4(data), Errors.Reentrancy.selector);
        }

        // Clear the callback and try again — the guard should not
        // remember the previous failed attempt.
        g.setCallback(address(0));
        g.protectedA();
        assertTrue(g.touched());
    }

    // -------------------------------------------------------------------------
    // Gas snapshot
    // -------------------------------------------------------------------------

    /// @dev Sanity-bound on the per-call gas cost of the modifier. The
    ///      protected body here is a single SSTORE + a zero-address
    ///      branch, so almost the entire cost is the modifier itself
    ///      plus call overhead. Ceiling is generous — the goal is to
    ///      catch a regression that swaps in a storage-slot guard.
    function test_gas_belowStorageGuardThreshold() external {
        uint256 before = gasleft();
        g.protectedA();
        uint256 used = before - gasleft();
        // Storage-slot guards burn ~2,100 gas/call once warm; transient
        // sits at ~100. Add a generous body + call-overhead buffer.
        // If this trips, almost certainly the modifier was reverted to
        // a `bool` storage slot.
        assertLt(used, 30_000, "modifier consumed unexpectedly large gas");
    }
}
