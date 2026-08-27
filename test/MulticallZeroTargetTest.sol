// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";

import {Call3Value} from "../src/common/Multicall3.sol";
import {RelayRouter} from "../src/RelayRouter.sol";
import {RelayRouter_NonTstore} from "../src/RelayRouter_NonTstore.sol";

interface IZeroTargetRouter {
    function multicall(
        Call3Value[] calldata calls,
        address refundTo,
        address nftRecipient,
        bytes calldata metadata
    ) external payable;
}

/// @title  Zero-target call rejection (VIG-RP-097)
/// @notice A `CALL` to `address(0)` returns success on the EVM and permanently
///         burns any value forwarded with it, while `SolverCallExecuted` would
///         report it as a successful call. `_aggregate3Value` performed no
///         target validation, so a malformed `calls` entry silently destroyed
///         native tokens and left a log line claiming it had worked.
contract MulticallZeroTargetTest is Test {
    error InvalidTarget(address target);

    address alice = address(0xA11CE);

    function test_zeroTargetWithValueReverts_tstore() public {
        _revertsWithValue(address(new RelayRouter()));
    }

    function test_zeroTargetWithValueReverts_nonTstore() public {
        _revertsWithValue(address(new RelayRouter_NonTstore()));
    }

    /// @notice Rejected even with no value attached: the call would still
    ///         report success and emit an event for something that did nothing.
    function test_zeroTargetWithoutValueReverts_tstore() public {
        _revertsWithoutValue(address(new RelayRouter()));
    }

    function test_zeroTargetWithoutValueReverts_nonTstore() public {
        _revertsWithoutValue(address(new RelayRouter_NonTstore()));
    }

    /// @notice `allowFailure` must not turn the rejection into a swallowed
    ///         no-op, which would put the burn back.
    function test_zeroTargetRejectedDespiteAllowFailure_tstore() public {
        _revertsAllowFailure(address(new RelayRouter()));
    }

    function test_zeroTargetRejectedDespiteAllowFailure_nonTstore() public {
        _revertsAllowFailure(address(new RelayRouter_NonTstore()));
    }

    function _call(
        bool allowFailure,
        uint256 value
    ) internal pure returns (Call3Value[] memory calls) {
        calls = new Call3Value[](1);
        calls[0] = Call3Value({
            target: address(0),
            allowFailure: allowFailure,
            value: value,
            callData: ""
        });
    }

    function _revertsWithValue(address router) internal {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(InvalidTarget.selector, address(0))
        );
        IZeroTargetRouter(router).multicall{value: 1 ether}(
            _call(false, 1 ether),
            alice,
            address(0),
            ""
        );

        assertEq(alice.balance, 1 ether, "value should not have moved");
    }

    function _revertsWithoutValue(address router) internal {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(InvalidTarget.selector, address(0))
        );
        IZeroTargetRouter(router).multicall(_call(false, 0), alice, address(0), "");
    }

    function _revertsAllowFailure(address router) internal {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(InvalidTarget.selector, address(0))
        );
        IZeroTargetRouter(router).multicall{value: 1 ether}(
            _call(true, 1 ether),
            alice,
            address(0),
            ""
        );

        assertEq(alice.balance, 1 ether, "value should not have moved");
    }
}
