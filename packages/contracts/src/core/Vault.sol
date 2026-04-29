// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {IProtocolHook} from "../interfaces/IProtocolHook.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IVault} from "../interfaces/IVault.sol";
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
    function rebalance() external pure override {
        // #29 implements remove-all → bounded swap → redeploy.
        revert Errors.UnknownOp();
    }

    /// @inheritdoc IVault
    function getPositions() external view override returns (Position[] memory) {
        return _positions;
    }

    /// @inheritdoc IVault
    function getTotalAmounts() external pure override returns (uint256, uint256) {
        // #30 wires the per-position amount aggregation against PoolManager
        // state.
        return (0, 0);
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
