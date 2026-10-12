// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IAllowanceModuleForReentrancy {
    function spend(address account, bytes32 id, address payee, uint256 amount) external;
}

/// @notice A hostile ERC-20 whose transfer() tries to re-enter
/// AllowanceModule.spend() mid-flight, for the "reentrancy via a hostile token"
/// adversarial case #23 names explicitly. USDC has no such hook today, but the
/// module must not assume its token forever — this proves the checks-effects-
/// interactions ordering (spent written before the external call) holds even
/// against a token designed specifically to exploit it.
contract ReentrantToken {
    // name/symbol/decimals stay lowercase deliberately — see MockERC20's
    // comment on the same choice: renaming would change the auto-generated
    // getter names away from the ERC-20 standard's required `name()`/
    // `symbol()`/`decimals()`.
    string public constant name = "Hostile Token";
    string public constant symbol = "EVIL";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    address public immutable MINTER;

    bool public armed;
    address public attackModule;
    address public attackAccount;
    bytes32 public attackId;
    address public attackPayee;
    uint256 public attackAmount;
    bool private _reentered;

    event Transfer(address indexed from, address indexed to, uint256 value);

    constructor(address minter_) {
        MINTER = minter_;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == MINTER, "not minter");
        balanceOf[to] += amount;
    }

    /// @notice Arms the reentrancy attempt: the next transfer() call will try to
    /// call `spend(account, id, payee, amount)` on `module` before finishing its
    /// own balance update.
    function arm(address module, address account, bytes32 id, address payee, uint256 amount) external {
        armed = true;
        attackModule = module;
        attackAccount = account;
        attackId = id;
        attackPayee = payee;
        attackAmount = amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (armed && !_reentered) {
            _reentered = true;
            // Deliberately not wrapped in try/catch: if the nested spend fails,
            // that failure must propagate, which is exactly what the test wants
            // to observe end to end (see ReentrancyGuard test in the adversarial
            // suite for why this is the honest way to model the attack).
            IAllowanceModuleForReentrancy(attackModule).spend(
                attackAccount, attackId, attackPayee, attackAmount
            );
        }
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
}
