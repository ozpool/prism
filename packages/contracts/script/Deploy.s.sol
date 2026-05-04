// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Vault} from "../src/core/Vault.sol";
import {VaultFactory} from "../src/core/VaultFactory.sol";
import {ProtocolHook} from "../src/hooks/ProtocolHook.sol";

import {IProtocolHook} from "../src/interfaces/IProtocolHook.sol";
import {AggregatorV3, ChainlinkAdapter} from "../src/oracles/ChainlinkAdapter.sol";
import {BellStrategy} from "../src/strategies/BellStrategy.sol";

/// @title Deploy — full PRISM stack on Base Sepolia
/// @notice One-shot deploy: BellStrategy → ChainlinkAdapter →
///         (mine hook salt) → ProtocolHook (CREATE2) → VaultFactory →
///         (no vaults yet — VaultFactory.create() lands as a follow-up
///         per pool the team chooses).
///
/// @dev    Usage:
///           forge script packages/contracts/script/Deploy.s.sol:Deploy \
///             --rpc-url $BASE_SEPOLIA_RPC_URL \
///             --broadcast \
///             --verify
///
///         Required env vars:
///           - DEPLOYER_PRIVATE_KEY   — hex 0x-prefixed
///           - POOL_MANAGER           — Base Sepolia PoolManager address
///           - DEFAULT_OWNER          — multisig that owns deployed vaults
///           - CHAINLINK_FEED         — primary price feed (e.g. ETH/USD)
///           - SEQUENCER_FEED         — L2 sequencer uptime feed
///           - PRICE_SCALE_NUM        — Q192 numerator (off-chain computed)
///           - PRICE_SCALE_DEN        — Q192 denominator
///
///         Output: addresses are written to `addresses.json` in the
///         repo root by the post-deploy step (#65); this script just
///         prints them via `console.log`.
contract Deploy is Script {
    function run()
        external
        returns (BellStrategy strategy, ChainlinkAdapter adapter, ProtocolHook hook, VaultFactory factory)
    {
        IPoolManager pm = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address owner = vm.envAddress("DEFAULT_OWNER");
        address feed = vm.envAddress("CHAINLINK_FEED");
        address sequencer = vm.envAddress("SEQUENCER_FEED");
        uint256 priceScaleNum = vm.envUint("PRICE_SCALE_NUM");
        uint256 priceScaleDen = vm.envUint("PRICE_SCALE_DEN");

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerKey);

        // 1. Strategy — pure / stateless / vault-agnostic.
        strategy = new BellStrategy();
        console.log("BellStrategy:", address(strategy));

        // 2. Oracle adapter — fail-soft, single read shape.
        adapter = new ChainlinkAdapter(
            AggregatorV3(feed),
            AggregatorV3(sequencer),
            ChainlinkAdapter(address(0)).DEFAULT_STALENESS(), // 3600
            ChainlinkAdapter(address(0)).DEFAULT_GRACE_PERIOD(), // 3600
            priceScaleNum,
            priceScaleDen
        );
        console.log("ChainlinkAdapter:", address(adapter));

        // 3. ProtocolHook — singleton, address-bit-validated. The
        //    factory address is one we don't have yet, so we mine a
        //    salt against (PoolManager, futureFactory) using a
        //    placeholder, then deploy hook + factory atomically. The
        //    factory's CREATE address is deterministic given the
        //    deployer + nonce, so we can predict it.
        address futureFactoryAddr = vm.computeCreateAddress(
            // deployer at the moment the factory is created
            tx.origin,
            // nonce after hook deploy
            vm.getNonce(tx.origin) + 1
        );

        bytes32 hookSalt = _mineHookSalt(pm, futureFactoryAddr);
        bytes memory hookCode = abi.encodePacked(type(ProtocolHook).creationCode, abi.encode(pm, futureFactoryAddr));
        address hookAddr;
        assembly {
            hookAddr := create2(0, add(hookCode, 0x20), mload(hookCode), hookSalt)
        }
        require(hookAddr != address(0), "hook deploy failed");
        require(uint160(hookAddr) & 0x3FFF == 0x05C0, "hook bits mismatch");
        hook = ProtocolHook(hookAddr);
        console.log("ProtocolHook:", address(hook));

        // 4. VaultFactory — predicted address must equal what we
        //    used in the hook ctor. If not, the deployer's nonce
        //    moved underneath us and we abort.
        factory = new VaultFactory(pm, hook, owner);
        require(address(factory) == futureFactoryAddr, "factory address drift");
        console.log("VaultFactory:", address(factory));

        vm.stopBroadcast();

        // The actual per-pool vault deploys happen via
        // `VaultFactory.create(...)` in a follow-up script once the
        // initial pool list is locked.
    }

    /// @dev Minimal in-script salt miner. Same algorithm as #25 but
    ///      inlined here so the script doesn't pull a separate lib.
    function _mineHookSalt(IPoolManager pm, address factoryAddr) internal view returns (bytes32) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(ProtocolHook).creationCode, abi.encode(pm, factoryAddr)));
        for (uint256 i = 0; i < 200_000; i++) {
            bytes32 salt = bytes32(i);
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), msg.sender, salt, initCodeHash)))));
            if (uint160(predicted) & 0x3FFF == 0x05C0) {
                return salt;
            }
        }
        revert("salt not found");
    }
}
