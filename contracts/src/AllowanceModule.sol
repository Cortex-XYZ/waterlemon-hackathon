// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC7579Module} from "./interfaces/IERC7579Module.sol";
import {IERC7579Account} from "./interfaces/IERC7579Account.sol";
import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title AllowanceModule
/// @notice An ERC-7579 executor module that lets an account owner grant a
/// third-party address (the "spender" — an AI agent's own key in waterleMON's
/// case) a capped, time-boxed, payee-restricted allowance to move a single ERC-20
/// token out of the account, without the owner signing anything at spend time.
///
/// This is a from-scratch implementation of GitHub issue #22's ADR
/// (backend/docs/adr/0002-allowance-policy.md) and is written to satisfy #23's
/// acceptance criteria directly. It has NOT been audited — per #23's explicit
/// scope, the compensating controls implemented here (the fixed target/selector
/// allowlist enforced at the account level, the module-level freeze, and the
/// per-account delegated-value cap) stand in for an audit budget this project
/// does not have.
///
/// SCOPE NOTE (confirmed against the real #22/#23 issue text, 2026-09-09): v1
/// only ever performs `token.transfer(payee, amount)` against an allowlisted
/// payee, or any payee if the allowance is explicitly marked `unrestricted`.
/// There is no support for calling into an arbitrary target/selector (a Uniswap
/// swap, an Aave deposit, etc.) — the ADR's struct layout and check order don't
/// have room for that, and #23's whole test list is written against
/// transfer/payee semantics. If waterleMON wants agents to execute arbitrary
/// DeFi actions under an allowance, that is a different, larger module and
/// should be scoped as its own issue rather than folded into this one.
///
/// UPGRADEABILITY NOTE: the ADR calls for "upgradeable without re-authorization"
/// — meaning waterleMON can ship new module logic in a single admin transaction,
/// with no account ever calling uninstallModule/installModule again. This draft
/// gets there via a UUPS (ERC-1967) proxy: every account installs the PROXY's
/// address as its executor (see script/DeployAllowanceModule.s.sol), and ADMIN
/// alone can point that proxy at a new implementation (see _authorizeUpgrade
/// below and script/UpgradeAllowanceModule.s.sol) — every account is running the
/// new logic the instant that one transaction lands. ERC-7201 namespaced storage
/// throughout (see AllowanceModuleStorage below) is what makes that safe: it's
/// what #23 explicitly calls for, and it's why admin/cap/domainSeparator moved
/// from constructor-set immutables to namespaced-storage fields set in
/// initialize() — an immutable would be baked into whichever implementation
/// happened to deploy first and could never change across an upgrade.
/// The team was also separately weighing splitting the module's rules into
/// several smaller contracts rather than one monolithic upgradeable one — that
/// decision is still open, and nothing here forecloses it: a split would still
/// deploy each piece behind its own proxy the same way.
///
/// GRANT PATHS: `createDefaultAllowance` takes exactly four inputs — spender,
/// token, cap, period — and defaults everything else (see its own doc
/// comment). `createAllowance` is the full-featured path (custom expiry, a
/// specific payee allowlist, a repeating window that outlives one period);
/// `createDefaultAllowance` is a thin wrapper around it for the common case,
/// not a replacement.
///
/// ADMIN: `admin` is just an address — `onlyAdmin` only ever checks
/// `msg.sender == admin`. That means `admin` can be a multisig contract (e.g.
/// a Safe) instead of an EOA with no code changes here: point `admin` at an
/// already-deployed multisig at `initialize()` time (see
/// script/DeployAllowanceModule.s.sol), and freezeModule/unfreezeModule/
/// upgradeToAndCall are automatically gated by that multisig's own threshold
/// of signers, since the multisig only calls out once its threshold is met.
/// There is no admin-rotation function (no way to swap `admin` to a different
/// address after `initialize()`); add one if that becomes necessary.
contract AllowanceModule is IERC7579Module, Initializable, UUPSUpgradeable {
    // ============================================================
    // ERC-7579 module type
    // ============================================================

    uint256 internal constant MODULE_TYPE_EXECUTOR = 2;

    /// @dev Single-mode default execution: CALLTYPE_SINGLE (0x00) | EXECTYPE_DEFAULT
    /// (0x00) | zero selector | zero payload, packed to 32 zero bytes.
    bytes32 internal constant MODE_SINGLE = bytes32(0);

    // ============================================================
    // Storage layout (ADR #22 "Storage, checks and semantics")
    // ============================================================

    /// @dev Fixed field-by-field, packed to exactly three 256-bit slots. Field
    /// *order* here is load-bearing: Solidity packs consecutive struct members
    /// into a slot only if they fit and only in declaration order, so this must
    /// not be reordered without re-checking the arithmetic below.
    ///
    /// slot 0: spender(160) + period(24) + expiresAt(48) + flags(8) + epoch(16) = 256
    /// slot 1: cap(96) + spent(96) + windowStart(48) + payeeCount(8) + unrestricted(8) = 256
    /// slot 2: token(160) = 160 (96 bits unused. Left as its own slot rather
    ///   than repacked elsewhere: `token` doesn't fit into slot 0 or slot 1's
    ///   remaining space, both already full at 256 bits.)
    struct Allowance {
        address spender; // the agent key allowed to call spend()/spendWithSig()
        uint24 period; // window length in seconds (e.g. 1 day = 86400)
        uint48 expiresAt; // unix timestamp; 0 = never expires
        uint8 flags; // bit0 = paused, bit1 = revoked
        uint16 epoch; // the account epoch this allowance was created under
        uint96 cap; // max spendable per window, token base units
        uint96 spent; // spent so far in the current window
        uint48 windowStart; // anchor for the current window (never = block.timestamp on roll)
        uint8 payeeCount; // number of allowlisted payees; meaningless if unrestricted
        bool unrestricted; // true = payee check is skipped entirely ("Anywhere")
        address token; // v1 is USDC-only in practice; address(0) is reserved below
    }

    /// @dev spendWithSig's nonce is deliberately NOT in the Allowance struct — the
    /// ADR calls it a cold path (agents self-submit in the common case) that must
    /// not occupy a hot storage slot every spend() touches.
    /// @custom:storage-location erc7201:waterlemon.storage.AllowanceModule
    struct AllowanceModuleStorage {
        mapping(address account => mapping(bytes32 id => Allowance)) allowances;
        mapping(address account => uint16 epoch) epoch;
        mapping(address account => mapping(bytes32 id => mapping(address payee => bool))) payeeAllowed;
        mapping(address account => mapping(bytes32 id => address[])) payeeList;
        mapping(address account => mapping(bytes32 id => uint256 nonce)) nonces;
        mapping(address account => uint256 totalCap) totalDelegatedCap;
        bool moduleFrozen;
        // Added when this module moved behind a UUPS proxy: these three used to
        // be immutables (admin, maxAccountDelegatedCap) or a constructor-set
        // immutable (domainSeparator) set once at the IMPLEMENTATION's own
        // deploy time. Behind a proxy that's wrong — they need to live in the
        // PROXY's storage (set via initialize(), not a constructor) so they
        // persist correctly across an upgrade to a new implementation. Appended
        // at the end of the struct rather than reordered in, since nothing has
        // been deployed yet and there's no existing layout to stay compatible
        // with — this is simply where they landed.
        address admin;
        uint256 maxAccountDelegatedCap;
        bytes32 domainSeparator;
    }

    // keccak256(abi.encode(uint256(keccak256("waterlemon.storage.AllowanceModule")) - 1))
    //   & ~bytes32(uint256(0xff))
    // Computed once with Python's pycryptodome keccak256 (not solc, since this
    // constant has to exist before the contract can compile) and pinned as a
    // literal per ERC-7201 / OpenZeppelin's own convention, rather than left as
    // an inline expression.
    bytes32 private constant ALLOWANCE_MODULE_STORAGE_LOCATION =
        0x87213ebc33f6628b3b775df745403f822175c3120bd676c665026d6885e46c00;

    function _s() private pure returns (AllowanceModuleStorage storage moduleStorage) {
        assembly {
            moduleStorage.slot := ALLOWANCE_MODULE_STORAGE_LOCATION
        }
    }

    uint8 private constant PAUSED_BIT = 1 << 0;
    uint8 private constant REVOKED_BIT = 1 << 1;

    function _isPaused(uint8 flags) private pure returns (bool) {
        return flags & PAUSED_BIT != 0;
    }

    function _isRevoked(uint8 flags) private pure returns (bool) {
        return flags & REVOKED_BIT != 0;
    }

    /// @dev v1 is USDC-only. address(0) is reserved in the struct for native MON
    /// so nobody accidentally builds a MON leash the app has no screen for (ADR
    /// #22, "Storage, checks and semantics").
    address public constant NATIVE_MON_RESERVED = address(0);

    // ============================================================
    // Compensating controls (#23 "The agent key cannot leave the spend path")
    // ============================================================

    /// @notice Module-wide circuit breaker, separate from any single allowance's
    /// pause bit. Freezing halts every spend()/spendWithSig() call regardless of
    /// individual allowance state. This is one of the compensating controls #23
    /// asks for in place of an audit.
    ///
    /// Storage-backed per the UPGRADEABILITY NOTE at the top of this file.
    function admin() public view returns (address) {
        return _s().admin;
    }

    /// @notice Per-account cap on total delegated value (the sum of every live
    /// allowance's `cap` for that account), never a single value shared across
    /// all users — #23 is explicit that a shared global cap is wrong, since a
    /// signup loop creating max-cap allowances could exhaust it and revert every
    /// other user's grant. This bounds the blast radius of one account's
    /// allowances without creating that cross-user contention.
    ///
    /// Storage-backed for the same reason as admin() above. NOT admin-adjustable
    /// after initialize() — making it changeable later is a separate, deliberate
    /// feature decision this draft does not make on its own.
    function maxAccountDelegatedCap() public view returns (uint256) {
        return _s().maxAccountDelegatedCap;
    }

    /// @dev Runs once, on the bare implementation contract's own deployment —
    /// before any proxy exists. Deliberately does none of the real setup; per
    /// OpenZeppelin's standard UUPS pattern, this just stops anyone from calling
    /// initialize() directly on the implementation itself (which isn't the
    /// address any account ever actually talks to, but shouldn't be left
    /// callable regardless).
    constructor() {
        _disableInitializers();
    }

    /// @notice The real constructor-equivalent: runs exactly once, via the
    /// proxy's own constructor, immediately after the proxy is created (see
    /// script/DeployAllowanceModule.s.sol). Unlike a real constructor, this
    /// executes via delegatecall FROM the proxy, so address(this) here
    /// correctly resolves to the proxy's own address — which is why
    /// domainSeparator is computed here rather than in a constructor: computed
    /// in a real constructor, it would have been permanently bound to the
    /// implementation contract's address instead of the proxy every account
    /// actually calls.
    function initialize(address admin_, uint256 maxAccountDelegatedCap_) external initializer {
        if (admin_ == address(0)) revert ZeroAddress();
        if (maxAccountDelegatedCap_ == 0) revert InvalidParams();
        AllowanceModuleStorage storage moduleStorage = _s();
        moduleStorage.admin = admin_;
        moduleStorage.maxAccountDelegatedCap = maxAccountDelegatedCap_;

        moduleStorage.domainSeparator = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256("waterleMON AllowanceModule"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    modifier onlyAdmin() {
        _onlyAdmin();
        _;
    }

    function _onlyAdmin() private view {
        if (msg.sender != _s().admin) revert NotAdmin();
    }

    /// @dev Upgrade authority is ADMIN — the same address that already controls
    /// freezeModule/unfreezeModule below. Deliberate, team-directed
    /// simplification: one key can both halt spending and replace the module's
    /// entire logic. If that combined blast radius ever needs splitting apart,
    /// this is the one function to change — gate it on a separate
    /// upgrade-authority address instead of onlyAdmin.
    function _authorizeUpgrade(address /*newImplementation*/ ) internal override onlyAdmin {}

    function freezeModule() external onlyAdmin {
        _s().moduleFrozen = true;
        emit ModuleFrozenSet(true);
    }

    function unfreezeModule() external onlyAdmin {
        _s().moduleFrozen = false;
        emit ModuleFrozenSet(false);
    }

    function isModuleFrozen() external view returns (bool) {
        return _s().moduleFrozen;
    }

    // ============================================================
    // Custom errors — this IS the blockedReason taxonomy (ADR #22)
    // ============================================================

    error NotTheSpender();
    error StaleEpoch();
    error Revoked();
    error Paused();
    error Expired();
    error PayeeNotAllowed();
    error OverCap();
    error TransferFailed(); // the "balance-family" error: insufficient balance, or any other failed transfer

    // Owner-mutator-path errors. Not part of the spend-path blockedReason
    // taxonomy above (check()/spend() parity is only required across those),
    // but named the same way for consistency.
    error AllowanceAlreadyExists();
    error AllowanceNotFound();
    error ZeroAddress();
    error InvalidParams();
    error NoPayees();
    error TooManyPayees();
    error AccountDelegatedCapExceeded();
    error ModuleFrozen();
    error NotAdmin();
    error SignatureExpired();
    error InvalidSignatureLength();
    error InvalidSignatureS();
    error InvalidSignature();

    // ============================================================
    // Events (ADR #22: "grant, pause and revoke events the indexer keys off")
    // ============================================================

    event AllowanceGranted(
        address indexed account,
        bytes32 indexed id,
        address indexed spender,
        address token,
        uint96 cap,
        uint24 period,
        uint48 expiresAt,
        bool unrestricted
    );
    event AllowancePausedSet(address indexed account, bytes32 indexed id, bool paused);
    event AllowanceRevoked(address indexed account, bytes32 indexed id);
    event Spent(
        address indexed account, bytes32 indexed id, address indexed payee, uint256 amount, uint96 spent, uint96 cap
    );
    event ModuleFrozenSet(bool frozen);

    // ============================================================
    // ERC-7579 module lifecycle
    // ============================================================

    /// @dev msg.sender is the account installing this module. Bumping the epoch
    /// here (and in onUninstall) is the fix for ADR #22 tension (g): re-delegation
    /// silently re-arming every allowance. Any allowance created under a prior
    /// epoch becomes permanently unspendable (StaleEpoch) the moment the module is
    /// installed again after ever having been uninstalled.
    function onInstall(bytes calldata /*data*/ ) external override {
        _s().epoch[msg.sender] += 1;
    }

    function onUninstall(bytes calldata /*data*/ ) external override {
        _s().epoch[msg.sender] += 1;
    }

    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == MODULE_TYPE_EXECUTOR;
    }

    // ============================================================
    // Owner-only mutators
    //
    // These are always called by the account itself on the owner's behalf (the
    // owner signs an ordinary account transaction whose calldata targets this
    // module) — so msg.sender IS the account, and no separate "account" or
    // "owner" parameter is needed or accepted. Every allowance is scoped to
    // msg.sender's own storage by construction; there is nothing for one account
    // to authorize on another's behalf.
    // ============================================================

    struct CreateAllowanceParams {
        address spender;
        address token;
        uint96 cap;
        uint24 period;
        uint48 expiresAt; // 0 = never
        bool unrestricted;
        address[] payees; // ignored (must be empty) if unrestricted
    }

    /// @notice Grants a new allowance under caller-chosen id `id`. Reverts if
    /// `id` was ever used before — including if the prior allowance at that id
    /// was later revoked. That's deliberate: allowing reuse of a revoked id would
    /// silently resurrect it (ADR #22).
    ///
    /// NOTE ON "one allowance per spender": per the real, current #22 text, that
    /// constraint is enforced at the *backend* (a partial unique index in #24's
    /// schema plus a 409 on #25's grant route) — not here. This contract only
    /// prevents id reuse; nothing stops one account from holding two different-id
    /// allowances for the same spender address at the contract level. If the
    /// product intent is genuinely "one live allowance per (account, spender),
    /// full stop," that needs its own on-chain check (e.g. a
    /// mapping(account => mapping(spender => bool)) guard) — flagging this
    /// explicitly rather than guessing, since #23's acceptance criteria never
    /// mention such a check and the backend-side description reads as the whole
    /// enforcement mechanism.
    ///
    /// This is the full-featured grant path (custom period/expiry/payee-list
    /// combinations). The frontend's v1 UI does not call this directly — see
    /// `createDefaultAllowance` below — but it is kept for any grant shape the
    /// simplified path can't express, and nothing here is deprecated by that
    /// addition.
    function createAllowance(bytes32 id, CreateAllowanceParams calldata params) external {
        _createAllowance(id, params);
    }

    /// @notice Simplified v1 grant path: the frontend collects exactly four
    /// inputs — spender (the agent), token, cap,
    /// and period — and everything else is defaulted here. This is deliberately
    /// NOT the same shape as `createAllowance`'s `period`, which is a repeating
    /// window that rolls forward forever. Here, `period` is the allowance's
    /// entire lifetime: "5 USDC for 30 minutes" means up to 5 USDC spendable
    /// across the next 30 minutes, and from the instant those 30 minutes are up
    /// the allowance is Expired — permanently, not rolled into a fresh window.
    /// That's implemented by setting `expiresAt = now + period` and leaving
    /// `period` itself set to the same value: `_reasonFor` checks `Expired`
    /// before it ever evaluates a window roll, so the window-roll branch is
    /// unreachable after that single period elapses.
    ///
    /// Defaults applied on top of the four inputs:
    ///  - `expiresAt = block.timestamp + period` (see above)
    ///  - `unrestricted = true` — the simplified UI takes no payee list, and
    ///    "Anywhere" is the only default that doesn't leave the allowance
    ///    unspendable out of the box (an empty, restricted payee list would
    ///    revert `NoPayees` on every grant). An agent that needs a payee
    ///    allowlist still has `createAllowance` available for that.
    function createDefaultAllowance(bytes32 id, address spender, address token, uint96 cap, uint24 period)
        external
    {
        address[] memory noPayees = new address[](0);
        CreateAllowanceParams memory params = CreateAllowanceParams({
            spender: spender,
            token: token,
            cap: cap,
            period: period,
            // period == 0 is rejected inside _createAllowance before this value is
            // ever read for anything but storage, so this can't silently wrap.
            expiresAt: uint48(block.timestamp) + period,
            unrestricted: true,
            payees: noPayees
        });
        _createAllowance(id, params);
    }

    /// @dev Shared effects for both grant paths above — kept as one function so
    /// the validation, delegated-cap accounting, and AllowanceGranted event stay
    /// in exactly one place no matter which entry point was used.
    function _createAllowance(bytes32 id, CreateAllowanceParams memory params) private {
        address account = msg.sender;
        AllowanceModuleStorage storage moduleStorage = _s();
        Allowance storage allowance = moduleStorage.allowances[account][id];
        if (allowance.spender != address(0)) revert AllowanceAlreadyExists();
        if (params.spender == address(0) || params.token == address(0)) revert ZeroAddress();
        if (params.cap == 0 || params.period == 0) revert InvalidParams();
        if (!params.unrestricted && params.payees.length == 0) revert NoPayees();
        if (params.payees.length > type(uint8).max) revert TooManyPayees();

        uint256 newTotal = moduleStorage.totalDelegatedCap[account] + params.cap;
        if (newTotal > moduleStorage.maxAccountDelegatedCap) revert AccountDelegatedCapExceeded();
        moduleStorage.totalDelegatedCap[account] = newTotal;

        allowance.spender = params.spender;
        allowance.period = params.period;
        allowance.expiresAt = params.expiresAt;
        allowance.flags = 0;
        allowance.epoch = moduleStorage.epoch[account];
        allowance.cap = params.cap;
        allowance.spent = 0;
        allowance.windowStart = uint48(block.timestamp);
        allowance.token = params.token;
        allowance.unrestricted = params.unrestricted;

        if (params.unrestricted) {
            allowance.payeeCount = 0;
        } else {
            allowance.payeeCount = uint8(params.payees.length);
            for (uint256 i = 0; i < params.payees.length; i++) {
                address payee = params.payees[i];
                if (payee == address(0)) revert ZeroAddress();
                moduleStorage.payeeAllowed[account][id][payee] = true;
                moduleStorage.payeeList[account][id].push(payee);
            }
        }

        emit AllowanceGranted(
            account, id, params.spender, params.token, params.cap, params.period, params.expiresAt, params.unrestricted
        );
    }

    /// @notice Reversible, cheap (~5k gas), preserves `spent` and `windowStart`.
    /// Distinct from revoke(), which is one-way and terminal.
    function setPaused(bytes32 id, bool paused) external {
        address account = msg.sender;
        Allowance storage allowance = _s().allowances[account][id];
        if (allowance.spender == address(0)) revert AllowanceNotFound();
        if (_isRevoked(allowance.flags)) revert Revoked();
        if (paused) {
            allowance.flags = allowance.flags | PAUSED_BIT;
        } else {
            allowance.flags = allowance.flags & ~PAUSED_BIT;
        }
        emit AllowancePausedSet(account, id, paused);
    }

    /// @notice One-way and terminal. Callable by the account owner from any
    /// wallet — its calldata is stable and derivable from the ABI and the
    /// allowance id alone, so revoking never depends on waterleMON's backend or
    /// sponsor being up (ADR #22 tension (a)).
    function revoke(bytes32 id) external {
        address account = msg.sender;
        AllowanceModuleStorage storage moduleStorage = _s();
        Allowance storage allowance = moduleStorage.allowances[account][id];
        if (allowance.spender == address(0)) revert AllowanceNotFound();
        if (_isRevoked(allowance.flags)) revert Revoked();
        allowance.flags = allowance.flags | REVOKED_BIT;

        uint256 current = moduleStorage.totalDelegatedCap[account];
        moduleStorage.totalDelegatedCap[account] = current > allowance.cap ? current - allowance.cap : 0;

        emit AllowanceRevoked(account, id);
    }

    // ============================================================
    // The free pre-check
    // ============================================================

    /// @notice Free, public, unauthenticated. Returns the exact same reason the
    /// corresponding spend() call would revert with — same selector, computed by
    /// the same internal function — so a well-built bot never has to broadcast a
    /// doomed spend, and any reason waterleMON's watcher records for a *mined*
    /// refusal is the contract's own reason, not a re-implementation of it.
    ///
    /// Uses msg.sender as the prospective spender: a bot calls this as itself
    /// (an eth_call from its own address) to ask "would I succeed right now?" —
    /// exactly mirroring how spend() checks msg.sender.
    function check(address account, bytes32 id, address payee, uint256 amount)
        external
        view
        returns (bool ok, bytes4 reason)
    {
        AllowanceModuleStorage storage moduleStorage = _s();
        Allowance memory allowance = moduleStorage.allowances[account][id];
        uint16 currentEpoch = moduleStorage.epoch[account];
        (reason,,) = _reasonFor(account, id, allowance, currentEpoch, payee, amount, msg.sender);
        return (reason == bytes4(0), reason);
    }

    // ============================================================
    // Spend paths
    // ============================================================

    /// @notice Self-submitted: the agent calls this directly with its own key,
    /// pays its own gas. msg.sender must equal the allowance's spender.
    function spend(address account, bytes32 id, address payee, uint256 amount) external {
        _executeSpend(account, id, payee, amount, msg.sender);
    }

    bytes32 public constant SPEND_TYPEHASH =
        keccak256("Spend(address account,bytes32 id,address payee,uint256 amount,uint256 nonce,uint256 deadline)");

    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @notice EIP-712 meta-transaction path: the agent signs off-chain, anyone
    /// (a relayer the *developer* runs — never waterleMON) submits and pays gas.
    /// Per ADR #22 tension (d): "a comment records that waterlemon never calls it
    /// and no waterlemon endpoint accepts an agent-signed payload." Consider this
    /// that comment.
    function spendWithSig(
        address account,
        bytes32 id,
        address payee,
        uint256 amount,
        uint256 deadline,
        bytes calldata signature
    ) external {
        // A validator can nudge block.timestamp by a handful of seconds at most —
        // negligible against a deadline meant to be set with real slack (minutes+),
        // and there's no better wall-clock primitive available in the EVM.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert SignatureExpired();
        AllowanceModuleStorage storage moduleStorage = _s();
        uint256 nonce = moduleStorage.nonces[account][id]++;
        bytes32 structHash = keccak256(abi.encode(SPEND_TYPEHASH, account, id, payee, amount, nonce, deadline));
        address signer = _recoverSigner(_hashTypedData(structHash), signature);
        _executeSpend(account, id, payee, amount, signer);
    }

    function nonceOf(address account, bytes32 id) external view returns (uint256) {
        return _s().nonces[account][id];
    }

    function domainSeparator() external view returns (bytes32) {
        return _s().domainSeparator;
    }

    // ============================================================
    // Shared spend logic
    // ============================================================

    /// @dev The check order below IS the blockedReason taxonomy (ADR #22):
    /// spender identity -> epoch current -> not revoked -> not paused -> not
    /// expired -> payee allowed (or unrestricted) -> window rolled and cap not
    /// exceeded. A pure function of a memory snapshot
    /// plus block.timestamp, so check() (view) and _executeSpend() (state-
    /// changing) are structurally guaranteed to agree — they call this same
    /// function and revert with (or return) the exact same selector.
    function _reasonFor(
        address account,
        bytes32 id,
        Allowance memory allowance,
        uint16 currentEpoch,
        address payee,
        uint256 amount,
        address caller
    ) private view returns (bytes4 reason, uint48 newWindowStart, uint96 newSpent) {
        if (caller != allowance.spender) return (NotTheSpender.selector, allowance.windowStart, allowance.spent);
        if (allowance.epoch != currentEpoch) return (StaleEpoch.selector, allowance.windowStart, allowance.spent);
        if (_isRevoked(allowance.flags)) return (Revoked.selector, allowance.windowStart, allowance.spent);
        if (_isPaused(allowance.flags)) return (Paused.selector, allowance.windowStart, allowance.spent);
        // Boundary convention: an allowance is valid strictly before expiresAt,
        // and Expired from expiresAt onward (>=, not >). Documented here because
        // #23 explicitly names "expiry exactly at block.timestamp" as a case to
        // test — this is the intended answer for that boundary.
        //
        // A validator's few-second timestamp latitude is immaterial against an
        // expiresAt set in minutes/hours/days by design — same reasoning as
        // spendWithSig's deadline check above.
        // forge-lint: disable-next-line(block-timestamp)
        if (allowance.expiresAt != 0 && block.timestamp >= allowance.expiresAt) {
            return (Expired.selector, allowance.windowStart, allowance.spent);
        }
        if (!allowance.unrestricted && !_s().payeeAllowed[account][id][payee]) {
            return (PayeeNotAllowed.selector, allowance.windowStart, allowance.spent);
        }

        // Anchored (non-rolling) window: windowStart += period * floor(elapsed /
        // period). Never windowStart = block.timestamp — that would make
        // "resets in Xh" drift with usage. Rolling forward by whole periods and
        // zeroing spent only happens here, in memory; it is only persisted if the
        // whole call succeeds.
        uint48 windowStart = allowance.windowStart;
        uint96 spentInWindow = allowance.spent;
        uint256 elapsed = block.timestamp - uint256(windowStart);
        if (elapsed >= uint256(allowance.period)) {
            uint256 periods = elapsed / uint256(allowance.period);
            // Safe: period * periods <= elapsed (periods is floor(elapsed/period)),
            // so windowStart + period*periods <= windowStart + elapsed == block.timestamp,
            // which fits uint48 until the year 8,921,556.
            // forge-lint: disable-next-line(unsafe-typecast)
            windowStart = uint48(uint256(windowStart) + uint256(allowance.period) * periods);
            spentInWindow = 0;
        }

        if (uint256(spentInWindow) + amount > uint256(allowance.cap)) {
            return (OverCap.selector, windowStart, spentInWindow);
        }

        // Safe: the branch above already proved spentInWindow + amount <= allowance.cap,
        // and allowance.cap is itself a uint96, so this sum fits in uint96 too.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (bytes4(0), windowStart, uint96(uint256(spentInWindow) + amount));
    }

    function _executeSpend(address account, bytes32 id, address payee, uint256 amount, address caller) private {
        AllowanceModuleStorage storage moduleStorage = _s();
        if (moduleStorage.moduleFrozen) revert ModuleFrozen();

        // Read-only snapshot used to evaluate the check order and to read
        // token/cap after the storage write below — distinct from
        // `allowanceSlot`, the actual storage pointer the roll/spend result
        // gets persisted through.
        Allowance memory allowance = moduleStorage.allowances[account][id];
        uint16 currentEpoch = moduleStorage.epoch[account];
        (bytes4 reason, uint48 newWindowStart, uint96 newSpent) =
            _reasonFor(account, id, allowance, currentEpoch, payee, amount, caller);
        if (reason != bytes4(0)) _revertWithReason(reason);

        // Effects before interaction: spent is written BEFORE the external call.
        // USDC has no transfer hooks today, but this module must not assume its
        // token forever (a hostile token is one of #23's named adversarial
        // cases) — if the external call below fails and this whole transaction
        // reverts, this write reverts with it, so a failed transfer can never
        // permanently burn cap either way.
        Allowance storage allowanceSlot = moduleStorage.allowances[account][id];
        allowanceSlot.windowStart = newWindowStart;
        allowanceSlot.spent = newSpent;

        // MODE_SINGLE is EXECTYPE_DEFAULT, so a failed inner call makes
        // executeFromExecutor itself revert (with the arbitrary token's own,
        // undecoded revert reason) rather than returning a failure flag — the
        // try/catch here is what turns that into this module's own typed
        // TransferFailed() error instead of bubbling a raw reason up to the agent.
        bytes memory executionCalldata = _encodeTransferExecution(allowance.token, payee, amount);
        try IERC7579Account(account).executeFromExecutor(MODE_SINGLE, executionCalldata) returns (
            bytes[] memory returnData
        ) {
            if (returnData.length == 0 || !_isSuccessfulTransfer(returnData[0])) revert TransferFailed();
        } catch {
            revert TransferFailed();
        }

        emit Spent(account, id, payee, amount, newSpent, allowance.cap);
    }

    function _revertWithReason(bytes4 reason) private pure {
        assembly {
            mstore(0x00, reason)
            revert(0x00, 4)
        }
    }

    function _encodeTransferExecution(address token, address payee, uint256 amount)
        private
        pure
        returns (bytes memory)
    {
        bytes memory callData = abi.encodeWithSelector(IERC20Minimal.transfer.selector, payee, amount);
        return abi.encodePacked(token, uint256(0), callData);
    }

    /// @dev The account already guarantees the call itself succeeded (MODE_SINGLE
    /// reverts the whole executeFromExecutor call on failure) — this only checks
    /// the ERC-20 return value, since some tokens signal failure by returning
    /// `false` rather than reverting. A zero-length return is treated as success,
    /// matching the common non-standard-ERC20 accommodation (USDC's real
    /// implementation returns a proper bool; this module must not assume every
    /// token does).
    function _isSuccessfulTransfer(bytes memory ret) private pure returns (bool) {
        if (ret.length == 0) return true;
        if (ret.length >= 32) return abi.decode(ret, (bool));
        return false;
    }

    // ============================================================
    // EIP-712 / signature recovery (self-contained — no external dependency)
    // ============================================================

    function _hashTypedData(bytes32 structHash) private view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", _s().domainSeparator, structHash));
    }

    /// @dev secp256k1 half-curve-order malleability guard, matching the standard
    /// convention (e.g. OpenZeppelin's ECDSA.sol): reject signatures with a high
    /// `s` value so a single valid signature cannot be trivially re-encoded into
    /// a second, different-looking "valid" signature over the same message.
    uint256 private constant SECP256K1_HALF_N =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    function _recoverSigner(bytes32 digest, bytes memory signature) private pure returns (address) {
        if (signature.length != 65) revert InvalidSignatureLength();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }
        if (uint256(s) > SECP256K1_HALF_N) revert InvalidSignatureS();
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert InvalidSignature();
        return signer;
    }

    // ============================================================
    // Read views the app needs — so the backend never reimplements the
    // window-roll / status derivation itself (ADR #22)
    // ============================================================

    enum Status {
        Active,
        Paused,
        Revoked,
        Expired
    }

    function allowanceOf(address account, bytes32 id) external view returns (Allowance memory) {
        return _s().allowances[account][id];
    }

    function payeesOf(address account, bytes32 id) external view returns (address[] memory) {
        return _s().payeeList[account][id];
    }

    function statusOf(address account, bytes32 id) external view returns (Status) {
        Allowance memory allowance = _s().allowances[account][id];
        if (_isRevoked(allowance.flags)) return Status.Revoked;
        // Same reasoning as the identical check in _reasonFor: negligible against
        // an expiresAt set in minutes/hours/days.
        // forge-lint: disable-next-line(block-timestamp)
        if (allowance.expiresAt != 0 && block.timestamp >= allowance.expiresAt) return Status.Expired;
        if (_isPaused(allowance.flags)) return Status.Paused;
        return Status.Active;
    }

    /// @notice Remaining spendable amount in the *current* window, derived on
    /// read rather than stored — spent is presented as if already rolled to 0
    /// once elapsed >= period, without any keeper ever having to touch storage.
    function remaining(address account, bytes32 id) external view returns (uint256) {
        Allowance memory allowance = _s().allowances[account][id];
        uint256 elapsed = block.timestamp - uint256(allowance.windowStart);
        uint256 spentInWindow = elapsed >= uint256(allowance.period) ? 0 : uint256(allowance.spent);
        uint256 cap = uint256(allowance.cap);
        return spentInWindow >= cap ? 0 : cap - spentInWindow;
    }

    /// @dev resetsAt = windowStart + period * (floor(elapsed / period) + 1). The
    /// single source of this derivation — the backend must not reimplement it.
    function resetsAt(address account, bytes32 id) external view returns (uint256) {
        Allowance memory allowance = _s().allowances[account][id];
        if (allowance.spender == address(0)) revert AllowanceNotFound(); // guards period == 0 division below
        uint256 elapsed = block.timestamp - uint256(allowance.windowStart);
        uint256 periods = elapsed / uint256(allowance.period);
        return uint256(allowance.windowStart) + uint256(allowance.period) * (periods + 1);
    }

    function totalDelegatedCapOf(address account) external view returns (uint256) {
        return _s().totalDelegatedCap[account];
    }

    function epochOf(address account) external view returns (uint16) {
        return _s().epoch[account];
    }
}
