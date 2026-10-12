// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal N-of-M threshold executor used ONLY to prove
/// AllowanceModule's `onlyAdmin` gating behaves correctly when `admin` is a
/// multisig CONTRACT rather than a single EOA — this is a test fixture, not a
/// multisig implementation waterleMON should ever deploy for real. Production
/// admin should be a battle-tested, independently audited wallet (e.g. a Safe)
/// at its own already-deployed address (see the ADMIN note atop
/// AllowanceModule.sol and script/DeployAllowanceModule.s.sol).
///
/// The whole point this fixture exists to demonstrate: AllowanceModule needs
/// ZERO code changes to support a multisig admin. `onlyAdmin` only ever checks
/// `msg.sender == admin` — a contract satisfies that exactly the same way an
/// EOA does, the moment IT decides to make the call. What "decides to make the
/// call" means is entirely up to that contract; here, it means a threshold of
/// registered signers approving the exact same (target, calldata) pair first.
contract MockMultisig {
    address[] public signers;
    uint256 public threshold;

    mapping(bytes32 callHash => mapping(address signer => bool approved)) public approvals;
    mapping(bytes32 callHash => uint256 count) public approvalCount;
    mapping(bytes32 callHash => bool done) public executed;

    error NotSigner();
    error AlreadyApproved();
    error BelowThreshold();
    error AlreadyExecuted();
    error CallFailed();
    error ZeroThreshold();
    error ThresholdAboveSignerCount();

    constructor(address[] memory signers_, uint256 threshold_) {
        if (threshold_ == 0) revert ZeroThreshold();
        if (threshold_ > signers_.length) revert ThresholdAboveSignerCount();
        signers = signers_;
        threshold = threshold_;
    }

    function isSigner(address who) public view returns (bool) {
        for (uint256 i = 0; i < signers.length; i++) {
            if (signers[i] == who) return true;
        }
        return false;
    }

    modifier onlySigner() {
        if (!isSigner(msg.sender)) revert NotSigner();
        _;
    }

    function _callHash(address target, bytes memory data) private pure returns (bytes32) {
        return keccak256(abi.encode(target, data));
    }

    /// @notice Each signer independently approves a specific (target, calldata)
    /// pair. Approving twice as the same signer is rejected rather than
    /// silently double-counted.
    function approve(address target, bytes calldata data) external onlySigner returns (bytes32 callHash) {
        callHash = _callHash(target, data);
        if (approvals[callHash][msg.sender]) revert AlreadyApproved();
        approvals[callHash][msg.sender] = true;
        approvalCount[callHash] += 1;
    }

    /// @notice Executes only once `threshold` distinct signers have approved
    /// this exact (target, calldata) pair, and only once ever per pair.
    /// `target.call(data)` here means `target`'s own `msg.sender` is THIS
    /// multisig's address — the one property AllowanceModule's `onlyAdmin`
    /// actually relies on.
    function execute(address target, bytes calldata data) external onlySigner returns (bytes memory) {
        bytes32 callHash = _callHash(target, data);
        if (executed[callHash]) revert AlreadyExecuted();
        if (approvalCount[callHash] < threshold) revert BelowThreshold();
        executed[callHash] = true;
        (bool success, bytes memory ret) = target.call(data);
        if (!success) revert CallFailed();
        return ret;
    }
}
