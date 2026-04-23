// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import {PoolKey} from "v4-core/types/PoolKey.sol";

/// @notice Placeholder test so `forge test` exits 0 before Vault tests land (#38).
/// @dev Also imports a v4-core type (`PoolKey`) to prove the submodule pins + remappings
///      resolve end-to-end. A deeper import (e.g. `PoolManager`) requires solc 0.8.26;
///      types/interfaces use floor pragmas and compile under our 0.8.25 pin.
contract SanityTest {
    function test_scaffold_compiles() external pure {
        assert(true);
    }

    function test_v4core_import_resolves() external pure {
        // Reference the type so the import is not dead-code-eliminated.
        PoolKey memory key;
        assert(key.fee == 0);
    }
}
