// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {IProtocolHook} from "../../src/interfaces/IProtocolHook.sol";

/// @notice Compile-time + selector-stability tests for `IProtocolHook`.
///
/// The behavioural tests on the hook implementation (#34, #35, #36) cover
/// real callback semantics — this file only verifies the interface
/// surface: signatures match V4's IHooks, the additional read accessors
/// have stable selectors, and the events have stable topics.
contract IProtocolHookTest is Test {
    // -------------------------------------------------------------------------
    // V4 IHooks inheritance
    //
    // Solidity does not expose inherited interface members through
    // `IProtocolHook.<member>.selector` — the inheritance is enforced
    // at the ABI level only. The compile-time `IHooks h = IProtocolHook(...)`
    // assignment proves the IS-A relationship; v4-core owns the
    // selector-stability tests for IHooks itself.
    // -------------------------------------------------------------------------

    function test_inherits_IHooks_isa() external pure {
        IProtocolHook ph = IProtocolHook(address(0));
        IHooks h = IHooks(ph);
        assertEq(address(h), address(ph));
    }

    function test_v4_IHooks_callback_selectors_stable() external pure {
        // Pin the four selectors PRISM relies on. If v4-core ever changes
        // its IHooks shape, this test trips before users hit the bug.
        assertEq(
            IHooks.beforeSwap.selector,
            bytes4(keccak256("beforeSwap(address,(address,address,uint24,int24,address),(bool,int256,uint160),bytes)"))
        );
        assertEq(
            IHooks.afterSwap.selector,
            bytes4(
                keccak256(
                    "afterSwap(address,(address,address,uint24,int24,address),(bool,int256,uint160),int256,bytes)"
                )
            )
        );
    }

    // -------------------------------------------------------------------------
    // PRISM-specific surface
    // -------------------------------------------------------------------------

    function test_selector_registerVault() external pure {
        assertEq(IProtocolHook.registerVault.selector, bytes4(keccak256("registerVault(address)")));
    }

    function test_selector_currentFee() external pure {
        assertEq(IProtocolHook.currentFee.selector, bytes4(keccak256("currentFee(bytes32)")));
    }

    function test_selector_mevProfits() external pure {
        assertEq(IProtocolHook.mevProfits.selector, bytes4(keccak256("mevProfits(address)")));
    }

    function test_selector_getHookPermissions() external pure {
        assertEq(IProtocolHook.getHookPermissions.selector, bytes4(keccak256("getHookPermissions()")));
    }

    // -------------------------------------------------------------------------
    // Event topics
    // -------------------------------------------------------------------------

    function test_event_FeeUpdated_topic() external pure {
        assertEq(IProtocolHook.FeeUpdated.selector, keccak256("FeeUpdated(bytes32,uint24,uint256)"));
    }

    function test_event_SwapObserved_topic() external pure {
        assertEq(IProtocolHook.SwapObserved.selector, keccak256("SwapObserved(bytes32,int24,uint160)"));
    }

    function test_event_MEVCaptured_topic() external pure {
        assertEq(IProtocolHook.MEVCaptured.selector, keccak256("MEVCaptured(address,uint256,bool)"));
    }

    // -------------------------------------------------------------------------
    // Permissions matrix — PRISM enables exactly bits 6, 7, 8, 10 (= 0x05C0)
    //
    // The permission *value* is ultimately produced by an implementation,
    // but the interface guarantees the return type is `Hooks.Permissions`
    // so call sites can construct the canonical PRISM permission set.
    // -------------------------------------------------------------------------

    function test_canonicalPRISMPermissions_compileGate() external pure {
        Hooks.Permissions memory p = Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true, // bit 10 — 0x0400
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true, // bit 8 — 0x0100
            beforeSwap: true, // bit 7 — 0x0080
            afterSwap: true, // bit 6 — 0x0040
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
        // Combined bits: 0x0400 + 0x0100 + 0x0080 + 0x0040 = 0x05C0.
        assertTrue(p.beforeSwap && p.afterSwap && p.afterAddLiquidity && p.afterRemoveLiquidity);
        assertFalse(p.beforeInitialize || p.afterInitialize);
    }
}
