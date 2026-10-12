// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AllowanceModule} from "../src/AllowanceModule.sol";
import {AllowanceModuleTestBase} from "./helpers/AllowanceModuleTestBase.sol";
import {MockERC7579Account} from "./mocks/MockERC7579Account.sol";

/// @notice Unit tests: one behavior per test, covering install, grant, the core
/// issue #1 proof (agent moves funds with zero owner signature), payee/cap/
/// expiry/pause/revoke enforcement, check()<->spend() parity, and the module-
/// level freeze.
contract AllowanceModuleTest is AllowanceModuleTestBase {
    // ============================================================
    // Install / epoch
    // ============================================================

    function test_InstallBumpsEpochToOne() public view {
        assertEq(module.epochOf(address(account)), 1);
    }

    function test_UninstallThenReinstallBumpsEpochAgain() public {
        vm.startPrank(owner);
        account.uninstallModule(2, address(module), "");
        account.installModule(2, address(module), "");
        vm.stopPrank();
        assertEq(module.epochOf(address(account)), 3);
    }

    // ============================================================
    // createAllowance
    // ============================================================

    function test_CreateAllowance_StoresFieldsAndEmits() public {
        AllowanceModule.CreateAllowanceParams memory params = _defaultParams(agent);

        vm.expectEmit(true, true, true, true, address(module));
        emit AllowanceModule.AllowanceGranted(
            address(account), ALLOWANCE_ID, agent, address(token), CAP, PERIOD, 0, false
        );
        _grant(ALLOWANCE_ID, params);

        AllowanceModule.Allowance memory a = module.allowanceOf(address(account), ALLOWANCE_ID);
        assertEq(a.spender, agent);
        assertEq(a.token, address(token));
        assertEq(a.cap, CAP);
        assertEq(a.period, PERIOD);
        assertEq(a.spent, 0);
        assertFalse(a.unrestricted);
        assertEq(a.epoch, module.epochOf(address(account)));

        address[] memory payees = module.payeesOf(address(account), ALLOWANCE_ID);
        assertEq(payees.length, 1);
        assertEq(payees[0], payee1);
    }

    function test_CreateAllowance_RevertsOnIdReuse() public {
        _grantDefault();
        vm.expectRevert(AllowanceModule.AllowanceAlreadyExists.selector);
        _grant(ALLOWANCE_ID, _defaultParams(agent));
    }

    function test_CreateAllowance_IdReuseForbiddenEvenAfterRevoke() public {
        _grantDefault();
        _revoke(ALLOWANCE_ID);
        // Reusing a revoked id must never "resurrect" it (ADR #22).
        vm.expectRevert(AllowanceModule.AllowanceAlreadyExists.selector);
        _grant(ALLOWANCE_ID, _defaultParams(agent));
    }

    function test_CreateAllowance_RevertsOnZeroSpender() public {
        AllowanceModule.CreateAllowanceParams memory params = _defaultParams(address(0));
        vm.expectRevert(AllowanceModule.ZeroAddress.selector);
        _grant(ALLOWANCE_ID, params);
    }

    function test_CreateAllowance_RevertsOnNoPayeesWhenRestricted() public {
        AllowanceModule.CreateAllowanceParams memory params = _defaultParams(agent);
        params.payees = new address[](0);
        vm.expectRevert(AllowanceModule.NoPayees.selector);
        _grant(ALLOWANCE_ID, params);
    }

    function test_CreateAllowance_RevertsWhenExceedsAccountDelegatedCap() public {
        AllowanceModule.CreateAllowanceParams memory params = _defaultParams(agent);
        // Safe: MAX_ACCOUNT_DELEGATED_CAP is 1_000_000e6, far under uint96's range.
        // forge-lint: disable-next-line(unsafe-typecast)
        params.cap = uint96(MAX_ACCOUNT_DELEGATED_CAP + 1);
        vm.expectRevert(AllowanceModule.AccountDelegatedCapExceeded.selector);
        _grant(ALLOWANCE_ID, params);
    }

    function test_TotalDelegatedCap_TracksGrantsAndRevokes() public {
        _grantDefault();
        assertEq(module.totalDelegatedCapOf(address(account)), CAP);
        _revoke(ALLOWANCE_ID);
        assertEq(module.totalDelegatedCapOf(address(account)), 0);
    }

    // ============================================================
    // The core proof: the agent moves funds with zero owner signature
    // ============================================================

    function test_Spend_AgentMovesFundsWithoutOwnerSignature() public {
        _grantDefault();

        uint256 accountBalanceBefore = token.balanceOf(address(account));
        uint256 payeeBalanceBefore = token.balanceOf(payee1);

        // Note: no vm.prank(owner) anywhere below. The only signer touching this
        // transaction is the agent's own key.
        vm.prank(agent);
        module.spend(address(account), ALLOWANCE_ID, payee1, 10e6);

        assertEq(token.balanceOf(address(account)), accountBalanceBefore - 10e6);
        assertEq(token.balanceOf(payee1), payeeBalanceBefore + 10e6);

        AllowanceModule.Allowance memory a = module.allowanceOf(address(account), ALLOWANCE_ID);
        assertEq(a.spent, 10e6);
    }

    function test_Spend_EmitsSpentEvent() public {
        _grantDefault();
        vm.expectEmit(true, true, true, true, address(module));
        emit AllowanceModule.Spent(address(account), ALLOWANCE_ID, payee1, 10e6, 10e6, CAP);
        vm.prank(agent);
        module.spend(address(account), ALLOWANCE_ID, payee1, 10e6);
    }

    // ============================================================
    // Rejections
    // ============================================================

    function test_Spend_RevertsForNonAllowedSpender() public {
        _grantDefault();
        vm.prank(stranger);
        vm.expectRevert(AllowanceModule.NotTheSpender.selector);
        module.spend(address(account), ALLOWANCE_ID, payee1, 10e6);
    }

    function test_Spend_RevertsForWrongPayee() public {
        _grantDefault();
        vm.prank(agent);
        vm.expectRevert(AllowanceModule.PayeeNotAllowed.selector);
        module.spend(address(account), ALLOWANCE_ID, payee2, 10e6);
    }

    function test_Spend_RevertsOverCap() public {
        AllowanceModule.CreateAllowanceParams memory params = _defaultParams(agent);
        _grant(ALLOWANCE_ID, params);

        vm.prank(agent);
        vm.expectRevert(AllowanceModule.OverCap.selector);
        module.spend(address(account), ALLOWANCE_ID, payee1, CAP + 1);
    }

    function test_Spend_RevertsWhenExpired() public {
        AllowanceModule.CreateAllowanceParams memory params = _defaultParams(agent);
        params.expiresAt = uint48(block.timestamp + 1 hours);
        _grant(ALLOWANCE_ID, params);

        vm.warp(block.timestamp + 1 hours); // exactly at expiresAt
        vm.prank(agent);
        vm.expectRevert(AllowanceModule.Expired.selector);
        module.spend(address(account), ALLOWANCE_ID, payee1, 1e6);
    }

    function test_Spend_RevertsWhenPaused_SucceedsAfterUnpause() public {
        _grantDefault();
        _setPaused(ALLOWANCE_ID, true);

        vm.prank(agent);
        vm.expectRevert(AllowanceModule.Paused.selector);
        module.spend(address(account), ALLOWANCE_ID, payee1, 1e6);

        _setPaused(ALLOWANCE_ID, false);
        vm.prank(agent);
        module.spend(address(account), ALLOWANCE_ID, payee1, 1e6); // now succeeds
    }

    function test_PauseIsReversible_PreservesSpentAndWindowStart() public {
        _grantDefault();
        vm.prank(agent);
        module.spend(address(account), ALLOWANCE_ID, payee1, 5e6);

        AllowanceModule.Allowance memory before = module.allowanceOf(address(account), ALLOWANCE_ID);
        _setPaused(ALLOWANCE_ID, true);
        _setPaused(ALLOWANCE_ID, false);
        AllowanceModule.Allowance memory afterUnpause = module.allowanceOf(address(account), ALLOWANCE_ID);

        assertEq(afterUnpause.spent, before.spent);
        assertEq(afterUnpause.windowStart, before.windowStart);
    }

    function test_Spend_RevertsWhenRevoked_AndRevokeIsTerminal() public {
        _grantDefault();
        _revoke(ALLOWANCE_ID);

        vm.prank(agent);
        vm.expectRevert(AllowanceModule.Revoked.selector);
        module.spend(address(account), ALLOWANCE_ID, payee1, 1e6);

        // Terminal: cannot un-revoke via setPaused or a second revoke call.
        vm.expectRevert(AllowanceModule.Revoked.selector);
        _setPaused(ALLOWANCE_ID, false);

        vm.expectRevert(AllowanceModule.Revoked.selector);
        _revoke(ALLOWANCE_ID);
    }

    // ============================================================
    // "Anywhere" allowances
    // ============================================================

    function test_UnrestrictedAllowance_AllowsAnyPayee() public {
        AllowanceModule.CreateAllowanceParams memory params = _defaultParams(agent);
        params.unrestricted = true;
        params.payees = new address[](0);
        _grant(ALLOWANCE_ID, params);

        vm.prank(agent);
        module.spend(address(account), ALLOWANCE_ID, payee2, 1e6); // payee2 was never allowlisted
        assertEq(token.balanceOf(payee2), 1e6);
    }

    function test_RestrictedAllowance_ZeroedPayeeCountIsNotUnrestricted() public {
        // Guards against the exact bug ADR #22 calls out: payeeCount == 0 must
        // never be an implicit sentinel for "Anywhere."
        AllowanceModule.CreateAllowanceParams memory params = _defaultParams(agent);
        params.unrestricted = false;
        // _defaultParams already supplies one payee, so payeeCount is 1 here —
        // this test's point is that `unrestricted` is a real, independent flag,
        // not derived from payeeCount at all.
        _grant(ALLOWANCE_ID, params);

        AllowanceModule.Allowance memory a = module.allowanceOf(address(account), ALLOWANCE_ID);
        assertFalse(a.unrestricted);
        assertEq(a.payeeCount, 1);

        vm.prank(agent);
        vm.expectRevert(AllowanceModule.PayeeNotAllowed.selector);
        module.spend(address(account), ALLOWANCE_ID, payee2, 1e6);
    }

    // ============================================================
    // check() / spend() parity
    // ============================================================

    function test_Check_AgreesWithSpend_WrongSpender() public {
        _grantDefault();
        vm.prank(stranger);
        (bool ok, bytes4 reason) = module.check(address(account), ALLOWANCE_ID, payee1, 1e6);
        assertFalse(ok);
        assertEq(reason, AllowanceModule.NotTheSpender.selector);
    }

    function test_Check_AgreesWithSpend_WrongPayee() public {
        _grantDefault();
        vm.prank(agent);
        (bool ok, bytes4 reason) = module.check(address(account), ALLOWANCE_ID, payee2, 1e6);
        assertFalse(ok);
        assertEq(reason, AllowanceModule.PayeeNotAllowed.selector);
    }

    function test_Check_AgreesWithSpend_OverCap() public {
        AllowanceModule.CreateAllowanceParams memory params = _defaultParams(agent);
        _grant(ALLOWANCE_ID, params);

        vm.prank(agent);
        (bool ok, bytes4 reason) = module.check(address(account), ALLOWANCE_ID, payee1, CAP + 1);
        assertFalse(ok);
        assertEq(reason, AllowanceModule.OverCap.selector);
    }

    function test_Check_TrueWhenSpendWouldSucceed() public {
        _grantDefault();
        vm.prank(agent);
        (bool ok, bytes4 reason) = module.check(address(account), ALLOWANCE_ID, payee1, 1e6);
        assertTrue(ok);
        assertEq(reason, bytes4(0));
    }

    // ============================================================
    // spendWithSig
    // ============================================================

    function test_SpendWithSig_HappyPath() public {
        _grantDefault();
        uint256 deadline = block.timestamp + 1 hours;
        _spendWithSig(ALLOWANCE_ID, payee1, 5e6, deadline, agentPk);
        assertEq(token.balanceOf(payee1), 5e6);
    }

    function test_SpendWithSig_RevertsAfterDeadline() public {
        _grantDefault();
        uint256 deadline = block.timestamp + 1 hours;
        // Signature built (and its nonceOf/domainSeparator lookups made) BEFORE
        // vm.expectRevert is armed — otherwise one of those lookups, not the
        // spendWithSig call below, would be treated as "the next call" and this
        // would fail with "next call did not revert as expected" instead of
        // actually exercising SignatureExpired.
        bytes memory signature = _signSpend(ALLOWANCE_ID, payee1, 5e6, deadline, agentPk);
        vm.warp(deadline + 1);
        vm.expectRevert(AllowanceModule.SignatureExpired.selector);
        module.spendWithSig(address(account), ALLOWANCE_ID, payee1, 5e6, deadline, signature);
    }

    function test_SpendWithSig_RevertsForWrongSigner() public {
        _grantDefault();
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory signature = _signSpend(ALLOWANCE_ID, payee1, 5e6, deadline, strangerPk);
        vm.expectRevert(AllowanceModule.NotTheSpender.selector);
        module.spendWithSig(address(account), ALLOWANCE_ID, payee1, 5e6, deadline, signature);
    }

    // ============================================================
    // Module-level freeze (admin circuit breaker, distinct from per-allowance pause)
    // ============================================================

    function test_ModuleFreeze_BlocksAllSpends() public {
        _grantDefault();
        vm.prank(admin);
        module.freezeModule();

        vm.prank(agent);
        vm.expectRevert(AllowanceModule.ModuleFrozen.selector);
        module.spend(address(account), ALLOWANCE_ID, payee1, 1e6);

        vm.prank(admin);
        module.unfreezeModule();

        vm.prank(agent);
        module.spend(address(account), ALLOWANCE_ID, payee1, 1e6); // now succeeds
    }

    function test_ModuleFreeze_OnlyAdmin() public {
        vm.expectRevert(AllowanceModule.NotAdmin.selector);
        module.freezeModule();
    }

    // ============================================================
    // Owner-mutator scoping: an agent calling a non-spend selector directly
    // never touches the real account's allowance state
    // ============================================================

    function test_AgentCallingCreateAllowanceDirectly_NeverTouchesRealAccount() public {
        AllowanceModule.CreateAllowanceParams memory params = _defaultParams(agent);
        vm.prank(agent);
        // This succeeds — but only against the agent's OWN address as the
        // "account" key (see AllowanceModule.createAllowance's NOTE), which has
        // no funds, no installed module, and nothing routing to it. It can never
        // reach the real account's allowance at this id.
        module.createAllowance(ALLOWANCE_ID, params);

        AllowanceModule.Allowance memory real = module.allowanceOf(address(account), ALLOWANCE_ID);
        assertEq(real.spender, address(0)); // untouched

        AllowanceModule.Allowance memory agentsOwn = module.allowanceOf(agent, ALLOWANCE_ID);
        assertEq(agentsOwn.spender, agent); // only affected the agent's own namespace
    }

    function test_AgentCallingExecuteDirectly_Reverts() public {
        bytes memory executionCalldata = abi.encodePacked(payee1, uint256(1), bytes(""));
        vm.prank(agent);
        vm.expectRevert(MockERC7579Account.NotOwner.selector);
        account.execute(bytes32(0), executionCalldata);
    }

    function test_AgentCallingExecuteFromExecutorDirectly_Reverts() public {
        bytes memory executionCalldata = abi.encodePacked(payee1, uint256(1), bytes(""));
        vm.prank(agent); // agent's own address was never installed as an executor
        vm.expectRevert(MockERC7579Account.NotInstalledExecutor.selector);
        account.executeFromExecutor(bytes32(0), executionCalldata);
    }

    function test_AgentCallingInstallModule_Reverts() public {
        vm.prank(agent);
        vm.expectRevert(MockERC7579Account.NotOwner.selector);
        account.installModule(2, address(module), "");
    }

    function test_AgentCallingUninstallModule_Reverts() public {
        vm.prank(agent);
        vm.expectRevert(MockERC7579Account.NotOwner.selector);
        account.uninstallModule(2, address(module), "");
    }

    function test_AgentSignature_NeverValidatesAsOwner() public view {
        bytes32 hash = keccak256("some user op or batch");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentPk, hash);
        bytes4 result = account.isValidSignature(hash, abi.encodePacked(r, s, v));
        assertTrue(result != bytes4(0x1626ba7e)); // not the ERC-1271 success magic value
    }
}
