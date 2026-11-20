// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {ISignatureTransfer} from "permit2-relay/src/interfaces/ISignatureTransfer.sol";
import {RelayApprovalProxyBase} from "../../src/RelayApprovalProxyBase.sol";
import {Call3Value} from "../../src/common/Multicall3.sol";
import {LimitOrderTailCode} from "./LimitOrderTailCode.sol";

interface IVmTypedData {
    function eip712HashTypedData(string calldata jsonData) external pure returns (bytes32 digest);
}

interface ITailMulticaller {
    function aggregate(address[] calldata targets, bytes[] calldata data, uint256[] calldata values, address refundTo)
        external
        payable
        returns (bytes[] memory);
}

/// @dev Etches Relay's Base contracts at their Base addresses. A contract of its own, so that the runtime code it
/// carries does not count against the size of the contracts that use it
contract TailEtcher is Test {
    function etch() external {
        vm.chainId(8453);
        vm.etch(LimitOrderTailCode.PERMIT2, LimitOrderTailCode.PERMIT2_RUNTIME);
        vm.etch(LimitOrderTailCode.DEPOSITORY, LimitOrderTailCode.DEPOSITORY_RUNTIME);
        vm.etch(LimitOrderTailCode.MULTICALLER, LimitOrderTailCode.MULTICALLER_RUNTIME);
        // solady's Ownable keeps the owner in this slot
        vm.store(
            LimitOrderTailCode.MULTICALLER,
            bytes32(uint256(0xffffffffffffffffffffffffffffffffffffffffffffffffffffffff74873927)),
            bytes32(uint256(uint160(LimitOrderTailCode.MULTICALLER_OWNER)))
        );
    }
}

/// @dev What the handler and the reproduction tests share: the digests a user signs, computed with
/// vm.eip712HashTypedData from the JSON typed data and not from the contract's typehash constants, and the tail's
/// router call built from the signed fields
abstract contract TailTyped is Test {
    address internal constant PERMIT2 = LimitOrderTailCode.PERMIT2;
    address internal constant DEPOSITORY = LimitOrderTailCode.DEPOSITORY;
    address internal constant MULTICALLER = LimitOrderTailCode.MULTICALLER;
    address internal constant MULTICALLER_OWNER = LimitOrderTailCode.MULTICALLER_OWNER;

    bytes internal constant META = "limit-order-tail";

    bytes32 internal constant ERC20_DEPOSIT = keccak256("RelayErc20Deposit(address,address,uint256,bytes32)");
    bytes32 internal constant NATIVE_DEPOSIT = keccak256("RelayNativeDeposit(address,uint256,bytes32)");
    bytes32 internal constant SOLVER_CALL_EXECUTED = keccak256("SolverCallExecuted(address,bytes32,uint256)");
    bytes32 internal constant FUNDS_MOVEMENT = keccak256("FundsMovement(address,address,address,uint256,bytes)");
    bytes32 internal constant TAIL_STARTS = keccak256("TailStarts()");

    bytes32 internal constant PROXY_GUARD_SLOT = bytes32(uint256(keccak256("RelayApprovalProxy.guard")) - 1);
    bytes32 internal constant ROUTER_CONTEXT_SLOT = bytes32(uint256(keccak256("RelayRouterV4.context")) - 1);
    bytes32 internal constant ROUTER_RECIPIENT_SLOT = bytes32(uint256(keccak256("RelayRouterV4.recipient")) - 1);

    string internal constant DOMAIN_TYPE =
        '"EIP712Domain":[{"name":"name","type":"string"},{"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}]';
    string internal constant BATCH_TYPE =
        '"PermitBatchWitnessTransferFrom":[{"name":"permitted","type":"TokenPermissions[]"},{"name":"spender","type":"address"},{"name":"nonce","type":"uint256"},{"name":"deadline","type":"uint256"},{"name":"witness","type":"';
    string internal constant TOKEN_PERMISSIONS_TYPE =
        '"TokenPermissions":[{"name":"token","type":"address"},{"name":"amount","type":"uint256"}]';
    string internal constant TAIL_TYPES =
        '"TailWitness":[{"name":"relayer","type":"address"},{"name":"refundTo","type":"address"},{"name":"tail","type":"SweepWithMinimum"}],"SweepWithMinimum":[{"name":"token","type":"address"},{"name":"minAmount","type":"uint256"},{"name":"recipient","type":"address"},{"name":"orderId","type":"bytes32"}]';
    string internal constant RELAYER_TYPES =
        '"RelayerWitness":[{"name":"relayer","type":"address"},{"name":"msgValue","type":"uint256"},{"name":"refundTo","type":"address"},{"name":"nftRecipient","type":"address"},{"name":"metadata","type":"bytes"},{"name":"call3Values","type":"Call3Value[]"}],"Call3Value":[{"name":"target","type":"address"},{"name":"allowFailure","type":"bool"},{"name":"value","type":"uint256"},{"name":"callData","type":"bytes"}]';

    /// @notice The digest Permit2 checks for a tail fill with these fields
    function _tailDigest(
        ISignatureTransfer.PermitBatchTransferFrom memory permit,
        address spender,
        address relayer,
        address refundTo,
        RelayApprovalProxyBase.SweepWithMinimum memory tail
    ) internal view returns (bytes32) {
        string memory witness = string.concat(
            '{"relayer":"',
            vm.toString(relayer),
            '","refundTo":"',
            vm.toString(refundTo),
            '","tail":{"token":"',
            vm.toString(tail.token),
            '","minAmount":"',
            vm.toString(tail.minAmount),
            '","recipient":"',
            vm.toString(tail.recipient),
            '","orderId":"',
            vm.toString(tail.orderId),
            '"}}'
        );
        return _typedData("TailWitness", TAIL_TYPES, permit, spender, witness);
    }

    /// @notice The digest Permit2 checks for a permit2TransferAndMulticall fill with these fields
    function _relayerDigest(
        ISignatureTransfer.PermitBatchTransferFrom memory permit,
        address spender,
        address relayer,
        address refundTo,
        Call3Value[] memory calls
    ) internal view returns (bytes32) {
        string memory list = "[";
        for (uint256 i; i < calls.length; ++i) {
            list = string.concat(
                list,
                i == 0 ? "" : ",",
                '{"target":"',
                vm.toString(calls[i].target),
                '","allowFailure":',
                calls[i].allowFailure ? "true" : "false",
                ',"value":"',
                vm.toString(calls[i].value),
                '","callData":"',
                vm.toString(calls[i].callData),
                '"}'
            );
        }
        string memory witness = string.concat(
            '{"relayer":"',
            vm.toString(relayer),
            '","msgValue":"0","refundTo":"',
            vm.toString(refundTo),
            '","nftRecipient":"',
            vm.toString(address(0)),
            '","metadata":"',
            vm.toString(META),
            '","call3Values":',
            list,
            "]}"
        );
        return _typedData("RelayerWitness", RELAYER_TYPES, permit, spender, witness);
    }

    function _typedData(
        string memory witnessType,
        string memory witnessTypes,
        ISignatureTransfer.PermitBatchTransferFrom memory permit,
        address spender,
        string memory witness
    ) internal view returns (bytes32) {
        string memory permitted = "[";
        for (uint256 i; i < permit.permitted.length; ++i) {
            permitted = string.concat(
                permitted,
                i == 0 ? "" : ",",
                '{"token":"',
                vm.toString(permit.permitted[i].token),
                '","amount":"',
                vm.toString(permit.permitted[i].amount),
                '"}'
            );
        }
        string memory json = string.concat(
            '{"types":{',
            DOMAIN_TYPE,
            ",",
            BATCH_TYPE,
            witnessType,
            '"}],',
            TOKEN_PERMISSIONS_TYPE,
            ",",
            witnessTypes,
            '},"primaryType":"PermitBatchWitnessTransferFrom","domain":{"name":"Permit2","chainId":"',
            vm.toString(block.chainid),
            '","verifyingContract":"',
            vm.toString(PERMIT2),
            '"},"message":{"permitted":',
            permitted,
            '],"spender":"',
            vm.toString(spender),
            '","nonce":"',
            vm.toString(permit.nonce),
            '","deadline":"',
            vm.toString(permit.deadline),
            '","witness":',
            witness,
            "}}"
        );
        return IVmTypedData(address(vm)).eip712HashTypedData(json);
    }

    function _signDigest(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @notice The router call of a tail, built from the signed fields with the function signatures written out
    function _tailCalldata(address user, RelayApprovalProxyBase.SweepWithMinimum memory tail)
        internal
        pure
        returns (bytes memory)
    {
        bool deposit = tail.orderId != bytes32(0);
        if (tail.token == address(0)) {
            return abi.encodeWithSignature(
                "sweepNativeWithMinimum(uint256,address,bytes)",
                tail.minAmount,
                tail.recipient,
                deposit ? abi.encodeWithSignature("depositNative(address,bytes32)", user, tail.orderId) : bytes("")
            );
        }
        return abi.encodeWithSignature(
            "sweepWithMinimum(address,uint256,address,bytes)",
            tail.token,
            tail.minAmount,
            tail.recipient,
            deposit
                ? abi.encodeWithSignature("depositErc20(address,address,bytes32)", user, tail.token, tail.orderId)
                : bytes("")
        );
    }

    /// @notice Submits `data` to `target` as Relay does: the multicaller's owner calls `aggregate`
    function _viaMulticaller(address target, bytes memory data) internal returns (bool ok, bytes memory ret) {
        address[] memory targets = new address[](1);
        targets[0] = target;
        bytes[] memory datas = new bytes[](1);
        datas[0] = data;
        bytes memory call = abi.encodeCall(ITailMulticaller.aggregate, (targets, datas, new uint256[](1), address(1)));
        vm.prank(MULTICALLER_OWNER);
        (ok, ret) = MULTICALLER.call(call);
        if (ok) ret = abi.decode(ret, (bytes[]))[0];
    }
}
