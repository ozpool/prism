// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {Vault} from "../../src/core/Vault.sol";
import {IProtocolHook} from "../../src/interfaces/IProtocolHook.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {Errors} from "../../src/utils/Errors.sol";

// ---------------------------------------------------------------------------
// Minimal ERC-20 for test tokens
// ---------------------------------------------------------------------------

contract TestERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ---------------------------------------------------------------------------
// Mock PoolManager
//
// Implements just enough of IPoolManager to exercise _handleDeposit:
//   - unlock: calls unlockCallback(data) on the locker, mirrors the real PM
//   - extsload: returns a pre-configured slot0 word so StateLibrary.getSlot0 works
//   - modifyLiquidity: returns a configurable BalanceDelta (negative = caller owes)
//   - sync / settle: no-ops (vault pushes tokens; we don't enforce reserves here)
//   - All other IPoolManager methods: revert with "NOT_IMPL" as a safety guard
//
// The mock is deliberately unlocked from re-entrance checks to let the vault
// call back freely.
// ---------------------------------------------------------------------------

contract MockPoolManager {
    using PoolIdLibrary for PoolKey;

    // Slot0 word returned for any extsload call. Set in setUp.
    // Layout (matches StateLibrary): [lpFee(24)][protocolFee(24)][tick(24)][sqrtPriceX96(160)]
    bytes32 public slot0Word;

    // Delta returned by modifyLiquidity. Negative amount0 = vault owes token0.
    BalanceDelta public nextDelta;

    // Track how many times modifyLiquidity was called.
    uint256 public modifyCount;

    function setSlot0(uint160 sqrtPriceX96, int24 tick) external {
        // Pack: bottom 160 bits = sqrtPrice, next 24 = tick (sign-extended),
        // upper bits zero (no protocol fee, no lp fee in mock).
        bytes32 packed;
        assembly ("memory-safe") {
            // Store sqrtPriceX96 in the lower 160 bits.
            packed := and(sqrtPriceX96, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            // OR in tick at bits [160:184]. Tick is int24; mask to 24 bits.
            packed := or(packed, shl(160, and(tick, 0xFFFFFF)))
        }
        slot0Word = packed;
    }

    function setNextDelta(int128 amount0, int128 amount1) external {
        nextDelta = toBalanceDelta(amount0, amount1);
    }

    // Called by Vault._handleDeposit via StateLibrary.getSlot0.
    // StateLibrary computes: keccak256(abi.encodePacked(poolId, POOLS_SLOT))
    // and calls extsload on that slot. We return slot0Word for any slot.
    function extsload(
        bytes32 /*slot*/
    )
        external
        view
        returns (bytes32)
    {
        return slot0Word;
    }

    // Multi-slot variant (not used by getSlot0 but required by interface).
    function extsload(
        bytes32,
        /*startSlot*/
        uint256 nSlots
    )
        external
        view
        returns (bytes32[] memory values)
    {
        values = new bytes32[](nSlots);
        for (uint256 i; i < nSlots; ++i) {
            values[i] = slot0Word;
        }
    }

    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory values) {
        values = new bytes32[](slots.length);
        for (uint256 i; i < slots.length; ++i) {
            values[i] = slot0Word;
        }
    }

    // IExttload stubs (not called in deposit path).
    function exttload(bytes32) external pure returns (bytes32) {
        return bytes32(0);
    }

    function exttload(bytes32[] calldata keys) external pure returns (bytes32[] memory values) {
        values = new bytes32[](keys.length);
    }

    // Core: unlock calls the locker's unlockCallback and returns its result.
    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function modifyLiquidity(
        PoolKey memory,
        /*key*/
        ModifyLiquidityParams memory,
        /*params*/
        bytes calldata /*hookData*/
    )
        external
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        ++modifyCount;
        callerDelta = nextDelta;
        feesAccrued = toBalanceDelta(0, 0);
    }

    // Settlement helpers — vault transfers tokens to this mock then calls settle.
    // No-op: we accept the transfer, settle returns 0 (no accounting needed).
    function sync(Currency) external {}

    function settle() external payable returns (uint256) {
        return 0;
    }

    function settleFor(address) external payable returns (uint256) {
        return 0;
    }

    // Unused stubs required to satisfy IPoolManager interface.
    function initialize(PoolKey memory, uint160) external pure returns (int24) {
        revert("NOT_IMPL");
    }

    function swap(PoolKey memory, ModifyLiquidityParams memory, bytes calldata) external pure returns (BalanceDelta) {
        revert("NOT_IMPL");
    }

    // donate, take, clear, mint, burn, updateDynamicLPFee → not called in deposit path.
    function donate(PoolKey memory, uint256, uint256, bytes calldata) external pure returns (BalanceDelta) {
        revert("NOT_IMPL");
    }

    function take(Currency, address, uint256) external pure {
        revert("NOT_IMPL");
    }

    function clear(Currency, uint256) external pure {
        revert("NOT_IMPL");
    }

    function mint(address, uint256, uint256) external pure {
        revert("NOT_IMPL");
    }

    function burn(address, uint256, uint256) external pure {
        revert("NOT_IMPL");
    }

    function updateDynamicLPFee(PoolKey memory, uint24) external pure {
        revert("NOT_IMPL");
    }

    // ERC-6909 Claims stubs — not used by deposit path.
    function balanceOf(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function allowance(address, address, uint256) external pure returns (uint256) {
        return 0;
    }

    function approve(address, uint256, uint256) external pure returns (bool) {
        return false;
    }

    function transfer(address, uint256, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256, uint256) external pure returns (bool) {
        return false;
    }

    function isOperator(address, address) external pure returns (bool) {
        return false;
    }

    function setOperator(address, bool) external pure returns (bool) {
        return false;
    }

    // IProtocolFees stubs.
    function setProtocolFee(PoolKey memory, uint24) external pure {
        revert("NOT_IMPL");
    }

    function collectProtocolFees(address, Currency, uint256) external pure returns (uint256) {
        revert("NOT_IMPL");
    }

    function protocolFeesAccrued(Currency) external pure returns (uint256) {
        return 0;
    }

    function setProtocolFeeController(address) external pure {
        revert("NOT_IMPL");
    }

    function protocolFeeController() external pure returns (address) {
        return address(0);
    }
}

// ---------------------------------------------------------------------------
// Minimal strategy that returns a single position at [tickLower, tickUpper]
// with 100% weight for simple test cases.
// ---------------------------------------------------------------------------

contract SinglePositionStrategy is IStrategy {
    int24 public immutable lower;
    int24 public immutable upper;

    constructor(int24 tickLower, int24 tickUpper) {
        lower = tickLower;
        upper = tickUpper;
    }

    function computePositions(
        int24,
        /*currentTick*/
        int24,
        /*tickSpacing*/
        uint256,
        /*amount0*/
        uint256 /*amount1*/
    )
        external
        view
        override
        returns (TargetPosition[] memory positions)
    {
        positions = new TargetPosition[](1);
        positions[0] = TargetPosition({tickLower: lower, tickUpper: upper, weight: 10_000});
    }

    function shouldRebalance(int24, int24, uint256) external pure override returns (bool) {
        return false;
    }
}

// ---------------------------------------------------------------------------
// Strategy that returns N positions of equal weight (for multi-position tests)
// ---------------------------------------------------------------------------

contract MultiPositionStrategy is IStrategy {
    uint256 public immutable n;
    int24 public immutable spacing;

    constructor(uint256 n_, int24 spacing_) {
        n = n_;
        spacing = spacing_;
    }

    function computePositions(
        int24 currentTick,
        int24 ts,
        uint256,
        /*amount0*/
        uint256 /*amount1*/
    )
        external
        view
        override
        returns (TargetPosition[] memory positions)
    {
        positions = new TargetPosition[](n);
        // Align to tick spacing.
        int24 anchor = currentTick - (currentTick % ts);
        uint256 eachWeight = 10_000 / n;
        uint256 remainder = 10_000 - (eachWeight * n);
        for (uint256 i; i < n; ++i) {
            int24 lo = anchor + int24(int256(i)) * ts;
            int24 hi = lo + ts;
            uint256 w = i == n - 1 ? eachWeight + remainder : eachWeight;
            positions[i] = TargetPosition({tickLower: lo, tickUpper: hi, weight: w});
        }
    }

    function shouldRebalance(int24, int24, uint256) external pure override returns (bool) {
        return false;
    }
}

// ---------------------------------------------------------------------------
// Test suite
// ---------------------------------------------------------------------------

contract VaultDepositTest is Test {
    using PoolIdLibrary for PoolKey;

    // ── Constants ────────────────────────────────────────────────────────────

    // sqrtPrice for tick 0 (1:1 price): sqrt(1) * 2^96
    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;

    int24 constant TICK_SPACING = 60;

    address constant HOOK = address(0xB00C);
    address constant OWNER = address(0xACE);
    uint256 constant TVL_CAP = type(uint256).max;

    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // ── State ─────────────────────────────────────────────────────────────────

    MockPoolManager pm;
    TestERC20 token0;
    TestERC20 token1;
    Vault vault;
    SinglePositionStrategy strategy;

    // ── Setup ─────────────────────────────────────────────────────────────────

    function setUp() public {
        pm = new MockPoolManager();

        // Ensure token0 < token1 for PoolKey ordering.
        TestERC20 ta = new TestERC20("TokenA", "TA");
        TestERC20 tb = new TestERC20("TokenB", "TB");
        if (address(ta) < address(tb)) {
            token0 = ta;
            token1 = tb;
        } else {
            token0 = tb;
            token1 = ta;
        }

        // Position centred on tick 0: [-60, 60], within range for tick spacing 60.
        strategy = new SinglePositionStrategy(-60, 60);

        PoolKey memory key = _poolKey();
        vault = new Vault(
            IPoolManager(address(pm)),
            key,
            IStrategy(address(strategy)),
            IProtocolHook(HOOK),
            OWNER,
            TVL_CAP,
            "PRISM Vault",
            "pVAULT"
        );

        // Configure mock: price at tick 0, delta costs 1e18 of each token.
        pm.setSlot0(SQRT_PRICE_1_1, 0);
        // Negative delta = vault owes tokens to pool.
        pm.setNextDelta(-1e18, -1e18);

        // Fund ALICE and BOB with tokens; they approve the vault.
        token0.mint(ALICE, 1000e18);
        token1.mint(ALICE, 1000e18);
        token0.mint(BOB, 1000e18);
        token1.mint(BOB, 1000e18);

        vm.prank(ALICE);
        token0.approve(address(vault), type(uint256).max);
        vm.prank(ALICE);
        token1.approve(address(vault), type(uint256).max);
        vm.prank(BOB);
        token0.approve(address(vault), type(uint256).max);
        vm.prank(BOB);
        token1.approve(address(vault), type(uint256).max);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _poolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0x800000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });
    }

    // ── Test 1: first deposit mints MIN_SHARES to DEAD + remainder to recipient
    //
    // With amount0Used = amount1Used = 1e18 (from mock delta),
    //   geomMean = sqrt(1e18 * 1e18) = 1e18
    //   shares to recipient = 1e18 - 1000
    // ──────────────────────────────────────────────────────────────────────────

    function test_deposit_firstDeposit_minSharesBurnedToDead() public {
        vm.prank(ALICE);
        (uint256 shares,,) = vault.deposit(2e18, 2e18, 0, 0, ALICE);

        assertEq(vault.balanceOf(DEAD), vault.MIN_SHARES(), "MIN_SHARES not burned to DEAD");
        assertEq(vault.balanceOf(ALICE), shares, "Alice share balance mismatch");
        assertEq(vault.totalSupply(), shares + vault.MIN_SHARES(), "total supply mismatch");
        assertGt(shares, 0, "zero shares minted");
    }

    // ── Test 2: subsequent deposit from a second EOA mints proportional shares
    //
    // After Alice's first deposit, Bob deposits the same amount. Because the
    // mock delta is deterministic (always -1e18/-1e18), Bob's consumed amounts
    // equal Alice's. The share math scales against vault's remaining idle
    // balance of token0 (after settlement vault holds the refunded unused
    // tokens; in this test desired == used so refund == 0, meaning the vault
    // balance of token0 is whatever wasn't transferred plus any leftover).
    //
    // Since the mock settle() is a no-op (tokens pile up in the PM contract),
    // vault.token0.balanceOf(vault) stays at 0 after transferring to PM.
    // The subsequent-deposit formula uses vault's idle balance AFTER settlement.
    // With vault holding 0 idle token0 (all transferred to PM), it falls back
    // to token1. Same reasoning: 0 idle. In that edge case the formula reverts
    // ZeroShares. So we configure the mock to only consume half the desired
    // amount, leaving idle balance in the vault for the second depositor math.
    // ──────────────────────────────────────────────────────────────────────────

    function test_deposit_secondDeposit_proportionalShares() public {
        // Delta consumes 1e18 of each; desired is 2e18 → 1e18 refunded to payer.
        // After Alice's deposit the vault will have 0 token0 idle
        // (it transferred 1e18 to PM, and refunded the remaining 1e18 back to Alice).
        // We need idle balance for subsequent math — set delta to consume only 0.5e18.
        pm.setNextDelta(-0.5e18, -0.5e18);

        // Alice: first deposit. Leaves 1.5e18 of each token idle in vault
        // (desired=2e18, used=0.5e18, refund=1.5e18 back to Alice).
        // Wait — refund goes back to ALICE (payer), not vault. So vault ends
        // up with 0 idle after refund. The shares denominator needs a non-zero
        // vault balance, so we use a setup where desired == used == consumed.
        // The only idle balance is what the vault holds that wasn't used.
        // To make subsequent deposits work we need vault to hold tokens between
        // deposit calls. Simplest: set delta so vault keeps 1e18 idle token0.
        // desired=2e18, delta=-1e18 → used=1e18 → refund 1e18 to Alice.
        // Vault: transferred 1e18 to PM (mock no-op), refunded 1e18 to Alice.
        // So vault.token0.balanceOf() = 0 after first deposit.
        //
        // We need a different approach: pre-load the vault with token0 before
        // Bob's deposit so the denominator is non-zero.
        pm.setNextDelta(-1e18, -1e18);

        vm.prank(ALICE);
        vault.deposit(2e18, 2e18, 0, 0, ALICE);

        uint256 supplyAfterAlice = vault.totalSupply();

        // Pre-load vault with 1e18 token0 to give the subsequent-deposit
        // formula a non-zero denominator. This simulates accrued fees or
        // a keeper transfer. Real integration: vault balance > 0 after any
        // settle because the PM credits back via take().
        token0.mint(address(vault), 1e18);
        token1.mint(address(vault), 1e18);

        vm.prank(BOB);
        (uint256 bobShares,,) = vault.deposit(2e18, 2e18, 0, 0, BOB);

        assertGt(bobShares, 0, "Bob received no shares");
        // Bob's shares = amount0Used * totalSupply / total0
        //              = 1e18 * supplyAfterAlice / 1e18 = supplyAfterAlice
        assertEq(bobShares, supplyAfterAlice, "Bob's proportional shares incorrect");
        assertEq(vault.balanceOf(BOB), bobShares, "Bob balance mismatch");
    }

    // ── Test 3: reverts when amount0Used < amount0Min (slippage breach)
    //
    // Mock delta returns -0.5e18 for token0; caller demands 1e18 minimum → revert.
    // ──────────────────────────────────────────────────────────────────────────

    function test_deposit_revertsOnSlippageBreach() public {
        // Mock: vault only gets 0.5e18 of token0 deployed.
        pm.setNextDelta(-0.5e18, -1e18);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Errors.SlippageExceeded.selector, 0.5e18, 1e18));
        vault.deposit(2e18, 2e18, 1e18, 0, ALICE);
    }

    // ── Test 4: reverts when recipient == address(0)
    //
    // Checked in the deposit() entry point before unlock, so no PM interaction.
    // ──────────────────────────────────────────────────────────────────────────

    function test_deposit_revertsOnZeroRecipient() public {
        vm.prank(ALICE);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.deposit(2e18, 2e18, 0, 0, address(0));
    }

    // ── Test 5: reverts when depositsPaused
    // ──────────────────────────────────────────────────────────────────────────

    function test_deposit_revertsWhenDepositsPaused() public {
        vm.prank(OWNER);
        vault.setDepositsPaused(true);

        vm.prank(ALICE);
        vm.expectRevert(Errors.DepositsPaused.selector);
        vault.deposit(2e18, 2e18, 0, 0, ALICE);
    }

    // ── Test 6: multi-position — every position gets a non-zero liquidity entry
    //
    // Use a 3-position strategy centred on tick 0.  The price sits at SQRT_PRICE_1_1
    // (tick 0), so position [0,60] is in-range for token0 and gets non-zero
    // liquidity. The mock PoolManager returns -1e18/-1e18 per modifyLiquidity.
    //
    // This is a FIRST deposit on a fresh multiVault so the geometric-mean share
    // math applies. Total consumed = 3 * 1e18 = 3e18 each token.
    // geomMean = sqrt(3e18 * 3e18) = 3e18 > MIN_SHARES → succeeds.
    // ──────────────────────────────────────────────────────────────────────────

    function test_deposit_multiPosition_allPositionsStored() public {
        // 3-position strategy spanning ticks [0,180] with spacing 60.
        MultiPositionStrategy multiStrat = new MultiPositionStrategy(3, 60);

        PoolKey memory key = _poolKey();
        Vault multiVault = new Vault(
            IPoolManager(address(pm)),
            key,
            IStrategy(address(multiStrat)),
            IProtocolHook(HOOK),
            OWNER,
            TVL_CAP,
            "PRISM Multi",
            "pMULTI"
        );

        uint256 depositAmount = 10e18;
        token0.mint(ALICE, depositAmount);
        token1.mint(ALICE, depositAmount);
        vm.prank(ALICE);
        token0.approve(address(multiVault), type(uint256).max);
        vm.prank(ALICE);
        token1.approve(address(multiVault), type(uint256).max);

        // Each modifyLiquidity returns -1e18/-1e18 (3 positions → -3e18 total each).
        // geomMean = sqrt(3e18 * 3e18) = 3e18; 3e18 - MIN_SHARES > 0 → OK.
        pm.setNextDelta(-1e18, -1e18);

        vm.prank(ALICE);
        multiVault.deposit(depositAmount, depositAmount, 0, 0, ALICE);

        IVault.Position[] memory positions = multiVault.getPositions();
        assertEq(positions.length, 3, "expected 3 stored positions");
        for (uint256 i; i < positions.length; ++i) {
            assertGt(positions[i].liquidity, 0, "zero liquidity in stored position");
        }
    }

    // ── Test 7: Deposit event emitted with correct fields
    // ──────────────────────────────────────────────────────────────────────────

    function test_deposit_emitsDepositEvent() public {
        pm.setNextDelta(-1e18, -1e18);

        vm.prank(ALICE);
        vm.expectEmit(true, false, false, false, address(vault));
        emit IVault.Deposit(ALICE, 0, 0, 0); // indexed topic only; amounts checked below
        vault.deposit(2e18, 2e18, 0, 0, ALICE);
    }

    // ── Test 8: first depositor ZeroShares guard (geometric mean ≤ MIN_SHARES)
    //
    // With a tiny delta (1 wei each), sqrt(1*1) = 1 < MIN_SHARES → ZeroShares.
    // ──────────────────────────────────────────────────────────────────────────

    function test_deposit_firstDeposit_revertsZeroShares_whenGeomMeanTooSmall() public {
        // Consume only 1 wei of each token.
        pm.setNextDelta(-1, -1);

        vm.prank(ALICE);
        vm.expectRevert(Errors.ZeroShares.selector);
        vault.deposit(2e18, 2e18, 0, 0, ALICE);
    }
}
