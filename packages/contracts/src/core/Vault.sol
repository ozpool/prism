// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

import {IProtocolHook} from "../interfaces/IProtocolHook.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IVault} from "../interfaces/IVault.sol";
import {PositionLib} from "../libraries/PositionLib.sol";
import {Errors} from "../utils/Errors.sol";

/// @title PRISM Vault — multi-position LP aggregator on Uniswap V4
/// @notice This PR (#26) wires storage layout, ERC-20 share accounting,
///         and the constructor. The hot-path methods land in follow-ups:
///           - deposit  → #27
///           - withdraw → #28
///           - rebalance → #29
///           - views    → #30
///         Until those land the methods revert UnknownOp; the contract
///         compiles, tests can verify the storage shape, and downstream
///         integrators (factory, deployer scripts) can wire against the
///         real ABI.
///
/// @dev Storage layout is part of the immutable surface — moving slots
///      after launch is a redeploy, not an upgrade (ADR-006). Slot
///      ordering is therefore fixed:
///        slot 0..N-1 → ERC20 base (name, symbol, _balances, _allowances, _totalSupply)
///        slot 1     ↓ owner (mutable)
///        slot ↓     → depositsPaused (mutable)
///        slot ↓     → tvlCap (mutable, owner-bounded)
///        slot ↓     → positions (Position[] mutable)
///      The immutables (poolManager, poolKey hashed, strategy, hook,
///      token0, token1, MIN_SHARES, MAX_POSITIONS) live in code, not
///      storage — gas and rotation hygiene.
///
///      ERC-20 transfer hooks: this vault deliberately does NOT
///      override _update / _beforeTokenTransfer. Shares are freely
///      transferable, no transfer fees, no blocklists — composability
///      is non-negotiable per the PRD anti-goals.
///
///      MIN_SHARES = 1000 burned to address(0) on first deposit
///      mitigates the first-depositor inflation attack (PRD §13).
contract Vault is IVault, ERC20, IUnlockCallback {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @notice Keeper bonus per ADR-007 §keeper economics — 5 basis
    ///         points of the post-rebalance share supply, minted to
    ///         the keeper that triggered the rebalance.
    uint256 public constant KEEPER_BONUS_BPS = 5;
    uint256 internal constant BPS_DENOM = 10_000;

    /// @dev Tagged operations for `unlockCallback`. Each entry point
    ///      (deposit / withdraw / rebalance) calls `poolManager.unlock`
    ///      with `abi.encode(Op.X, payload)`; the callback dispatches
    ///      to the matching branch.
    enum Op {
        DEPOSIT,
        WITHDRAW,
        REBALANCE
    }

    struct DepositPayload {
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address payer;
        address to;
    }

    struct WithdrawPayload {
        uint256 shares;
        uint256 amount0Min;
        uint256 amount1Min;
        address from;
        address to;
    }

    struct RebalancePayload {
        address keeper;
    }
    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    /// @notice First-deposit shares burned to dead address. Inflation guard.
    uint256 public constant MIN_SHARES = 1000;

    /// @notice Hard cap on positions per vault (PRD invariant 3).
    uint256 public constant MAX_POSITIONS = 7;

    /// @notice Address that receives the MIN_SHARES burn.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // -------------------------------------------------------------------------
    // Immutables — set at construction, never updatable
    // -------------------------------------------------------------------------

    /// @notice Canonical V4 PoolManager.
    IPoolManager public immutable poolManager;

    /// @notice Strategy that computes target positions + the rebalance gate.
    ///         Per ADR-005 implementations are pure / stateless.
    IStrategy public immutable strategy;

    /// @notice Singleton hook that handles dynamic fees + MEV observation.
    IProtocolHook public immutable hook;

    /// @notice Pool tokens, snapshot from `PoolKey` for hot-path use.
    IERC20 public immutable token0;
    IERC20 public immutable token1;

    /// @notice Pool tickSpacing, snapshot for tick-alignment math.
    int24 public immutable tickSpacing;

    /// @notice Fee tier of the underlying pool. For PRISM this is the
    ///         dynamic-fee sentinel `0x800000`; immutable on the vault.
    uint24 public immutable poolFee;

    // -------------------------------------------------------------------------
    // Mutable storage
    // -------------------------------------------------------------------------

    /// @notice Multisig-controlled admin. Holds the two mutable levers
    ///         (depositsPaused, tvlCap) per ADR-006.
    address public owner;

    /// @notice Pause flag for deposits only. Withdrawals are NEVER pausable.
    bool public depositsPaused;

    /// @notice TVL cap in token0 notional units. Enforced by deposit().
    uint256 public tvlCap;

    /// @notice Active positions. Set by `rebalance` (#29). Indexed
    ///         in the order the strategy emits them.
    Position[] internal _positions;

    /// @notice Pool tick at the moment of the last successful rebalance.
    ///         Used by `IStrategy.shouldRebalance` to compute drift.
    int24 public lastRebalanceTick;

    /// @notice Block timestamp of the last successful rebalance.
    ///         Used by both the strategy gate and the keeper bonus
    ///         accrual model (ADR-007).
    uint256 public lastRebalanceTimestamp;

    /// @notice Currency0 / currency1 slots from the pool key — kept as
    ///         storage (not immutable) only because PoolKey is a struct
    ///         and Solidity doesn't allow struct immutables. The values
    ///         match `token0` / `token1` and never change post-construction.
    PoolKey internal _poolKey;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event DepositsPausedSet(bool paused);
    event TVLCapSet(uint256 newCap);

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert Errors.OnlyOwner();
        _;
    }

    // -------------------------------------------------------------------------
    // Construction
    // -------------------------------------------------------------------------

    constructor(
        IPoolManager poolManager_,
        PoolKey memory poolKey_,
        IStrategy strategy_,
        IProtocolHook hook_,
        address owner_,
        uint256 tvlCap_,
        string memory name_,
        string memory symbol_
    )
        ERC20(name_, symbol_)
    {
        if (address(poolManager_) == address(0)) revert Errors.ZeroAddress();
        if (address(strategy_) == address(0)) revert Errors.ZeroAddress();
        if (address(hook_) == address(0)) revert Errors.ZeroAddress();
        if (owner_ == address(0)) revert Errors.ZeroAddress();
        if (tvlCap_ == 0) revert Errors.ValueOutOfBounds(tvlCap_, type(uint256).max);
        if (poolKey_.tickSpacing <= 0) revert Errors.InvalidTickRange(0, 0);

        poolManager = poolManager_;
        strategy = strategy_;
        hook = hook_;

        // Snapshot pool tokens. PoolKey enforces currency0 < currency1
        // at the V4 layer; we mirror that ordering for hot-path use.
        token0 = IERC20(_unwrap(poolKey_.currency0));
        token1 = IERC20(_unwrap(poolKey_.currency1));
        tickSpacing = poolKey_.tickSpacing;
        poolFee = poolKey_.fee;

        _poolKey = poolKey_;

        owner = owner_;
        tvlCap = tvlCap_;

        emit OwnershipTransferred(address(0), owner_);
        emit TVLCapSet(tvlCap_);
    }

    // -------------------------------------------------------------------------
    // IERC20Metadata override — already provided by OZ ERC20 base
    // -------------------------------------------------------------------------

    function decimals() public pure override returns (uint8) {
        // Vault shares are 18 decimals regardless of underlying token
        // decimals. Keeps frontend formatting deterministic and matches
        // the convention from ERC-4626.
        return 18;
    }

    // -------------------------------------------------------------------------
    // Admin (ADR-006 two-lever model)
    // -------------------------------------------------------------------------

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert Errors.ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setDepositsPaused(bool paused) external onlyOwner {
        depositsPaused = paused;
        emit DepositsPausedSet(paused);
    }

    function setTVLCap(uint256 newCap) external onlyOwner {
        if (newCap == 0) revert Errors.ValueOutOfBounds(newCap, type(uint256).max);
        tvlCap = newCap;
        emit TVLCapSet(newCap);
    }

    // -------------------------------------------------------------------------
    // IVault method stubs — filled by #27/#28/#29/#30
    // -------------------------------------------------------------------------

    /// @inheritdoc IVault
    /// @dev #27 wires the entry point + unlock callback dispatch.
    ///      The actual multi-position deploy + MIN_SHARES burn lands
    ///      in the integration phase against a real PoolManager — the
    ///      tests here exercise the entry-point preconditions
    ///      (DepositsPaused, slippage, TVL cap) without poking
    ///      PoolManager state.
    function deposit(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to
    )
        external
        override
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        if (depositsPaused) revert Errors.DepositsPaused();
        if (to == address(0)) revert Errors.ZeroAddress();
        if (amount0Desired == 0 && amount1Desired == 0) revert Errors.ZeroShares();

        // Pull tokens from the caller into the vault as the source of
        // funds for the unlock callback. The callback consumes only as
        // much as the strategy actually needs; any remainder is
        // refunded by the unlockCallback before settling deltas.
        if (amount0Desired > 0) token0.safeTransferFrom(msg.sender, address(this), amount0Desired);
        if (amount1Desired > 0) token1.safeTransferFrom(msg.sender, address(this), amount1Desired);

        DepositPayload memory payload = DepositPayload({
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            payer: msg.sender,
            to: to
        });

        bytes memory result = poolManager.unlock(abi.encode(Op.DEPOSIT, abi.encode(payload)));
        (shares, amount0, amount1) = abi.decode(result, (uint256, uint256, uint256));

        emit Deposit(to, amount0, amount1, shares);
    }

    /// @notice IPoolManager unlock callback. Dispatch by op tag.
    /// @dev Only `poolManager` may call. The actual modifyLiquidity +
    ///      delta settlement sequence lands in the integration phase;
    ///      for now each branch reverts so unit tests can verify the
    ///      auth + dispatch shape without standing up a full pool.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert Errors.OnlyPoolManager();

        (Op op, bytes memory payload) = abi.decode(data, (Op, bytes));

        if (op == Op.DEPOSIT) {
            return _handleDeposit(abi.decode(payload, (DepositPayload)));
        }
        if (op == Op.WITHDRAW) {
            return _handleWithdraw(abi.decode(payload, (WithdrawPayload)));
        }
        if (op == Op.REBALANCE) {
            return _handleRebalance(abi.decode(payload, (RebalancePayload)));
        }

        revert Errors.UnknownOp();
    }

    /// @dev Stub: real implementation pulls tokens via permit2, calls
    ///      `poolManager.modifyLiquidity` per target position, settles
    ///      deltas, and refunds any unused desired amount.
    function _handleDeposit(DepositPayload memory /*payload*/ ) internal pure returns (bytes memory) {
        revert Errors.UnknownOp();
    }

    /// @dev Stub: real implementation removes a proportional slice of
    ///      every position via `modifyLiquidity` with negative liquidity
    ///      delta, takes both currencies, and transfers to `payload.to`.
    function _handleWithdraw(WithdrawPayload memory /*payload*/ ) internal pure returns (bytes memory) {
        revert Errors.UnknownOp();
    }

    /// @dev Remove-all → recompute shape → redeploy → settle → mint
    ///      keeper bonus.
    ///
    ///      Steps:
    ///        1. Read post-swap pool state for the target shape
    ///           computation.
    ///        2. Tear down every existing position via modifyLiquidity
    ///           with negative liquidityDelta. Take the resulting
    ///           positive deltas — the vault now holds all assets idle.
    ///        3. Ask the strategy for the target shape against the new
    ///           idle balances. Validate weight sum + position count.
    ///        4. Deploy each new target. Settle the resulting negative
    ///           deltas back to PoolManager.
    ///        5. Mint KEEPER_BONUS_BPS of the post-rebalance share
    ///           supply to the keeper as payment for the gas they paid
    ///           (ADR-007 §keeper economics).
    ///
    ///      v1.0 does NOT run an internal swap to balance the idle
    ///      between the two tokens. The strategy is expected to absorb
    ///      uneven balances via its weight allocation; a bounded
    ///      internal swap is a v1.1 follow-up.
    function _handleRebalance(RebalancePayload memory payload) internal returns (bytes memory) {
        PoolId pid = _poolKey.toId();
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(pid);

        // 1. Tear down every active position.
        uint256 oldCount = _positions.length;
        for (uint256 i = 0; i < oldCount; i++) {
            Position memory p = _positions[i];
            if (p.liquidity == 0) continue;

            (BalanceDelta delta,) = poolManager.modifyLiquidity(
                _poolKey,
                ModifyLiquidityParams({
                    tickLower: p.tickLower,
                    tickUpper: p.tickUpper,
                    liquidityDelta: -int256(uint256(p.liquidity)),
                    salt: bytes32(uint256(i))
                }),
                ""
            );

            int128 d0 = delta.amount0();
            int128 d1 = delta.amount1();
            if (d0 > 0) poolManager.take(_poolKey.currency0, address(this), uint128(d0));
            if (d1 > 0) poolManager.take(_poolKey.currency1, address(this), uint128(d1));
        }

        // 2. Reset the position list — the strategy decides the new shape.
        delete _positions;

        // 3. Compute the new target shape against current idle balances.
        uint256 idle0 = token0.balanceOf(address(this));
        uint256 idle1 = token1.balanceOf(address(this));

        IStrategy.TargetPosition[] memory targets = strategy.computePositions(currentTick, tickSpacing, idle0, idle1);

        if (targets.length == 0 || targets.length > MAX_POSITIONS) {
            revert Errors.MaxPositionsExceeded(targets.length);
        }
        uint256 weightSum;
        for (uint256 i = 0; i < targets.length; i++) {
            weightSum += targets[i].weight;
        }
        if (weightSum != 10_000) revert Errors.WeightsDoNotSum(weightSum);

        // 4. Deploy each target. Aggregate negative deltas paid to the
        // pool come from the vault's idle balance.
        uint256 spent0;
        uint256 spent1;

        for (uint256 i = 0; i < targets.length; i++) {
            IStrategy.TargetPosition memory t = targets[i];
            uint256 share0 = (idle0 * t.weight) / 10_000;
            uint256 share1 = (idle1 * t.weight) / 10_000;

            uint128 liquidity =
                PositionLib.liquidityForAmounts(sqrtPriceX96, t.tickLower, t.tickUpper, tickSpacing, share0, share1);
            if (liquidity == 0) continue;

            (BalanceDelta delta,) = poolManager.modifyLiquidity(
                _poolKey,
                ModifyLiquidityParams({
                    tickLower: t.tickLower,
                    tickUpper: t.tickUpper,
                    liquidityDelta: int256(uint256(liquidity)),
                    salt: bytes32(uint256(i))
                }),
                ""
            );

            int128 d0 = delta.amount0();
            int128 d1 = delta.amount1();
            if (d0 < 0) spent0 += uint128(-d0);
            if (d1 < 0) spent1 += uint128(-d1);

            _positions.push(Position({tickLower: t.tickLower, tickUpper: t.tickUpper, liquidity: liquidity}));
        }

        // 5. Settle the aggregate spend back to PoolManager.
        if (spent0 > 0) {
            poolManager.sync(_poolKey.currency0);
            token0.safeTransfer(address(poolManager), spent0);
            poolManager.settle();
        }
        if (spent1 > 0) {
            poolManager.sync(_poolKey.currency1);
            token1.safeTransfer(address(poolManager), spent1);
            poolManager.settle();
        }

        // 6. Keeper bonus — 5 bps of post-rebalance supply minted to
        // the keeper. The +1 floor ensures even a fresh vault credits
        // a single share so on-chain attribution is unambiguous.
        uint256 supply = totalSupply();
        if (supply > 0 && payload.keeper != address(0)) {
            uint256 bonus = Math.mulDiv(supply, KEEPER_BONUS_BPS, BPS_DENOM);
            if (bonus == 0) bonus = 1;
            _mint(payload.keeper, bonus);
        }

        return abi.encode(currentTick, _positions.length, uint256(0));
    }

    /// @inheritdoc IVault
    /// @dev Never pausable (invariant 6). The `depositsPaused` flag is
    ///      checked in `deposit` only; this entry point is reachable in
    ///      every state of the contract for the lifetime of the vault.
    function withdraw(
        uint256 shares,
        uint256 amount0Min,
        uint256 amount1Min,
        address to
    )
        external
        override
        returns (uint256 amount0, uint256 amount1)
    {
        if (shares == 0) revert Errors.InvalidShareAmount();
        if (shares > balanceOf(msg.sender)) revert Errors.InvalidShareAmount();
        if (to == address(0)) revert Errors.ZeroAddress();

        // Burn shares up-front so the unlock callback can compute
        // proportional withdrawals against the post-burn supply.
        // Inflation guard: MIN_SHARES never circulates; burning more
        // than (totalSupply - MIN_SHARES) is rejected by the
        // balanceOf check above on the first depositor.
        _burn(msg.sender, shares);

        WithdrawPayload memory payload =
            WithdrawPayload({shares: shares, amount0Min: amount0Min, amount1Min: amount1Min, from: msg.sender, to: to});

        bytes memory result = poolManager.unlock(abi.encode(Op.WITHDRAW, abi.encode(payload)));
        (amount0, amount1) = abi.decode(result, (uint256, uint256));

        emit Withdraw(to, amount0, amount1, shares);
    }

    /// @inheritdoc IVault
    /// @dev Permissionless. Caller becomes `payload.keeper` and is
    ///      credited the rebalance bonus on successful settlement.
    ///      Gates on `strategy.shouldRebalance(currentTick, lastTick,
    ///      lastTimestamp)` — reverts `RebalanceNotNeeded` if the
    ///      strategy says no.
    ///
    ///      The full remove-all → bounded swap → redeploy sequence
    ///      lives in `_handleRebalance`. The current PR exercises the
    ///      entry-point gate; settlement lands during integration
    ///      testing against a real PoolManager.
    function rebalance() external override {
        // Read the current tick from PoolManager via StateLibrary —
        // single extsload, no StateView contract dependency.
        (, int24 currentTick,,) = poolManager.getSlot0(_poolKey.toId());

        if (!strategy.shouldRebalance(currentTick, lastRebalanceTick, lastRebalanceTimestamp)) {
            revert Errors.RebalanceNotNeeded();
        }

        RebalancePayload memory payload = RebalancePayload({keeper: msg.sender});
        bytes memory result = poolManager.unlock(abi.encode(Op.REBALANCE, abi.encode(payload)));
        // Settlement returns (newTick, nPositions, gasUsed). Decode
        // and record post-rebalance state.
        (int24 newTick, uint256 nPositions, uint256 gasUsed) = abi.decode(result, (int24, uint256, uint256));

        lastRebalanceTick = newTick;
        lastRebalanceTimestamp = block.timestamp;

        emit Rebalanced(newTick, nPositions, gasUsed);
    }

    /// @inheritdoc IVault
    function getPositions() external view override returns (Position[] memory) {
        return _positions;
    }

    /// @inheritdoc IVault
    function getTotalAmounts() external view override returns (uint256 total0, uint256 total1) {
        // Idle balance is part of TVL — frontends and the share-price
        // view both expect it to count.
        total0 = token0.balanceOf(address(this));
        total1 = token1.balanceOf(address(this));

        if (_positions.length == 0) return (total0, total1);

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(_poolKey.toId());

        uint256 n = _positions.length;
        for (uint256 i = 0; i < n; i++) {
            Position memory p = _positions[i];
            (uint256 a0, uint256 a1) =
                PositionLib.amountsForLiquidity(sqrtPriceX96, p.tickLower, p.tickUpper, tickSpacing, p.liquidity);
            total0 += a0;
            total1 += a1;
        }
    }

    /// @inheritdoc IVault
    function poolKey() external view override returns (PoolKey memory) {
        return _poolKey;
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    /// @dev Currency is `type Currency is address;` in v4-core.
    function _unwrap(Currency c) private pure returns (address) {
        return Currency.unwrap(c);
    }
}
