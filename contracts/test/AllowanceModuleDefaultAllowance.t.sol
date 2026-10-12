// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AllowanceModule} from "../src/AllowanceModule.sol";
import {AllowanceModuleTestBase} from "./helpers/AllowanceModuleTestBase.sol";

/// @notice Tests for `createDefaultAllowance`, the simplified grant path that
/// takes only spender, token, cap and period and defaults everything else —
/// expiresAt, unrestricted, payees — inside the contract. The defining
/// behavior under test throughout this file: "5 USDC for 30 minutes" means up
/// to 5 USDC spendable across the next 30 minutes, and the INSTANT those 30
/// minutes are up the allowance is dead — not rolled into a fresh window the
/// way `createAllowance`'s repeating `period` would be.
contract AllowanceModuleDefaultAllowanceTest is AllowanceModuleTestBase {
    // ============================================================
    // Defaults actually applied
    // ============================================================

    function test_CreateDefaultAllowance_StoresExpectedDefaults() public {
        uint256 grantTime = block.timestamp;
        _grantDefaultAllowanceForAgent(ALLOWANCE_ID);

        AllowanceModule.Allowance memory a = module.allowanceOf(address(account), ALLOWANCE_ID);
        assertEq(a.spender, agent);
        assertEq(a.token, address(token));
        assertEq(a.cap, CAP);
        assertEq(a.period, PERIOD);
        assertEq(a.expiresAt, grantTime + PERIOD); // dies after exactly one period
        assertTrue(a.unrestricted); // no payee list collected by this path
        assertEq(a.payeeCount, 0);
        assertEq(a.spent, 0);

        address[] memory payees = module.payeesOf(address(account), ALLOWANCE_ID);
        assertEq(payees.length, 0);
    }

    function test_CreateDefaultAllowance_EmitsAllowanceGrantedWithDefaults() public {
        uint48 expectedExpiresAt = uint48(block.timestamp) + PERIOD;
        vm.expectEmit(true, true, true, true, address(module));
        emit AllowanceModule.AllowanceGranted(
            address(account), ALLOWANCE_ID, agent, address(token), CAP, PERIOD, expectedExpiresAt, true
        );
        _grantDefaultAllowanceForAgent(ALLOWANCE_ID);
    }

    // ============================================================
    // The worked example: "5 USDC for 30 minutes"
    // ============================================================

    function test_DefaultAllowance_SpendableAnytimeWithinThePeriod() public {
        uint24 thirtyMinutes = 30 minutes;
        uint96 fiveUsdc = 5e6;
        _grantDefaultAllowance(ALLOWANCE_ID, agent, address(token), fiveUsdc, thirtyMinutes);

        vm.warp(block.timestamp + 10 minutes);
        vm.prank(agent);
        module.spend(address(account), ALLOWANCE_ID, payee1, 2e6); // partial spend, still well inside the window

        vm.warp(block.timestamp + 19 minutes); // 29 minutes total, still inside
        vm.prank(agent);
        module.spend(address(account), ALLOWANCE_ID, payee1, 3e6); // spends the rest of the 5 USDC

        assertEq(token.balanceOf(payee1), fiveUsdc);
    }

    function test_DefaultAllowance_UnrestrictedAllowsAnyPayee() public {
        _grantDefaultAllowanceForAgent(ALLOWANCE_ID);
        vm.prank(agent);
        module.spend(address(account), ALLOWANCE_ID, payee2, 1e6); // payee2 was never allowlisted anywhere
        assertEq(token.balanceOf(payee2), 1e6);
    }

    /// @notice Once the period elapses, the allowance is dead, full stop — not
    /// rolled into a fresh window. This is what distinguishes
    /// `createDefaultAllowance` from `createAllowance`'s ordinary
    /// repeating-`period` semantics.
    function test_DefaultAllowance_ExpiresPermanently_DoesNotRollIntoNewWindow() public {
        uint24 thirtyMinutes = 30 minutes;
        _grantDefaultAllowance(ALLOWANCE_ID, agent, address(token), 5e6, thirtyMinutes);

        vm.warp(block.timestamp + thirtyMinutes); // exactly at expiresAt
        vm.prank(agent);
        vm.expectRevert(AllowanceModule.Expired.selector);
        module.spend(address(account), ALLOWANCE_ID, payee1, 1e6);

        // Contrast with a repeating-period allowance: warping an extra whole
        // period further still never revives it — there is no "next window."
        vm.warp(block.timestamp + thirtyMinutes * 10);
        vm.prank(agent);
        vm.expectRevert(AllowanceModule.Expired.selector);
        module.spend(address(account), ALLOWANCE_ID, payee1, 1e6);

        assertTrue(module.statusOf(address(account), ALLOWANCE_ID) == AllowanceModule.Status.Expired);
    }

    function test_DefaultAllowance_OneSecondBeforeExpiry_StillSucceeds() public {
        uint24 thirtyMinutes = 30 minutes;
        _grantDefaultAllowance(ALLOWANCE_ID, agent, address(token), 5e6, thirtyMinutes);

        vm.warp(block.timestamp + thirtyMinutes - 1);
        vm.prank(agent);
        module.spend(address(account), ALLOWANCE_ID, payee1, 5e6); // the full cap, one second before the deadline
        assertEq(token.balanceOf(payee1), 5e6);
    }

    function test_DefaultAllowance_CannotExceedCapEvenWithinThePeriod() public {
        _grantDefaultAllowance(ALLOWANCE_ID, agent, address(token), 5e6, 30 minutes);

        vm.prank(agent);
        vm.expectRevert(AllowanceModule.OverCap.selector);
        module.spend(address(account), ALLOWANCE_ID, payee1, 5e6 + 1);
    }

    // ============================================================
    // check() / spend() parity for the default path
    // ============================================================

    function test_DefaultAllowance_CheckAgreesWithSpend() public {
        _grantDefaultAllowanceForAgent(ALLOWANCE_ID);

        vm.prank(agent);
        (bool ok, bytes4 reason) = module.check(address(account), ALLOWANCE_ID, payee1, 1e6);
        assertTrue(ok);
        assertEq(reason, bytes4(0));

        vm.warp(block.timestamp + PERIOD);
        vm.prank(agent);
        (bool okAfterExpiry, bytes4 reasonAfterExpiry) = module.check(address(account), ALLOWANCE_ID, payee1, 1e6);
        assertFalse(okAfterExpiry);
        assertEq(reasonAfterExpiry, AllowanceModule.Expired.selector);
    }

    // ============================================================
    // Validation — shares _createAllowance's checks with createAllowance
    // ============================================================

    function test_DefaultAllowance_RevertsOnZeroCap() public {
        vm.expectRevert(AllowanceModule.InvalidParams.selector);
        _grantDefaultAllowance(ALLOWANCE_ID, agent, address(token), 0, PERIOD);
    }

    function test_DefaultAllowance_RevertsOnZeroPeriod() public {
        vm.expectRevert(AllowanceModule.InvalidParams.selector);
        _grantDefaultAllowance(ALLOWANCE_ID, agent, address(token), CAP, 0);
    }

    function test_DefaultAllowance_RevertsOnZeroSpender() public {
        vm.expectRevert(AllowanceModule.ZeroAddress.selector);
        _grantDefaultAllowance(ALLOWANCE_ID, address(0), address(token), CAP, PERIOD);
    }

    function test_DefaultAllowance_RevertsOnIdReuse() public {
        _grantDefaultAllowanceForAgent(ALLOWANCE_ID);
        vm.expectRevert(AllowanceModule.AllowanceAlreadyExists.selector);
        _grantDefaultAllowanceForAgent(ALLOWANCE_ID);
    }

    function test_DefaultAllowance_RevertsWhenExceedsAccountDelegatedCap() public {
        // Safe: MAX_ACCOUNT_DELEGATED_CAP is 1_000_000e6, far under uint96's range.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint96 tooMuch = uint96(MAX_ACCOUNT_DELEGATED_CAP + 1);
        vm.expectRevert(AllowanceModule.AccountDelegatedCapExceeded.selector);
        _grantDefaultAllowance(ALLOWANCE_ID, agent, address(token), tooMuch, PERIOD);
    }

    // ============================================================
    // setPaused / revoke work identically regardless of which grant path
    // created the allowance
    // ============================================================

    function test_DefaultAllowance_CanBePausedAndUnpaused() public {
        _grantDefaultAllowanceForAgent(ALLOWANCE_ID);
        _setPaused(ALLOWANCE_ID, true);

        vm.prank(agent);
        vm.expectRevert(AllowanceModule.Paused.selector);
        module.spend(address(account), ALLOWANCE_ID, payee1, 1e6);

        _setPaused(ALLOWANCE_ID, false);
        vm.prank(agent);
        module.spend(address(account), ALLOWANCE_ID, payee1, 1e6); // succeeds again
    }

    function test_DefaultAllowance_CanBeRevoked() public {
        _grantDefaultAllowanceForAgent(ALLOWANCE_ID);
        _revoke(ALLOWANCE_ID);

        vm.prank(agent);
        vm.expectRevert(AllowanceModule.Revoked.selector);
        module.spend(address(account), ALLOWANCE_ID, payee1, 1e6);
    }
}
