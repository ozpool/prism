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

contract RTestERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Mock PoolManager covering the full rebalance path: take + modifyLiquidity
///      with sequencing semantics (one delta queued per call).
contract RMockPoolManager {
    bytes32 public slot0Word;

    // Sequence of deltas returned by modifyLiquidity, one per call.
    // Index increments on every call.
    BalanceDelta[] public deltas;
    uint256 public callIndex;
    uint256 public modifyCount;

    function setSlot0(uint160 sqrtPriceX96, int24 tick) external {
        bytes32 packed;
        assembly ("memory-safe") {
            packed := and(sqrtPriceX96, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            packed := or(packed, shl(160, and(tick, 0xFFFFFF)))
        }
        slot0Word = packed;
    }

    function pushDelta(int128 amount0, int128 amount1) external {
        deltas.push(toBalanceDelta(amount0, amount1));
    }

    function resetDeltas() external {
        delete deltas;
        callIndex = 0;
    }

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
        callerDelta = callIndex < deltas.length ? deltas[callIndex] : toBalanceDelta(0, 0);
        ++callIndex;
        feesAccrued = toBalanceDelta(0, 0);
    }

    function sync(Currency) external {}

    function settle() external payable returns (uint256) {
        return 0;
    }

    function settleFor(address) external payable returns (uint256) {
        return 0;
    }

    function take(Currency currency, address to, uint256 amount) external {
        IERC20(Currency.unwrap(currency)).transfer(to, amount);
    }

    // Unused IPoolManager surface — revert if hit.
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

/// @dev Strategy with externally settable shape and rebalance gate.
contract RControllableStrategy is IStrategy {
    bool public gate;
    TargetPosition[] internal _next;

    function setGate(bool v) external {
        gate = v;
    }

    function setShape(TargetPosition[] calldata positions) external {
        delete _next;
        for (uint256 i; i < positions.length; ++i) {
            _next.push(positions[i]);
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
        returns (TargetPosition[] memory positions)
    {
        positions = new TargetPosition[](_next.length);
        for (uint256 i; i < _next.length; ++i) {
            positions[i] = _next[i];
        }
    }

    function shouldRebalance(int24, int24, uint256) external view override returns (bool) {
        return gate;
    }
}

contract VaultRebalanceTest is Test {
    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    int24 constant TICK_SPACING = 60;

    address constant HOOK = address(0xB00C);
    address constant OWNER = address(0xACE);
    uint256 constant TVL_CAP = type(uint256).max;
    address constant ALICE = address(0xA11CE);

    RMockPoolManager pm;
    RTestERC20 token0;
    RTestERC20 token1;
    Vault vault;
    RControllableStrategy strategy;

    function setUp() public {
        pm = new RMockPoolManager();

        RTestERC20 ta = new RTestERC20("TokenA", "TA");
        RTestERC20 tb = new RTestERC20("TokenB", "TB");
        if (address(ta) < address(tb)) {
            token0 = ta;
            token1 = tb;
        } else {
            token0 = tb;
            token1 = ta;
        }

        strategy = new RControllableStrategy();

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
            "PRISM",
            "pVAULT"
        );

        pm.setSlot0(SQRT_PRICE_1_1, 0);

        token0.mint(ALICE, 1000e18);
        token1.mint(ALICE, 1000e18);
        vm.prank(ALICE);
        token0.approve(address(vault), type(uint256).max);
        vm.prank(ALICE);
        token1.approve(address(vault), type(uint256).max);
    }

    /// @dev Seed the vault with one position via deposit. Sets the strategy
    ///      to a single-position shape covering [-60, 60].
    function _seedDeposit() internal {
        IStrategy.TargetPosition[] memory shape = new IStrategy.TargetPosition[](1);
        shape[0] = IStrategy.TargetPosition({tickLower: -60, tickUpper: 60, weight: 10_000});
        strategy.setShape(shape);

        // Deposit consumes 1e18/1e18 of each.
        pm.pushDelta(-1e18, -1e18);
        vm.prank(ALICE);
        vault.deposit(2e18, 2e18, 0, 0, ALICE);
    }

    // ── Test 1: closed gate reverts RebalanceNotNeeded ────────────────────
    function test_rebalance_revertsWhenGateClosed() public {
        _seedDeposit();
        strategy.setGate(false);
        vm.expectRevert(Errors.RebalanceNotNeeded.selector);
        vault.rebalance();
    }

    // ── Test 2: open gate executes the unlock body, emits Rebalanced ──────
    function test_rebalance_openGate_emitsEvent() public {
        _seedDeposit();
        strategy.setGate(true);

        // Pre-fund mock with the tokens it would owe back via `take`.
        token0.mint(address(pm), 1e18);
        token1.mint(address(pm), 1e18);

        // Sequence on rebalance:
        //   1) modifyLiquidity (remove)  → +1e18/+1e18 (positive: take into vault)
        //   2) modifyLiquidity (deploy)  → -1e18/-1e18 (negative: vault owes pool)
        pm.pushDelta(1e18, 1e18);
        pm.pushDelta(-1e18, -1e18);

        // Same shape on redeploy.
        IStrategy.TargetPosition[] memory shape = new IStrategy.TargetPosition[](1);
        shape[0] = IStrategy.TargetPosition({tickLower: -60, tickUpper: 60, weight: 10_000});
        strategy.setShape(shape);

        vm.expectEmit(false, false, false, false, address(vault));
        emit IVault.Rebalanced(0, 0, 0); // topics-only check
        vault.rebalance();
    }

    // ── Test 3: lastRebalanceTick / lastRebalanceTimestamp updated ────────
    function test_rebalance_updatesLastTickAndTimestamp() public {
        _seedDeposit();
        strategy.setGate(true);
        token0.mint(address(pm), 1e18);
        token1.mint(address(pm), 1e18);
        pm.pushDelta(1e18, 1e18);
        pm.pushDelta(-1e18, -1e18);

        IStrategy.TargetPosition[] memory shape = new IStrategy.TargetPosition[](1);
        shape[0] = IStrategy.TargetPosition({tickLower: -60, tickUpper: 60, weight: 10_000});
        strategy.setShape(shape);

        // Move pool tick before rebalance.
        pm.setSlot0(SQRT_PRICE_1_1, 42);
        vm.warp(123_456);

        vault.rebalance();

        assertEq(vault.lastRebalanceTick(), int24(42), "lastRebalanceTick not updated");
        assertEq(vault.lastRebalanceTimestamp(), 123_456, "lastRebalanceTimestamp not updated");
    }

    // ── Test 4: positions array swapped to new shape ──────────────────────
    function test_rebalance_replacesPositions() public {
        _seedDeposit();
        // After deposit there is 1 position at [-60, 60].
        assertEq(vault.getPositions().length, 1, "expected 1 seed position");

        strategy.setGate(true);
        token0.mint(address(pm), 1e18);
        token1.mint(address(pm), 1e18);

        // Two new positions.
        IStrategy.TargetPosition[] memory shape = new IStrategy.TargetPosition[](2);
        shape[0] = IStrategy.TargetPosition({tickLower: -120, tickUpper: 0, weight: 5000});
        shape[1] = IStrategy.TargetPosition({tickLower: 0, tickUpper: 120, weight: 5000});
        strategy.setShape(shape);

        // Sequence: 1 remove + 2 deploy = 3 modifyLiquidity calls.
        pm.pushDelta(1e18, 1e18); // remove
        pm.pushDelta(-1e17, -1e17); // deploy[0]
        pm.pushDelta(-1e17, -1e17); // deploy[1]

        vault.rebalance();

        IVault.Position[] memory after_ = vault.getPositions();
        assertEq(after_.length, 2, "expected 2 positions after rebalance");
        assertEq(after_[0].tickLower, int24(-120), "shape[0] lower mismatch");
        assertEq(after_[1].tickUpper, int24(120), "shape[1] upper mismatch");
    }

    // ── Test 5: rebalance with malformed weights reverts WeightsDoNotSum ──
    function test_rebalance_revertsOnBadWeights() public {
        _seedDeposit();
        strategy.setGate(true);
        token0.mint(address(pm), 1e18);
        token1.mint(address(pm), 1e18);
        // Weights sum to 9000 (not 10_000).
        IStrategy.TargetPosition[] memory shape = new IStrategy.TargetPosition[](1);
        shape[0] = IStrategy.TargetPosition({tickLower: -60, tickUpper: 60, weight: 9000});
        strategy.setShape(shape);

        // Only the remove call should land before the revert.
        pm.pushDelta(1e18, 1e18);

        vm.expectRevert(abi.encodeWithSelector(Errors.WeightsDoNotSum.selector, 9000));
        vault.rebalance();
    }

    // ── Test 6: rebalance with too many positions reverts MaxPositionsExceeded
    function test_rebalance_revertsOnTooManyPositions() public {
        _seedDeposit();
        strategy.setGate(true);
        token0.mint(address(pm), 1e18);
        token1.mint(address(pm), 1e18);

        // 8 positions > MAX_POSITIONS (7).
        IStrategy.TargetPosition[] memory shape = new IStrategy.TargetPosition[](8);
        for (uint256 i; i < 8; ++i) {
            shape[i] = IStrategy.TargetPosition({
                tickLower: int24(int256(i) * 60 - 240), tickUpper: int24(int256(i) * 60 - 180), weight: 1250
            });
        }
        strategy.setShape(shape);

        pm.pushDelta(1e18, 1e18); // remove

        vm.expectRevert(abi.encodeWithSelector(Errors.MaxPositionsExceeded.selector, 8));
        vault.rebalance();
    }
}
