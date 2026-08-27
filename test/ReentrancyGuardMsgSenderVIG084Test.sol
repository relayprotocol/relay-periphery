// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";

import {Call3Value} from "../src/common/Multicall3.sol";
import {RelayApprovalProxy} from "../src/RelayApprovalProxy.sol";
import {RelayRouter} from "../src/RelayRouter.sol";
import {RelayRouter_NonTstore} from "../src/RelayRouter_NonTstore.sol";

interface IVIG084Router {
    function cleanupNative(uint256 amount, address recipient, bytes calldata metadata) external;
}

/// @dev Re-enters the router through the shared ApprovalProxy sender, then
///      restores the ETH it received from the outer multicall to the router.
contract VIG084NestedApprovalProxyCall {
    RelayApprovalProxy private immutable APPROVAL_PROXY;
    address private immutable ROUTER;
    address private immutable REFUND_TO;

    constructor(RelayApprovalProxy approvalProxy, address router, address refundTo) {
        APPROVAL_PROXY = approvalProxy;
        ROUTER = router;
        REFUND_TO = refundTo;
    }

    function reenter() external payable {
        address[] memory tokens = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        Call3Value[] memory calls = new Call3Value[](0);

        APPROVAL_PROXY.transferAndMulticall(tokens, amounts, calls, REFUND_TO, address(0), "");

        // Make funds available after the nested multicall has returned. They
        // must remain protected by the still-active outer guard frame.
        (bool success,) = ROUTER.call{value: address(this).balance}("");
        require(success);
    }
}

/// @dev Attempts to enter a guarded cleanup function from a sender other than
///      the ApprovalProxy while its outer multicall is still executing.
contract VIG084UnrelatedReentrantCaller {
    address private immutable ROUTER;
    address private immutable RECIPIENT;

    bool public cleanupSucceeded;

    constructor(address router, address recipient) {
        ROUTER = router;
        RECIPIENT = recipient;
    }

    function tryCleanup() external {
        (cleanupSucceeded,) = ROUTER.call(abi.encodeCall(IVIG084Router.cleanupNative, (0, RECIPIENT, bytes(""))));
    }
}

contract ReentrancyGuardMsgSenderVIG084Test is Test {
    function test_nestedApprovalProxyCallDoesNotClearTransientGuard() public {
        _assertNestedCallDoesNotClearGuard(address(new RelayRouter()));
    }

    function test_nestedApprovalProxyCallDoesNotClearStorageGuard() public {
        _assertNestedCallDoesNotClearGuard(address(new RelayRouter_NonTstore()));
    }

    function _assertNestedCallDoesNotClearGuard(address router) private {
        // Permit2 is unused on this path but must be non-zero.
        RelayApprovalProxy approvalProxy =
            new RelayApprovalProxy(address(this), router, makeAddr("permit2"));

        address refundTo = makeAddr("refundTo");
        address attemptedRecipient = makeAddr("attemptedRecipient");
        VIG084NestedApprovalProxyCall nestedCaller = new VIG084NestedApprovalProxyCall(approvalProxy, router, refundTo);
        VIG084UnrelatedReentrantCaller unrelatedCaller = new VIG084UnrelatedReentrantCaller(router, attemptedRecipient);

        Call3Value[] memory calls = new Call3Value[](2);
        calls[0] = Call3Value({
            target: address(nestedCaller),
            allowFailure: false,
            value: 1 ether,
            callData: abi.encodeCall(nestedCaller.reenter, ())
        });
        calls[1] = Call3Value({
            target: address(unrelatedCaller),
            allowFailure: false,
            value: 0,
            callData: abi.encodeCall(unrelatedCaller.tryCleanup, ())
        });

        address[] memory tokens = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        vm.deal(address(this), 2 ether);

        approvalProxy.transferAndMulticall{value: 2 ether}(tokens, amounts, calls, refundTo, address(0), "");

        assertFalse(unrelatedCaller.cleanupSucceeded(), "nested call cleared the outer reentrancy guard");
        assertEq(attemptedRecipient.balance, 0);
        assertEq(refundTo.balance, 2 ether);
        assertEq(router.balance, 0);

        // The outermost frame must still clear the guard on normal exit.
        vm.deal(router, 1 ether);
        vm.prank(attemptedRecipient);
        IVIG084Router(router).cleanupNative(0, attemptedRecipient, bytes(""));
        assertEq(attemptedRecipient.balance, 1 ether);
    }
}
