// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AllowanceModule} from "../src/AllowanceModule.sol";
import {AllowanceModuleTestBase} from "./helpers/AllowanceModuleTestBase.sol";
import {ReentrantToken} from "./mocks/ReentrantToken.sol";

/// @notice The named adversarial cases #23 calls out explicitly, one test per
/// case, each with the outcome the ADR says is correct (not always "must
/// revert" — the period-boundary burst is an accepted consequence of the
/// anchored window design, not a bug).
contract AllowanceModuleAdversarialTest is AllowanceModuleTestBase {
    function _grantUnrestricted(bytes32 id, address spender, uint96 cap, uint24 period) internal {
        address[] memory empty = new address[](0);
        AllowanceModule.CreateAllowanceParams memory params = AllowanceModule.CreateAllowanceParams({
            spender: spender,
            token: address(token),
            cap: cap,
            period: period,
            expiresAt: 0,
            unrestricted: true,
            payees: empty
        });
        _grant(id, params);
    }

    /// @notice ADR #22's own example: "a $50/day allowance permits $50 at T-1s
    /// and $50 at T+1s." This is a documented property of the anchored window,
    /// not a bug to fix here — the test exists to lock the behavior in, not to
    /// assert it reverts.
    function test_Adversarial_PeriodBoundaryBurst_IsAcceptedByDesign() public {
        _grantUnrestricted(ALLOWANCE_ID, agent, CAP, PERIOD);
        AllowanceModule.Allowance memory a0 = module.allowanceOf(address(account), ALLOWANCE_ID);
        uint256 windowStart = a0.windowStart;

        vm.warp(windowStart + PERIOD - 1);
        vm.prank(agent);
        module.spend(address(account), ALLOWANCE_ID, payee1, CAP); // full cap, just inside the window

        vm.warp(windowStart + PERIOD + 1);
        vm.prank(agent);
        module.spend(address(account), ALLOWANCE_ID, payee1, CAP); // full cap again, just inside the NEXT window

        assertEq(token.balanceOf(payee1), uint256(CAP) * 2); // twice the cap inside a few seconds, by design
    }

    function test_Adversarial_WindowBoundaryOffByOne() public {
        _grantUnrestricted(ALLOWANCE_ID, agent, CAP, PERIOD);
        AllowanceModule.Allowance memory a0 = module.allowanceOf(address(account), ALLOWANCE_ID);
        uint256 windowStart = a0.windowStart;

        vm.warp(windowStart + PERIOD - 1);
        vm.prank(agent);
        module.spend(address(account), ALLOWANCE_ID, payee1, CAP); // exhausts this window

        vm.warp(windowStart + PERIOD - 1); // still same second, same window
        vm.prank(agent);
        vm.expectRevert(AllowanceModule.OverCap.selector);
        module.spend(address(account), ALLOWANCE_ID, payee1, 1);

        vm.warp(windowStart + PERIOD); // exactly one period later: new window
        vm.prank(agent);
        module.spend(address(account), ALLOWANCE_ID, payee1, 1); // succeeds, window has rolled
    }

    function test_Adversarial_IdReuseCannotResurrectRevoked() public {
        _grantDefault();
        _revoke(ALLOWANCE_ID);
        vm.expectRevert(AllowanceModule.AllowanceAlreadyExists.selector);
        _grant(ALLOWANCE_ID, _defaultParams(agent));
    }

    /// @dev Note on what this actually proves: the reentrant call below lands
    /// with msg.sender == the hostile token contract itself, not the agent — so
    /// in practice it is caught by the spender-identity check before it ever
    /// reaches the cap logic, since the token can never impersonate the agent's
    /// address. The test still matters: it proves the *outer* spend() unwinds
    /// completely (spent stays 0, no balance moves) rather than leaving anything
    /// partially applied. The deeper protection this module relies on for a
    /// truly same-identity reentrant call — spent written before the external
    /// call, so a nested call from the legitimate spender would see the already-
    /// updated spent and be correctly cap-limited — isn't independently
    /// exercised by a plain hostile-token callback, since the agent here is a
    /// plain EOA that cannot itself be the source of a callback. Flagging this
    /// gap rather than overclaiming what one test proves.
    function test_Adversarial_ReentrancyViaHostileToken_FailsCleanly() public {
        ReentrantToken hostile = new ReentrantToken(address(this));
        hostile.mint(address(account), 1_000e6);

        address[] memory payees = new address[](1);
        payees[0] = payee1;
        AllowanceModule.CreateAllowanceParams memory params = AllowanceModule.CreateAllowanceParams({
            spender: agent,
            token: address(hostile),
            cap: CAP,
            period: PERIOD,
            expiresAt: 0,
            unrestricted: false,
            payees: payees
        });
        _grant(ALLOWANCE_ID, params);

        // Arm the token to try re-entering spend() with the exact same args
        // mid-transfer.
        hostile.arm(address(module), address(account), ALLOWANCE_ID, payee1, CAP);

        uint256 accountBalanceBefore = hostile.balanceOf(address(account));

        vm.prank(agent);
        vm.expectRevert(AllowanceModule.TransferFailed.selector);
        module.spend(address(account), ALLOWANCE_ID, payee1, CAP);

        // The whole transaction unwound: spent is still 0, no balance moved,
        // exactly as if the reentrancy attempt had never happened.
        AllowanceModule.Allowance memory a = module.allowanceOf(address(account), ALLOWANCE_ID);
        assertEq(a.spent, 0);
        assertEq(hostile.balanceOf(address(account)), accountBalanceBefore);
    }

    function test_Adversarial_PausedMidFlight_ThenUnpausedResumesCorrectly() public {
        _grantDefault();
        vm.prank(agent);
        module.spend(address(account), ALLOWANCE_ID, payee1, 10e6);

        _setPaused(ALLOWANCE_ID, true);
        vm.prank(agent);
        vm.expectRevert(AllowanceModule.Paused.selector);
        module.spend(address(account), ALLOWANCE_ID, payee1, 5e6);

        _setPaused(ALLOWANCE_ID, false);
        vm.prank(agent);
        module.spend(address(account), ALLOWANCE_ID, payee1, 5e6); // resumes exactly where it left off

        AllowanceModule.Allowance memory a = module.allowanceOf(address(account), ALLOWANCE_ID);
        assertEq(a.spent, 15e6); // the paused attempt never counted against spent
    }

    function test_Adversarial_SpenderNotOwner_OwnerCannotSelfSpend() public {
        _grantDefault(); // spender == agent, not owner
        vm.prank(owner);
        vm.expectRevert(AllowanceModule.NotTheSpender.selector);
        module.spend(address(account), ALLOWANCE_ID, payee1, 1e6);
    }

    function test_Adversarial_ExpiryExactlyAtTimestamp_JustBeforeSucceeds() public {
        AllowanceModule.CreateAllowanceParams memory params = _defaultParams(agent);
        params.expiresAt = uint48(block.timestamp + 1 hours);
        _grant(ALLOWANCE_ID, params);

        vm.warp(params.expiresAt - 1);
        vm.prank(agent);
        module.spend(address(account), ALLOWANCE_ID, payee1, 1e6); // one second before expiry: succeeds

        vm.warp(params.expiresAt);
        vm.prank(agent);
        vm.expectRevert(AllowanceModule.Expired.selector);
        module.spend(address(account), ALLOWANCE_ID, payee1, 1e6); // exactly at expiry: fails
    }

    function test_Adversarial_ExactCapThenOneMoreFails() public {
        _grantUnrestricted(ALLOWANCE_ID, agent, CAP, PERIOD);
        vm.prank(agent);
        module.spend(address(account), ALLOWANCE_ID, payee1, CAP);

        vm.prank(agent);
        vm.expectRevert(AllowanceModule.OverCap.selector);
        module.spend(address(account), ALLOWANCE_ID, payee1, 1);
    }

    function test_Adversarial_InsufficientBalance_RevertsAndLeavesSpentUnchanged() public {
        // Drain the account down to less than the allowance's cap. The balance
        // read has to happen BEFORE vm.prank — vm.prank only overrides msg.sender
        // for the very next call, and that read is itself an external call to
        // `token`. Reading balanceOf first, then pranking immediately before
        // transfer(), is what makes the drain actually run as the account.
        uint256 accountBalance = token.balanceOf(address(account));
        vm.prank(address(account));
        bool drained = token.transfer(address(this), accountBalance - 5e6);
        assertTrue(drained);

        AllowanceModule.CreateAllowanceParams memory params = _defaultParams(agent);
        params.cap = 50e6;
        _grant(ALLOWANCE_ID, params);

        vm.prank(agent);
        vm.expectRevert(AllowanceModule.TransferFailed.selector);
        module.spend(address(account), ALLOWANCE_ID, payee1, 50e6); // more than the 5e6 the account actually holds

        AllowanceModule.Allowance memory a = module.allowanceOf(address(account), ALLOWANCE_ID);
        assertEq(a.spent, 0); // the policy didn't refuse this — the token did; spent must not have moved
    }

    function test_Adversarial_TokenReturningFalseWithoutReverting_IsCaught() public {
        _grantDefault();
        token.setForceReturnFalse(true);

        vm.prank(agent);
        vm.expectRevert(AllowanceModule.TransferFailed.selector);
        module.spend(address(account), ALLOWANCE_ID, payee1, 10e6);
    }

    function test_Adversarial_ReDelegation_StaleEpochBlocksOldAllowance() public {
        _grantDefault();

        vm.startPrank(owner);
        account.uninstallModule(2, address(module), "");
        account.installModule(2, address(module), "");
        vm.stopPrank();

        vm.prank(agent);
        vm.expectRevert(AllowanceModule.StaleEpoch.selector);
        module.spend(address(account), ALLOWANCE_ID, payee1, 1e6);
    }

    function test_Adversarial_ReDelegation_NewAllowanceUnderNewEpochWorks() public {
        _grantDefault();
        vm.startPrank(owner);
        account.uninstallModule(2, address(module), "");
        account.installModule(2, address(module), "");
        vm.stopPrank();

        bytes32 newId = keccak256("post-redelegation-allowance");
        _grant(newId, _defaultParams(agent));

        vm.prank(agent);
        module.spend(address(account), newId, payee1, 1e6); // fine: created under the current epoch
    }
}
