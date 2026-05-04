// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IExtsload} from "v4-core/interfaces/IExtsload.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {Vault} from "../../src/core/Vault.sol";
import {IProtocolHook} from "../../src/interfaces/IProtocolHook.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {Errors} from "../../src/utils/Errors.sol";

/// Minimal ERC20 used by the deposit-body tests so the vault can run
/// real `safeTransferFrom` / `safeTransfer` against funded balances.
contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Stub strategy that returns a single tick range with weight 10_000.
contract MockStrategy is IStrategy {
    int24 public lowerTick;
    int24 public upperTick;
    bool public misbehave;
    uint256 public extraPositions;

    function set(int24 l, int24 u) external {
        lowerTick = l;
        upperTick = u;
    }

    function setMisbehave(bool m) external {
        misbehave = m;
    }

    function setExtraPositions(uint256 n) external {
        extraPositions = n;
    }

    function computePositions(
        int24, /* currentTick */
        int24, /* tickSpacing */
        uint256, /* amount0 */
        uint256 /* amount1 */
    )
        external
        view
        override
        returns (TargetPosition[] memory)
    {
        if (extraPositions > 0) {
            TargetPosition[] memory many = new TargetPosition[](extraPositions);
            for (uint256 i = 0; i < extraPositions; i++) {
                many[i] = TargetPosition({tickLower: lowerTick, tickUpper: upperTick, weight: 1});
            }
            return many;
        }
        TargetPosition[] memory ps = new TargetPosition[](1);
        ps[0] = TargetPosition({tickLower: lowerTick, tickUpper: upperTick, weight: misbehave ? 9999 : 10_000});
        return ps;
    }

    function shouldRebalance(int24, int24, uint256) external pure override returns (bool) {
        return false;
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

    function test_rebalance_stubReverts() public {
        vm.expectRevert(Errors.UnknownOp.selector);
        vault.rebalance();
    }

    function test_views_stubsAreSafe() public view {
        // getPositions returns empty array on a fresh vault.
        Vault.Position[] memory ps = vault.getPositions();
        assertEq(ps.length, 0);

        // getTotalAmounts returns 0/0 stub.
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
// VaultDepositTest — exercises _handleDeposit against mock ERC20s and a
// mocked PoolManager. Slot0 / unlock / modifyLiquidity / settle / take /
// sync are all faked via vm.mockCall so the test runs without bringing
// up a real PoolManager.
// =============================================================================

contract VaultDepositTest is Test {
    address constant HOOK = address(0xB00C);
    address constant OWNER = address(0xACE);
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// Sqrt-price for tick 0 — produces equal-weighted token0/token1.
    uint160 constant SQRT_PRICE_TICK_0 = 79_228_162_514_264_337_593_543_950_336;

    uint256 constant TVL_CAP = 1_000_000e18;

    Vault vault;
    MockERC20 token0;
    MockERC20 token1;
    MockStrategy strategy;
    MockPoolManager pool;
    PoolKey key;

    function setUp() public {
        // Deterministic order: token0 < token1.
        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");
        if (uint160(address(token1)) < uint160(address(token0))) {
            (token0, token1) = (token1, token0);
        }

        strategy = new MockStrategy();
        strategy.set(-600, 600);
        pool = new MockPoolManager();

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

        _mockSlot0(0);
    }

    function test_deposit_firstDepositMintsSharesAndBurnsMin() public {
        uint256 a0 = 10e18;
        uint256 a1 = 10e18;
        token0.mint(address(this), a0);
        token1.mint(address(this), a1);
        token0.approve(address(vault), a0);
        token1.approve(address(vault), a1);

        // Mock the modifyLiquidity call: vault owes 9e18 / 9e18 (90% of desired,
        // 10% refunded as if liquidity didn't fully consume).
        pool.setDelta(int128(-9e18), int128(-9e18));

        (uint256 shares, uint256 amt0, uint256 amt1) = vault.deposit(a0, a1, 1, 1, address(this));

        assertEq(amt0, 9e18, "amt0 used");
        assertEq(amt1, 9e18, "amt1 used");

        // First-deposit shares = sqrt(9e18 * 9e18) - MIN_SHARES = 9e18 - 1000.
        uint256 expectedShares = Math.sqrt(uint256(9e18) * uint256(9e18)) - 1000;
        assertEq(shares, expectedShares, "shares");
        assertEq(vault.balanceOf(address(this)), expectedShares, "shares minted to depositor");
        assertEq(vault.balanceOf(DEAD), 1000, "MIN_SHARES burn");

        // Refund — depositor should hold the unused 1e18 of each token back.
        assertEq(token0.balanceOf(address(this)), 1e18, "refund0");
        assertEq(token1.balanceOf(address(this)), 1e18, "refund1");

        // Position recorded.
        Vault.Position[] memory positions = vault.getPositions();
        assertEq(positions.length, 1, "position count");
        assertEq(positions[0].tickLower, -600, "tickLower");
        assertEq(positions[0].tickUpper, 600, "tickUpper");
    }

    function test_deposit_revertsOnSlippage() public {
        token0.mint(address(this), 10e18);
        token1.mint(address(this), 10e18);
        token0.approve(address(vault), 10e18);
        token1.approve(address(vault), 10e18);

        // Mock so the strategy actually consumes only 1e18 of each — well
        // under the user-supplied min of 5e18.
        pool.setDelta(int128(-1e18), int128(-1e18));

        vm.expectRevert(abi.encodeWithSelector(Errors.SlippageExceeded.selector, 1e18, 5e18));
        vault.deposit(10e18, 10e18, 5e18, 5e18, address(this));
    }

    function test_deposit_revertsOnBadStrategyWeights() public {
        token0.mint(address(this), 10e18);
        token1.mint(address(this), 10e18);
        token0.approve(address(vault), 10e18);
        token1.approve(address(vault), 10e18);

        strategy.setMisbehave(true); // weight = 9_999 instead of 10_000

        pool.setDelta(int128(-9e18), int128(-9e18));

        vm.expectRevert(abi.encodeWithSelector(Errors.WeightsDoNotSum.selector, 9999));
        vault.deposit(10e18, 10e18, 0, 0, address(this));
    }

    function test_deposit_revertsOnTooManyPositions() public {
        token0.mint(address(this), 10e18);
        token1.mint(address(this), 10e18);
        token0.approve(address(vault), 10e18);
        token1.approve(address(vault), 10e18);

        // Strategy returns MAX_POSITIONS + 1 = 8 positions.
        strategy.setExtraPositions(8);

        pool.setDelta(int128(-1), int128(-1));

        vm.expectRevert(abi.encodeWithSelector(Errors.MaxPositionsExceeded.selector, 8));
        vault.deposit(10e18, 10e18, 0, 0, address(this));
    }

    // -------------------------------------------------------------------------
    // Mock helpers
    // -------------------------------------------------------------------------

    /// Pre-pack slot0 (sqrtPriceX96 + tick) on the mock pool so the
    /// vault's StateLibrary.getSlot0 call returns the expected values.
    function _mockSlot0(int24 tick) internal {
        bytes32 slot0 = bytes32(uint256(SQRT_PRICE_TICK_0)) | bytes32(uint256(uint24(tick)) << 160);
        pool.setSlot0(slot0);
    }
}

/// Minimal PoolManager stand-in for the deposit-body unit tests. Real
/// PoolManager flow (modifyLiquidity → settle/take/sync) is exercised
/// against Base Sepolia in the fork tests (#42); here we only need
/// enough surface to drive the unlock callback.
///
/// The mock returns a configurable BalanceDelta from `modifyLiquidity`
/// and treats settle/take/sync as no-ops. `unlock` invokes
/// `IUnlockCallback.unlockCallback` on the caller — matching the V4
/// reentrancy pattern.
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";

contract MockPoolManager {
    BalanceDelta public mockedDelta;
    bytes public lastUnlockData;
    bytes32 public lastSlot0;

    function setDelta(int128 d0, int128 d1) external {
        mockedDelta = toBalanceDelta(d0, d1);
    }

    function setSlot0(bytes32 slot0) external {
        lastSlot0 = slot0;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        lastUnlockData = data;
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

    function sync(Currency) external {}

    function take(Currency, address, uint256) external {}

    function settle() external payable returns (uint256) {
        return 0;
    }

    function extsload(bytes32) external view returns (bytes32) {
        return lastSlot0;
    }
}
