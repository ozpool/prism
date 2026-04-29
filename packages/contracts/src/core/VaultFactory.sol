// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {IProtocolHook} from "../interfaces/IProtocolHook.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {Errors} from "../utils/Errors.sol";
import {Vault} from "./Vault.sol";

/// @title VaultFactory — CREATE2 vault deployer + registry
/// @notice Deploys one `Vault` per `(PoolKey, IStrategy)` tuple via
///         CREATE2 so the vault address is predictable off-chain. Maintains
///         a registry of all deployed vaults indexed by the keccak256 of
///         the (PoolKey, strategy) tuple.
///
/// @dev    Per ADR-006 the factory is itself immutable — no setters, no
///         proxy. The hook + poolManager are pinned at construction so
///         every vault deployed by this factory shares the same hook
///         instance (singleton, ADR-002).
///
///         The factory is the only address authorised to call
///         `IProtocolHook.registerVault` — see ProtocolHook constructor's
///         `factory` immutable. Rotating the factory therefore requires
///         redeploying both factory and hook.
contract VaultFactory {
    /// @notice Canonical V4 PoolManager.
    IPoolManager public immutable poolManager;

    /// @notice Singleton ProtocolHook every vault from this factory uses.
    IProtocolHook public immutable hook;

    /// @notice Multisig admin owner used as the initial owner for every
    ///         vault deployed by this factory. Per-vault ownership can
    ///         be transferred via `Vault.transferOwnership`.
    address public immutable defaultOwner;

    /// @notice keccak256(abi.encode(PoolKey, strategy)) → vault address.
    ///         Zero means no vault has been deployed for that tuple.
    mapping(bytes32 => address) public vaultByKey;

    /// @notice Every vault address ever deployed by this factory, in
    ///         deployment order. Off-chain consumers (the dApp, keeper)
    ///         walk this to enumerate live vaults.
    address[] internal _allVaults;

    event VaultCreated(address indexed vault, address indexed strategy, bytes32 indexed registryKey, address creator);

    constructor(IPoolManager poolManager_, IProtocolHook hook_, address defaultOwner_) {
        if (address(poolManager_) == address(0)) revert Errors.ZeroAddress();
        if (address(hook_) == address(0)) revert Errors.ZeroAddress();
        if (defaultOwner_ == address(0)) revert Errors.ZeroAddress();

        poolManager = poolManager_;
        hook = hook_;
        defaultOwner = defaultOwner_;
    }

    /// @notice Deploy a vault for `(poolKey, strategy)` if one does not
    ///         already exist. Reverts if a vault is already registered
    ///         for the tuple (prevents address collisions and accidental
    ///         re-deployment over an active vault).
    /// @param  poolKey       The Uniswap V4 pool the vault wraps.
    /// @param  strategy      The IStrategy implementation the vault uses.
    /// @param  tvlCap        Per-vault TVL cap in token0 notional units.
    /// @param  name_         ERC-20 name of the share token.
    /// @param  symbol_       ERC-20 symbol of the share token.
    /// @param  salt          CREATE2 salt — caller-supplied so off-chain
    ///                       tooling can mine vanity addresses if desired.
    function create(
        PoolKey calldata poolKey,
        IStrategy strategy,
        uint256 tvlCap,
        string calldata name_,
        string calldata symbol_,
        bytes32 salt
    )
        external
        returns (address vault)
    {
        if (address(strategy) == address(0)) revert Errors.ZeroAddress();

        bytes32 registryKey = keccak256(abi.encode(poolKey, strategy));
        if (vaultByKey[registryKey] != address(0)) revert Errors.OnlyOwner();

        // CREATE2 deploy. The factory itself is the deployer so the
        // address can be predicted off-chain via
        //   keccak256(0xff, factory, salt, keccak256(creationCode + ctorArgs))[12:]
        bytes memory creationCode = type(Vault).creationCode;
        bytes memory ctorArgs = abi.encode(poolManager, poolKey, strategy, hook, defaultOwner, tvlCap, name_, symbol_);
        bytes memory initCode = abi.encodePacked(creationCode, ctorArgs);

        assembly {
            vault := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        if (vault == address(0)) revert Errors.UnknownOp();

        vaultByKey[registryKey] = vault;
        _allVaults.push(vault);

        // Tell the hook about the new vault so afterSwap can attribute
        // MEV observations. Reverts via OnlyOwner on the hook side if
        // this factory wasn't the one set in the hook's `factory`
        // immutable — that's the address-binding invariant from #34.
        hook.registerVault(vault);

        emit VaultCreated(vault, address(strategy), registryKey, msg.sender);
    }

    /// @notice Number of vaults this factory has deployed.
    function allVaultsLength() external view returns (uint256) {
        return _allVaults.length;
    }

    /// @notice Vault at index `i`. Reverts on out-of-bounds.
    function allVaults(uint256 i) external view returns (address) {
        return _allVaults[i];
    }

    /// @notice Predicted address for a CREATE2 deploy with the given
    ///         args + salt. Lets off-chain tooling and the dApp render
    ///         the future address before transaction submission.
    function predictAddress(
        PoolKey calldata poolKey,
        IStrategy strategy,
        uint256 tvlCap,
        string calldata name_,
        string calldata symbol_,
        bytes32 salt
    )
        external
        view
        returns (address)
    {
        bytes memory creationCode = type(Vault).creationCode;
        bytes memory ctorArgs = abi.encode(poolManager, poolKey, strategy, hook, defaultOwner, tvlCap, name_, symbol_);
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, ctorArgs));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }
}
