// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AllowanceModule} from "../src/AllowanceModule.sol";
import {AllowanceModuleTestBase} from "./helpers/AllowanceModuleTestBase.sol";
import {MockAllowanceModuleV2} from "./mocks/MockAllowanceModuleV2.sol";

/// @notice Proves the UUPS upgrade path the ADR's "upgradeable without
/// re-authorization" note actually needs: ADMIN (and only ADMIN) can point the
/// proxy at new logic in one transaction, every account's existing storage
/// (allowances, admin, cap, domain separator) survives untouched, and the new
/// logic is live immediately through the SAME address every account already
/// installed as its executor — no account calls uninstallModule/installModule,
/// no owner or agent re-signs anything.
contract AllowanceModuleUpgradeTest is AllowanceModuleTestBase {
    function test_Upgrade_NonAdminCannotAuthorize() public {
        MockAllowanceModuleV2 v2 = new MockAllowanceModuleV2();
        vm.expectRevert(AllowanceModule.NotAdmin.selector);
        module.upgradeToAndCall(address(v2), "");
    }

    function test_Upgrade_AdminCanUpgrade_ExistingStorageSurvives() public {
        _grantDefault();
        vm.prank(agent);
        module.spend(address(account), ALLOWANCE_ID, payee1, 10e6);

        AllowanceModule.Allowance memory before = module.allowanceOf(address(account), ALLOWANCE_ID);
        address adminBefore = module.admin();
        uint256 capBefore = module.maxAccountDelegatedCap();
        bytes32 domainBefore = module.domainSeparator();

        MockAllowanceModuleV2 v2 = new MockAllowanceModuleV2();
        vm.prank(admin);
        module.upgradeToAndCall(address(v2), "");

        // Same proxy address (`module` was never reassigned), same storage —
        // no account had to do anything, no re-authorization of any kind.
        AllowanceModule.Allowance memory afterUpgrade = module.allowanceOf(address(account), ALLOWANCE_ID);
        assertEq(afterUpgrade.spent, before.spent);
        assertEq(afterUpgrade.cap, before.cap);
        assertEq(afterUpgrade.windowStart, before.windowStart);
        assertEq(module.admin(), adminBefore);
        assertEq(module.maxAccountDelegatedCap(), capBefore);
        assertEq(module.domainSeparator(), domainBefore);

        // New logic is actually live through the same address.
        assertEq(MockAllowanceModuleV2(address(module)).version(), 2);

        // Old logic still works exactly as before the upgrade, too.
        vm.prank(agent);
        module.spend(address(account), ALLOWANCE_ID, payee1, 5e6);
        AllowanceModule.Allowance memory afterSpend = module.allowanceOf(address(account), ALLOWANCE_ID);
        assertEq(afterSpend.spent, 15e6);
    }

    function test_Upgrade_PreservesModuleFrozenState() public {
        vm.prank(admin);
        module.freezeModule();

        MockAllowanceModuleV2 v2 = new MockAllowanceModuleV2();
        vm.prank(admin);
        module.upgradeToAndCall(address(v2), "");

        assertTrue(module.isModuleFrozen()); // survived the upgrade unchanged
    }
}
