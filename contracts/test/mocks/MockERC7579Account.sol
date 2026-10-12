// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC7579Module} from "../../src/interfaces/IERC7579Module.sol";

/// @notice A deliberately minimal test harness standing in for a real ERC-7579
/// account (Kernel, Safe7579, OZ's AccountERC7579, etc). It exists only to give
/// AllowanceModule's tests something to install into and call against — the real
/// account implementation is out of scope for #23 ("The delegate itself" is #6's
/// job) and choosing one was already settled empirically in #1's proof-of-concept
/// work using Privy's Kernel integration.
///
/// It reproduces the two access-control guarantees ERC-7579 mandates and that
/// #23's account-level bypass tests actually exercise:
///   - execute() / installModule() / uninstallModule() are owner-only.
///   - executeFromExecutor() is callable only by a currently-installed executor
///     module, and performs the caller-supplied single-mode call on the
///     account's behalf regardless of what target it names.
/// It does not implement ERC-4337 UserOp validation or a real EntryPoint; the
/// isValidSignature() function below is a lightweight ERC-1271-style stand-in
/// used only to exercise "an agent's signature is never treated as the owner's."
contract MockERC7579Account {
    address public immutable OWNER;
    mapping(address module => bool installed) public installedExecutors;

    error NotOwner();
    error NotInstalledExecutor();

    constructor(address owner_) {
        OWNER = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != OWNER) revert NotOwner();
        _;
    }

    receive() external payable {}

    /// @notice Owner-initiated path: the owner signs an ordinary transaction that
    /// reaches here (in production, after the account's own validator checks the
    /// owner's signature — omitted in this mock since only the *destination*
    /// access-control matters for what #23 asks the module's tests to prove).
    ///
    /// `MODE_SINGLE` (the only mode this module ever uses) encodes CALLTYPE_SINGLE
    /// | EXECTYPE_DEFAULT — and EXECTYPE_DEFAULT's whole meaning, per ERC-7579, is
    /// that a failed inner call reverts the entire execution rather than being
    /// swallowed. So unlike `executeFromExecutor` below, this bubbles the inner
    /// call's revert reason up instead of returning it — that's what lets the
    /// test suite's own owner-path helpers (`_grant`/`_setPaused`/`_revoke`, which
    /// all route through this function) use `vm.expectRevert` the ordinary way.
    function execute(bytes32 mode, bytes calldata executionCalldata)
        external
        onlyOwner
        returns (bytes memory)
    {
        (bool success, bytes memory ret) = _execSingle(mode, executionCalldata);
        if (!success) _bubbleRevert(ret);
        return abi.encode(success, ret);
    }

    /// @notice Module-initiated path: any *installed* executor module may call
    /// this to move funds out of the account, with no separate signature check —
    /// this is the entire ERC-7579 executor mechanism, and it is why
    /// AllowanceModule's own internal checks are the only thing standing between
    /// an installed executor and the account's funds.
    ///
    /// MODE_SINGLE is EXECTYPE_DEFAULT, same as `execute` above, so a failed
    /// inner call bubbles up (reverting this call) rather than being swallowed;
    /// AllowanceModule._executeSpend wraps this call in its own try/catch to
    /// turn that into its typed TransferFailed() error.
    function executeFromExecutor(bytes32 mode, bytes calldata executionCalldata)
        external
        returns (bytes[] memory returnData)
    {
        if (!installedExecutors[msg.sender]) revert NotInstalledExecutor();
        (bool success, bytes memory ret) = _execSingle(mode, executionCalldata);
        if (!success) _bubbleRevert(ret);
        returnData = new bytes[](1);
        returnData[0] = ret;
    }

    /// @dev Re-reverts with the original revert data verbatim (selector and all),
    /// so a caller's `vm.expectRevert(SomeError.selector)` sees exactly the error
    /// the inner call actually raised. Falls back to a bare `revert()` if the
    /// inner call failed without any return data (e.g. an out-of-gas or a plain
    /// `revert()` with no reason).
    function _bubbleRevert(bytes memory ret) private pure {
        if (ret.length == 0) revert();
        assembly {
            revert(add(ret, 32), mload(ret))
        }
    }

    function installModule(uint256, /*moduleTypeId*/ address module, bytes calldata initData)
        external
        onlyOwner
    {
        installedExecutors[module] = true;
        IERC7579Module(module).onInstall(initData);
    }

    function uninstallModule(uint256, /*moduleTypeId*/ address module, bytes calldata deInitData)
        external
        onlyOwner
    {
        installedExecutors[module] = false;
        IERC7579Module(module).onUninstall(deInitData);
    }

    /// @dev ERC-1271 magic value on success; 0xffffffff on failure (never
    /// reverts, matching the real standard). Only ever treats `OWNER`'s ECDSA
    /// signature as valid — used to exercise "an agent's key can never sign for
    /// the account."
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (signature.length != 65) return 0xffffffff;
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        address signer = ecrecover(hash, v, r, s);
        return (signer != address(0) && signer == OWNER) ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }

    /// @dev Single-mode-only decode, matching ERC7579Utils' packed encoding:
    /// target (20 bytes) || value (32 bytes) || callData. Itself never reverts on
    /// a failed inner call — just reports (bool success, bytes returnData) — both
    /// callers above (`execute`, `executeFromExecutor`) bubble that failure up via
    /// `_bubbleRevert`, matching MODE_SINGLE's EXECTYPE_DEFAULT semantics.
    function _execSingle(bytes32, /*mode*/ bytes calldata executionCalldata)
        private
        returns (bool success, bytes memory ret)
    {
        address target = address(bytes20(executionCalldata[0:20]));
        uint256 value = uint256(bytes32(executionCalldata[20:52]));
        (success, ret) = target.call{value: value}(executionCalldata[52:]);
    }
}
