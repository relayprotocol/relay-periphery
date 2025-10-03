// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPermit2} from "permit2-relay/src/interfaces/IPermit2.sol";
import {ISignatureTransfer} from "permit2-relay/src/interfaces/ISignatureTransfer.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import {SignatureCheckerLib} from "solady/src/utils/SignatureCheckerLib.sol";
import {TrustlessPermit} from "trustlessPermit/TrustlessPermit.sol";

import {IRelayRouterV3} from "./interfaces/IRelayRouterV3.sol";
import {IERC3009} from "../common/IERC3009.sol";
import {Call3Value, Result} from "../common/Multicall3.sol";
import {Permit2612, Permit3009} from "../common/Permits.sol";

contract RelayApprovalProxyV3 is Ownable {
    using SafeERC20 for IERC20;
    using SignatureCheckerLib for address;
    using TrustlessPermit for address;

    /// @notice Revert if the array lengths do not match
    error ArrayLengthsMismatch();

    /// @notice Revert if the native transfer fails
    error NativeTransferFailed();

    /// @notice Revert if the refundTo address is zero address
    error RefundToCannotBeZeroAddress();

    /// @notice Emitted on any explicit movement of funds
    event FundsMovement(
        address from,
        address to,
        address currency,
        uint256 amount,
        bytes metadata
    );

    /// @notice The address of the router contract
    address private immutable ROUTER;

    /// @notice The Permit2 contract
    IPermit2 private immutable PERMIT2;

    bytes32 public constant _CALL3VALUE_TYPEHASH =
        keccak256(
            "Call3Value(address target,bool allowFailure,uint256 value,bytes callData)"
        );
    string public constant _RELAYER_WITNESS_TYPE_STRING =
        "RelayerWitness witness)Call3Value(address target,bool allowFailure,uint256 value,bytes callData)RelayerWitness(address relayer,address refundTo,address nftRecipient,bytes metadata,Call3Value[] call3Values)TokenPermissions(address token,uint256 amount)";
    bytes32 public constant _RELAYER_WITNESS_TYPEHASH =
        keccak256(
            "RelayerWitness(address relayer,address refundTo,address nftRecipient,bytes metadata,Call3Value[] call3Values)Call3Value(address target,bool allowFailure,uint256 value,bytes callData)"
        );

    receive() external payable {}

    constructor(address _owner, address _router, address _permit2) {
        _initializeOwner(_owner);
        ROUTER = _router;
        PERMIT2 = IPermit2(_permit2);
    }

    /// @notice Withdraw function in case funds get stuck in contract
    function withdraw() external onlyOwner {
        _send(msg.sender, address(this).balance);
    }

    /// @notice Transfer tokens to RelayRouter and perform multicall in a single tx
    /// @dev    This contract must be approved to transfer msg.sender's tokens to the RelayRouter. If leftover native tokens
    ///         is expected as part of the multicall, be sure to set refundTo to the expected recipient. If the multicall
    ///         includes ERC721/ERC1155 mints or transfers, be sure to set nftRecipient to the expected recipient.
    /// @param tokens An array of token addresses to transfer
    /// @param amounts An array of token amounts to transfer
    /// @param calls The calls to perform
    /// @param refundTo The address to refund any leftover native tokens to
    /// @param nftRecipient The address to set as recipient of ERC721/ERC1155 mints
    /// @param metadata Additional data to associate the call to
    function transferAndMulticall(
        address[] calldata tokens,
        uint256[] calldata amounts,
        Call3Value[] calldata calls,
        address refundTo,
        address nftRecipient,
        bytes calldata metadata
    ) external payable returns (Result[] memory returnData) {
        // Revert if array lengths do not match
        if ((tokens.length != amounts.length)) {
            revert ArrayLengthsMismatch();
        }

        // Revert if refundTo is zero address
        if (refundTo == address(0)) {
            revert RefundToCannotBeZeroAddress();
        }

        // Transfer the tokens to the router
        for (uint256 i = 0; i < tokens.length; i++) {
            IERC20(tokens[i]).safeTransferFrom(msg.sender, ROUTER, amounts[i]);

            emit FundsMovement(
                msg.sender,
                ROUTER,
                tokens[i],
                amounts[i],
                metadata
            );
        }

        // Call multicall on the router
        returnData = IRelayRouterV3(ROUTER).multicall{value: msg.value}(
            calls,
            refundTo,
            nftRecipient,
            metadata
        );
    }

    /// @notice Use ERC2612 permit to transfer tokens to RelayRouter and execute multicall in a single tx
    /// @dev    Approved spender must be address(this) to transfer user's tokens to the RelayRouter. If leftover native tokens
    ///         is expected as part of the multicall, be sure to set refundTo to the expected recipient. If the multicall
    ///         includes ERC721/ERC1155 mints or transfers, be sure to set nftRecipient to the expected recipient.
    /// @param permits An array of permits
    /// @param calls The calls to perform
    /// @param refundTo The address to refund any leftover native tokens to
    /// @param nftRecipient The address to set as recipient of ERC721/ERC1155 mints
    /// @param metadata Additional data to associate the call to
    /// @return returnData The return data from the multicall
    function permitTransferAndMulticall(
        Permit2612[] calldata permits,
        Call3Value[] calldata calls,
        address refundTo,
        address nftRecipient,
        bytes calldata metadata
    ) external payable returns (Result[] memory returnData) {
        // Revert if refundTo is zero address
        if (refundTo == address(0)) {
            revert RefundToCannotBeZeroAddress();
        }

        for (uint256 i = 0; i < permits.length; i++) {
            Permit2612 memory permit = permits[i];

            // Revert if the permit owner is not the msg.sender
            if (permit.owner != msg.sender) {
                revert Unauthorized();
            }

            // Use the permit. Calling `trustlessPermit` allows tx to
            // continue even if permit gets frontrun
            permit.token.trustlessPermit(
                permit.owner,
                address(this),
                permit.value,
                permit.deadline,
                permit.v,
                permit.r,
                permit.s
            );

            // Transfer the tokens to the router
            IERC20(permit.token).safeTransferFrom(
                permit.owner,
                ROUTER,
                permit.value
            );

            emit FundsMovement(
                permit.owner,
                ROUTER,
                permit.token,
                permit.value,
                metadata
            );
        }

        // Call multicall on the router
        returnData = IRelayRouterV3(ROUTER).multicall{value: msg.value}(
            calls,
            refundTo,
            nftRecipient,
            metadata
        );
    }

    /// @notice Use Permit2 to transfer tokens to RelayRouter and perform an arbitrary multicall.
    ///         Pass in an empty permitSignature to only perform the multicall.
    /// @dev    msg.value will persist across all calls in the multicall. If leftover native tokens is expected
    ///         as part of the multicall, be sure to set refundTo to the expected recipient. If the multicall
    ///         includes ERC721/ERC1155 mints or transfers, be sure to set nftRecipient to the expected recipient.
    /// @param user The address of the user
    /// @param permit The permit details
    /// @param calls The calls to perform
    /// @param refundTo The address to refund any leftover native tokens to
    /// @param nftRecipient The address to set as recipient of ERC721/ERC1155 mints
    /// @param metadata Additional data to associate the call to
    /// @param permitSignature The signature for the permit
    function permit2TransferAndMulticall(
        address user,
        ISignatureTransfer.PermitBatchTransferFrom memory permit,
        Call3Value[] calldata calls,
        address refundTo,
        address nftRecipient,
        bytes calldata metadata,
        bytes memory permitSignature
    ) external payable returns (Result[] memory returnData) {
        // Revert if refundTo is zero address
        if (refundTo == address(0)) {
            revert RefundToCannotBeZeroAddress();
        }

        // If a permit signature is provided, use it to transfer tokens from user to router
        if (permitSignature.length != 0) {
            _handleBatchPermit(
                user,
                refundTo,
                nftRecipient,
                metadata,
                permit,
                calls,
                permitSignature
            );
        }

        // Call multicall on the router
        returnData = IRelayRouterV3(ROUTER).multicall{value: msg.value}(
            calls,
            refundTo,
            nftRecipient,
            metadata
        );
    }

    /// @notice Use ERC3009 permit to transfer tokens to RelayRouter and execute multicall in a single tx
    /// @dev    Approved spender must be address(this) to transfer user's tokens to the RelayRouter. If leftover native tokens
    ///         is expected as part of the multicall, be sure to set refundTo to the expected recipient. If the multicall
    ///         includes ERC721/ERC1155 mints or transfers, be sure to set nftRecipient to the expected recipient.
    /// @param permits An array of permits
    /// @param calls The calls to perform
    /// @param refundTo The address to refund any leftover native tokens to
    /// @param nftRecipient The address to set as recipient of ERC721/ERC1155 mints
    /// @param metadata Additional data to associate the call to
    /// @return returnData The return data from the multicall
    function permit3009TransferAndMulticall(
        Permit3009[] calldata permits,
        address[] calldata tokens,
        Call3Value[] calldata calls,
        address refundTo,
        address nftRecipient,
        bytes calldata metadata
    ) external payable returns (Result[] memory returnData) {
        // Revert if array lengths do not match
        if ((tokens.length != permits.length)) {
            revert ArrayLengthsMismatch();
        }

        // Revert if refundTo is zero address
        if (refundTo == address(0)) {
            revert RefundToCannotBeZeroAddress();
        }

        for (uint256 i = 0; i < permits.length; i++) {
            Permit3009 memory permit = permits[i];

            // Use the permit
            IERC3009(tokens[i]).receiveWithAuthorization(
                permit.from,
                address(this),
                permit.value,
                permit.validAfter,
                permit.validBefore,
                _getRelayerWitnessHash(refundTo, nftRecipient, metadata, calls),
                permit.v,
                permit.r,
                permit.s
            );

            // Transfer the tokens to the router
            IERC20(tokens[i]).safeTransfer(ROUTER, permit.value);

            emit FundsMovement(
                permit.from,
                ROUTER,
                tokens[i],
                permit.value,
                metadata
            );
        }

        // Call multicall on the router
        returnData = IRelayRouterV3(ROUTER).multicall{value: msg.value}(
            calls,
            refundTo,
            nftRecipient,
            metadata
        );
    }

    /// @notice Internal function to get the hash of a list of `Call3Value` structs
    /// @param calls The calls to perform
    function _getCallsHash(
        Call3Value[] memory calls
    ) internal pure returns (bytes32) {
        // Create an array of keccak256 hashes of the calls
        bytes32[] memory callHashes = new bytes32[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            // Encode the call and hash it
            callHashes[i] = keccak256(
                abi.encode(
                    _CALL3VALUE_TYPEHASH,
                    calls[i].target,
                    calls[i].allowFailure,
                    calls[i].value,
                    keccak256(calls[i].callData)
                )
            );
        }

        return keccak256(abi.encodePacked(callHashes));
    }

    /// @notice Internal function to get the hash of a relayer witness
    /// @param refundTo The address to refund any leftover native tokens to
    /// @param nftRecipient The nftRecipient address
    /// @param metadata Additional data to associate the call to
    /// @param calls The calls to be executed
    function _getRelayerWitnessHash(
        address refundTo,
        address nftRecipient,
        bytes memory metadata,
        Call3Value[] memory calls
    ) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    _RELAYER_WITNESS_TYPEHASH,
                    msg.sender,
                    refundTo,
                    nftRecipient,
                    metadata,
                    _getCallsHash(calls)
                )
            );
    }

    /// @notice Internal function to handle a permit batch transfer
    /// @param user The address of the user
    /// @param refundTo The address to refund any leftover native tokens to
    /// @param nftRecipient The address to set as recipient of ERC721/ERC1155 mints
    /// @param metadata Additional data to associate the call to
    /// @param permit The permit details
    /// @param calls The calls to perform
    /// @param permitSignature The signature for the permit
    function _handleBatchPermit(
        address user,
        address refundTo,
        address nftRecipient,
        bytes calldata metadata,
        ISignatureTransfer.PermitBatchTransferFrom memory permit,
        Call3Value[] calldata calls,
        bytes memory permitSignature
    ) internal {
        bytes32 witness = _getRelayerWitnessHash(
            refundTo,
            nftRecipient,
            metadata,
            calls
        );

        // Create the SignatureTransferDetails array
        ISignatureTransfer.SignatureTransferDetails[]
            memory signatureTransferDetails = new ISignatureTransfer.SignatureTransferDetails[](
                permit.permitted.length
            );
        for (uint256 i = 0; i < permit.permitted.length; i++) {
            uint256 amount = permit.permitted[i].amount;

            signatureTransferDetails[i] = ISignatureTransfer
                .SignatureTransferDetails({
                    to: address(ROUTER),
                    requestedAmount: amount
                });

            emit FundsMovement(
                user,
                ROUTER,
                permit.permitted[i].token,
                amount,
                metadata
            );
        }

        // Use the SignatureTransferDetails and permit signature to transfer tokens to the router
        PERMIT2.permitWitnessTransferFrom(
            permit,
            signatureTransferDetails,
            // When using a permit signature, cannot deposit on behalf of someone else other than `user`
            user,
            witness,
            _RELAYER_WITNESS_TYPE_STRING,
            permitSignature
        );
    }

    function _send(address to, uint256 value) internal {
        bool success;
        assembly {
            // Save gas by avoiding copying the return data to memory.
            // Provide at most 100k gas to the internal call, which is
            // more than enough to cover common use-cases of logic for
            // receiving native tokens (eg. SCW payable fallbacks).
            success := call(100000, to, value, 0, 0, 0, 0)
        }

        if (!success) {
            revert NativeTransferFailed();
        }
    }
}
