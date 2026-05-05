// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Errors} from "../utils/Errors.sol";

/// @title HookMiner
/// @notice Off-chain helper: deterministic CREATE2 salt search for a
///         hook contract whose deployed address satisfies a permission
///         bit pattern.
/// @dev V4 enforces hook permissions through the lower 14 bits of the
///      deployed hook address (`address & 0x3FFF`). PRISM enables
///      bits 6, 7, 8, 10 (`afterSwap` / `beforeSwap` /
///      `afterRemoveLiquidity` / `afterAddLiquidity`) — combined
///      `0x05C0`. The deployed `ProtocolHook` MUST land at an address
///      satisfying `address & 0x3FFF == 0x05C0` or
///      `PoolManager.initialize` reverts (invariant #7, ADR-002).
///
///      This library is intended to be called from a Foundry deploy
///      script:
///
///        bytes memory args = abi.encode(POOL_MANAGER, oracle);
///        (address mined, bytes32 salt) = HookMiner.find(
///            CREATE2_DEPLOYER,
///            uint160(0x05C0),
///            type(ProtocolHook).creationCode,
///            args
///        );
///        ProtocolHook hook = new ProtocolHook{salt: salt}(POOL_MANAGER, oracle);
///        require(address(hook) == mined);
///
///      Pure library — no state, no external calls. Safe to call
///      on-chain in tests; not gas-efficient enough for on-chain
///      production deployment of large hooks.
///
///      Iteration cap: at 14 bit-pattern requirements with uniformly
///      distributed addresses, a match is expected every ~16,384 salts
///      on average. The 200,000 ceiling gives ~12× safety margin.
library HookMiner {
    /// @notice Mask for the V4 permission bits (lower 14 of an address).
    uint160 internal constant FLAG_MASK = 0x3FFF;

    /// @notice Maximum salt iterations per `find` call before giving up.
    /// @dev 200_000 ≈ 12× the expected mean for a 14-bit pattern. A
    ///      `find` failing at this ceiling is overwhelmingly likely a
    ///      bug in the caller's `requiredFlags`, not statistical bad
    ///      luck. The library reverts via `Errors.MathOverflow`
    ///      (selector reused as "search exhausted") so callers can
    ///      distinguish from input-shape errors.
    uint256 internal constant MAX_ITERATIONS = 200_000;

    /// @notice Find the first salt whose CREATE2 address has
    ///         `address & FLAG_MASK == requiredFlags`.
    /// @dev Searches `salt = 0, 1, 2, ...` deterministically so the
    ///      same `(deployer, requiredFlags, creationCode,
    ///      constructorArgs)` always returns the same result.
    /// @param deployer Address that will perform the CREATE2 (typically
    ///        the canonical CREATE2 deployer or the deploy script
    ///        itself).
    /// @param requiredFlags The bit pattern the result must satisfy
    ///        when masked with `FLAG_MASK`. For PRISM: `0x05C0`.
    /// @param creationCode Contract creation bytecode (e.g.
    ///        `type(ProtocolHook).creationCode`).
    /// @param constructorArgs ABI-encoded constructor arguments to
    ///        append to `creationCode` for the codehash calculation.
    /// @return hookAddress The mined deployment address.
    /// @return salt The salt that produces `hookAddress`.
    function find(
        address deployer,
        uint160 requiredFlags,
        bytes memory creationCode,
        bytes memory constructorArgs
    )
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        bytes memory codeWithArgs = bytes.concat(creationCode, constructorArgs);
        bytes32 codeHash = keccak256(codeWithArgs);

        for (uint256 i; i < MAX_ITERATIONS; ++i) {
            salt = bytes32(i);
            hookAddress = computeAddress(deployer, salt, codeHash);
            if ((uint160(hookAddress) & FLAG_MASK) == (requiredFlags & FLAG_MASK)) {
                return (hookAddress, salt);
            }
        }

        revert Errors.MathOverflow();
    }

    /// @notice Compute the CREATE2 address that results from a
    ///         deployer + salt + initcode hash.
    /// @dev Mirror of EIP-1014 / EIP-1052 derivation:
    ///      `keccak256(0xff ++ deployer ++ salt ++ codeHash)[12:]`.
    /// @param deployer The deploying contract's address.
    /// @param salt The CREATE2 salt.
    /// @param codeHash `keccak256(creationCode ++ constructorArgs)`.
    /// @return The would-be deployed address.
    function computeAddress(address deployer, bytes32 salt, bytes32 codeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, codeHash)))));
    }
}
