// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {Vault} from "../../../src/core/Vault.sol";
import {IStrategy} from "../../../src/interfaces/IStrategy.sol";

/// @notice Mintable ERC-20 used as token0 / token1 in the invariant fixture.
contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Configurable strategy: handler installs a fresh shape before
///         every rebalance call. The vault re-checks invariants on the
///         shape — rebalances with malformed shapes revert and the
///         handler tolerates that (`fail_on_revert = false`).
contract FuzzStrategy is IStrategy {
    TargetPosition[] internal _shape;
    bool public verdict = true;

    function setVerdict(bool v) external {
        verdict = v;
    }

    function setShape(TargetPosition[] memory ps) external {
        delete _shape;
        for (uint256 i = 0; i < ps.length; i++) {
            _shape.push(ps[i]);
        }
    }

    function computePositions(
        int24,
        int24,
        uint256,
        uint256
    )
        external
        view
        override
        returns (TargetPosition[] memory out)
    {
        out = new TargetPosition[](_shape.length);
        for (uint256 i = 0; i < _shape.length; i++) {
            out[i] = _shape[i];
        }
    }

    function shouldRebalance(int24, int24, uint256) external view override returns (bool) {
        return verdict;
    }
}

/// @notice Pool stand-in. Returns a configurable delta on every
///         `modifyLiquidity` call; flips the sign when the request is a
///         remove (`liquidityDelta < 0`) so the same setting drives both
///         sides of the rebalance cycle.
///
///         `take` transfers ERC-20s from the pool's own balance — the
///         handler mints to the pool to cover this. `settle` is a no-op
///         because the vault has already pushed tokens to the pool via
///         `safeTransfer`.
contract FuzzPoolManager {
    BalanceDelta public deployDelta;
    bytes32 public mockedSlot0;

    function setDelta(int128 d0, int128 d1) external {
        deployDelta = toBalanceDelta(d0, d1);
    }

    function setSlot0(uint160 sqrtPriceX96, int24 tick) external {
        mockedSlot0 = bytes32(uint256(sqrtPriceX96)) | bytes32(uint256(uint24(tick)) << 160);
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function modifyLiquidity(
        PoolKey memory,
        ModifyLiquidityParams memory params,
        bytes calldata
    )
        external
        view
        returns (BalanceDelta, BalanceDelta)
    {
        BalanceDelta d = deployDelta;
        if (params.liquidityDelta < 0) {
            // Remove: vault should *receive* tokens. Flip the sign of
            // the deploy delta so a single configuration drives both
            // legs symmetrically.
            d = toBalanceDelta(-d.amount0(), -d.amount1());
        }
        return (d, BalanceDelta.wrap(0));
    }

    function take(Currency currency, address to, uint256 amount) external {
        ERC20(Currency.unwrap(currency)).transfer(to, amount);
    }

    function settle() external payable returns (uint256) {
        return 0;
    }

    function sync(Currency) external {}

    /// @dev `StateLibrary.getSlot0` reads slot0 via `extsload`; the mock
    ///      returns the packed (sqrtPriceX96, tick, ...) word the
    ///      handler installed.
    function extsload(bytes32) external view returns (bytes32) {
        return mockedSlot0;
    }
}

/// @title VaultHandler
/// @notice Drives the invariant fuzzer. Each public method is a guarded
///         action the fuzzer may call; reverts are tolerated
///         (`fail_on_revert = false`) so adversarial inputs (bad shapes,
///         weights ≠ 10_000) round-trip through the vault's checks.
///
///         Ghost variables track activity the invariants cross-check
///         against vault state — successful rebalance count, last
///         observed timestamp, supply floor.
contract VaultHandler is Test {
    /// @notice Pool sqrt-price for tick 0. Hard-coded so tick math stays
    ///         deterministic across runs.
    uint160 internal constant SQRT_PRICE_TICK_0 = 79_228_162_514_264_337_593_543_950_336;

    Vault public immutable vault;
    FuzzPoolManager public immutable pool;
    FuzzStrategy public immutable strategy;
    MockERC20 public immutable token0;
    MockERC20 public immutable token1;
    address public immutable owner;
    int24 public immutable tickSpacing;

    /// @notice Successful rebalance count.
    uint256 public ghost_rebalanceCount;
    /// @notice `vault.lastRebalanceTimestamp()` after the most recent
    ///         successful rebalance.
    uint256 public ghost_lastTimestamp;
    /// @notice `vault.totalSupply()` floor — the supply at fixture
    ///         start. Rebalance only mints, so live supply must never
    ///         dip below this.
    uint256 public immutable ghost_supplyFloor;
    /// @notice Snapshot of `vault.balanceOf(DEAD)` at fixture start.
    ///         Burned MIN_SHARES never circulate; the balance is
    ///         constant for the vault's lifetime.
    uint256 public immutable ghost_deadBalance;

    /// @notice Pool of valid keepers cycled by `doRebalance`.
    address[] internal _keepers;

    constructor(
        Vault _vault,
        FuzzPoolManager _pool,
        FuzzStrategy _strategy,
        MockERC20 _token0,
        MockERC20 _token1,
        address _owner
    ) {
        vault = _vault;
        pool = _pool;
        strategy = _strategy;
        token0 = _token0;
        token1 = _token1;
        owner = _owner;
        tickSpacing = _vault.tickSpacing();

        _keepers.push(address(0xBEE9E2));
        _keepers.push(address(0xBEE1));
        _keepers.push(address(0xBEE2));

        ghost_supplyFloor = _vault.totalSupply();
        ghost_deadBalance = _vault.balanceOf(_vault.DEAD());
    }

    // -------------------------------------------------------------------------
    // Actions
    // -------------------------------------------------------------------------

    /// @notice Configure the strategy with a fuzz-generated shape and
    ///         the pool with a fuzz-generated delta, then call
    ///         `vault.rebalance()`.
    function doRebalance(uint256 keeperSeed, uint8 nPositionsSeed, int24 baseTickSeed, int128 deltaSeed) external {
        // 1..7 positions per call.
        uint256 n = (uint256(nPositionsSeed) % vault.MAX_POSITIONS()) + 1;

        // Bound the base tick comfortably inside the V4 usable range
        // (≈ ±887_220 at tickSpacing=60). Pin the floor to leave room
        // for `n * tickSpacing` worth of upper tick.
        int256 base = bound(int256(baseTickSeed), -100_000, 100_000);
        // Snap to a multiple of tickSpacing — V4 / PositionLib rejects
        // unaligned ticks.
        int256 spacing = int256(tickSpacing);
        int256 rem = base % spacing;
        if (rem != 0) base -= rem;

        IStrategy.TargetPosition[] memory ps = new IStrategy.TargetPosition[](n);
        // Even-split weights with the rounding remainder absorbed by
        // the last slot — matches the IStrategy contract.
        uint256 baseWeight = 10_000 / n;
        uint256 leftover = 10_000 - baseWeight * n;
        for (uint256 i = 0; i < n; i++) {
            int24 lower = int24(base + int256(i) * spacing);
            int24 upper = lower + tickSpacing;
            ps[i] = IStrategy.TargetPosition({
                tickLower: lower,
                tickUpper: upper,
                weight: baseWeight + (i + 1 == n ? leftover : 0)
            });
        }
        strategy.setShape(ps);
        strategy.setVerdict(true);

        // Bound the per-position delta so total spend stays well below
        // the idle balance the handler mints below.
        int128 d = int128(int256(bound(int256(deltaSeed), -1000, -1)));
        pool.setDelta(d, d);

        // Top up the vault's idle and the pool's reserve. Vault needs
        // idle to settle deploy negatives; pool needs balance to honour
        // `take` on the remove leg of subsequent rebalances.
        token0.mint(address(vault), 1_000_000);
        token1.mint(address(vault), 1_000_000);
        token0.mint(address(pool), 1_000_000);
        token1.mint(address(pool), 1_000_000);

        address keeper = _keepers[keeperSeed % _keepers.length];
        vm.prank(keeper);
        try vault.rebalance() {
            ghost_rebalanceCount++;
            ghost_lastTimestamp = vault.lastRebalanceTimestamp();
        } catch {
            // Strategy gate, malformed shape, or settlement shortfall —
            // all valid revert paths. Invariants must still hold.
        }
    }

    /// @notice Advance the chain clock so `block.timestamp` varies
    ///         across rebalance calls.
    function warp(uint256 sec) external {
        sec = bound(sec, 1, 1 days);
        vm.warp(block.timestamp + sec);
    }

    /// @notice Owner toggles the deposits-paused flag.
    function togglePause(bool paused) external {
        vm.prank(owner);
        vault.setDepositsPaused(paused);
    }

    /// @notice Owner sets a fresh TVL cap.
    function setTVLCap(uint256 cap) external {
        cap = bound(cap, 1, type(uint128).max);
        vm.prank(owner);
        vault.setTVLCap(cap);
    }

    /// @notice Vary the pool's reported tick — the strategy gate and
    ///         `getTotalAmounts` both consume it via `extsload`.
    function setPoolTick(int24 tick) external {
        int256 t = bound(int256(tick), -100_000, 100_000);
        pool.setSlot0(SQRT_PRICE_TICK_0, int24(t));
    }

    /// @notice Number of keepers seeded — used for unit-style asserts.
    function keeperCount() external view returns (uint256) {
        return _keepers.length;
    }
}
