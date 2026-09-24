// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, Vm} from "forge-std/Test.sol";

import {Call3Value} from "../src/common/Multicall3.sol";
import {IRelayRouter} from "../src/interfaces/IRelayRouter.sol";
import {RelayRouter} from "../src/RelayRouter.sol";
import {RelayRouter_NonTstore} from "../src/RelayRouter_NonTstore.sol";

/// @notice A target that accepts any calldata, so the router has something
///         real to call and the emitted hash can be checked against what was
///         sent
contract Sink {
    uint256 public hits;

    fallback() external payable {
        hits++;
    }

    receive() external payable {
        hits++;
    }
}

/// @notice A target that always reverts, for the allowFailure path
contract Reverter {
    fallback() external payable {
        revert("nope");
    }
}

/// @title  SolverCallExecuted carries a calldata hash
/// @notice The router used to copy every solver call's calldata into the
///         event, 8 gas per byte of log data for bytes the order already
///         committed to. It now emits `keccak256(callData)`; the oracle checks
///         that against the calldata it holds from the order.
contract SolverCallExecutedHashTest is Test {
    event SolverCallExecuted(address to, bytes32 dataHash, uint256 amount);

    address alice = address(0xA11CE);
    Sink sink;

    function setUp() public {
        sink = new Sink();
        vm.deal(alice, 10 ether);
    }

    function test_emitsHashOfCalldata_tstore() public {
        _emitsHash(address(new RelayRouter()));
    }

    function test_emitsHashOfCalldata_nonTstore() public {
        _emitsHash(address(new RelayRouter_NonTstore()));
    }

    function test_emitsHashPerCallInOrder_tstore() public {
        _emitsInOrder(address(new RelayRouter()));
    }

    function test_emitsHashPerCallInOrder_nonTstore() public {
        _emitsInOrder(address(new RelayRouter_NonTstore()));
    }

    /// @notice The event's data is three words whatever the calldata length:
    ///         no length word, no padded bytes
    function test_logDataIsThreeWords_tstore() public {
        _logDataIsThreeWords(address(new RelayRouter()));
    }

    function test_logDataIsThreeWords_nonTstore() public {
        _logDataIsThreeWords(address(new RelayRouter_NonTstore()));
    }

    /// @notice Empty calldata hashes to keccak256("") and still emits
    function test_emptyCalldata_tstore() public {
        _emitsHashOfEmptyCalldata(address(new RelayRouter()));
    }

    function test_emptyCalldata_nonTstore() public {
        _emitsHashOfEmptyCalldata(address(new RelayRouter_NonTstore()));
    }

    /// @notice A call that fails under allowFailure emits nothing
    function test_failedCallEmitsNothing_tstore() public {
        _failedCallEmitsNothing(address(new RelayRouter()));
    }

    function test_failedCallEmitsNothing_nonTstore() public {
        _failedCallEmitsNothing(address(new RelayRouter_NonTstore()));
    }

    /// @notice Both routers report the version that ships the hashed event
    function test_version() public {
        assertEq(new RelayRouter().VERSION(), "3.2");
        assertEq(new RelayRouter_NonTstore().VERSION(), "3.2");
    }

    function _emitsHashOfEmptyCalldata(address router) internal {
        vm.expectEmit(false, false, false, true, router);
        emit SolverCallExecuted(address(sink), keccak256(""), 0);
        vm.prank(alice);
        IRelayRouter(router).multicall(_calls("", 0), alice, address(0), "");
        assertEq(sink.hits(), 1);
    }

    function _failedCallEmitsNothing(address router) internal {
        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = Call3Value({target: address(new Reverter()), allowFailure: true, value: 0, callData: hex"01"});

        vm.recordLogs();
        vm.prank(alice);
        IRelayRouter(router).multicall(calls, alice, address(0), "");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic = keccak256("SolverCallExecuted(address,bytes32,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != topic, "failed call must not emit SolverCallExecuted");
        }
    }

    function _logDataIsThreeWords(address router) internal {
        bytes memory big = new bytes(5000);
        for (uint256 i = 0; i < big.length; i++) {
            big[i] = bytes1(uint8(i));
        }

        vm.recordLogs();
        vm.prank(alice);
        IRelayRouter(router).multicall(_calls(big, 0), alice, address(0), "");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic = keccak256("SolverCallExecuted(address,bytes32,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) {
                found = true;
                assertEq(logs[i].data.length, 96);
                (address to, bytes32 dataHash, uint256 amount) = abi.decode(logs[i].data, (address, bytes32, uint256));
                assertEq(to, address(sink));
                assertEq(dataHash, keccak256(big));
                assertEq(amount, 0);
            }
        }
        assertTrue(found);
    }

    function _calls(bytes memory data, uint256 value) internal view returns (Call3Value[] memory calls) {
        calls = new Call3Value[](1);
        calls[0] = Call3Value({target: address(sink), allowFailure: false, value: value, callData: data});
    }

    function _emitsHash(address router) internal {
        bytes memory data = hex"deadbeef00112233";
        vm.expectEmit(false, false, false, true, router);
        emit SolverCallExecuted(address(sink), keccak256(data), 1 ether);
        vm.prank(alice);
        IRelayRouter(router).multicall{value: 1 ether}(_calls(data, 1 ether), alice, address(0), "");
        assertEq(sink.hits(), 1);
    }

    function _emitsInOrder(address router) internal {
        Call3Value[] memory calls = new Call3Value[](2);
        calls[0] = Call3Value({target: address(sink), allowFailure: false, value: 0, callData: hex"01"});
        calls[1] = Call3Value({target: address(sink), allowFailure: false, value: 0, callData: hex"0202"});
        vm.expectEmit(false, false, false, true, router);
        emit SolverCallExecuted(address(sink), keccak256(hex"01"), 0);
        vm.expectEmit(false, false, false, true, router);
        emit SolverCallExecuted(address(sink), keccak256(hex"0202"), 0);
        vm.prank(alice);
        IRelayRouter(router).multicall(calls, alice, address(0), "");
        assertEq(sink.hits(), 2);
    }
}
