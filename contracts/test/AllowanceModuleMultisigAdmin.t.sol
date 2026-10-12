// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AllowanceModule} from "../src/AllowanceModule.sol";
import {MockMultisig} from "./mocks/MockMultisig.sol";
import {MockAllowanceModuleV2} from "./mocks/MockAllowanceModuleV2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Proves `admin` works correctly when it's a multisig contract
/// instead of a single EOA: `onlyAdmin` only ever checks
/// `msg.sender == admin`, so pointing `admin` at a contract that only calls
/// out once a threshold of its own signers agree is enough on its own — no
/// changes to AllowanceModule itself are required. This is a deliberately
/// separate test file/deployment from AllowanceModuleTestBase (whose `admin`
/// is a plain EOA throughout the rest of the suite) so this suite's own
/// module instance can use a MockMultisig as admin without touching every
/// other test.
contract AllowanceModuleMultisigAdminTest is Test {
    AllowanceModule internal module;
    MockMultisig internal multisig;

    uint256 internal constant MAX_ACCOUNT_DELEGATED_CAP = 1_000_000e6;

    address internal signer1 = makeAddr("signer1");
    address internal signer2 = makeAddr("signer2");
    address internal signer3 = makeAddr("signer3");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        address[] memory signers = new address[](3);
        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;
        multisig = new MockMultisig(signers, 2); // 2-of-3

        AllowanceModule implementation = new AllowanceModule();
        bytes memory initData =
            abi.encodeCall(AllowanceModule.initialize, (address(multisig), MAX_ACCOUNT_DELEGATED_CAP));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        module = AllowanceModule(address(proxy));
    }

    // ============================================================
    // The core property: admin() is the multisig's own address
    // ============================================================

    function test_Admin_IsTheMultisigAddress() public view {
        assertEq(module.admin(), address(multisig));
    }

    // ============================================================
    // freezeModule / unfreezeModule gated by the multisig's threshold
    // ============================================================

    function test_FreezeModule_RequiresThresholdApprovals() public {
        bytes memory freezeCall = abi.encodeCall(AllowanceModule.freezeModule, ());

        vm.prank(signer1);
        multisig.approve(address(module), freezeCall);

        // Only one of two required approvals so far.
        vm.prank(signer1);
        vm.expectRevert(MockMultisig.BelowThreshold.selector);
        multisig.execute(address(module), freezeCall);
        assertFalse(module.isModuleFrozen());

        vm.prank(signer2);
        multisig.approve(address(module), freezeCall);

        // Threshold now met — any signer can trigger execution.
        vm.prank(signer3);
        multisig.execute(address(module), freezeCall);
        assertTrue(module.isModuleFrozen());
    }

    function test_UnfreezeModule_AlsoRequiresThreshold() public {
        _freezeViaMultisig();
        assertTrue(module.isModuleFrozen());

        bytes memory unfreezeCall = abi.encodeCall(AllowanceModule.unfreezeModule, ());
        vm.prank(signer1);
        multisig.approve(address(module), unfreezeCall);
        vm.prank(signer2);
        multisig.approve(address(module), unfreezeCall);
        vm.prank(signer1);
        multisig.execute(address(module), unfreezeCall);

        assertFalse(module.isModuleFrozen());
    }

    /// @notice The property that actually matters: no single signer — even a
    /// real, registered one — can act as admin alone. Only the multisig
    /// CONTRACT's own address passes `onlyAdmin`; an individual signer calling
    /// the module directly is just another stranger as far as the module is
    /// concerned.
    function test_IndividualSigner_CannotCallAdminFunctionsDirectly() public {
        vm.prank(signer1);
        vm.expectRevert(AllowanceModule.NotAdmin.selector);
        module.freezeModule();

        vm.prank(signer2);
        vm.expectRevert(AllowanceModule.NotAdmin.selector);
        module.freezeModule();
    }

    function test_NonSigner_CannotApproveOrExecute() public {
        bytes memory freezeCall = abi.encodeCall(AllowanceModule.freezeModule, ());

        vm.prank(stranger);
        vm.expectRevert(MockMultisig.NotSigner.selector);
        multisig.approve(address(module), freezeCall);

        // Even with enough real approvals, a non-signer can't be the one to execute.
        vm.prank(signer1);
        multisig.approve(address(module), freezeCall);
        vm.prank(signer2);
        multisig.approve(address(module), freezeCall);

        vm.prank(stranger);
        vm.expectRevert(MockMultisig.NotSigner.selector);
        multisig.execute(address(module), freezeCall);
    }

    function test_SameApprovalCannotBeExecutedTwice() public {
        _freezeViaMultisig();

        bytes memory freezeCall = abi.encodeCall(AllowanceModule.freezeModule, ());
        vm.prank(signer3);
        vm.expectRevert(MockMultisig.AlreadyExecuted.selector);
        multisig.execute(address(module), freezeCall);
    }

    // ============================================================
    // Upgrade authority (_authorizeUpgrade) gated the same way
    // ============================================================

    function test_Upgrade_RequiresThresholdApprovals() public {
        MockAllowanceModuleV2 v2 = new MockAllowanceModuleV2();
        // `upgradeToAndCall` is inherited from OZ's UUPSUpgradeable as a
        // PUBLIC (not external) function, so `AllowanceModule.upgradeToAndCall`
        // has no external function type to give abi.encodeCall — referencing it
        // through the deployed `module` instance instead does, since a public
        // function called through a contract-typed value always uses the
        // external ABI.
        bytes memory upgradeCall = abi.encodeCall(module.upgradeToAndCall, (address(v2), ""));

        vm.prank(signer1);
        multisig.approve(address(module), upgradeCall);

        vm.prank(signer1);
        vm.expectRevert(MockMultisig.BelowThreshold.selector);
        multisig.execute(address(module), upgradeCall);

        vm.prank(signer2);
        multisig.approve(address(module), upgradeCall);
        vm.prank(signer1);
        multisig.execute(address(module), upgradeCall);

        assertEq(MockAllowanceModuleV2(address(module)).version(), 2);
    }

    function test_Upgrade_IndividualSignerCannotAuthorizeAlone() public {
        MockAllowanceModuleV2 v2 = new MockAllowanceModuleV2();
        vm.prank(signer1);
        vm.expectRevert(AllowanceModule.NotAdmin.selector);
        module.upgradeToAndCall(address(v2), "");
    }

    /// @notice Confirms the upgraded module still recognizes the SAME
    /// multisig as admin afterward — storage (including `admin`) survives the
    /// upgrade untouched, exactly as AllowanceModuleUpgrade.t.sol proves for
    /// the EOA-admin case.
    function test_Upgrade_PreservesMultisigAsAdmin() public {
        MockAllowanceModuleV2 v2 = new MockAllowanceModuleV2();
        bytes memory upgradeCall = abi.encodeCall(module.upgradeToAndCall, (address(v2), ""));
        vm.prank(signer1);
        multisig.approve(address(module), upgradeCall);
        vm.prank(signer2);
        multisig.approve(address(module), upgradeCall);
        vm.prank(signer1);
        multisig.execute(address(module), upgradeCall);

        assertEq(module.admin(), address(multisig));
    }

    function _freezeViaMultisig() internal {
        bytes memory freezeCall = abi.encodeCall(AllowanceModule.freezeModule, ());
        vm.prank(signer1);
        multisig.approve(address(module), freezeCall);
        vm.prank(signer2);
        multisig.approve(address(module), freezeCall);
        vm.prank(signer3);
        multisig.execute(address(module), freezeCall);
    }
}
