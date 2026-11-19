// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BondVault} from "@src/BondVault.sol";

/// @notice Upgrade-path probe: same storage, one new function.
contract BondVaultV2 is BondVault {
    function version() external pure returns (uint256) {
        return 2;
    }
}
