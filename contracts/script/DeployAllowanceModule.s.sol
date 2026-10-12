// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {AllowanceModule} from "../src/AllowanceModule.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Deterministic CREATE2 deployment, per #23's acceptance criteria: "The
/// module is deployed at a deterministic CREATE2 address per chain, and the
/// address, salt, deployer and constructor arguments are recorded in the ADR."
///
/// Deploys AllowanceModule behind a UUPS (ERC-1967) proxy — see the
/// UPGRADEABILITY NOTE at the top of AllowanceModule.sol. Two addresses come
/// out of this: the implementation (raw logic, nobody should call it directly)
/// and the proxy. **The proxy's address is the one every account installs as
/// its executor module** — that's what makes a later upgrade
/// (script/UpgradeAllowanceModule.s.sol) a single ADMIN transaction rather than
/// something every account has to individually redo.
///
/// This is a skeleton, not a finished deploy pipeline — a few things are
/// deliberately left for the caller rather than guessed at:
///   1. The deployer key. #23's own notes flag that access to it was, as of the
///      real issue text, still an open/blocked item ("if it is still blocked,
///      that is escalated rather than worked around"). This script reads it from
///      the standard Foundry env var (DEPLOYER_PRIVATE_KEY) rather than assuming
///      a path — contracts/README.md says where that key is meant to live once
///      access is unblocked. For a testnet run this can be any funded throwaway
///      key (`cast wallet new`, then send it testnet MON from
///      https://faucet.monad.xyz) — it does not need to be, and should not be,
///      anything used elsewhere.
///   2. `admin` — the module's freeze/unfreeze circuit breaker AND sole upgrade
///      authority (see AllowanceModule._authorizeUpgrade). This MUST be an
///      already-deployed multisig wallet (e.g. a Safe) for anything beyond a
///      disposable local/testnet run — set it with the ADMIN_ADDRESS env var.
///      AllowanceModule needs no code of its own to support this: onlyAdmin
///      only ever checks msg.sender == admin, so a multisig contract satisfies
///      it the same way an EOA does, once ITS OWN threshold of signers
///      approves the call. If ADMIN_ADDRESS is left unset, this script falls
///      back to the deployer's own EOA and logs a loud warning — that
///      fallback exists only so a quick local/testnet deploy isn't blocked on
///      standing up a multisig, and must never be relied on for anything
///      real: that one EOA would hold both freeze and upgrade authority over
///      the whole module.
///   3. `MAX_ACCOUNT_DELEGATED_CAP` — placeholder value below; do not deploy to
///      a real chain with it unchanged.
///   4. Explorer verification and the ABI export to
///      backend/src/chain/allowance.ts are separate steps (`forge verify-contract`
///      for BOTH addresses, then a codegen/copy step) — not run by this script.
///
/// Usage (once the deployer key is available). rpc-url/chain come from
/// foundry.toml's [profile.default] now, so they don't need repeating here.
/// Verification is a separate `forge verify-contract` call per address (see
/// the two addresses this script logs), rather than this script's own
/// `--verify` flag, because that flag's handling of a run that deploys more
/// than one contract has been flaky in practice (foundry#2688 — a `--resume`
/// retried only 1 of 5 pending verifications from one broadcast). Two
/// deliberate, individually-confirmable calls cost one extra command and
/// remove that uncertainty:
///
///   forge script script/DeployAllowanceModule.s.sol:DeployAllowanceModule --broadcast
///
///   # No API key needed (docs.monad.xyz/guides/verify-smart-contract/foundry):
///   forge verify-contract <implementation address> AllowanceModule \
///     --verifier sourcify --verifier-url https://sourcify-api-monad.blockvision.org/
///   forge verify-contract <proxy address> \
///     lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy \
///     --constructor-args $(cast abi-encode "constructor(address,bytes)" <implementation address> <initData>) \
///     --verifier sourcify --verifier-url https://sourcify-api-monad.blockvision.org/
///
///   # Or on Monadscan directly, needs an API key from monadscan.com:
///   forge verify-contract <address> <contract> --verifier etherscan \
///     --etherscan-api-key <key> --watch
contract DeployAllowanceModule is Script {
    /// @dev Foundry's standard deterministic CREATE2 deployer
    /// (0x4e59b44847b379578588920cA78FbF26c0B4956), the same one
    /// `vm.computeCreate2Address` and `new X{salt: ...}(...)` assume during a
    /// broadcast. It is already deployed on essentially every EVM chain,
    /// including Monad testnet. Separate salts for the implementation and the
    /// proxy since they're two different deployed contracts at two different
    /// addresses.
    bytes32 internal constant IMPLEMENTATION_SALT = keccak256("waterlemon.AllowanceModule.impl.v1");
    bytes32 internal constant PROXY_SALT = keccak256("waterlemon.AllowanceModule.proxy.v1");

    // TODO: replace with the real per-account delegated-value ceiling the team
    // settles on. $1,000,000 in USDC base units (6dp) shown here only as an
    // obviously-a-placeholder round number.
    uint256 internal constant MAX_ACCOUNT_DELEGATED_CAP_PLACEHOLDER = 1_000_000e6;

    function run() external returns (AllowanceModule module, address implementation) {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // ADMIN_ADDRESS should be an already-deployed multisig (e.g. a Safe) —
        // see the ADMIN note in the file-level doc comment above. No hardcoded
        // placeholder here on purpose: a silently-wrong admin address is a
        // worse failure mode than a missing one, so an unset ADMIN_ADDRESS
        // falls back to the one address this script already knows is real —
        // the deployer's own EOA — rather than to a guessed default, and says
        // so loudly below rather than letting that fallback pass unnoticed.
        address admin = vm.envOr("ADMIN_ADDRESS", address(0));
        if (admin == address(0)) {
            admin = vm.addr(deployerPk);
            console2.log("=====================================================================");
            console2.log("WARNING: ADMIN_ADDRESS not set - falling back to the deployer's own EOA.");
            console2.log("This single key would hold BOTH freeze/unfreeze AND upgrade authority");
            console2.log("over the whole module. Fine for a disposable local/testnet run only -");
            console2.log("set ADMIN_ADDRESS to a deployed multisig before any deployment that");
            console2.log("matters.");
            console2.log("=====================================================================");
        }

        bytes memory initData =
            abi.encodeCall(AllowanceModule.initialize, (admin, MAX_ACCOUNT_DELEGATED_CAP_PLACEHOLDER));

        address predictedImpl =
            vm.computeCreate2Address(IMPLEMENTATION_SALT, hashInitCode(type(AllowanceModule).creationCode));
        address predictedProxy = vm.computeCreate2Address(
            PROXY_SALT, hashInitCode(type(ERC1967Proxy).creationCode, abi.encode(predictedImpl, initData))
        );
        console2.log("Predicted implementation address:", predictedImpl);
        console2.log("Predicted proxy address (install THIS as the executor):", predictedProxy);

        vm.startBroadcast(deployerPk);
        AllowanceModule impl = new AllowanceModule{salt: IMPLEMENTATION_SALT}();
        ERC1967Proxy proxy = new ERC1967Proxy{salt: PROXY_SALT}(address(impl), initData);
        vm.stopBroadcast();

        implementation = address(impl);
        module = AllowanceModule(address(proxy));

        require(implementation == predictedImpl, "implementation CREATE2 address mismatch");
        require(address(proxy) == predictedProxy, "proxy CREATE2 address mismatch");

        console2.log("Implementation deployed at:", implementation);
        console2.log("Proxy deployed at (this is THE module address):", address(module));
        console2.log("  admin:", module.admin());
        console2.log("  maxAccountDelegatedCap:", module.maxAccountDelegatedCap());
        console2.log("Next: forge verify-contract on BOTH addresses, then update");
        console2.log("backend/src/chain/allowance.ts with the PROXY address.");
    }
}
