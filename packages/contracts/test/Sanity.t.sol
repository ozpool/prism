// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PoolManager} from "v4-core/PoolManager.sol";

/// @notice Placeholder test so `forge test` exits 0 before Vault tests land (#38).
/// @dev Imports `PoolManager` from v4-core to prove the submodule pins + remappings
///      resolve end-to-end. `PoolManager.sol` pins `pragma solidity 0.8.26` strictly,
///      so this import would fail to compile under the previous 0.8.25 pin (see ADR-001).
contract SanityTest {
    function test_scaffold_compiles() external pure {
        assert(true);
    }

    function test_v4core_poolmanager_import_resolves() external pure {
        // Reference a PoolManager-specific selector so the import isn't dead-code-eliminated.
        bytes4 sel = PoolManager.unlock.selector;
        assert(sel != bytes4(0));
    }
}
