// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {AllowanceModule} from "../src/AllowanceModule.sol";

/// @notice The one-transaction upgrade flow the ADR's "upgradeable without
/// re-authorization" requirement is actually asking for: deploy a new
/// implementation, then have ADMIN point the existing proxy at it.
///
/// No account calls uninstallModule/installModule, nothing about any account's
/// allowance data changes, and nothing needs re-signing by any owner or agent —
/// every account that installed the PROXY address (see
/// DeployAllowanceModule.s.sol) is running the new implementation's logic the
/// instant this transaction is mined. That's the whole point of deploying
/// behind a proxy instead of a bare contract.
///
/// Only ADMIN's key can broadcast this successfully — AllowanceModule's
/// _authorizeUpgrade rejects anyone else, so this script existing does not by
/// itself grant anyone upgrade power beyond what ADMIN already has.
///
/// Usage:
///   PROXY_ADDRESS=<the proxy address from the original deploy> \
///   ADMIN_PRIVATE_KEY=<ADMIN's key> \
///   forge script script/UpgradeAllowanceModule.s.sol:UpgradeAllowanceModule \
///     --rpc-url <chain> --broadcast --verify
contract UpgradeAllowanceModule is Script {
    function run() external returns (address newImplementation) {
        address proxyAddress = vm.envAddress("PROXY_ADDRESS");
        uint256 adminPk = vm.envUint("ADMIN_PRIVATE_KEY");

        vm.startBroadcast(adminPk);
        AllowanceModule impl = new AllowanceModule();
        AllowanceModule(proxyAddress).upgradeToAndCall(address(impl), "");
        vm.stopBroadcast();

        newImplementation = address(impl);
        console2.log("New implementation deployed at:", newImplementation);
        console2.log("Proxy now running the new implementation:", proxyAddress);
        console2.log("Next: forge verify-contract on the new implementation address.");
    }
}
