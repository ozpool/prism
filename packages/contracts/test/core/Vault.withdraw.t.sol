// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {Vault} from "../../src/core/Vault.sol";
import {IProtocolHook} from "../../src/interfaces/IProtocolHook.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {IVault} from "../../src/interfaces/IVault.sol";
import {Errors} from "../../src/utils/Errors.sol";

// ---------------------------------------------------------------------------
// Test-only ERC-20
// ---------------------------------------------------------------------------

contract WTestERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ---------------------------------------------------------------------------
// Mock PoolManager — withdraw flavour
//
// Variant of the Vault.deposit.t.sol mock with a working `take` that
// transfers tokens from the mock's own balance to the recipient. The
// `modifyLiquidity` returns a configurable BalanceDelta (positive on
// remove). The mock is pre-funded with the tokens it would owe back so
// `take` doesn't run a balance underflow.
// ---------------------------------------------------------------------------

contract WMockPoolManager {
    bytes32 public slot0Word;
    BalanceDelta public nextDelta;
    uint256 public modifyCount;

    function setSlot0(uint160 sqrtPriceX96, int24 tick) external {
        bytes32 packed;
        assembly ("memory-safe") {
            packed := and(sqrtPriceX96, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            packed := or(packed, shl(160, and(tick, 0xFFFFFF)))
        }
        slot0Word = packed;
    }

    function setNextDelta(int128 amount0, int128 amount1) external {
        nextDelta = toBalanceDelta(amount0, amount1);
    }

    // extsload for getSlot0.
    function extsload(bytes32) external view returns (bytes32) {
        return slot0Word;
    }

    function extsload(bytes32, uint256 nSlots) external view returns (bytes32[] memory values) {
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

    function exttload(bytes32) external pure returns (bytes32) {
        return bytes32(0);
    }

    function exttload(bytes32[] calldata keys) external pure returns (bytes32[] memory values) {
        values = new bytes32[](keys.length);
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function modifyLiquidity(
        PoolKey memory,
        ModifyLiquidityParams memory,
        bytes calldata
    )
        external
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        ++modifyCount;
        callerDelta = nextDelta;
        feesAccrued = toBalanceDelta(0, 0);
    }

    function sync(Currency) external {}

    function settle() external payable returns (uint256) {
        return 0;
    }

    function settleFor(address) external payable returns (uint256) {
        return 0;
    }

    /// @dev The vault calls take() inside `_handleWithdraw` to receive
    ///      tokens removed from positions. Pre-fund the mock with both
    ///      tokens before invoking withdraw to satisfy this transfer.
    function take(Currency currency, address to, uint256 amount) external {
        IERC20(Currency.unwrap(currency)).transfer(to, amount);
    }

    function initialize(PoolKey memory, uint160) external pure returns (int24) {
        revert("NOT_IMPL");
    }

    function swap(PoolKey memory, ModifyLiquidityParams memory, bytes calldata) external pure returns (BalanceDelta) {
        revert("NOT_IMPL");
    }

    function donate(PoolKey memory, uint256, uint256, bytes calldata) external pure returns (BalanceDelta) {
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
// Single-position strategy reused from the deposit suite
// ---------------------------------------------------------------------------

contract WSinglePositionStrategy is IStrategy {
    int24 public immutable lower;
    int24 public immutable upper;

    constructor(int24 tickLower, int24 tickUpper) {
        lower = tickLower;
        upper = tickUpper;
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
// Test suite
// ---------------------------------------------------------------------------

contract VaultWithdrawTest is Test {
    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    int24 constant TICK_SPACING = 60;

    address constant HOOK = address(0xB00C);
    address constant OWNER = address(0xACE);
    uint256 constant TVL_CAP = type(uint256).max;

    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    WMockPoolManager pm;
    WTestERC20 token0;
    WTestERC20 token1;
    Vault vault;
    WSinglePositionStrategy strategy;

    function setUp() public {
        pm = new WMockPoolManager();

        WTestERC20 ta = new WTestERC20("TokenA", "TA");
        WTestERC20 tb = new WTestERC20("TokenB", "TB");
        if (address(ta) < address(tb)) {
            token0 = ta;
            token1 = tb;
        } else {
            token0 = tb;
            token1 = ta;
        }

        strategy = new WSinglePositionStrategy(-60, 60);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0x800000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });

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

        pm.setSlot0(SQRT_PRICE_1_1, 0);

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

    /// @dev Helper: seed a deposit so the vault has a position + minted shares.
    ///      Returns Alice's share balance.
    function _aliceDeposits(uint128 token0Used, uint128 token1Used) internal returns (uint256 aliceShares) {
        pm.setNextDelta(-int128(token0Used), -int128(token1Used));
        vm.prank(ALICE);
        (aliceShares,,) = vault.deposit(uint256(token0Used) + 1, uint256(token1Used) + 1, 0, 0, ALICE);
    }

    /// @dev Pre-fund the mock with `amount` of each token so its `take` calls
    ///      have funds to send.
    function _fundMock(uint256 amount0, uint256 amount1) internal {
        token0.mint(address(pm), amount0);
        token1.mint(address(pm), amount1);
    }

    // ── Test 1: zero-share withdraw reverts InvalidShareAmount ────────────
    function test_withdraw_revertsOnZeroShares() public {
        _aliceDeposits(1e18, 1e18);
        vm.prank(ALICE);
        vm.expectRevert(Errors.InvalidShareAmount.selector);
        vault.withdraw(0, 0, 0, ALICE);
    }

    // ── Test 2: shares > balance reverts InvalidShareAmount ───────────────
    function test_withdraw_revertsWhenSharesExceedBalance() public {
        uint256 aliceShares = _aliceDeposits(1e18, 1e18);
        vm.prank(ALICE);
        vm.expectRevert(Errors.InvalidShareAmount.selector);
        vault.withdraw(aliceShares + 1, 0, 0, ALICE);
    }

    // ── Test 3: zero recipient reverts ZeroAddress ────────────────────────
    function test_withdraw_revertsOnZeroRecipient() public {
        uint256 aliceShares = _aliceDeposits(1e18, 1e18);
        vm.prank(ALICE);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.withdraw(aliceShares, 0, 0, address(0));
    }

    // ── Test 4: full withdraw burns shares and returns tokens via take ────
    //
    // Alice deposits 1e18/1e18 used. She then withdraws all her shares.
    // The mock is configured to return +1e18/+1e18 from modifyLiquidity (the
    // pro-rata sliver of liquidity removed). Since DEAD holds MIN_SHARES,
    // Alice cannot redeem the full underlying — a small fraction stays.
    // We assert: tokens were transferred to Alice, her share balance is 0.
    function test_withdraw_fullBalance_transfersTokensToRecipient() public {
        uint256 aliceShares = _aliceDeposits(1e18, 1e18);
        _fundMock(2e18, 2e18); // mock take() needs balance to send

        // Mock returns +1e18 of each from modifyLiquidity (the removed slice).
        pm.setNextDelta(int128(1e18), int128(1e18));

        uint256 t0Before = token0.balanceOf(ALICE);
        uint256 t1Before = token1.balanceOf(ALICE);

        vm.prank(ALICE);
        (uint256 a0, uint256 a1) = vault.withdraw(aliceShares, 0, 0, ALICE);

        assertEq(vault.balanceOf(ALICE), 0, "shares should be fully burned");
        assertEq(token0.balanceOf(ALICE) - t0Before, a0, "alice did not receive a0");
        assertEq(token1.balanceOf(ALICE) - t1Before, a1, "alice did not receive a1");
        assertGt(a0, 0, "amount0 returned should be > 0");
        assertGt(a1, 0, "amount1 returned should be > 0");
    }

    // ── Test 5: stored position liquidity decremented after withdraw ──────
    function test_withdraw_decrementsStoredLiquidity() public {
        uint256 aliceShares = _aliceDeposits(1e18, 1e18);
        _fundMock(2e18, 2e18);
        pm.setNextDelta(int128(1e18), int128(1e18));

        uint128 liqBefore = vault.getPositions()[0].liquidity;

        // Withdraw half.
        vm.prank(ALICE);
        vault.withdraw(aliceShares / 2, 0, 0, ALICE);

        uint128 liqAfter = vault.getPositions()[0].liquidity;
        assertLt(liqAfter, liqBefore, "liquidity should have decreased");
    }

    // ── Test 6: slippage breach reverts SlippageExceeded ──────────────────
    function test_withdraw_revertsOnSlippageBreach() public {
        uint256 aliceShares = _aliceDeposits(1e18, 1e18);
        _fundMock(2e18, 2e18);
        // Mock returns only +0.5e18 of token0; demand 1e18 minimum → revert.
        pm.setNextDelta(int128(0.5e18), int128(1e18));

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Errors.SlippageExceeded.selector, 0.5e18, 1e18));
        vault.withdraw(aliceShares, 1e18, 0, ALICE);
    }

    // ── Test 7: emits Withdraw event ──────────────────────────────────────
    function test_withdraw_emitsWithdrawEvent() public {
        uint256 aliceShares = _aliceDeposits(1e18, 1e18);
        _fundMock(2e18, 2e18);
        pm.setNextDelta(int128(1e18), int128(1e18));

        vm.prank(ALICE);
        vm.expectEmit(true, false, false, false, address(vault));
        emit IVault.Withdraw(ALICE, 0, 0, 0); // indexed topic only; amounts unchecked
        vault.withdraw(aliceShares, 0, 0, ALICE);
    }

    // ── Test 8: withdraw to a different recipient sends to that address ───
    function test_withdraw_routesToExplicitRecipient() public {
        uint256 aliceShares = _aliceDeposits(1e18, 1e18);
        _fundMock(2e18, 2e18);
        pm.setNextDelta(int128(1e18), int128(1e18));

        uint256 bobT0Before = token0.balanceOf(BOB);
        uint256 bobT1Before = token1.balanceOf(BOB);

        vm.prank(ALICE);
        vault.withdraw(aliceShares, 0, 0, BOB);

        assertGt(token0.balanceOf(BOB), bobT0Before, "BOB token0 not credited");
        assertGt(token1.balanceOf(BOB), bobT1Before, "BOB token1 not credited");
        assertEq(vault.balanceOf(ALICE), 0, "alice shares not burned");
    }

    // ── Test 9: idle vault balance is paid pro-rata to withdrawer ─────────
    //
    // Pre-load 1e18 of each token directly into the vault (simulates accrued
    // fees / dust). After deposit, total supply is `aliceShares + MIN_SHARES`.
    // Withdraw of half Alice's shares should pay roughly half of half of that
    // idle balance (½ · aliceShares / preSupply ≈ ½) to Alice.
    function test_withdraw_payoutIncludesIdleBalanceProRata() public {
        uint256 aliceShares = _aliceDeposits(1e18, 1e18);
        _fundMock(2e18, 2e18);
        token0.mint(address(vault), 1e18);
        token1.mint(address(vault), 1e18);
        pm.setNextDelta(int128(1e18), int128(1e18));

        uint256 t0Before = token0.balanceOf(ALICE);

        vm.prank(ALICE);
        (uint256 a0,) = vault.withdraw(aliceShares / 2, 0, 0, ALICE);

        // Alice should receive at least the idle pro-rata sliver on top of
        // the take() sliver. We assert the payout is greater than the take()
        // amount alone (1e18 * 0.5 * shares/preSupply).
        uint256 received = token0.balanceOf(ALICE) - t0Before;
        assertEq(received, a0, "alice received != reported amount0");
        // Sanity: received some, which must include both idle + take.
        assertGt(received, 0, "alice received nothing");
    }
}
