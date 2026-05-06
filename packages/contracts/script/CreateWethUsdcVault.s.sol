// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {VaultFactory} from "../src/core/VaultFactory.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";

/// @title CreateWethUsdcVault — initialise a real WETH/USDC pool on Base Sepolia
///        and spawn a PRISM vault for it.
/// @notice This is the testnet "real-asset" path. Unlike CreateVault which
///         deploys mock ERC-20s, this script targets the canonical Base Sepolia
///         WETH (0x4200…0006) and Circle's testnet USDC (0x036C…CF7e). The
///         deployer EOA does NOT need to hold either token — pool init only
///         touches PoolManager, not the tokens.
///
/// Required env:
///   - DEPLOYER_PRIVATE_KEY    — funded EOA
///   - VAULT_FACTORY           — from initial deploy
///   - PROTOCOL_HOOK           — from initial deploy
///   - BELL_STRATEGY           — from initial deploy
///   - POOL_MANAGER            — Base Sepolia V4 PoolManager
contract CreateWethUsdcVault is Script {
    /// @dev Canonical Base Sepolia WETH (predeploy slot, same on every OP stack).
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    /// @dev Circle's testnet USDC on Base Sepolia.
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;

    /// @dev V4 dynamic-fee sentinel. Hook overrides per-swap.
    uint24 internal constant DYNAMIC_FEE = 0x800000;

    /// @dev 60-tick spacing — matches the 30bps fee tier most ETH/stable pools
    ///      converge on. Strategy's tick math aligns to this.
    int24 internal constant TICK_SPACING = 60;

    /// @dev Initial pool price ≈ 3000 USDC / 1 WETH.
    ///
    /// V4 sqrtPriceX96 represents `sqrt(price1/price0) << 96` where price is
    /// in raw token units (10^decimals). For currency0=USDC, currency1=WETH:
    ///
    ///   price1/price0 = (1 WETH = 1e18 wei) / (3000 USDC = 3000e6 = 3e9)
    ///                 = 1e18 / 3e9 = 3.333e8
    ///   sqrt(3.333e8) = 18257.4
    ///   sqrtPriceX96  = 18257.4 * 2^96 ≈ 1.446e30
    ///
    /// This is the encoded value below. If WETH < USDC numerically (it is —
    /// 0x4200... > 0x036C... so USDC sorts first), this assignment matches
    /// the sorted PoolKey.
    uint160 internal constant SQRT_PRICE_X96_USDC_WETH = 1446501726624999858175504384000;

    function run() external returns (address vault, address token0, address token1) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        VaultFactory factory = VaultFactory(vm.envAddress("VAULT_FACTORY"));
        IHooks hook = IHooks(vm.envAddress("PROTOCOL_HOOK"));
        IStrategy strategy = IStrategy(vm.envAddress("BELL_STRATEGY"));
        IPoolManager pm = IPoolManager(vm.envAddress("POOL_MANAGER"));

        // V4 requires currency0 < currency1 numerically.
        if (uint160(USDC) < uint160(WETH)) {
            token0 = USDC;
            token1 = WETH;
        } else {
            token0 = WETH;
            token1 = USDC;
        }

        console.log("token0:", token0);
        console.log("token1:", token1);

        vm.startBroadcast(deployerKey);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: DYNAMIC_FEE,
            tickSpacing: TICK_SPACING,
            hooks: hook
        });

        // Initialise. If the pool already exists (i.e. someone else ran this
        // script before), V4 reverts; either case the script aborts and the
        // operator can read the existing pool's tick from PoolManager.
        pm.initialize(key, SQRT_PRICE_X96_USDC_WETH);
        console.log("Pool initialised");

        bytes32 salt = keccak256(abi.encode("PRISM-WETH-USDC-v1"));
        vault = factory.create(
            key,
            strategy,
            type(uint256).max, // tvlCap unlimited for testnet
            "PRISM WETH/USDC Vault",
            "PRISM-WETH-USDC",
            salt
        );

        console.log("Vault:", vault);

        vm.stopBroadcast();
    }
}
