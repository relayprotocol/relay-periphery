// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

// The test-only contracts of the limit-order tail suite: the tokens, a smart-contract wallet, the venue, the
// recipients and the attackers. Permit2, the depository and the multicaller are Relay's real contracts.

// TailToken.kind
uint8 constant STANDARD = 0;
uint8 constant FEE_ON_TRANSFER = 1; // keeps 1% of every transfer
uint8 constant ROUNDS_DOWN = 2; // delivers amount - 1 of a non-zero transfer
uint8 constant HOOK = 3; // calls its hook at the end of every transferFrom
uint8 constant USDT_APPROVE = 4; // approve returns nothing and refuses to change one non-zero allowance to another
uint8 constant NO_ZERO_APPROVE = 5; // approve(spender, 0) reverts

interface ITransferHook {
    function onTransferFrom(address from, address to, uint256 amount) external;
}

interface IBalanceOf {
    function balanceOf(address account) external view returns (uint256);
}

/// @dev An ERC20 with at most one quirk, chosen by `kind`. The sender always loses `amount`; what the token keeps of
/// it is burned
contract TailToken {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    uint8 public immutable kind;
    address public immutable deployer;
    string public name;
    address public hook;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint8 kind_, string memory name_) {
        kind = kind_;
        name = name_;
        deployer = msg.sender;
    }

    function symbol() external view returns (string memory) {
        return name;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function setHook(address hook_) external {
        require(msg.sender == deployer);
        hook = hook_;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == deployer);
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (kind == USDT_APPROVE) require(amount == 0 || allowance[msg.sender][spender] == 0, "USDT approve");
        if (kind == NO_ZERO_APPROVE) require(amount != 0, "approve(0)");
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        if (kind == USDT_APPROVE) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _move(from, to, amount);
        if (kind == HOOK && hook != address(0)) ITransferHook(hook).onTransferFrom(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        uint256 credited = amount;
        if (kind == FEE_ON_TRANSFER) credited = amount - amount / 100;
        else if (kind == ROUNDS_DOWN && amount != 0) credited = amount - 1;
        balanceOf[from] -= amount;
        balanceOf[to] += credited;
        totalSupply -= amount - credited;
        emit Transfer(from, to, credited);
        if (credited != amount) emit Transfer(from, address(0), amount - credited);
    }
}

/// @dev A smart-contract wallet that accepts its signer's ECDSA signature of a digest (ERC-1271). Etched onto an EOA
/// it plays an EIP-7702 delegation that checks the EOA's own key
contract TailWallet {
    address public immutable signer;

    constructor(address signer_) {
        signer = signer_;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (signature.length == 65) {
            bytes32 r = bytes32(signature[0:32]);
            bytes32 s = bytes32(signature[32:64]);
            uint8 v = uint8(signature[64]);
            address recovered = ecrecover(hash, v, r, s);
            if (recovered != address(0) && recovered == signer) return 0x1626ba7e;
        }
        return 0xffffffff;
    }

    receive() external payable {}
}

/// @dev Code that a user may delegate to after signing that has no isValidSignature
contract TailCodeWithoutSignatures {
    receive() external payable {}
}

struct Attempt {
    address target;
    bytes data;
}

/// @dev Where the attempts of a fill come from: the contract that deployed the actor. The invariant handler keeps
/// them in transient storage, so that setting them for each fill costs little
interface IAttemptSource {
    function currentAttempts() external view returns (Attempt[] memory);
}

/// @dev Calls each attempt of its source and counts the ones that succeeded. Never reverts itself and never runs
/// inside itself, so a token hook that triggers itself does not recurse
abstract contract Reenters {
    address internal immutable source;
    uint256 public attemptsMade;
    uint256 public attemptsSucceeded;

    constructor() {
        source = msg.sender;
    }

    function _reenter() internal {
        uint256 inside;
        assembly ("memory-safe") {
            inside := tload(0)
        }
        if (inside != 0) return;
        assembly ("memory-safe") {
            tstore(0, 1)
        }
        Attempt[] memory attempts = IAttemptSource(source).currentAttempts();
        for (uint256 i; i < attempts.length; ++i) {
            ++attemptsMade;
            (bool ok,) = attempts[i].target.call(attempts[i].data);
            if (ok) ++attemptsSucceeded;
        }
        assembly ("memory-safe") {
            tstore(0, 0)
        }
    }
}

/// @dev What a HOOK token calls at the end of every transferFrom
contract TailHookTarget is Reenters, ITransferHook {
    function onTransferFrom(address, address, uint256) external {
        _reenter();
    }

    receive() external payable {}
}

/// @dev A venue. It pulls `pull` of `tokenIn` from its caller, which must have approved it, may call back, and pays
/// `out` of `tokenOut` (native for address(0)) to its caller. Paying less or taking less is a matter of the amounts
contract TailVenue is Reenters {
    function swap(address tokenIn, uint256 pull, address tokenOut, uint256 out, bool callBack) external {
        if (pull != 0) SafeTransferLib.safeTransferFrom(tokenIn, msg.sender, address(this), pull);
        if (callBack) _reenter();
        if (out != 0) {
            if (tokenOut == address(0)) SafeTransferLib.safeTransferETH(msg.sender, out);
            else SafeTransferLib.safeTransfer(tokenOut, msg.sender, out);
        }
    }

    receive() external payable {}
}

/// @dev A recipient that calls out whenever it gets native value, with or without calldata, and keeps the value.
/// Any other call does nothing and succeeds
contract TailCalloutRecipient is Reenters {
    receive() external payable {
        _reenter();
    }

    fallback() external payable {
        if (msg.value != 0) _reenter();
    }
}

/// @dev A depository look-alike that pulls half of the allowance it is given and logs what it pulled
contract TailHalfPullingRecipient {
    event RelayNativeDeposit(address from, uint256 amount, bytes32 id);
    event RelayErc20Deposit(address from, address token, uint256 amount, bytes32 id);

    function depositErc20(address depositor, address token, bytes32 id) external {
        uint256 amount = TailToken(token).allowance(msg.sender, address(this)) / 2;
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        emit RelayErc20Deposit(depositor, token, amount, id);
    }

    function depositNative(address depositor, bytes32 id) external payable {
        emit RelayNativeDeposit(depositor, msg.value, id);
    }

    receive() external payable {}
}

/// @dev A recipient that reverts on every call
contract TailRevertingRecipient {
    fallback() external payable {
        revert("TailRevertingRecipient");
    }
}

/// @dev A relayer contract that submits what it is told, and when one of its solver calls calls it back, tries to
/// re-enter the proxy, the router and Permit2
contract TailEvilRelayer is Reenters {
    function submit(address target, bytes calldata data) external returns (bool ok, bytes memory ret) {
        require(msg.sender == source);
        (ok, ret) = target.call(data);
    }

    function reenter() external {
        _reenter();
    }

    receive() external payable {}
}

/// @dev The harness appends a call to `snap` as the last solver call of every fill. It records `B`, the router's
/// balance of `tail.token` immediately before the tail, the recipient's balance and the balances of the watched
/// accounts (the proxies) when the relayer's calls end, and marks where the tail's logs start
contract TailProbe {
    event TailStarts();

    uint256 public runs;
    uint256 public routerBalance;
    uint256 public recipientBalance;
    address[] internal watchedAccounts;
    address[] internal watchedTokens;
    // account index * (watchedTokens.length + 1) + token index; the last index of each account is native
    mapping(uint256 => uint256) public watchedBalance;

    /// @notice Sets the accounts whose balances of `tokens` and of native value each snap also records
    function watch(address[] calldata accounts, address[] calldata tokens) external {
        watchedAccounts = accounts;
        watchedTokens = tokens;
    }

    function snap(address token, address recipient) external {
        ++runs;
        if (token == address(0)) {
            routerBalance = msg.sender.balance;
            recipientBalance = recipient.balance;
        } else {
            routerBalance = IBalanceOf(token).balanceOf(msg.sender);
            recipientBalance = IBalanceOf(token).balanceOf(recipient);
        }
        uint256 k;
        for (uint256 a; a < watchedAccounts.length; ++a) {
            for (uint256 t; t < watchedTokens.length; ++t) {
                watchedBalance[k++] = IBalanceOf(watchedTokens[t]).balanceOf(watchedAccounts[a]);
            }
            watchedBalance[k++] = watchedAccounts[a].balance;
        }
        emit TailStarts();
    }
}

/// @dev Etched over a contract for one staticcall to read one of its transient slots
contract TailTransientReader {
    fallback(bytes calldata data) external returns (bytes memory) {
        uint256 slot = abi.decode(data, (uint256));
        uint256 value;
        assembly ("memory-safe") {
            value := tload(slot)
        }
        return abi.encode(value);
    }
}
