// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice A minimal, well-behaved 6-decimal token standing in for USDC, plus one
/// deliberate misbehavior toggle (`forceReturnFalse`) used to test that
/// AllowanceModule checks the ERC-20 return value and not just call success —
/// real USDC reverts on failure rather than returning false, but the module must
/// not assume every token behaves that way (see AllowanceModule's
/// _isSuccessfulTransfer comment).
contract MockERC20 {
    // name/symbol/decimals are deliberately left lowercase, against the
    // constant-naming lint below: `public constant` auto-generates a getter
    // with the same name as the variable, and the ERC-20 standard mandates the
    // callable functions be exactly `name()`/`symbol()`/`decimals()`. Renaming
    // these would silently break ERC-20 interface compatibility for a token
    // that exists specifically to model a real one.
    string public constant name = "Mock USDC";
    string public constant symbol = "mUSDC";
    uint8 public constant decimals = 6;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public immutable MINTER;
    bool public forceReturnFalse;

    error NotMinter();
    error InsufficientBalance();

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(address minter_) {
        MINTER = minter_;
    }

    modifier onlyMinter() {
        if (msg.sender != MINTER) revert NotMinter();
        _;
    }

    function mint(address to, uint256 amount) external onlyMinter {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @notice Test-only toggle. When true, transfer() returns false instead of
    /// moving any balance, without reverting — simulating a non-reverting-on-
    /// failure ERC-20.
    function setForceReturnFalse(bool value) external onlyMinter {
        forceReturnFalse = value;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (forceReturnFalse) return false;
        if (balanceOf[msg.sender] < amount) revert InsufficientBalance();
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
