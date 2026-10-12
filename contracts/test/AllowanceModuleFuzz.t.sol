// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AllowanceModule} from "../src/AllowanceModule.sol";
import {AllowanceModuleTestBase} from "./helpers/AllowanceModuleTestBase.sol";
import {MockERC7579Account} from "./mocks/MockERC7579Account.sol";

/// @notice Fuzz tests for the cap/window arithmetic: spent never exceeds cap
/// within a window, and the anchored window always rolls forward by whole
/// multiples of `period` — never to block.timestamp.
contract AllowanceModuleFuzzTest is AllowanceModuleTestBase {
    function _grantUnrestricted(bytes32 id, uint96 cap, uint24 period) internal {
        address[] memory empty = new address[](0);
        AllowanceModule.CreateAllowanceParams memory params = AllowanceModule.CreateAllowanceParams({
            spender: agent,
            token: address(token),
            cap: cap,
            period: period,
            expiresAt: 0,
            unrestricted: true,
            payees: empty
        });
        _grant(id, params);
    }

    function testFuzz_RemainingNeverExceedsCap(uint96 cap, uint24 period, uint256 warpSeconds) public {
        cap = uint96(bound(cap, 1, 1_000_000e6));
        period = uint24(bound(period, 1, 365 days));
        warpSeconds = bound(warpSeconds, 0, uint256(period) * 50);

        _grantUnrestricted(ALLOWANCE_ID, cap, period);
        token.mint(address(account), uint256(cap) * 50);

        vm.warp(block.timestamp + warpSeconds);
        assertLe(module.remaining(address(account), ALLOWANCE_ID), cap);
    }

    function testFuzz_SpendingExactlyRemainingAlwaysSucceeds(
        uint96 cap,
        uint24 period,
        uint256 warpSeconds
    ) public {
        cap = uint96(bound(cap, 1, 1_000_000e6));
        period = uint24(bound(period, 1, 365 days));
        warpSeconds = bound(warpSeconds, 0, uint256(period) * 50);

        _grantUnrestricted(ALLOWANCE_ID, cap, period);
        token.mint(address(account), uint256(cap) * 50);

        vm.warp(block.timestamp + warpSeconds);
        uint256 rem = module.remaining(address(account), ALLOWANCE_ID);
        vm.assume(rem > 0);

        vm.prank(agent);
        module.spend(address(account), ALLOWANCE_ID, payee1, rem);

        assertEq(module.remaining(address(account), ALLOWANCE_ID), 0);
    }

    function testFuzz_SpendingOneOverRemainingAlwaysReverts(uint96 cap, uint24 period, uint96 firstSpend)
        public
    {
        cap = uint96(bound(cap, 2, 1_000_000e6));
        period = uint24(bound(period, 1, 365 days));
        // Leave at least 1 unit remaining after the first spend, so rem + 1 is a
        // meaningful, in-window over-cap attempt rather than a no-op.
        firstSpend = uint96(bound(firstSpend, 1, cap - 1));

        _grantUnrestricted(ALLOWANCE_ID, cap, period);
        token.mint(address(account), uint256(cap) * 2);

        vm.prank(agent);
        module.spend(address(account), ALLOWANCE_ID, payee1, firstSpend);

        uint256 rem = module.remaining(address(account), ALLOWANCE_ID);
        assertEq(rem, uint256(cap) - firstSpend);

        vm.prank(agent);
        vm.expectRevert(AllowanceModule.OverCap.selector);
        module.spend(address(account), ALLOWANCE_ID, payee1, rem + 1);
    }

    /// @notice The anchored window must always land on a boundary reachable from
    /// the original windowStart by whole multiples of `period` — never on
    /// block.timestamp itself (that was explicitly rejected in the ADR because it
    /// would make "resets in Xh" drift with usage).
    function testFuzz_WindowAlwaysRollsByWholePeriods(uint24 period, uint256 warpSeconds) public {
        period = uint24(bound(period, 1, 365 days));
        warpSeconds = bound(warpSeconds, 0, uint256(period) * 1000);

        _grantUnrestricted(ALLOWANCE_ID, CAP, period);
        AllowanceModule.Allowance memory a0 = module.allowanceOf(address(account), ALLOWANCE_ID);
        uint256 initialWindowStart = a0.windowStart;

        vm.warp(block.timestamp + warpSeconds);
        token.mint(address(account), 1e6);
        vm.prank(agent);
        // A tiny spend still forces the window-roll write path.
        module.spend(address(account), ALLOWANCE_ID, payee1, 1);

        AllowanceModule.Allowance memory a1 = module.allowanceOf(address(account), ALLOWANCE_ID);
        assertEq((uint256(a1.windowStart) - initialWindowStart) % period, 0);
    }
}

/// @notice Invariant testing: a handler performs arbitrary sequences of valid
/// spend attempts and time warps, and the invariant is checked after every
/// sequence — spent must never exceed cap, no matter what order or timing of
/// spends the fuzzer tries.
contract AllowanceModuleInvariantTest is AllowanceModuleTestBase {
    AllowanceModuleHandler internal handler;

    function setUp() public override {
        super.setUp();
        address[] memory empty = new address[](0);
        AllowanceModule.CreateAllowanceParams memory params = AllowanceModule.CreateAllowanceParams({
            spender: agent,
            token: address(token),
            cap: CAP,
            period: PERIOD,
            expiresAt: 0,
            unrestricted: true,
            payees: empty
        });
        _grant(ALLOWANCE_ID, params);
        token.mint(address(account), 10_000_000e6);

        handler = new AllowanceModuleHandler(module, account, agent, payee1, ALLOWANCE_ID, CAP, PERIOD);
        targetContract(address(handler));
    }

    function invariant_SpentNeverExceedsCap() public view {
        AllowanceModule.Allowance memory a = module.allowanceOf(address(account), ALLOWANCE_ID);
        assertLe(a.spent, a.cap);
    }

    function invariant_WindowStartStaysOnAnchorBoundary() public view {
        AllowanceModule.Allowance memory a = module.allowanceOf(address(account), ALLOWANCE_ID);
        assertEq((uint256(a.windowStart) - handler.initialWindowStart()) % a.period, 0);
    }

    function invariant_ModuleNeverHoldsTokenBalance() public view {
        // Value moves from the account, never through the module (ADR #22 /
        // #23): the module's own token balance must always be zero.
        assertEq(token.balanceOf(address(module)), 0);
    }
}

contract AllowanceModuleHandler is Test {
    AllowanceModule internal module;
    MockERC7579Account internal account;
    address internal agent;
    address internal payee;
    bytes32 internal id;
    uint96 internal cap;
    uint24 internal period;
    uint256 public initialWindowStart;

    constructor(
        AllowanceModule module_,
        MockERC7579Account account_,
        address agent_,
        address payee_,
        bytes32 id_,
        uint96 cap_,
        uint24 period_
    ) {
        module = module_;
        account = account_;
        agent = agent_;
        payee = payee_;
        id = id_;
        cap = cap_;
        period = period_;
        initialWindowStart = module.allowanceOf(address(account), id).windowStart;
    }

    function spend(uint96 amount, uint256 warpSeconds) public {
        warpSeconds = bound(warpSeconds, 0, uint256(period) * 10);
        vm.warp(block.timestamp + warpSeconds);
        amount = uint96(bound(amount, 1, cap));

        vm.prank(agent);
        // Some fuzzed sequences legitimately hit OverCap (spending more than
        // what's left in the current window) — that's a correct, expected
        // revert, not a bug, so it's swallowed here rather than failing the run.
        // The invariant above is what actually proves cap is never exceeded.
        try module.spend(address(account), id, payee, amount) {} catch {}
    }

    function warp(uint256 warpSeconds) public {
        warpSeconds = bound(warpSeconds, 0, uint256(period) * 10);
        vm.warp(block.timestamp + warpSeconds);
    }
}
