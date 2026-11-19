// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {Call3Value, Result} from "./common/Multicall3.sol";
import {RouteRaceEngine} from "./RouteRaceEngine.sol";
import {IRouteRace} from "./interfaces/IRouteRace.sol";

abstract contract RelayRouterBase is RouteRaceEngine {
    using SafeTransferLib for address;

    string public constant VERSION = "4.0";

    error Reentrancy();
    error InvalidMsgSender(address storedSender, address actualSender);
    error InvalidNativeCommand();
    error UnauthorizedAttempt();
    error NoRecipientSet();
    error ArrayLengthsMismatch();
    error CallFailed();
    error InvalidTarget(address target);

    event SolverCallExecuted(address to, bytes32 dataHash, uint256 amount);
    event SolverNativeTransfer(address to, uint256 amount);
    event FundsMovement(address from, address to, address currency, uint256 amount, bytes metadata);

    bytes32 private constant CONTEXT_SLOT = bytes32(uint256(keccak256("RelayRouterV4.context")) - 1);
    bytes32 private constant RECIPIENT_SLOT = bytes32(uint256(keccak256("RelayRouterV4.recipient")) - 1);
    uint256 private constant RACE_ACTIVE = 1 << 160;
    uint256 private constant PHASE_MASK = RACE_ACTIVE;
    uint256 private constant DEPTH_UNIT = 1 << 192;

    function _load(bytes32 slot) internal view virtual returns (uint256 value);
    function _store(bytes32 slot, uint256 value) internal virtual;

    modifier outsideRace() {
        uint256 context = _load(CONTEXT_SLOT);
        if (context & PHASE_MASK != 0) revert Reentrancy();
        address sender = address(uint160(context));
        if (sender != address(0) && sender != msg.sender && msg.sender != address(this)) {
            revert InvalidMsgSender(sender, msg.sender);
        }
        if (context == 0) _store(CONTEXT_SLOT, uint160(msg.sender));
        _;
        if (context == 0) _store(CONTEXT_SLOT, 0);
    }

    receive() external payable {
        emit SolverNativeTransfer(address(this), msg.value);
    }

    function multicall(Call3Value[] calldata calls, address refundTo, address nftRecipient, bytes calldata metadata)
        public
        payable
        returns (Result[] memory returnData)
    {
        uint256 context = _load(CONTEXT_SLOT);
        if (context & PHASE_MASK != 0) revert Reentrancy();
        uint256 active = context;
        if (context == 0) {
            active = uint160(msg.sender);
        } else if (address(uint160(context)) != msg.sender && msg.sender != address(this)) {
            revert InvalidMsgSender(address(uint160(context)), msg.sender);
        }
        unchecked {
            active += DEPTH_UNIT;
        }
        _store(CONTEXT_SLOT, active);
        if (msg.value > 0) emit FundsMovement(msg.sender, address(this), address(0), msg.value, metadata);
        if (nftRecipient == address(0)) {
            returnData = _aggregate(calls, active, refundTo);
        } else {
            if (nftRecipient == address(this)) revert InvalidRecipient(address(this));
            uint256 previousRecipient = _load(RECIPIENT_SLOT);
            _store(RECIPIENT_SLOT, uint160(nftRecipient));
            returnData = _aggregate(calls, active, refundTo);
            _store(RECIPIENT_SLOT, previousRecipient);
        }
        _cleanupNative(0, refundTo, metadata);
        _store(CONTEXT_SLOT, context);
    }

    function _aggregate(Call3Value[] calldata calls, uint256 active, address refundTo)
        private
        returns (Result[] memory results)
    {
        results = new Result[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            Call3Value calldata command = calls[i];
            if (command.target != address(this)) {
                if (command.target == address(0)) revert InvalidTarget(address(0));
                _revertIfHookRegistry(command.target);
            } else if (command.callData.length >= 4) {
                bytes4 selector = bytes4(command.callData[:4]);
                uint256 kind = selector == IRouteRace.raceSingle.selector
                    ? 1
                    : selector == IRouteRace.race.selector
                        ? 2
                        : selector == IRouteRace.raceWithBackups.selector ? 3 : 0;
                if (kind != 0) {
                    if (active >> 192 != 1 || command.allowFailure) revert InvalidNativeCommand();
                    _store(CONTEXT_SLOT, active | RACE_ACTIVE);
                    address leftoverTo = refundTo == address(0) ? msg.sender : refundTo;
                    (uint256 winnerIndex, uint256 amountOut) = kind == 1
                        ? _raceSingle(command.callData[4:], command.value, leftoverTo)
                        : kind == 2
                            ? _race(command.callData[4:], command.value, leftoverTo)
                            : _raceWithBackups(command.callData[4:], command.value, leftoverTo);
                    _store(CONTEXT_SLOT, active);
                    results[i] = Result(true, abi.encode(winnerIndex, amountOut));
                    continue;
                }
                if (selector == RouteRaceEngine.callRoute.selector) revert UnauthorizedAttempt();
            }
            (bool success, bytes memory data) = command.target.call{value: command.value}(command.callData);
            if (!command.allowFailure && !success) {
                assembly ("memory-safe") { revert(add(data, 0x20), mload(data)) }
            }
            results[i] = Result(success, data);
            if (success) emit SolverCallExecuted(command.target, keccak256(command.callData), command.value);
        }
    }

    function _logDelivery(address recipient, address tokenOut, uint256 amountOut) internal override {
        bytes32 topic = FundsMovement.selector;
        assembly ("memory-safe") {
            let at := add(0x04, calldataload(0x64))
            let length := calldataload(at)
            let ptr := mload(0x40)
            mstore(ptr, address())
            mstore(add(ptr, 0x20), recipient)
            mstore(add(ptr, 0x40), tokenOut)
            mstore(add(ptr, 0x60), amountOut)
            mstore(add(ptr, 0x80), 0xa0)
            mstore(add(ptr, 0xa0), length)
            calldatacopy(add(ptr, 0xc0), add(at, 0x20), length)
            mstore(add(add(ptr, 0xc0), length), 0)
            log1(ptr, add(0xc0, and(add(length, 0x1f), not(0x1f))), topic)
        }
    }

    function _requireRaceActive() internal view override {
        if (_load(CONTEXT_SLOT) & RACE_ACTIVE == 0) revert UnauthorizedAttempt();
    }

    function _revertIfHookRegistry(address target) private pure {
        if (_isHookRegistry(target)) revert InvalidTarget(target);
    }

    function cleanupErc20s(
        address[] calldata tokens,
        address[] calldata recipients,
        uint256[] calldata amounts,
        bytes calldata metadata
    ) public outsideRace {
        if (tokens.length != amounts.length || amounts.length != recipients.length) {
            revert ArrayLengthsMismatch();
        }
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            uint256 amount = amounts[i] == 0 ? IERC20(token).balanceOf(address(this)) : amounts[i];
            if (amount > 0) {
                token.safeTransfer(recipients[i], amount);
                emit FundsMovement(address(this), recipients[i], token, amount, metadata);
            }
        }
    }

    function cleanupErc20sViaCall(
        address[] calldata tokens,
        address[] calldata tos,
        bytes[] calldata datas,
        uint256[] calldata amounts
    ) public outsideRace {
        if (tokens.length != amounts.length || amounts.length != tos.length || tos.length != datas.length) {
            revert ArrayLengthsMismatch();
        }
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            uint256 balanceBefore = IERC20(token).balanceOf(address(this));
            uint256 amount = amounts[i] == 0 ? balanceBefore : amounts[i];
            if (amount > 0) {
                _revertIfHookRegistry(tos[i]);
                token.safeApproveWithRetry(tos[i], amount);
                (bool success,) = tos[i].call(datas[i]);
                if (!success) revert CallFailed();
                uint256 balanceAfter = IERC20(token).balanceOf(address(this));
                if (balanceBefore > balanceAfter) {
                    emit FundsMovement(address(this), tos[i], token, balanceBefore - balanceAfter, "");
                }
            }
        }
    }

    function cleanupNative(uint256 amount, address recipient, bytes calldata metadata) public outsideRace {
        _cleanupNative(amount, recipient, metadata);
    }

    function _cleanupNative(uint256 amount, address recipient, bytes calldata metadata) private {
        address recipientAddr = recipient == address(0) ? msg.sender : recipient;
        uint256 amountToTransfer = amount == 0 ? address(this).balance : amount;
        if (amountToTransfer > 0) {
            recipientAddr.safeTransferETH(amountToTransfer);
            emit SolverNativeTransfer(recipientAddr, amountToTransfer);
            emit FundsMovement(address(this), recipientAddr, address(0), amountToTransfer, metadata);
        }
    }

    function cleanupNativeViaCall(uint256 amount, address to, bytes calldata data) public outsideRace {
        uint256 amountToTransfer = amount == 0 ? address(this).balance : amount;
        if (amountToTransfer > 0) {
            _revertIfHookRegistry(to);
            (bool success,) = to.call{value: amountToTransfer}(data);
            if (!success) revert CallFailed();
            emit FundsMovement(address(this), to, address(0), amountToTransfer, "");
        }
    }

    function _nftRecipient() private view returns (address recipient) {
        if (_load(CONTEXT_SLOT) & PHASE_MASK != 0) revert Reentrancy();
        recipient = address(uint160(_load(RECIPIENT_SLOT)));
        if (recipient == address(0)) revert NoRecipientSet();
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata data) external returns (bytes4) {
        IERC721(msg.sender).safeTransferFrom(address(this), _nftRecipient(), tokenId, data);
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256 id, uint256 value, bytes calldata data)
        external
        returns (bytes4)
    {
        IERC1155(msg.sender).safeTransferFrom(address(this), _nftRecipient(), id, value, data);
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    ) external returns (bytes4) {
        IERC1155(msg.sender).safeBatchTransferFrom(address(this), _nftRecipient(), ids, values, data);
        return this.onERC1155BatchReceived.selector;
    }
}
