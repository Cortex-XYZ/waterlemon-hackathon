// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The account-side surface AllowanceModule calls INTO. Deliberately
/// narrow: this module only ever performs a single default-mode execution as a
/// registered executor, so it only needs executeFromExecutor, never execute,
/// installModule, or anything validator-shaped.
///
/// executionCalldata for single mode is the ERC-7579 / ERC7579Utils packed
/// encoding: abi.encodePacked(target (20 bytes), value (32 bytes), callData).
/// mode is bytes32(0) (CALLTYPE_SINGLE | EXECTYPE_DEFAULT | no selector/payload).
///
/// This module intentionally targets the *generic* ERC-7579 executor shape
/// (per ADR #22's chosen architecture) rather than a Kernel-specific interface,
/// so it is portable across any compliant account — Kernel included. Kernel's own
/// installModule initData encoding (a leading hook-address byte prefix) is an
/// account-side concern the owner's install transaction has to satisfy; it does
/// not change what this module itself implements.
interface IERC7579Account {
    /// @return returnData one entry per call executed, per the ERC-7579 standard
    /// signature. MODE_SINGLE (EXECTYPE_DEFAULT) always executes exactly one call
    /// and always has the account revert the whole call if that inner call fails,
    /// so returnData is always length 1 and always holds a genuinely successful
    /// inner call's raw return bytes.
    function executeFromExecutor(bytes32 mode, bytes calldata executionCalldata)
        external
        returns (bytes[] memory returnData);
}
