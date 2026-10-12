// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AllowanceModule} from "../../src/AllowanceModule.sol";

/// @notice A trivial stand-in "v2" used only to prove the UUPS upgrade
/// mechanics actually work end to end. Inherits AllowanceModule wholesale
/// (same storage layout, same every-other-function) and adds exactly one new
/// function, so a test can upgrade a live proxy to this and check both halves
/// of what an upgrade needs to deliver: existing storage untouched, and new
/// logic reachable through the same address every account already installed.
contract MockAllowanceModuleV2 is AllowanceModule {
    function version() external pure returns (uint256) {
        return 2;
    }
}
