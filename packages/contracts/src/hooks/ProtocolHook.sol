// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

import {IProtocolHook} from "../interfaces/IProtocolHook.sol";
import {IVault} from "../interfaces/IVault.sol";
import {Errors} from "../utils/Errors.sol";

/// @title ProtocolHook — singleton V4 hook
/// @notice This PR (#34) wires the permission matrix, address-bit
///         assertion, onlyPoolManager guard, vault registry, and the
///         IHooks callback skeleton. The actual hot-path logic in
///         `beforeSwap` (#35) and `afterSwap` (#36) ships in
///         follow-up PRs — for now those callbacks return the canonical
///         "no-op" sentinels so a deployed hook composes correctly with
///         PoolManager and the test pool can already run swaps.
/// @dev    Singleton scope per ADR-002: one deployed hook services every
///         PRISM vault. State is sharded by `PoolId` (pool-level state
///         like volatility) and vault address (vault-level state like
///         MEV ledgers).
///
///         The hook ENABLES bits 6, 7, 8, 10:
///           - afterSwap (bit 6)
///           - beforeSwap (bit 7)
///           - afterRemoveLiquidity (bit 8)
///           - afterAddLiquidity (bit 10)
///         Combined: 0x05C0 — the deployed address LSB is mined to
///         satisfy `address(this) & 0x3FFF == 0x05C0` (HookMiner #25).
///         The constructor calls `Hooks.validateHookPermissions` which
///         reverts with `Hooks.HookAddressNotValid` if the address bits
///         disagree with `getHookPermissions()`.
contract ProtocolHook is IProtocolHook {
    using PoolIdLibrary for PoolKey;

    /// @notice Canonical V4 PoolManager singleton.
    IPoolManager public immutable poolManager;

    /// @notice The factory authorised to call `registerVault`. Pinned at
    ///         deploy time. Per ADR-006 there is no setter; rotation
    ///         requires redeploying the hook + factory + vaults.
    address public immutable factory;

    /// @notice `PoolId` → registered PRISM vault. Set by the factory
    ///         immediately after vault deployment. The hook reads this
    ///         in `afterSwap` to attribute MEV observations.
    mapping(PoolId => address) public vaultByPool;

    /// @notice Per-pool dynamic-fee state. EWMA short-window volatility,
    ///         long-window volatility, last-update timestamp, and the
    ///         most recent computed fee.
    /// @dev    Packed into one slot per pool to keep the beforeSwap
    ///         SLOAD/SSTORE pair within the 12k gas budget (ADR-007).
    ///         The full fee math (`FeeLib.update + FeeLib.feeFromVol`)
    ///         lands as part of the integration phase that pulls
    ///         FeeLib from #23 onto this branch — the storage slot is
    ///         declared now so the migration is a body-only change.
    struct FeeState {
        uint64 ewmaShort;
        uint64 ewmaLong;
        uint32 lastUpdate;
        uint24 lastFee;
    }

    /// @notice Last computed fee (in pips) per pool.
    mapping(PoolId => FeeState) internal _feeState;

    /// @notice Default starting fee in pips (0.30%) — used until the
    ///         EWMA has converged after the first few swaps.
    uint24 public constant DEFAULT_FEE = 3000;

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert Errors.OnlyPoolManager();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert Errors.OnlyOwner();
        _;
    }

    // -------------------------------------------------------------------------
    // Construction
    // -------------------------------------------------------------------------

    constructor(IPoolManager poolManager_, address factory_) {
        if (address(poolManager_) == address(0)) revert Errors.ZeroAddress();
        if (factory_ == address(0)) revert Errors.ZeroAddress();

        poolManager = poolManager_;
        factory = factory_;

        // Address-bit assertion. Reverts via Hooks.HookAddressNotValid
        // when the deployer's CREATE2 salt was not mined to encode the
        // exact permission flags this hook implements. HookMiner (#25)
        // is the off-chain helper that finds a satisfying salt.
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    // -------------------------------------------------------------------------
    // IProtocolHook — getHookPermissions
    // -------------------------------------------------------------------------

    /// @inheritdoc IProtocolHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: true, // bit 10
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true, // bit 8
            beforeSwap: true, // bit 7
            afterSwap: true, // bit 6
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -------------------------------------------------------------------------
    // IProtocolHook — registerVault
    // -------------------------------------------------------------------------

    /// @inheritdoc IProtocolHook
    function registerVault(address vault) external override onlyFactory {
        if (vault == address(0)) revert Errors.ZeroAddress();
        PoolKey memory key = IVault(vault).poolKey();
        PoolId pid = key.toId();
        vaultByPool[pid] = vault;
    }

    // -------------------------------------------------------------------------
    // IProtocolHook — view stubs (filled by #35/#36)
    // -------------------------------------------------------------------------

    /// @inheritdoc IProtocolHook
    function currentFee(bytes32 poolId) external view override returns (uint24) {
        uint24 fee = _feeState[PoolId.wrap(poolId)].lastFee;
        return fee == 0 ? DEFAULT_FEE : fee;
    }

    /// @inheritdoc IProtocolHook
    /// @dev v1.0 always returns (0, 0) — observation-only mode.
    function mevProfits(address /*vault*/ ) external pure override returns (uint256, uint256) {
        return (0, 0);
    }

    // -------------------------------------------------------------------------
    // IHooks callback skeleton — beforeInitialize through afterDonate
    //
    // PRISM enables only 4 callbacks; the others MUST never be reached
    // because the address bits forbid PoolManager from invoking them.
    // Implementations are left as `revert UnknownOp()` so a malformed
    // CREATE2 salt that somehow allowed an unintended call would surface
    // as a clear error rather than silent acceptance.
    // -------------------------------------------------------------------------

    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        revert Errors.UnknownOp();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert Errors.UnknownOp();
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    )
        external
        pure
        override
        returns (bytes4)
    {
        revert Errors.UnknownOp();
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    )
        external
        pure
        override
        returns (bytes4)
    {
        revert Errors.UnknownOp();
    }

    function beforeDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    )
        external
        pure
        override
        returns (bytes4)
    {
        revert Errors.UnknownOp();
    }

    function afterDonate(
        address,
        PoolKey calldata,
        uint256,
        uint256,
        bytes calldata
    )
        external
        pure
        override
        returns (bytes4)
    {
        revert Errors.UnknownOp();
    }

    // -------------------------------------------------------------------------
    // IHooks — enabled callbacks
    //
    // afterAddLiquidity / afterRemoveLiquidity MUST NOT revert
    // (ADR-002 hard rule — they sit on the withdraw hot-path). #34
    // returns the no-op sentinel; #35/#36 retain that property when
    // they fill the body.
    // -------------------------------------------------------------------------

    function beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        bytes calldata
    )
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // ≤12k gas budget per ADR-007. The full EWMA + clamped fee
        // calculation lives in FeeLib (#23); pulling it onto this
        // branch is the integration step. For now we read existing
        // state, return the stored fee (or DEFAULT_FEE on first swap),
        // and emit FeeUpdated for analytics. The storage slot layout
        // and the V4 OVERRIDE_FEE_FLAG path are settled here so the
        // FeeLib wire-up is a single-method change.
        PoolId pid = key.toId();
        FeeState storage state = _feeState[pid];

        uint24 fee = state.lastFee == 0 ? DEFAULT_FEE : state.lastFee;
        if (state.lastUpdate == 0) {
            state.lastUpdate = uint32(block.timestamp);
            state.lastFee = fee;
            emit FeeUpdated(PoolId.unwrap(pid), fee, 0);
        }

        // V4 OVERRIDE_FEE_FLAG = 0x400000 — set the high bit on the
        // returned fee so PoolManager applies it as the swap fee for
        // this transaction only. See v4-core LPFeeLibrary.
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | 0x400000);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta,
        bytes calldata
    )
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        // v1.0: emit SwapObserved with the post-swap pool tick + sqrtPrice
        // so off-chain analytics can compute deviation against an oracle
        // reference. Backrun execution (v1.1) consumes the same numbers.
        //
        // The pool tick + sqrtPrice come from `IPoolManager.getSlot0`
        // — but reading slot0 here would push us past the 18k-gas
        // budget set by ADR-007. Integration phase wires this via
        // `StateView.getSlot0(poolId)` which is cheaper. For now the
        // event is emitted with zeroed numbers; the integration PR
        // populates them and gas-snapshots against the budget.
        PoolId pid = key.toId();
        emit SwapObserved(PoolId.unwrap(pid), 0, 0);

        return (IHooks.afterSwap.selector, 0);
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    )
        external
        view
        override
        onlyPoolManager
        returns (bytes4, BalanceDelta)
    {
        // ADR-002 hard rule: never reverts. v1.0 is a pure no-op.
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    )
        external
        view
        override
        onlyPoolManager
        returns (bytes4, BalanceDelta)
    {
        // ADR-002 hard rule: never reverts. v1.0 is a pure no-op.
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }
}
