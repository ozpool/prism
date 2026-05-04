// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {Vault} from "../../src/core/Vault.sol";
import {IProtocolHook} from "../../src/interfaces/IProtocolHook.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {Errors} from "../../src/utils/Errors.sol";

/// Minimal ERC20 used by the rebalance-body integration tests.
contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Stub strategy: returns one position with weight 10_000 and a
/// configurable shouldRebalance verdict.
contract MockStrategy is IStrategy {
    int24 public lowerTick;
    int24 public upperTick;
    bool public rebalanceVerdict = true;

    function set(int24 l, int24 u, bool gate) external {
        lowerTick = l;
        upperTick = u;
        rebalanceVerdict = gate;
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
        returns (TargetPosition[] memory)
    {
        TargetPosition[] memory ps = new TargetPosition[](1);
        ps[0] = TargetPosition({tickLower: lowerTick, tickUpper: upperTick, weight: 10_000});
        return ps;
    }

    function shouldRebalance(int24, int24, uint256) external view override returns (bool) {
        return rebalanceVerdict;
    }
}

/// Minimal PoolManager stand-in. modifyLiquidity returns a configurable
/// per-call delta — the test sets it before each modifyLiquidity to
/// drive remove vs deploy paths through the same mock.
contract MockPoolManager {
    BalanceDelta public mockedDelta;
    bytes32 public mockedSlot0;

    function setDelta(int128 d0, int128 d1) external {
        mockedDelta = toBalanceDelta(d0, d1);
    }

    function setSlot0(uint160 sqrtPriceX96, int24 tick) external {
        mockedSlot0 = bytes32(uint256(sqrtPriceX96)) | bytes32(uint256(uint24(tick)) << 160);
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
        view
        returns (BalanceDelta, BalanceDelta)
    {
        return (mockedDelta, BalanceDelta.wrap(0));
    }

    function take(Currency currency, address to, uint256 amount) external {
        ERC20(Currency.unwrap(currency)).transfer(to, amount);
    }

    function settle() external payable returns (uint256) {
        return 0;
    }

    function sync(Currency) external {}

    function extsload(bytes32) external view returns (bytes32) {
        return mockedSlot0;
    }
}

contract VaultStorageTest is Test {
    address constant POOL_MANAGER = address(0xCa11);
    address constant STRATEGY = address(0x5747);
    address constant HOOK = address(0xB00C);
    address constant TOKEN0 = address(0x0001);
    address constant TOKEN1 = address(0x0002);
    address constant OWNER = address(0xACE);

    uint256 constant TVL_CAP = 1_000_000e18;

    Vault vault;

    function setUp() public {
        PoolKey memory key = _key();
        vault = new Vault(
            IPoolManager(POOL_MANAGER),
            key,
            IStrategy(STRATEGY),
            IProtocolHook(HOOK),
            OWNER,
            TVL_CAP,
            "PRISM Vault WETH/USDC",
            "pWETHUSDC"
        );
    }

    function _key() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(TOKEN0),
            currency1: Currency.wrap(TOKEN1),
            fee: 0x800000, // dynamic-fee sentinel
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });
    }

    // -------------------------------------------------------------------------
    // Construction
    // -------------------------------------------------------------------------

    function test_immutables_pinnedAtConstruction() public view {
        assertEq(address(vault.poolManager()), POOL_MANAGER);
        assertEq(address(vault.strategy()), STRATEGY);
        assertEq(address(vault.hook()), HOOK);
        assertEq(address(vault.token0()), TOKEN0);
        assertEq(address(vault.token1()), TOKEN1);
        assertEq(vault.tickSpacing(), 60);
        assertEq(vault.poolFee(), 0x800000);
    }

    function test_storage_initialState() public view {
        assertEq(vault.owner(), OWNER);
        assertEq(vault.depositsPaused(), false);
        assertEq(vault.tvlCap(), TVL_CAP);
        assertEq(vault.totalSupply(), 0);
    }

    function test_metadata() public view {
        assertEq(vault.name(), "PRISM Vault WETH/USDC");
        assertEq(vault.symbol(), "pWETHUSDC");
        assertEq(vault.decimals(), 18);
    }

    function test_constants() public view {
        assertEq(vault.MIN_SHARES(), 1000);
        assertEq(vault.MAX_POSITIONS(), 7);
        assertEq(vault.DEAD(), 0x000000000000000000000000000000000000dEaD);
    }

    function test_poolKey_returnsConstructedKey() public view {
        PoolKey memory k = vault.poolKey();
        assertEq(Currency.unwrap(k.currency0), TOKEN0);
        assertEq(Currency.unwrap(k.currency1), TOKEN1);
        assertEq(k.fee, 0x800000);
        assertEq(k.tickSpacing, 60);
        assertEq(address(k.hooks), HOOK);
    }

    // -------------------------------------------------------------------------
    // Constructor reverts
    // -------------------------------------------------------------------------

    function test_constructor_revertsOnZeroPoolManager() public {
        PoolKey memory key = _key();
        vm.expectRevert(Errors.ZeroAddress.selector);
        new Vault(IPoolManager(address(0)), key, IStrategy(STRATEGY), IProtocolHook(HOOK), OWNER, TVL_CAP, "n", "s");
    }

    function test_constructor_revertsOnZeroStrategy() public {
        PoolKey memory key = _key();
        vm.expectRevert(Errors.ZeroAddress.selector);
        new Vault(IPoolManager(POOL_MANAGER), key, IStrategy(address(0)), IProtocolHook(HOOK), OWNER, TVL_CAP, "n", "s");
    }

    function test_constructor_revertsOnZeroHook() public {
        PoolKey memory key = _key();
        vm.expectRevert(Errors.ZeroAddress.selector);
        new Vault(
            IPoolManager(POOL_MANAGER), key, IStrategy(STRATEGY), IProtocolHook(address(0)), OWNER, TVL_CAP, "n", "s"
        );
    }

    function test_constructor_revertsOnZeroOwner() public {
        PoolKey memory key = _key();
        vm.expectRevert(Errors.ZeroAddress.selector);
        new Vault(
            IPoolManager(POOL_MANAGER), key, IStrategy(STRATEGY), IProtocolHook(HOOK), address(0), TVL_CAP, "n", "s"
        );
    }

    function test_constructor_revertsOnZeroTvlCap() public {
        PoolKey memory key = _key();
        vm.expectRevert();
        new Vault(IPoolManager(POOL_MANAGER), key, IStrategy(STRATEGY), IProtocolHook(HOOK), OWNER, 0, "n", "s");
    }

    // -------------------------------------------------------------------------
    // Admin levers
    // -------------------------------------------------------------------------

    function test_setDepositsPaused_onlyOwner() public {
        vm.prank(address(0x1234));
        vm.expectRevert(Errors.OnlyOwner.selector);
        vault.setDepositsPaused(true);
    }

    function test_setDepositsPaused_owner() public {
        vm.prank(OWNER);
        vault.setDepositsPaused(true);
        assertTrue(vault.depositsPaused());

        vm.prank(OWNER);
        vault.setDepositsPaused(false);
        assertFalse(vault.depositsPaused());
    }

    function test_setTVLCap_onlyOwner() public {
        vm.prank(address(0x1234));
        vm.expectRevert(Errors.OnlyOwner.selector);
        vault.setTVLCap(2_000_000e18);
    }

    function test_setTVLCap_owner() public {
        vm.prank(OWNER);
        vault.setTVLCap(2_000_000e18);
        assertEq(vault.tvlCap(), 2_000_000e18);
    }

    function test_setTVLCap_revertsOnZero() public {
        vm.prank(OWNER);
        vm.expectRevert();
        vault.setTVLCap(0);
    }

    function test_transferOwnership_onlyOwner() public {
        vm.prank(address(0x1234));
        vm.expectRevert(Errors.OnlyOwner.selector);
        vault.transferOwnership(address(0x5678));
    }

    function test_transferOwnership_owner() public {
        vm.prank(OWNER);
        vault.transferOwnership(address(0x5678));
        assertEq(vault.owner(), address(0x5678));
    }

    function test_transferOwnership_revertsOnZero() public {
        vm.prank(OWNER);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.transferOwnership(address(0));
    }

    // -------------------------------------------------------------------------
    // Stub method reverts (replaced by #27/#28/#29)
    // -------------------------------------------------------------------------

    function test_deposit_revertsWhenPaused() public {
        vm.prank(OWNER);
        vault.setDepositsPaused(true);

        vm.expectRevert(Errors.DepositsPaused.selector);
        vault.deposit(1e18, 1e18, 0, 0, address(this));
    }

    function test_deposit_revertsOnZeroRecipient() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.deposit(1e18, 1e18, 0, 0, address(0));
    }

    function test_deposit_revertsOnZeroAmounts() public {
        vm.expectRevert(Errors.ZeroShares.selector);
        vault.deposit(0, 0, 0, 0, address(this));
    }

    function test_unlockCallback_revertsForNonPoolManager() public {
        vm.expectRevert(Errors.OnlyPoolManager.selector);
        vault.unlockCallback(abi.encode(uint8(0), bytes("")));
    }

    function test_withdraw_revertsOnZeroShares() public {
        vm.expectRevert(Errors.InvalidShareAmount.selector);
        vault.withdraw(0, 0, 0, address(this));
    }

    function test_withdraw_revertsOnInsufficientBalance() public {
        vm.expectRevert(Errors.InvalidShareAmount.selector);
        vault.withdraw(1, 0, 0, address(this));
    }

    function test_withdraw_revertsOnZeroRecipient() public {
        // Mint shares directly (bypassing deposit) to test the recipient
        // check independently of the deposit flow.
        deal(address(vault), address(this), 1e18);
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.withdraw(1, 0, 0, address(0));
    }

    function test_withdraw_neverPaused() public {
        // Even with deposits paused, withdraw must remain reachable.
        vm.prank(OWNER);
        vault.setDepositsPaused(true);

        // Withdraw still validates (zero shares → InvalidShareAmount),
        // not DepositsPaused.
        vm.expectRevert(Errors.InvalidShareAmount.selector);
        vault.withdraw(0, 0, 0, address(this));
    }

    function test_rebalance_revertsWhenStrategyGateClosed() public {
        // Mock the StateLibrary.getSlot0 extsload + the strategy gate.
        // The pool manager is a stub address with no code, so extsload
        // would otherwise revert before reaching the strategy check.
        vm.etch(POOL_MANAGER, hex"60");
        vm.mockCall(
            POOL_MANAGER, abi.encodeWithSelector(bytes4(keccak256("extsload(bytes32)"))), abi.encode(bytes32(0))
        );
        vm.mockCall(STRATEGY, abi.encodeWithSelector(IStrategy.shouldRebalance.selector), abi.encode(false));

        vm.expectRevert(Errors.RebalanceNotNeeded.selector);
        vault.rebalance();
    }

    function test_rebalance_lastTimestampInitiallyZero() public view {
        assertEq(vault.lastRebalanceTimestamp(), 0);
        assertEq(vault.lastRebalanceTick(), 0);
    }

    function test_views_emptyVaultReturnsZeros() public {
        // getPositions returns empty array on a fresh vault.
        Vault.Position[] memory ps = vault.getPositions();
        assertEq(ps.length, 0);

        // Mock token balances — stub addresses have no code.
        vm.mockCall(TOKEN0, abi.encodeWithSignature("balanceOf(address)", address(vault)), abi.encode(uint256(0)));
        vm.mockCall(TOKEN1, abi.encodeWithSignature("balanceOf(address)", address(vault)), abi.encode(uint256(0)));

        (uint256 a, uint256 b) = vault.getTotalAmounts();
        assertEq(a, 0);
        assertEq(b, 0);
    }

    // -------------------------------------------------------------------------
    // ERC-20 base behaviour (transfers, allowances)
    // -------------------------------------------------------------------------

    function test_erc20_initialBalances() public view {
        assertEq(vault.balanceOf(OWNER), 0);
        assertEq(vault.balanceOf(address(this)), 0);
    }

    function test_erc20_transfer_zeroBalance() public {
        vm.expectRevert();
        vault.transfer(address(0x9999), 1);
    }
}

// =============================================================================
// VaultRebalanceTest — exercises _handleRebalance + currentTick wire-up +
// getTotalAmounts against the mock pool. Real V4 settle/take is exercised
// in the fork suite (#42); the mock is enough to drive the dispatch shape
// and the keeper-bonus math.
// =============================================================================

contract VaultRebalanceTest is Test {
    address constant HOOK = address(0xB00C);
    address constant OWNER = address(0xACE);

    /// Sqrt-price for tick 0 — gives equal-weight token0/token1 deploys.
    uint160 constant SQRT_PRICE_TICK_0 = 79_228_162_514_264_337_593_543_950_336;

    uint256 constant TVL_CAP = 1_000_000e18;

    Vault vault;
    MockERC20 token0;
    MockERC20 token1;
    MockStrategy strategy;
    MockPoolManager pool;
    PoolKey key;

    function setUp() public {
        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");
        if (uint160(address(token1)) < uint160(address(token0))) {
            (token0, token1) = (token1, token0);
        }

        strategy = new MockStrategy();
        strategy.set(-600, 600, true);
        pool = new MockPoolManager();
        pool.setSlot0(SQRT_PRICE_TICK_0, 0);

        key = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 0x800000,
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });

        vault = new Vault(
            IPoolManager(address(pool)),
            key,
            IStrategy(address(strategy)),
            IProtocolHook(HOOK),
            OWNER,
            TVL_CAP,
            "v",
            "v"
        );
    }

    function test_rebalance_revertsWhenStrategyGateClosed() public {
        strategy.set(-600, 600, false);
        vm.expectRevert(Errors.RebalanceNotNeeded.selector);
        vault.rebalance();
    }

    function test_rebalance_emptyVaultDeploysAndCreditsKeeperBonus() public {
        // Pre-mint shares to a depositor + DEAD so the bonus has a base
        // to pro-rate against. 100_000 supply → 5 bps = 50 share bonus.
        deal(address(vault), address(0xBEEF), 99_000, true);
        deal(address(vault), 0x000000000000000000000000000000000000dEaD, 1000, true);

        // Vault holds 1_000 of each token idle.
        token0.mint(address(vault), 1000);
        token1.mint(address(vault), 1000);

        // No prior positions to remove. Mock the deploy delta: vault
        // owes 800 of each (the strategy consumes 80% of idle).
        pool.setDelta(int128(-800), int128(-800));

        address keeper = address(0xBEE9E2);
        vm.prank(keeper);
        vault.rebalance();

        // One position deployed.
        Vault.Position[] memory ps = vault.getPositions();
        assertEq(ps.length, 1, "position count");

        // Keeper bonus: 5 bps of 100_000 = 50 shares.
        assertEq(vault.balanceOf(keeper), 50, "keeper bonus");

        // Last-rebalance state recorded — currentTick was 0 from setUp.
        assertEq(vault.lastRebalanceTick(), 0, "lastRebalanceTick");
        assertEq(vault.lastRebalanceTimestamp(), block.timestamp, "lastRebalanceTimestamp");
    }

    function test_rebalance_revertsOnBadStrategyShape() public {
        // Strategy returns 0 positions — invariant 3 trip.
        BadStrategy bad = new BadStrategy();
        vault = new Vault(
            IPoolManager(address(pool)), key, IStrategy(address(bad)), IProtocolHook(HOOK), OWNER, TVL_CAP, "v", "v"
        );

        vm.expectRevert();
        vault.rebalance();
    }

    function test_getTotalAmounts_emptyPositions_returnsIdleOnly() public {
        token0.mint(address(vault), 12_345);
        token1.mint(address(vault), 67_890);

        (uint256 a, uint256 b) = vault.getTotalAmounts();
        assertEq(a, 12_345, "total0");
        assertEq(b, 67_890, "total1");
    }
}

/// Strategy that misbehaves — returns zero positions. Exercises invariant 3.
contract BadStrategy is IStrategy {
    function computePositions(
        int24,
        int24,
        uint256,
        uint256
    )
        external
        pure
        override
        returns (TargetPosition[] memory)
    {
        return new TargetPosition[](0);
    }

    function shouldRebalance(int24, int24, uint256) external pure override returns (bool) {
        return true;
    }
}
