// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The module-side of ERC-7579: what an account calls ON the module during
/// install/uninstall, and how the account discovers what kind of module this is.
/// AllowanceModule implements this; it does not call it.
interface IERC7579Module {
    /// @dev Called by the account itself (msg.sender == the account) when the
    /// account's owner installs this module. Per ADR #22 tension (g), this is
    /// where the account's epoch is bumped so that re-delegation (uninstall then
    /// reinstall) cannot silently resurrect allowances created under a stale epoch.
    function onInstall(bytes calldata data) external;

    /// @dev Called by the account itself when the module is removed. Also bumps
    /// the epoch, for the same reason: an allowance created before this uninstall
    /// must never be spendable again, even if the module is reinstalled later.
    function onUninstall(bytes calldata data) external;

    /// @dev ERC-7579 module type ids: 1 = validator, 2 = executor, 3 = fallback,
    /// 4 = hook. AllowanceModule is an executor (it moves funds via
    /// executeFromExecutor), never a validator — see the ADR's agent-key-scope
    /// section on why a validator role would reopen the hole allowances exist to
    /// close.
    function isModuleType(uint256 moduleTypeId) external view returns (bool);
}
