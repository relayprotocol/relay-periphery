// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {Call3Value, Multicall3, Result} from "./common/Multicall3.sol";
import {
    ReentrancyGuardMsgSender_NonTstore
} from "./common/ReentrancyGuardMsgSender_NonTstore.sol";

/// @title  RelayRouter_NonTstore
/// @notice Stateless multicall router. Holds no ETH or ERC20 balances at
///         rest by design — every inflow is consumed and forwarded within
///         the same transaction.
///
/// @dev    Threat model: residual funds are out of scope. As consequences:
///         - `cleanup*` functions are intentionally permissionless (they
///           sweep stranded dust; there is nothing to steal in normal
///           operation).
///         - `msg.sender == address(this)` bypassing the reentrancy guard
///           is intentional to support self-calls inside a multicall.
///         A finding whose loss path requires the router to hold a non-zero
///         balance at the start of the attack tx is not a vulnerability
///         under this model. See vigil PRECON-012 and the residual-funds
///         tests in test/RelayRouterResidualFundsTest.sol.
contract RelayRouter_NonTstore is
    Multicall3,
    ReentrancyGuardMsgSender_NonTstore
{
    using SafeTransferLib for address;

    /// @notice Semantic version of this contract. Contract names are
    ///         unversioned; this constant is the version marker.
    string public constant VERSION = "3.1";

    /// @notice Revert if this contract is set as the recipient
    error InvalidRecipient(address recipient);

    /// @notice Revert if the native transfer failed
    error NativeTransferFailed();

    /// @notice Revert if no recipient is set
    error NoRecipientSet();

    /// @notice Revert if a nested multicall requests a different NFT recipient
    ///         than the one already set by an enclosing frame
    error RecipientAlreadySet(address current, address requested);

    /// @notice Revert if the array lengths do not match
    error ArrayLengthsMismatch();

    /// @notice Revert if a call fails
    error CallFailed();

    /// @notice Protocol event to be emitted when transferring native tokens
    event SolverNativeTransfer(address to, uint256 amount);

    /// @notice Emitted on any explicit movement of funds
    /// @param from The address the funds left
    /// @param to The counterparty of the movement. For direct transfers
    ///        (`multicall`, `cleanupErc20s`, `cleanupNative`,
    ///        `cleanupNativeViaCall`) this is the address the funds were sent
    ///        to. For `cleanupErc20sViaCall` it is the call target the router
    ///        approved, which spends the allowance from within its own code
    ///        and may deliver the tokens to a different final recipient that
    ///        the router cannot observe.
    /// @param currency The token moved, or address(0) for native tokens
    /// @param amount The amount that actually left `from`
    /// @param metadata Additional data associated with the movement
    event FundsMovement(
        address from,
        address to,
        address currency,
        uint256 amount,
        bytes metadata
    );

    uint256 private constant RECIPIENT_STORAGE_SLOT =
        uint256(keccak256("RelayRouter.recipient")) - 1;

    constructor() {}

    receive() external payable {
        emit SolverNativeTransfer(address(this), msg.value);
    }

    /// @notice Execute a multicall with the RelayRouter as msg.sender.
    /// @dev    If a multicall is expecting to mint ERC721s or ERC1155s, the recipient must be explicitly set
    ///         All calls to ERC721s and ERC1155s in the multicall will have the same recipient set in recipient
    ///         Be sure to transfer ERC20s or native tokens out of the router as part of the multicall
    /// @param calls The calls to perform
    /// @param refundTo The address to refund any leftover native tokens to
    /// @param nftRecipient The address to set as recipient of ERC721/ERC1155 mints
    /// @param metadata Additional data to associate the call to
    function multicall(
        Call3Value[] calldata calls,
        address refundTo,
        address nftRecipient,
        bytes calldata metadata
    ) public payable nonReentrant returns (Result[] memory returnData) {
        if (msg.value > 0) {
            emit FundsMovement(
                msg.sender,
                address(this),
                address(0),
                msg.value,
                metadata
            );
        }

        // Set the NFT recipient if provided. The reentrancy guard admits
        // nested same-sender calls, so a call inside `calls` may re-enter
        // `multicall`. Only the frame that acquired the recipient may clear
        // it: a nested frame clearing it would leave every later NFT callback
        // in the enclosing frame reading a zero recipient, reverting with
        // `NoRecipientSet` — or, under `allowFailure`, swallowing that revert
        // so the mint never happens and the multicall still reports success.
        bool recipientSetHere;
        if (nftRecipient != address(0)) {
            address currentRecipient = _getRecipient();
            if (currentRecipient == address(0)) {
                _setRecipient(nftRecipient);
                recipientSetHere = true;
            } else if (currentRecipient != nftRecipient) {
                revert RecipientAlreadySet(currentRecipient, nftRecipient);
            }
        }

        // Perform the multicall
        returnData = _aggregate3Value(calls);

        // Clear the recipient in storage
        if (recipientSetHere) {
            _clearRecipient();
        }

        // Refund any leftover native tokens to the sender
        cleanupNative(0, refundTo, metadata);
    }

    /// @notice Send leftover ERC20 tokens to recipients
    /// @dev    Should be included in the multicall if the router is expecting to receive tokens
    ///         Set amount to 0 to transfer the full balance
    /// @param tokens The addresses of the ERC20 tokens
    /// @param recipients The addresses to refund the tokens to
    /// @param amounts The amounts to send
    /// @param metadata Additional data to associate the call to
    function cleanupErc20s(
        address[] calldata tokens,
        address[] calldata recipients,
        uint256[] calldata amounts,
        bytes calldata metadata
    ) public nonReentrant {
        // Revert if array lengths do not match
        if (
            tokens.length != amounts.length ||
            amounts.length != recipients.length
        ) {
            revert ArrayLengthsMismatch();
        }

        for (uint256 i; i < tokens.length; i++) {
            address token = tokens[i];
            address recipient = recipients[i];

            // Get the amount to transfer
            uint256 amount = amounts[i] == 0
                ? IERC20(token).balanceOf(address(this))
                : amounts[i];

            if (amount > 0) {
                // Transfer the token to the recipient address
                token.safeTransfer(recipient, amount);

                emit FundsMovement(
                    address(this),
                    recipient,
                    token,
                    amount,
                    metadata
                );
            }
        }
    }

    /// @notice Send leftover ERC20 tokens via explicit method calls
    /// @dev    Should be included in the multicall if the router is expecting to receive tokens
    ///         Set amount to 0 to transfer the full balance
    /// @param tokens The addresses of the ERC20 tokens
    /// @param tos The target addresses for the calls
    /// @param datas The data for the calls
    /// @param amounts The amounts to send
    /// @dev    Emits `FundsMovement` with empty metadata: unlike `cleanupErc20s`
    ///         this entrypoint takes no metadata argument, so movements cannot be
    ///         correlated off-chain by request id. The event's `to` is the call
    ///         target the allowance was granted to, not necessarily the final
    ///         token recipient — the target may `transferFrom` the router to a
    ///         third party, which the router cannot observe.
    function cleanupErc20sViaCall(
        address[] calldata tokens,
        address[] calldata tos,
        bytes[] calldata datas,
        uint256[] calldata amounts
    ) public nonReentrant {
        // Revert if array lengths do not match
        if (
            tokens.length != amounts.length ||
            amounts.length != tos.length ||
            tos.length != datas.length
        ) {
            revert ArrayLengthsMismatch();
        }

        for (uint256 i; i < tokens.length; i++) {
            address token = tokens[i];
            address to = tos[i];
            bytes calldata data = datas[i];

            uint256 balanceBefore = IERC20(token).balanceOf(address(this));

            // Get the amount to transfer
            uint256 amount = amounts[i] == 0 ? balanceBefore : amounts[i];

            if (amount > 0) {
                // Approve the target for the call. Use safeApproveWithRetry to
                // support non-standard ERC20s: tokens that do not return a bool
                // on approve (e.g. USDT, which reverts the typed call with empty
                // returndata) and tokens that require resetting the allowance to
                // zero before setting a new non-zero value (also USDT).
                token.safeApproveWithRetry(to, amount);

                // Make the call
                (bool success, ) = to.call(data);
                if (!success) {
                    revert CallFailed();
                }

                // Emit the amount the target actually consumed, which can be
                // less than the amount approved. `to` is the approved spender,
                // not necessarily the final holder of the tokens.
                uint256 balanceAfter = IERC20(token).balanceOf(address(this));
                if (balanceBefore > balanceAfter) {
                    emit FundsMovement(
                        address(this),
                        to,
                        token,
                        balanceBefore - balanceAfter,
                        ""
                    );
                }
            }
        }
    }

    /// @notice Send leftover native tokens to the recipient address
    /// @dev Set amount to 0 to transfer the full balance. Set recipient to address(0) to transfer to msg.sender
    /// @param amount The amount of native tokens to transfer
    /// @param recipient The recipient address
    /// @param metadata Additional data to associate the call to
    function cleanupNative(
        uint256 amount,
        address recipient,
        bytes calldata metadata
    ) public nonReentrant {
        // If recipient is address(0), set to msg.sender
        address recipientAddr = recipient == address(0)
            ? msg.sender
            : recipient;

        uint256 amountToTransfer = amount == 0 ? address(this).balance : amount;

        if (amountToTransfer > 0) {
            recipientAddr.safeTransferETH(amountToTransfer);
            emit SolverNativeTransfer(recipientAddr, amountToTransfer);

            emit FundsMovement(
                address(this),
                recipientAddr,
                address(0),
                amountToTransfer,
                metadata
            );
        }
    }

    /// @notice Send leftover native tokens via an explicit method call
    /// @dev Set amount to 0 to transfer the full balance
    /// @param amount The amount of native tokens to transfer
    /// @param to The target address of the call
    /// @param data The data for the call
    /// @dev    Emits `FundsMovement` with empty metadata, and does not emit
    ///         `SolverNativeTransfer` (unlike `cleanupNative`).
    function cleanupNativeViaCall(
        uint256 amount,
        address to,
        bytes calldata data
    ) public nonReentrant {
        uint256 amountToTransfer = amount == 0 ? address(this).balance : amount;

        if (amountToTransfer > 0) {
            (bool success, ) = to.call{value: amountToTransfer}(data);
            if (!success) {
                revert CallFailed();
            }

            emit FundsMovement(
                address(this),
                to,
                address(0),
                amountToTransfer,
                ""
            );
        }
    }

    /// @notice Internal function to set the recipient address for ERC721 or ERC1155 mint
    /// @dev If the chain does not support tstore, recipient will be saved in storage
    /// @param recipient The address of the recipient
    function _setRecipient(address recipient) internal {
        // For safety, revert if the recipient is this contract
        // Tokens should either be minted directly to recipient, or transferred to recipient through the onReceived hooks
        if (recipient == address(this)) {
            revert InvalidRecipient(address(this));
        }

        // Set the recipient in storage
        uint256 recipientStorageSlot = RECIPIENT_STORAGE_SLOT;
        uint256 recipientValue = uint256(uint160(recipient));
        assembly {
            sstore(recipientStorageSlot, recipientValue)
        }
    }

    /// @notice Internal function to get the recipient address for ERC721 or ERC1155 mint
    function _getRecipient() internal view returns (address) {
        uint256 recipientStorageSlot = RECIPIENT_STORAGE_SLOT;
        uint256 value;

        assembly {
            value := sload(recipientStorageSlot)
        }

        // Get the recipient from storage
        return address(uint160(value));
    }

    /// @notice Internal function to clear the recipient address for ERC721 or ERC1155 mint
    function _clearRecipient() internal {
        // Return if recipient hasn't been set
        if (_getRecipient() == address(0)) {
            return;
        }

        // Clear the recipient in storage
        uint256 recipientStorageSlot = RECIPIENT_STORAGE_SLOT;
        assembly {
            sstore(recipientStorageSlot, 0)
        }
    }

    function onERC721Received(
        address,
        /*_operator*/ address,
        /*_from*/ uint256 _tokenId,
        bytes calldata _data
    ) external returns (bytes4) {
        // Get the recipient from storage
        address recipient = _getRecipient();

        // Revert if no recipient is set
        // Note this means transferring NFTs to this contract via `safeTransferFrom` will revert,
        // unless the transfer is part of a multicall that sets the recipient in storage
        if (recipient == address(0)) {
            revert NoRecipientSet();
        }

        // Transfer the NFT to the recipient
        IERC721(msg.sender).safeTransferFrom(
            address(this),
            recipient,
            _tokenId,
            _data
        );

        return this.onERC721Received.selector;
    }

    function onERC1155Received(
        address /*_operator*/,
        address /*_from*/,
        uint256 _id,
        uint256 _value,
        bytes calldata _data
    ) external returns (bytes4) {
        // Get the recipient from storage
        address recipient = _getRecipient();

        // Revert if no recipient is set
        // Note this means transferring NFTs to this contract via `safeTransferFrom` will revert,
        // unless the transfer is part of a multicall that sets the recipient in storage
        if (recipient == address(0)) {
            revert NoRecipientSet();
        }

        // Transfer the tokens to the recipient
        IERC1155(msg.sender).safeTransferFrom(
            address(this),
            recipient,
            _id,
            _value,
            _data
        );

        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address /*_operator*/,
        address /*_from*/,
        uint256[] calldata _ids,
        uint256[] calldata _values,
        bytes calldata _data
    ) external returns (bytes4) {
        // Get the recipient from storage
        address recipient = _getRecipient();

        // Revert if no recipient is set
        // Note this means transferring NFTs to this contract via `safeTransferFrom` will revert,
        // unless the transfer is part of a multicall that sets the recipient in storage
        if (recipient == address(0)) {
            revert NoRecipientSet();
        }

        // Transfer the tokens to the recipient
        IERC1155(msg.sender).safeBatchTransferFrom(
            address(this),
            recipient,
            _ids,
            _values,
            _data
        );

        return this.onERC1155BatchReceived.selector;
    }
}
