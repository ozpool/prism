// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Vault} from "../../src/core/Vault.sol";
import {IProtocolHook} from "../../src/interfaces/IProtocolHook.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";

import {FuzzPoolManager, FuzzStrategy, MockERC20, VaultHandler} from "./handlers/VaultHandler.sol";

/// @title Vault invariants — PRD §13
/// @notice Stateful fuzzing of `Vault.rebalance()` plus the admin
///         levers. Fixture pre-mints MIN_SHARES to DEAD and a notional
///         user supply to mimic a vault that has already taken its
///         first deposit; deposit / withdraw bodies land in #27 / #28
///         body PRs and will extend this suite then.
///
/// @dev Invariants exercised:
///        - INV-1  positions.length ≤ MAX_POSITIONS
///        - INV-2  every active position has aligned, ordered ticks
///                 inside `[minUsableTick, maxUsableTick]`
///        - INV-3  `lastRebalanceTimestamp` matches handler ghost
///        - INV-4  `lastRebalanceTimestamp` ≤ `block.timestamp`
///        - INV-5  `totalSupply` is monotonic non-decreasing
///                 (rebalance only mints; deposit / withdraw aren't
///                  driven on this branch)
///        - INV-6  `balanceOf(DEAD)` never moves — burned MIN_SHARES
///        - INV-7  immutable constants stay pinned
///        - INV-8  ownership stays with the constructor `owner`
///        - INV-9  `lastRebalanceTick` sits inside V4 usable bounds
contract VaultInvariantsTest is StdInvariant, Test {
    address constant HOOK = address(0xB00C);
    address constant OWNER = address(0xACE);
    address constant USER = address(0xD05E);

    uint256 constant TVL_CAP = 1_000_000e18;
    uint256 constant USER_INITIAL_SHARES = 99_000;

    /// @notice Sqrt-price for tick 0.
    uint160 constant SQRT_PRICE_TICK_0 = 79_228_162_514_264_337_593_543_950_336;

    Vault internal vault;
    FuzzPoolManager internal pool;
    FuzzStrategy internal strategy;
    MockERC20 internal token0;
    MockERC20 internal token1;
    VaultHandler internal handler;

    int24 internal constant TICK_SPACING = 60;

    function setUp() public {
        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");
        // PoolKey requires currency0 < currency1.
        if (uint160(address(token1)) < uint160(address(token0))) {
            (token0, token1) = (token1, token0);
        }

        strategy = new FuzzStrategy();
        pool = new FuzzPoolManager();
        pool.setSlot0(SQRT_PRICE_TICK_0, 0);
        // Default delta — handler overrides per call but a sane initial
        // value avoids zero-liquidity deploys on the first rebalance.
        pool.setDelta(int128(-100), int128(-100));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0x800000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });

        vault = new Vault(
            IPoolManager(address(pool)),
            key,
            IStrategy(address(strategy)),
            IProtocolHook(HOOK),
            OWNER,
            TVL_CAP,
            "PRISM Vault",
            "pVAULT"
        );

        // Mint MIN_SHARES to DEAD + a notional user supply. Models a
        // vault that has already accepted its first deposit so the
        // keeper-bonus path has a non-zero supply to pro-rate against.
        deal(address(vault), vault.DEAD(), vault.MIN_SHARES(), true);
        deal(address(vault), USER, USER_INITIAL_SHARES, true);

        handler = new VaultHandler(vault, pool, strategy, token0, token1, OWNER);

        // Restrict the fuzzer to handler selectors. Without this
        // forge would also call the vault directly, fall foul of
        // unlock auth (no callback path) and waste runs.
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = VaultHandler.doRebalance.selector;
        selectors[1] = VaultHandler.warp.selector;
        selectors[2] = VaultHandler.togglePause.selector;
        selectors[3] = VaultHandler.setTVLCap.selector;
        selectors[4] = VaultHandler.setPoolTick.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // -------------------------------------------------------------------------
    // Invariants
    // -------------------------------------------------------------------------

    /// @notice INV-1: position count never exceeds MAX_POSITIONS.
    function invariant_positionCount_withinCap() public view {
        Vault.Position[] memory ps = vault.getPositions();
        assertLe(ps.length, vault.MAX_POSITIONS(), "INV-1: positions.length > MAX_POSITIONS");
    }

    /// @notice INV-2: every active position has tickLower < tickUpper,
    ///         both aligned to tickSpacing, both inside the V4 usable
    ///         range. Mirrors `PositionLib.validateRange`.
    function invariant_positionTicks_valid() public view {
        Vault.Position[] memory ps = vault.getPositions();
        int24 ts = vault.tickSpacing();
        int24 minUsable = TickMath.minUsableTick(ts);
        int24 maxUsable = TickMath.maxUsableTick(ts);
        for (uint256 i = 0; i < ps.length; i++) {
            assertLt(ps[i].tickLower, ps[i].tickUpper, "INV-2a: tickLower >= tickUpper");
            assertEq(int256(ps[i].tickLower) % int256(ts), 0, "INV-2b: tickLower not aligned");
            assertEq(int256(ps[i].tickUpper) % int256(ts), 0, "INV-2c: tickUpper not aligned");
            assertGe(ps[i].tickLower, minUsable, "INV-2d: tickLower below minUsable");
            assertLe(ps[i].tickUpper, maxUsable, "INV-2e: tickUpper above maxUsable");
        }
    }

    /// @notice INV-3: vault's `lastRebalanceTimestamp` matches the
    ///         handler's last-observed timestamp.
    function invariant_lastRebalanceTimestamp_matchesGhost() public view {
        assertEq(
            vault.lastRebalanceTimestamp(), handler.ghost_lastTimestamp(), "INV-3: lastRebalanceTimestamp != ghost"
        );
    }

    /// @notice INV-4: `lastRebalanceTimestamp` is never in the future.
    function invariant_lastRebalanceTimestamp_pastOrPresent() public view {
        assertLe(vault.lastRebalanceTimestamp(), block.timestamp, "INV-4: lastTimestamp > now");
    }

    /// @notice INV-5: total supply is monotonic non-decreasing —
    ///         rebalance only mints (keeper bonus); deposit / withdraw
    ///         aren't reachable on this branch (bodies revert
    ///         UnknownOp until #187 / #190 land).
    function invariant_totalSupply_monotonic() public view {
        assertGe(vault.totalSupply(), handler.ghost_supplyFloor(), "INV-5: totalSupply dipped");
    }

    /// @notice INV-6: DEAD address balance is invariant — the
    ///         MIN_SHARES burn is permanent.
    function invariant_DEAD_balance_preserved() public view {
        assertEq(vault.balanceOf(vault.DEAD()), handler.ghost_deadBalance(), "INV-6: DEAD balance moved");
    }

    /// @notice INV-7: immutable constants stay pinned.
    function invariant_constants_immutable() public view {
        assertEq(vault.MIN_SHARES(), 1000, "INV-7a: MIN_SHARES");
        assertEq(vault.MAX_POSITIONS(), 7, "INV-7b: MAX_POSITIONS");
        assertEq(vault.KEEPER_BONUS_BPS(), 5, "INV-7c: KEEPER_BONUS_BPS");
        assertEq(vault.DEAD(), 0x000000000000000000000000000000000000dEaD, "INV-7d: DEAD");
        assertEq(vault.tickSpacing(), TICK_SPACING, "INV-7e: tickSpacing");
        assertEq(vault.poolFee(), 0x800000, "INV-7f: poolFee");
    }

    /// @notice INV-8: ownership stays with the constructor `owner`.
    ///         The handler never calls `transferOwnership`.
    function invariant_owner_pinned() public view {
        assertEq(vault.owner(), OWNER, "INV-8: owner moved");
    }

    /// @notice INV-9: `lastRebalanceTick` sits inside the V4 usable
    ///         range for the configured tickSpacing.
    function invariant_lastRebalanceTick_withinUsable() public view {
        int24 ts = vault.tickSpacing();
        int24 minUsable = TickMath.minUsableTick(ts);
        int24 maxUsable = TickMath.maxUsableTick(ts);
        int24 t = vault.lastRebalanceTick();
        assertGe(t, minUsable, "INV-9a: lastTick below minUsable");
        assertLe(t, maxUsable, "INV-9b: lastTick above maxUsable");
    }
}
