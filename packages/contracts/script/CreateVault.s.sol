// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {VaultFactory} from "../src/core/VaultFactory.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";

/// @notice Minimal mock ERC20 — fixed-supply, owner-mint, used to bootstrap
///         a V4 pool on testnet so we can test the PRISM rebalance flow.
contract MockToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @title CreateVault — deploy mock ERC20s, initialise a V4 pool, spawn a PRISM vault.
/// @notice Wires up a minimal end-to-end testbed on Base Sepolia.
///
/// Required env vars:
///   - DEPLOYER_PRIVATE_KEY    — funded EOA
///   - VAULT_FACTORY           — address from initial deploy
///   - PROTOCOL_HOOK           — address from initial deploy
///   - BELL_STRATEGY           — address from initial deploy
///   - POOL_MANAGER            — Base Sepolia V4 PoolManager
contract CreateVault is Script {
    // V4 dynamic-fee sentinel (top bit set = dynamic fee). PRISM's hook
    // computes the per-swap fee in beforeSwap and overrides via the
    // OVERRIDE flag on the returned uint24.
    uint24 internal constant DYNAMIC_FEE = 0x800000;

    // Mid range; stays inside V4's tick-spacing constraints for a 30bps
    // pool. Bell strategy aligns its tick math to this.
    int24 internal constant TICK_SPACING = 60;

    // Initial pool price = 1.0 (token0 == token1 in real terms).
    // sqrt(1) * 2^96 = 79228162514264337593543950336.
    uint160 internal constant SQRT_PRICE_X96_AT_1 = 79228162514264337593543950336;

    function run() external returns (address vault, address token0, address token1) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        VaultFactory factory = VaultFactory(vm.envAddress("VAULT_FACTORY"));
        IHooks hook = IHooks(vm.envAddress("PROTOCOL_HOOK"));
        IStrategy strategy = IStrategy(vm.envAddress("BELL_STRATEGY"));
        IPoolManager pm = IPoolManager(vm.envAddress("POOL_MANAGER"));

        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // 1. Deploy two mock ERC20s. We mint 1B units to the deployer so
        //    they can seed initial liquidity + test deposits.
        MockToken a = new MockToken("PRISM Test Token A", "tA");
        MockToken b = new MockToken("PRISM Test Token B", "tB");
        a.mint(deployer, 1_000_000_000 ether);
        b.mint(deployer, 1_000_000_000 ether);

        console.log("Token A:", address(a));
        console.log("Token B:", address(b));

        // 2. Sort tokens for PoolKey — V4 requires currency0 < currency1.
        if (uint160(address(a)) < uint160(address(b))) {
            token0 = address(a);
            token1 = address(b);
        } else {
            token0 = address(b);
            token1 = address(a);
        }

        // 3. Initialise the V4 pool with PRISM hook attached.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: DYNAMIC_FEE,
            tickSpacing: TICK_SPACING,
            hooks: hook
        });

        pm.initialize(key, SQRT_PRICE_X96_AT_1);
        console.log("Pool initialised at sqrtPriceX96 =", SQRT_PRICE_X96_AT_1);

        // 4. Spawn the vault via the factory.
        bytes32 salt = keccak256(abi.encode("PRISM-tA-tB-v1"));
        vault = factory.create(
            key,
            strategy,
            type(uint256).max, // tvlCap = unlimited for testnet
            "PRISM tA/tB Vault",
            "PRISM-tA-tB",
            salt
        );

        console.log("Vault:", vault);

        vm.stopBroadcast();
    }
}
