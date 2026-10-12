// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The minimal ERC-20 surface AllowanceModule needs. Deliberately not the
/// full interface — this module only ever calls `transfer`.
interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
