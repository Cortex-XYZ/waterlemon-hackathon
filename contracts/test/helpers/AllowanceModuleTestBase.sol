// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AllowanceModule} from "../../src/AllowanceModule.sol";
import {MockERC7579Account} from "../mocks/MockERC7579Account.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice Shared setup for every AllowanceModule test file: deploys the module,
/// a mock account owned by a known key, a mock USDC-alike, installs the module,
/// and provides helpers for the two things every test does repeatedly — granting
/// an allowance as the owner, and building a valid spendWithSig signature as the
/// agent.
abstract contract AllowanceModuleTestBase is Test {
    AllowanceModule internal module;
    MockERC7579Account internal account;
    MockERC20 internal token;

    address internal admin = makeAddr("admin");
    uint256 internal constant MAX_ACCOUNT_DELEGATED_CAP = 1_000_000e6; // $1,000,000 in 6dp

    uint256 internal ownerPk = 0xA11CE;
    address internal owner;

    uint256 internal agentPk = 0xA9E17;
    address internal agent;

    uint256 internal strangerPk = 0x57AA;
    address internal stranger;

    address internal payee1 = makeAddr("payee1");
    address internal payee2 = makeAddr("payee2");

    bytes32 internal constant ALLOWANCE_ID = keccak256("demo-allowance-1");

    uint96 internal constant CAP = 50e6; // $50/day, matches the demo's own numbers
    uint24 internal constant PERIOD = 1 days;

    function setUp() public virtual {
        owner = vm.addr(ownerPk);
        agent = vm.addr(agentPk);
        stranger = vm.addr(strangerPk);

        // Deployed behind a UUPS proxy (matches production: see
        // script/DeployAllowanceModule.s.sol) rather than via a raw constructor
        // call, so the test suite exercises the exact same initialize()-based
        // setup path real deployments use, not a shortcut that would drift from
        // it silently. `module` holds the PROXY's address throughout — that's
        // what every test interacts with, and it's also what
        // AllowanceModuleUpgrade.t.sol upgrades in place.
        AllowanceModule implementation = new AllowanceModule();
        bytes memory initData = abi.encodeCall(AllowanceModule.initialize, (admin, MAX_ACCOUNT_DELEGATED_CAP));
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);
        module = AllowanceModule(address(proxy));

        account = new MockERC7579Account(owner);
        token = new MockERC20(address(this));

        // Install the module as an executor. Bumps the account's epoch 0 -> 1.
        vm.prank(owner);
        account.installModule(2, address(module), "");

        token.mint(address(account), 1_000e6);
    }

    // ============================================================
    // Grant / pause / revoke, always as the owner via account.execute()
    // ============================================================

    function _defaultParams(address spender) internal view returns (AllowanceModule.CreateAllowanceParams memory) {
        address[] memory payees = new address[](1);
        payees[0] = payee1;
        return AllowanceModule.CreateAllowanceParams({
            spender: spender,
            token: address(token),
            cap: CAP,
            period: PERIOD,
            expiresAt: 0,
            unrestricted: false,
            payees: payees
        });
    }

    function _grant(bytes32 id, AllowanceModule.CreateAllowanceParams memory params) internal {
        bytes memory callData = abi.encodeCall(AllowanceModule.createAllowance, (id, params));
        bytes memory executionCalldata = abi.encodePacked(address(module), uint256(0), callData);
        vm.prank(owner);
        account.execute(bytes32(0), executionCalldata);
    }

    function _grantDefault() internal {
        _grant(ALLOWANCE_ID, _defaultParams(agent));
    }

    // ============================================================
    // createDefaultAllowance — the simplified v1 grant path
    // ============================================================

    function _grantDefaultAllowance(bytes32 id, address spender, address tokenAddr, uint96 cap, uint24 period)
        internal
    {
        bytes memory callData =
            abi.encodeCall(AllowanceModule.createDefaultAllowance, (id, spender, tokenAddr, cap, period));
        bytes memory executionCalldata = abi.encodePacked(address(module), uint256(0), callData);
        vm.prank(owner);
        account.execute(bytes32(0), executionCalldata);
    }

    /// @dev Convenience overload matching the module's own default grant
    /// shape most tests want: agent as spender, the shared mock token, CAP,
    /// PERIOD.
    function _grantDefaultAllowanceForAgent(bytes32 id) internal {
        _grantDefaultAllowance(id, agent, address(token), CAP, PERIOD);
    }

    function _setPaused(bytes32 id, bool paused) internal {
        bytes memory callData = abi.encodeCall(AllowanceModule.setPaused, (id, paused));
        bytes memory executionCalldata = abi.encodePacked(address(module), uint256(0), callData);
        vm.prank(owner);
        account.execute(bytes32(0), executionCalldata);
    }

    function _revoke(bytes32 id) internal {
        bytes memory callData = abi.encodeCall(AllowanceModule.revoke, (id));
        bytes memory executionCalldata = abi.encodePacked(address(module), uint256(0), callData);
        vm.prank(owner);
        account.execute(bytes32(0), executionCalldata);
    }

    // ============================================================
    // spendWithSig helper — replicates the module's own EIP-712 encoding
    // ============================================================

    /// @dev Split out from `_spendWithSig` below so a test that needs
    /// `vm.expectRevert` immediately before the actual `spendWithSig` call can
    /// build the signature first. `nonceOf()` and `domainSeparator()` are both
    /// external calls to `module` — if they happened *after* `vm.expectRevert`
    /// was armed, they (not the intended `spendWithSig` call) would be treated as
    /// "the next call" and the cheatcode would see them return normally instead.
    function _signSpend(bytes32 id, address payee, uint256 amount, uint256 deadline, uint256 signerPk)
        internal
        view
        returns (bytes memory signature)
    {
        uint256 nonce = module.nonceOf(address(account), id);
        bytes32 structHash = keccak256(
            abi.encode(module.SPEND_TYPEHASH(), address(account), id, payee, amount, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", module.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        signature = abi.encodePacked(r, s, v);
    }

    function _spendWithSig(bytes32 id, address payee, uint256 amount, uint256 deadline, uint256 signerPk)
        internal
    {
        bytes memory signature = _signSpend(id, payee, amount, deadline, signerPk);
        module.spendWithSig(address(account), id, payee, amount, deadline, signature);
    }
}
