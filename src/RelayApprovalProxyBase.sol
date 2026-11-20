// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPermit2} from "permit2-relay/src/interfaces/IPermit2.sol";
import {
    ISignatureTransfer
} from "permit2-relay/src/interfaces/ISignatureTransfer.sol";
import {Ownable} from "solady/src/auth/Ownable.sol";
import {EIP712} from "solady/src/utils/EIP712.sol";
import {SignatureCheckerLib} from "solady/src/utils/SignatureCheckerLib.sol";
import {TrustlessPermit} from "trustlessPermit/TrustlessPermit.sol";

import {IRelayDepository} from "./interfaces/IRelayDepository.sol";
import {IRelayRouter} from "./interfaces/IRelayRouter.sol";
import {IERC3009} from "./common/IERC3009.sol";
import {Call3Value, Result} from "./common/Multicall3.sol";
import {Permit2612, Permit3009} from "./common/Permits.sol";

abstract contract RelayApprovalProxyBase is Ownable, EIP712 {
    using SafeERC20 for IERC20;
    using SignatureCheckerLib for address;
    using TrustlessPermit for address;

    /// @notice Semantic version of this contract. Contract names are
    ///         unversioned; this constant is the version marker.
    string public constant VERSION = "4.0";

    /// @notice Revert if the array lengths do not match
    error ArrayLengthsMismatch();

    /// @notice Revert if a constructor argument is the zero address
    error ConstructorArgCannotBeZeroAddress();

    /// @notice Revert if the multicall authorization signature is invalid
    error InvalidMulticallSignature();

    /// @notice Revert if the native transfer fails
    error NativeTransferFailed();

    /// @notice Revert if no ERC3009 permits are provided
    error PermitsCannotBeEmpty();

    /// @notice Revert if the withdraw recipient cannot receive the funds
    error InvalidRecipient(address recipient);

    /// @notice Revert if the refundTo address is zero address
    error RefundToCannotBeZeroAddress();

    /// @notice Revert if a function of this contract is called while another one runs
    error Reentrancy();

    /// @notice Revert if a tail's permit does not hold exactly one token, `refundTo` or a field of the tail is
    ///         invalid, or a tail with an order id does not deposit into a known depository
    error InvalidTail();

    /// @notice The last call of a limit-order fill, as the user signs it: at least `minAmount` of `token`
    ///         (zero for native) goes to `recipient`, deposited for the user under `orderId` unless it is zero
    struct SweepWithMinimum {
        address token;
        uint256 minAmount;
        address recipient;
        bytes32 orderId;
    }

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

    /// @notice Relay's depository at the address it has on most chains. A constant, so that the proxy's code
    ///         and CREATE2 address stay the same on every chain
    address public constant DEPOSITORY =
        0x4cD00E387622C35bDDB9b4c962C136462338BC31;

    /// @notice Other depositories that a tail with an order id may deposit into: the depository of a chain
    ///         where it has another address, or a depository that moves. Set by the owner
    mapping(address => bool) public isDepository;

    /// @notice Emitted when the owner allows or removes a depository
    event DepositoryUpdated(address depository, bool allowed);

    bytes32 public constant _CALL3VALUE_TYPEHASH =
        keccak256(
            "Call3Value(address target,bool allowFailure,uint256 value,bytes callData)"
        );
    bytes32 public constant _FUNDING_AUTHORIZATION_TYPEHASH =
        keccak256(
            "FundingAuthorization(address token,address from,uint256 value,uint256 validAfter,uint256 validBefore)"
        );
    bytes32 public constant _MULTICALL_AUTHORIZATION_TYPEHASH =
        keccak256(
            "MulticallAuthorization(address from,address relayer,uint256 msgValue,address refundTo,address nftRecipient,bytes metadata,uint256 fundingIndex,Call3Value[] calls,FundingAuthorization[] funding)Call3Value(address target,bool allowFailure,uint256 value,bytes callData)FundingAuthorization(address token,address from,uint256 value,uint256 validAfter,uint256 validBefore)"
        );
    string public constant _RELAYER_WITNESS_TYPE_STRING =
        "RelayerWitness witness)Call3Value(address target,bool allowFailure,uint256 value,bytes callData)RelayerWitness(address relayer,uint256 msgValue,address refundTo,address nftRecipient,bytes metadata,Call3Value[] call3Values)TokenPermissions(address token,uint256 amount)";
    bytes32 public constant _RELAYER_WITNESS_TYPEHASH =
        keccak256(
            "RelayerWitness(address relayer,uint256 msgValue,address refundTo,address nftRecipient,bytes metadata,Call3Value[] call3Values)Call3Value(address target,bool allowFailure,uint256 value,bytes callData)"
        );

    bytes32 public constant _SWEEP_WITH_MINIMUM_TYPEHASH =
        keccak256(
            "SweepWithMinimum(address token,uint256 minAmount,address recipient,bytes32 orderId)"
        );
    bytes32 public constant _TAIL_WITNESS_TYPEHASH =
        keccak256(
            "TailWitness(address relayer,address refundTo,SweepWithMinimum tail)SweepWithMinimum(address token,uint256 minAmount,address recipient,bytes32 orderId)"
        );
    string public constant _TAIL_WITNESS_TYPE_STRING =
        "TailWitness witness)SweepWithMinimum(address token,uint256 minAmount,address recipient,bytes32 orderId)TailWitness(address relayer,address refundTo,SweepWithMinimum tail)TokenPermissions(address token,uint256 amount)";

    /// @notice Holds `_ENTERED` while a guarded function runs. The storage version starts at `_NOT_ENTERED`,
    ///         so that a call changes the slot between two non-zero values.
    bytes32 private constant _GUARD_SLOT =
        bytes32(uint256(keccak256("RelayApprovalProxy.guard")) - 1);
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    /// @notice Refuse every guarded function while one of them runs, so that code called during a
    ///         multicall cannot start another proxy call and act as the proxy on the router
    modifier nonReentrant() {
        if (_load(_GUARD_SLOT) == _ENTERED) {
            revert Reentrancy();
        }
        _store(_GUARD_SLOT, _ENTERED);
        _;
        _store(_GUARD_SLOT, _NOT_ENTERED);
    }

    function _load(bytes32 slot) internal view virtual returns (uint256 value);

    function _store(bytes32 slot, uint256 value) internal virtual;

    receive() external payable {
        if (msg.value > 0) {
            emit FundsMovement(
                msg.sender,
                address(this),
                address(0),
                msg.value,
                ""
            );
        }
    }

    constructor(address _owner, address _router, address _permit2) {
        // `ROUTER` and `PERMIT2` are immutable and `_owner` gates the only
        // rescue function, so a zero argument is unrecoverable post-deploy
        if (
            _owner == address(0) ||
            _router == address(0) ||
            _permit2 == address(0)
        ) {
            revert ConstructorArgCannotBeZeroAddress();
        }

        _initializeOwner(_owner);
        ROUTER = _router;
        PERMIT2 = IPermit2(_permit2);
        _store(_GUARD_SLOT, _NOT_ENTERED);
    }

    /// @notice Allow or remove a depository that a tail with an order id may deposit into, next to `DEPOSITORY`
    /// @dev    The user signs the recipient of a tail, so allowing an address cannot redirect a signed order.
    ///         Removing an address stops the fills of the orders signed for it
    /// @param depository The depository
    /// @param allowed Whether a tail with an order id may deposit into it
    function setDepository(
        address depository,
        bool allowed
    ) external onlyOwner nonReentrant {
        isDepository[depository] = allowed;
        emit DepositoryUpdated(depository, allowed);
    }

    /// @notice Withdraw function in case funds get stuck in contract
    /// @dev    Sends the contract's full balance of `token` to `recipient`.
    ///         Pass `address(0)` as `token` for the native balance. The
    ///         recipient is explicit so the owner does not have to be the
    ///         destination — a hardware wallet or multisig owner can sweep
    ///         straight to a treasury without a second hop, and an owner
    ///         whose key is being rotated can still direct funds elsewhere.
    ///         Neither the zero address nor this contract is accepted.
    /// @param token The token to withdraw, or `address(0)` for native
    /// @param recipient The address to send the funds to
    function withdraw(
        address token,
        address recipient
    ) external onlyOwner nonReentrant {
        // Zero would burn the balance this function exists to rescue, and
        // this contract would leave it in place while `FundsMovement` claimed
        // a recovery — twice over for native, since a value-bearing self-call
        // re-enters `receive()`. A successful withdraw must move funds out.
        if (recipient == address(0) || recipient == address(this)) {
            revert InvalidRecipient(recipient);
        }

        uint256 amount;
        if (token == address(0)) {
            amount = address(this).balance;
            _send(recipient, amount);
        } else {
            amount = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransfer(recipient, amount);
        }

        if (amount > 0) {
            emit FundsMovement(address(this), recipient, token, amount, "");
        }
    }

    /// @notice Transfer tokens to RelayRouter and perform multicall in a single tx
    /// @dev    This contract must be approved to transfer msg.sender's tokens to the RelayRouter. Once the multicall
    ///         has run, whatever balance of `tokens` and whatever native value is left on the router is sent to
    ///         refundTo, exactly as the permit entrypoints do: the router's cleanup functions are permissionless, so
    ///         any residue left there is claimable by the next caller. Only the tokens listed in `tokens` are swept;
    ///         if the multicall leaves other ERC20s on the router (swap output, for instance), include a
    ///         `cleanupErc20s` call for them. If the multicall includes ERC721/ERC1155 mints or transfers, be sure
    ///         to set nftRecipient to the expected recipient.
    /// @param tokens An array of token addresses to transfer
    /// @param amounts An array of token amounts to transfer
    /// @param calls The calls to perform
    /// @param refundTo The address to refund any leftover `tokens` and native value to
    /// @param nftRecipient The address to set as recipient of ERC721/ERC1155 mints
    /// @param metadata Additional data to associate the call to
    function transferAndMulticall(
        address[] calldata tokens,
        uint256[] calldata amounts,
        Call3Value[] calldata calls,
        address refundTo,
        address nftRecipient,
        bytes calldata metadata
    ) external payable nonReentrant returns (Result[] memory returnData) {
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

            if (amounts[i] > 0) {
                emit FundsMovement(
                    msg.sender,
                    ROUTER,
                    tokens[i],
                    amounts[i],
                    metadata
                );
            }
        }

        // Call multicall on the router
        returnData = IRelayRouter(ROUTER).multicall{value: msg.value}(
            calls,
            refundTo,
            nftRecipient,
            metadata
        );

        // Return whatever the multicall left of `tokens` to refundTo. The
        // router already refunded the native balance at the end of
        // `multicall`; ERC20s have no such automatic sweep, and residue left
        // on the router is claimable by anyone through its cleanup functions.
        _cleanupErc20s(tokens, refundTo, metadata);
    }

    /// @notice Use ERC2612 permit to transfer tokens to RelayRouter and execute multicall in a single tx
    /// @dev    Approved spender must be address(this) to transfer user's tokens to the RelayRouter. Once the multicall
    ///         has run, whatever balance of the permitted tokens and whatever native value is left on the router is
    ///         sent to refundTo. If the multicall includes ERC721/ERC1155 mints or transfers, be sure to set
    ///         nftRecipient to the expected recipient.
    /// @param permits An array of permits
    /// @param calls The calls to perform
    /// @param refundTo The address to refund any leftover permitted tokens and native value to
    /// @param nftRecipient The address to set as recipient of ERC721/ERC1155 mints
    /// @param metadata Additional data to associate the call to
    /// @return returnData The return data from the multicall
    function permitTransferAndMulticall(
        Permit2612[] calldata permits,
        Call3Value[] calldata calls,
        address refundTo,
        address nftRecipient,
        bytes calldata metadata
    ) external payable nonReentrant returns (Result[] memory returnData) {
        // Revert if refundTo is zero address
        if (refundTo == address(0)) {
            revert RefundToCannotBeZeroAddress();
        }

        address[] memory tokens = new address[](permits.length);
        for (uint256 i = 0; i < permits.length; i++) {
            Permit2612 memory permit = permits[i];
            tokens[i] = permit.token;

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

            if (permit.value > 0) {
                emit FundsMovement(
                    permit.owner,
                    ROUTER,
                    permit.token,
                    permit.value,
                    metadata
                );
            }
        }

        // Call multicall on the router
        returnData = IRelayRouter(ROUTER).multicall{value: msg.value}(
            calls,
            refundTo,
            nftRecipient,
            metadata
        );

        _cleanupErc20s(tokens, refundTo, metadata);
        IRelayRouter(ROUTER).cleanupNative(0, refundTo, metadata);
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
    ) external payable nonReentrant returns (Result[] memory returnData) {
        // Revert if refundTo is zero address
        if (refundTo == address(0)) {
            revert RefundToCannotBeZeroAddress();
        }

        // If a permit signature is provided, use it to transfer tokens from user to router
        address[] memory tokens;
        if (permitSignature.length != 0) {
            tokens = _handleBatchPermit(
                user,
                metadata,
                permit,
                _getRelayerWitnessHash(
                    refundTo,
                    nftRecipient,
                    metadata,
                    calls
                ),
                _RELAYER_WITNESS_TYPE_STRING,
                permitSignature
            );
        }

        // Call multicall on the router
        returnData = IRelayRouter(ROUTER).multicall{value: msg.value}(
            calls,
            refundTo,
            nftRecipient,
            metadata
        );

        if (permitSignature.length != 0) {
            _cleanupErc20s(tokens, refundTo, metadata);
        }
        IRelayRouter(ROUTER).cleanupNative(0, refundTo, metadata);
    }

    /// @notice Use Permit2 to transfer tokens to RelayRouter, run the relayer's calls, and then run the tail that the
    ///         user signed as the last call. The tail cannot fail: it moves the router's full balance of `tail.token`
    ///         to `tail.recipient`, deposited for `user` under `tail.orderId` unless that is zero, and it reverts the
    ///         whole call below `tail.minAmount`. The permit must hold exactly one token. With an order id, the
    ///         recipient must be `DEPOSITORY` or a depository the owner allowed. Leftover permitted tokens and
    ///         native value go to refundTo.
    /// @dev    The witness binds msg.sender as the relayer, `refundTo` and the tail, but not the relayer's calls.
    /// @param user The address of the user
    /// @param permit The permit details
    /// @param solverCalls The calls to perform before the tail
    /// @param tail The last call, as the user signed it
    /// @param refundTo The address to refund any leftover permitted tokens and native value to
    /// @param metadata Additional data to associate the call to
    /// @param permitSignature The signature for the permit
    /// @return returnData The return data from the multicall, with the tail last
    function permit2TransferAndMulticallWithTail(
        address user,
        ISignatureTransfer.PermitBatchTransferFrom memory permit,
        Call3Value[] calldata solverCalls,
        SweepWithMinimum calldata tail,
        address refundTo,
        bytes calldata metadata,
        bytes memory permitSignature
    ) external nonReentrant returns (Result[] memory returnData) {
        if (
            permit.permitted.length != 1 ||
            refundTo == address(0) ||
            tail.minAmount == 0 ||
            tail.recipient == address(0) ||
            tail.recipient == address(this) ||
            tail.recipient == ROUTER ||
            (tail.orderId != bytes32(0) &&
                tail.recipient != DEPOSITORY &&
                !isDepository[tail.recipient])
        ) {
            revert InvalidTail();
        }

        address[] memory tokens = _handleBatchPermit(
            user,
            metadata,
            permit,
            _getTailWitnessHash(refundTo, tail),
            _TAIL_WITNESS_TYPE_STRING,
            permitSignature
        );

        Call3Value[] memory calls = new Call3Value[](solverCalls.length + 1);
        for (uint256 i = 0; i < solverCalls.length; i++) {
            calls[i] = solverCalls[i];
        }
        calls[solverCalls.length] = Call3Value({
            target: ROUTER,
            allowFailure: false,
            value: 0,
            callData: _getTailCallData(user, tail)
        });

        returnData = IRelayRouter(ROUTER).multicall(
            calls,
            refundTo,
            address(0),
            metadata
        );

        _cleanupErc20s(tokens, refundTo, metadata);
        IRelayRouter(ROUTER).cleanupNative(0, refundTo, metadata);
    }

    /// @notice Use ERC3009 authorizations to transfer tokens to RelayRouter and execute a signed multicall
    /// @dev    The user must sign the MulticallAuthorization typed data in addition to each ERC3009 authorization.
    ///         The typed-data digest is used as each ERC3009 nonce, cryptographically binding the complete ordered
    ///         funding batch to the displayed call targets, values, data, and other execution parameters.
    ///         `msgValue` in the authorization is the exact native value the relayer must attach, so the relayer
    ///         cannot under-fund calls that carry a value and rely on `allowFailure` to swallow the shortfall.
    /// @param permits An array of permits
    /// @param tokens An array of tokens corresponding to the permits
    /// @param calls The calls to perform
    /// @param refundTo The address to refund any leftover `tokens` and native value to
    /// @param nftRecipient The address to set as recipient of ERC721/ERC1155 mints
    /// @param metadata Additional data to associate the call to
    /// @param multicallSignatures The EIP712 signatures over the MulticallAuthorization, corresponding to each permit
    /// @return returnData The return data from the multicall
    function permit3009TransferAndMulticall(
        Permit3009[] calldata permits,
        address[] calldata tokens,
        Call3Value[] calldata calls,
        address refundTo,
        address nftRecipient,
        bytes calldata metadata,
        bytes[] calldata multicallSignatures
    ) external payable nonReentrant returns (Result[] memory returnData) {
        // Revert if array lengths do not match
        if (
            tokens.length != permits.length ||
            multicallSignatures.length != permits.length
        ) {
            revert ArrayLengthsMismatch();
        }

        if (permits.length == 0) {
            revert PermitsCannotBeEmpty();
        }

        // Revert if refundTo is zero address
        if (refundTo == address(0)) {
            revert RefundToCannotBeZeroAddress();
        }

        bytes32 fundingHash = _getFundingHash(permits, tokens);
        for (uint256 i = 0; i < permits.length; i++) {
            _handlePermit3009(
                permits[i],
                tokens[i],
                calls,
                refundTo,
                nftRecipient,
                metadata,
                fundingHash,
                i,
                multicallSignatures[i]
            );
        }

        // Call multicall on the router
        returnData = IRelayRouter(ROUTER).multicall{value: msg.value}(
            calls,
            refundTo,
            nftRecipient,
            metadata
        );

        _cleanupErc20s(tokens, refundTo, metadata);
        IRelayRouter(ROUTER).cleanupNative(0, refundTo, metadata);
    }

    function _handlePermit3009(
        Permit3009 memory permit,
        address token,
        Call3Value[] calldata calls,
        address refundTo,
        address nftRecipient,
        bytes calldata metadata,
        bytes32 fundingHash,
        uint256 fundingIndex,
        bytes calldata multicallSignature
    ) internal {
        bytes32 authorizationDigest = _getMulticallAuthorizationDigest(
            permit.from,
            refundTo,
            nftRecipient,
            metadata,
            calls,
            fundingHash,
            fundingIndex
        );

        // Verify the signature against the owner of the corresponding permit.
        if (
            !permit.from.isValidSignatureNowCalldata(
                authorizationDigest,
                multicallSignature
            )
        ) {
            revert InvalidMulticallSignature();
        }

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));

        // The authorization digest is also the ERC3009 nonce, so this
        // authorization cannot be used with different multicall details.
        IERC3009(token).receiveWithAuthorization(
            permit.from,
            address(this),
            permit.value,
            permit.validAfter,
            permit.validBefore,
            authorizationDigest,
            permit.v,
            permit.r,
            permit.s
        );

        // Forward what actually landed rather than the authorized amount. A
        // fee-on-transfer ERC3009 token delivers less than `permit.value`, and
        // forwarding the authorized amount would revert on the shortfall. The
        // delta is used instead of the full balance so that any unrelated
        // balance already sitting on this contract is left alone.
        uint256 received = IERC20(token).balanceOf(address(this)) -
            balanceBefore;

        if (received > 0) {
            // The forwarding leg can be taxed again by a fee-on-transfer
            // token, so report the router's balance delta rather than the
            // proxy's receipt: downstream consumers size against what the
            // router actually holds.
            uint256 routerBalanceBefore = IERC20(token).balanceOf(ROUTER);
            IERC20(token).safeTransfer(ROUTER, received);
            uint256 delivered = IERC20(token).balanceOf(ROUTER) -
                routerBalanceBefore;

            if (delivered > 0) {
                emit FundsMovement(
                    permit.from,
                    ROUTER,
                    token,
                    delivered,
                    metadata
                );
            }
        }
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

    /// @notice Internal function to hash the complete ordered ERC3009 funding batch
    function _getFundingHash(
        Permit3009[] calldata permits,
        address[] calldata tokens
    ) internal pure returns (bytes32) {
        bytes32[] memory fundingHashes = new bytes32[](permits.length);
        for (uint256 i = 0; i < permits.length; i++) {
            fundingHashes[i] = keccak256(
                abi.encode(
                    _FUNDING_AUTHORIZATION_TYPEHASH,
                    tokens[i],
                    permits[i].from,
                    permits[i].value,
                    permits[i].validAfter,
                    permits[i].validBefore
                )
            );
        }

        return keccak256(abi.encodePacked(fundingHashes));
    }

    /// @notice Internal function to get the EIP712 digest of a multicall authorization
    /// @param user The user authorizing the multicall
    /// @param refundTo The address to refund any leftover native tokens to
    /// @param nftRecipient The nftRecipient address
    /// @param metadata Additional data to associate the call to
    /// @param calls The calls to be executed
    /// @param fundingHash The hash of the complete ordered funding batch
    /// @param fundingIndex The index of the permit within the funding batch
    function _getMulticallAuthorizationDigest(
        address user,
        address refundTo,
        address nftRecipient,
        bytes memory metadata,
        Call3Value[] memory calls,
        bytes32 fundingHash,
        uint256 fundingIndex
    ) internal view returns (bytes32) {
        return
            _hashTypedData(
                keccak256(
                    abi.encode(
                        _MULTICALL_AUTHORIZATION_TYPEHASH,
                        user,
                        msg.sender,
                        msg.value,
                        refundTo,
                        nftRecipient,
                        keccak256(metadata),
                        fundingIndex,
                        _getCallsHash(calls),
                        fundingHash
                    )
                )
            );
    }

    /// @notice Internal function to get the hash of a relayer witness
    /// @param refundTo The address to refund any leftover native tokens to
    /// @param nftRecipient The nftRecipient address
    /// @param metadata Additional data to associate the call to
    /// @param calls The calls to be executed
    /// @dev   Binds `msg.value` so the relayer cannot under-fund value-carrying calls
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
                    msg.value,
                    refundTo,
                    nftRecipient,
                    keccak256(metadata),
                    _getCallsHash(calls)
                )
            );
    }

    /// @notice Internal function to get the hash of a tail witness
    /// @param refundTo The address to refund any leftover tokens to
    /// @param tail The last call of the multicall
    function _getTailWitnessHash(
        address refundTo,
        SweepWithMinimum calldata tail
    ) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    _TAIL_WITNESS_TYPEHASH,
                    msg.sender,
                    refundTo,
                    keccak256(
                        abi.encode(
                            _SWEEP_WITH_MINIMUM_TYPEHASH,
                            tail.token,
                            tail.minAmount,
                            tail.recipient,
                            tail.orderId
                        )
                    )
                )
            );
    }

    /// @notice Internal function to build the router call of a tail
    /// @param user The depositor of a deposit
    /// @param tail The last call of the multicall
    function _getTailCallData(
        address user,
        SweepWithMinimum calldata tail
    ) internal pure returns (bytes memory) {
        bool deposit = tail.orderId != bytes32(0);
        if (tail.token == address(0)) {
            return
                abi.encodeCall(
                    IRelayRouter.sweepNativeWithMinimum,
                    (
                        tail.minAmount,
                        tail.recipient,
                        deposit
                            ? abi.encodeCall(
                                IRelayDepository.depositNative,
                                (user, tail.orderId)
                            )
                            : bytes("")
                    )
                );
        }
        return
            abi.encodeCall(
                IRelayRouter.sweepWithMinimum,
                (
                    tail.token,
                    tail.minAmount,
                    tail.recipient,
                    deposit
                        ? abi.encodeCall(
                            IRelayDepository.depositErc20,
                            (user, tail.token, tail.orderId)
                        )
                        : bytes("")
                )
            );
    }

    /// @notice Internal function to handle a permit batch transfer
    /// @param user The address of the user
    /// @param metadata Additional data to associate the call to
    /// @param permit The permit details
    /// @param witness The hash of the witness the user signed
    /// @param witnessTypeString The Permit2 witness type string of `witness`
    /// @param permitSignature The signature for the permit
    function _handleBatchPermit(
        address user,
        bytes calldata metadata,
        ISignatureTransfer.PermitBatchTransferFrom memory permit,
        bytes32 witness,
        string memory witnessTypeString,
        bytes memory permitSignature
    ) internal returns (address[] memory tokens) {
        // Create the SignatureTransferDetails array
        ISignatureTransfer.SignatureTransferDetails[]
            memory signatureTransferDetails = new ISignatureTransfer.SignatureTransferDetails[](
                permit.permitted.length
            );
        tokens = new address[](permit.permitted.length);
        for (uint256 i = 0; i < permit.permitted.length; i++) {
            uint256 amount = permit.permitted[i].amount;
            tokens[i] = permit.permitted[i].token;

            signatureTransferDetails[i] = ISignatureTransfer
                .SignatureTransferDetails({
                    to: address(ROUTER),
                    requestedAmount: amount
                });

            if (amount > 0) {
                emit FundsMovement(
                    user,
                    ROUTER,
                    permit.permitted[i].token,
                    amount,
                    metadata
                );
            }
        }

        // Use the SignatureTransferDetails and permit signature to transfer tokens to the router
        PERMIT2.permitWitnessTransferFrom(
            permit,
            signatureTransferDetails,
            // When using a permit signature, cannot deposit on behalf of someone else other than `user`
            user,
            witness,
            witnessTypeString,
            permitSignature
        );
    }

    function _cleanupErc20s(
        address[] memory tokens,
        address refundTo,
        bytes memory metadata
    ) internal {
        address[] memory recipients = new address[](tokens.length);
        uint256[] memory amounts = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            recipients[i] = refundTo;
        }

        IRelayRouter(ROUTER).cleanupErc20s(
            tokens,
            recipients,
            amounts,
            metadata
        );
    }

    function _domainNameAndVersion()
        internal
        pure
        override
        returns (string memory name, string memory version)
    {
        name = "RelayApprovalProxy";
        version = VERSION;
    }

    function _send(address to, uint256 value) internal {
        bool success;
        assembly {
            // Save gas by avoiding copying the return data to memory.
            // All remaining gas is forwarded: `_send` is only reachable from
            // `withdraw`, which is `onlyOwner`, and the owner-chosen recipient
            // may be a multisig or smart contract wallet whose receive hook
            // exceeds a fixed stipend. Capping it would strand the balance.
            success := call(gas(), to, value, 0, 0, 0, 0)
        }

        if (!success) {
            revert NativeTransferFailed();
        }
    }
}
