// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC1820Registry} from "@openzeppelin/contracts/interfaces/IERC1820Registry.sol";
import {IERC777Recipient} from "@openzeppelin/contracts/interfaces/IERC777Recipient.sol";
import {IERC777Sender} from "@openzeppelin/contracts/interfaces/IERC777Sender.sol";

import {HookRegistryCode} from "./HookRegistryCode.sol";

/// @notice The ERC20 side of an ERC777 token, with the hook calls of
///         OpenZeppelin's ERC777: before the balances move it calls the
///         holder's `ERC777TokensSender` implementer, after they move the
///         recipient's `ERC777TokensRecipient` implementer, both looked up in
///         the ERC1820 registry. Tests must etch the registry first.
contract TestERC777 {
    IERC1820Registry private constant ERC1820 = IERC1820Registry(HookRegistryCode.ERC1820);
    bytes32 private constant TOKENS_SENDER_HASH = keccak256("ERC777TokensSender");
    bytes32 private constant TOKENS_RECIPIENT_HASH = keccak256("ERC777TokensRecipient");

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _send(msg.sender, msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        _send(msg.sender, from, to, amount);
        return true;
    }

    function _send(address operator, address from, address to, uint256 amount) private {
        address senderHook = ERC1820.getInterfaceImplementer(from, TOKENS_SENDER_HASH);
        if (senderHook != address(0)) {
            IERC777Sender(senderHook).tokensToSend(operator, from, to, amount, "", "");
        }

        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        address recipientHook = ERC1820.getInterfaceImplementer(to, TOKENS_RECIPIENT_HASH);
        if (recipientHook != address(0)) {
            IERC777Recipient(recipientHook).tokensReceived(operator, from, to, amount, "", "");
        }
    }
}
