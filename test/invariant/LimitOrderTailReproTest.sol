// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Vm} from "forge-std/Vm.sol";
import {ISignatureTransfer} from "permit2-relay/src/interfaces/ISignatureTransfer.sol";
import {RelayRouter} from "../../src/RelayRouter.sol";
import {RelayRouterBase} from "../../src/RelayRouterBase.sol";
import {RelayApprovalProxy} from "../../src/RelayApprovalProxy.sol";
import {RelayApprovalProxyBase} from "../../src/RelayApprovalProxyBase.sol";
import {Call3Value} from "../../src/common/Multicall3.sol";
import {TailEtcher, TailTyped} from "./LimitOrderTailBase.sol";
import {
    TailToken,
    Attempt,
    TailHookTarget,
    TailVenue,
    TailCalloutRecipient,
    TailHalfPullingRecipient,
    TailProbe,
    STANDARD,
    FEE_ON_TRANSFER,
    ROUNDS_DOWN,
    HOOK
} from "./LimitOrderTailActors.sol";

/// @notice One test per class of invariant failure the suite finds on the current contracts, with fixed inputs and
///         the numbers in its message. These tests assert the invariant, so they fail until the contract (or the
///         invariant) changes. The test_fixedBy83_* tests were such reproductions on #82; #83 (a tail with an
///         orderId deposits only into a known depository) fixed them, and they now assert the refusal. The test_knownLimit_* tests assert today's behaviour for the tokens T2 leaves to the
///         solver (fee on transfer, rounding down); they pass now and fail when the contract starts to measure at
///         the recipient.
/// @dev Same world as the invariant suite: Relay's Permit2, depository and multicaller from their Base runtime code,
///      chain id 8453, a fresh user key, and the multicaller's owner submitting through `aggregate`.
contract LimitOrderTailReproTest is TailTyped {
    bytes32 internal constant ORDER_ID = keccak256("limit-order-tail repro order");

    RelayRouter internal router;
    RelayApprovalProxy internal proxy;
    TailToken internal std;
    TailToken internal out;
    TailToken internal fee;
    TailToken internal rounding;
    TailToken internal hook;
    TailVenue internal venue;
    TailHookTarget internal hookTarget;
    TailCalloutRecipient internal callout;
    TailHalfPullingRecipient internal halfPull;
    TailProbe internal probe;
    address internal user;
    uint256 internal userKey;
    address internal recipient;
    address internal noCode;
    address internal thief;
    uint256 internal nonce;
    Attempt[] internal attemptList;

    struct Outcome {
        bool ok;
        bytes ret;
        uint256 B;
        uint256 recipientDelta;
        uint256 depositLogs;
        address logEmitter;
        uint256 logAmount;
        Vm.AccountAccess[] acc; // the submission's calls, those of reverted frames included
    }

    function setUp() public {
        new TailEtcher().etch();
        router = new RelayRouter();
        proxy = new RelayApprovalProxy(address(this), address(router), PERMIT2);
        proxy.setDepository(DEPOSITORY, true);
        (user, userKey) = makeAddrAndKey("limit-order-tail repro user");
        recipient = makeAddr("limit-order-tail repro recipient");
        thief = makeAddr("limit-order-tail repro thief");
        noCode = address(uint160(uint256(keccak256("limit-order-tail repro address without code"))));
        std = new TailToken(STANDARD, "STD");
        out = new TailToken(STANDARD, "OUT");
        fee = new TailToken(FEE_ON_TRANSFER, "FEE");
        rounding = new TailToken(ROUNDS_DOWN, "ROUND");
        hook = new TailToken(HOOK, "HOOK");
        venue = new TailVenue();
        hookTarget = new TailHookTarget();
        hook.setHook(address(hookTarget));
        callout = new TailCalloutRecipient();
        halfPull = new TailHalfPullingRecipient();
        probe = new TailProbe();
        std.mint(user, 1e30);
        vm.prank(user);
        std.approve(PERMIT2, type(uint256).max);
        TailToken[4] memory outputs = [out, fee, rounding, hook];
        for (uint256 i; i < outputs.length; ++i) {
            outputs[i].mint(address(venue), 1e30);
        }
        vm.deal(address(venue), 1e30);
        assertEq(user.code.length, 0);
    }

    // ================================================================ fixed by #83: a tail with an orderId deposits only
    // into a known depository. These were reproductions of T2.1 and T2.2 failures on #82; they now assert the refusal

    /// @notice Was test_T2_1_halfPullingRecipientGetsHalfOfB and test_T2_2_halfPullingRecipientLogsHalfOfB (one
    ///         scenario): on #82 a recipient that pulls half its allowance got 50 of B 100 and logged 50, and the
    ///         other 50 stayed on the router for anyone. #83 refuses the tail before anything moves
    function test_fixedBy83_halfPullingRecipientWithAnOrderIdIsRefused() public {
        _assertRefusedWithInvalidTail(
            _swap(100, address(out), 100), _tail(address(out), 50, address(halfPull), ORDER_ID)
        );
    }

    /// @notice Was test_T2_2_nativeDepositToAnAddressWithoutCode: on #82 the fill succeeded, the address got 100 wei
    ///         and there was no deposit log
    function test_fixedBy83_nativeTailWithAnOrderIdToAnAddressWithoutCodeIsRefused() public {
        _assertRefusedWithInvalidTail(_swap(100, address(0), 100), _tail(address(0), 100, noCode, ORDER_ID));
    }

    /// @notice Was test_T2_2_nativeDepositToAContractThatIsNotADepository: on #82 its fallback kept 100 wei and
    ///         the depositNative calldata, and nothing was logged
    function test_fixedBy83_nativeTailWithAnOrderIdToAContractThatIsNotADepositoryIsRefused() public {
        _assertRefusedWithInvalidTail(_swap(100, address(0), 100), _tail(address(0), 100, address(callout), ORDER_ID));
    }

    /// @notice On #82 a recipient that is not a depository kept 100 wei and called the depository during the
    ///         tail. It never runs now
    function test_fixedBy83_nonDepositoryRecipientWithAnOrderIdIsRefusedBeforeItCanLog() public {
        Attempt[] memory attempts = new Attempt[](1);
        attempts[0] = Attempt(DEPOSITORY, abi.encodeWithSignature("depositNative(address,bytes32)", user, ORDER_ID));
        _setAttempts(attempts);
        Outcome memory o = _assertRefusedWithInvalidTail(
            _swap(100, address(0), 100), _tail(address(0), 100, address(callout), ORDER_ID)
        );
        assertFalse(_called(o.acc, address(callout)), "the recipient never ran");
    }

    // ================================================================ reproductions: these fail on the current contracts

    /// @notice T2.2: a tail token whose transferFrom calls out can add a depository log of its own to the tail:
    ///         the depository pulls the token, and the hook calls depositNative(user, orderId)
    function test_T2_2_hookTokenAddsASecondDepositoryLog() public {
        Attempt[] memory attempts = new Attempt[](1);
        attempts[0] = Attempt(DEPOSITORY, abi.encodeWithSignature("depositNative(address,bytes32)", user, ORDER_ID));
        _setAttempts(attempts);
        Outcome memory o =
            _fill(100, _swap(100, address(hook), 100), _tail(address(hook), 100, DEPOSITORY, ORDER_ID), user);
        assertTrue(o.ok, "the fill should succeed");
        assertEq(o.recipientDelta, 100);
        assertEq(
            o.depositLogs,
            1,
            string.concat(
                "T2.2: the tail made ",
                vm.toString(o.depositLogs),
                " depository logs, B 100, minAmount 100, fill succeeded"
            )
        );
    }

    /// @notice T2.3: a same-chain native tail to a recipient that calls out: the recipient calls depositNative when
    ///         it gets the value, and the tail of an order without an orderId has a depository log
    function test_T2_3_recipientDepositsDuringATailWithoutOrderId() public {
        Attempt[] memory attempts = new Attempt[](1);
        attempts[0] = Attempt(DEPOSITORY, abi.encodeWithSignature("depositNative(address,bytes32)", user, ORDER_ID));
        _setAttempts(attempts);
        Outcome memory o =
            _fill(100, _swap(100, address(0), 100), _tail(address(0), 100, address(callout), bytes32(0)), user);
        assertTrue(o.ok, "the fill should succeed");
        assertEq(
            o.depositLogs,
            0,
            string.concat(
                "T2.3: the tail made ", vm.toString(o.depositLogs), " depository logs, orderId 0, B 100, fill succeeded"
            )
        );
    }

    /// @notice T1.2: a solver call sends router-held tail.token to the proxy in a fill that succeeds
    function test_T1_2_aSolverCallSendsValueToTheProxy() public {
        Call3Value[] memory calls = new Call3Value[](3);
        Call3Value[] memory swap = _swap(100, address(out), 100);
        calls[0] = swap[0];
        calls[1] = swap[1];
        calls[2] =
            Call3Value(address(out), false, 0, abi.encodeWithSignature("transfer(address,uint256)", address(proxy), 1));
        Outcome memory o = _fill(100, calls, _tail(address(out), 99, recipient, bytes32(0)), user);
        assertTrue(o.ok, "the fill should succeed");
        assertEq(
            out.balanceOf(address(proxy)),
            0,
            string.concat(
                "T1.2: the proxy's OUT went from 0 to ",
                vm.toString(out.balanceOf(address(proxy))),
                " in a successful fill (recipient +",
                vm.toString(o.recipientDelta),
                ", minAmount 99)"
            )
        );
    }

    /// @notice T1.2: a solver call sends router-held native value to the proxy, whose receive() accepts it while
    ///         the proxy's own guarded call runs
    function test_T1_2_aSolverCallSendsNativeToTheProxy() public {
        Call3Value[] memory calls = new Call3Value[](3);
        Call3Value[] memory swap = _swap(100, address(0), 100);
        calls[0] = swap[0];
        calls[1] = swap[1];
        calls[2] = Call3Value(address(proxy), false, 1, "");
        Outcome memory o = _fill(100, calls, _tail(address(0), 99, recipient, bytes32(0)), user);
        assertTrue(o.ok, "the fill should succeed");
        assertEq(
            address(proxy).balance,
            0,
            string.concat(
                "T1.2: the proxy's native went from 0 to ",
                vm.toString(address(proxy).balance),
                " in a successful fill (recipient +",
                vm.toString(o.recipientDelta),
                " wei, minAmount 99)"
            )
        );
    }

    /// @notice T1.2: refundTo may be the proxy (the tail's recipient may not), and the input the venue did not take
    ///         is refunded to it
    function test_T1_2_refundToTheProxyKeepsTheLeftoverInput() public {
        Outcome memory o =
            _fill(100, _swap(60, address(out), 60), _tail(address(out), 60, recipient, bytes32(0)), address(proxy));
        assertTrue(o.ok, "the fill should succeed");
        assertEq(
            std.balanceOf(address(proxy)),
            0,
            string.concat(
                "T1.2: refundTo is the proxy; the proxy's STD went from 0 to ",
                vm.toString(std.balanceOf(address(proxy))),
                " in a successful fill (the venue took 60 of 100)"
            )
        );
    }

    // ================================================================ known limits: these pass on the current contracts

    /// @notice A 1% fee token as tail.token, paid to an address: B 100, signed minimum 100, the recipient gets 99
    ///         and the fill succeeds. The solver only signs tails in its fee-free deposit currencies
    function test_knownLimit_feeOnTransferTokenPaysTheRecipientLessThanTheMinimum() public {
        Outcome memory o =
            _fill(100, _swap(100, address(fee), 101), _tail(address(fee), 100, recipient, bytes32(0)), user);
        assertTrue(o.ok, "the fill succeeds");
        assertEq(o.B, 100, "B");
        assertEq(o.recipientDelta, 99, "the recipient gets 99 for a signed minimum of 100");
    }

    /// @notice A 1% fee token as tail.token, deposited: the deposit log says 100 and the depository gets 99
    function test_knownLimit_feeOnTransferTokenDepositLogsMoreThanTheDepositoryGets() public {
        Outcome memory o =
            _fill(100, _swap(100, address(fee), 101), _tail(address(fee), 100, DEPOSITORY, ORDER_ID), user);
        assertTrue(o.ok, "the fill succeeds");
        assertEq(o.B, 100, "B");
        assertEq(o.depositLogs, 1);
        assertEq(o.logAmount, 100, "the deposit log says 100");
        assertEq(o.recipientDelta, 99, "the depository gets 99");
    }

    /// @notice A token that delivers amount - 1 as tail.token, paid to an address: B 100, signed minimum 100, the
    ///         recipient gets 99 and the fill succeeds
    function test_knownLimit_roundingTokenPaysTheRecipientLessThanTheMinimum() public {
        Outcome memory o =
            _fill(100, _swap(100, address(rounding), 101), _tail(address(rounding), 100, recipient, bytes32(0)), user);
        assertTrue(o.ok, "the fill succeeds");
        assertEq(o.B, 100, "B");
        assertEq(o.recipientDelta, 99, "the recipient gets 99 for a signed minimum of 100");
    }

    /// @notice A token that delivers amount - 1 as tail.token, deposited: the deposit log says 100 and the
    ///         depository gets 99
    function test_knownLimit_roundingTokenDepositLogsMoreThanTheDepositoryGets() public {
        Outcome memory o =
            _fill(100, _swap(100, address(rounding), 101), _tail(address(rounding), 100, DEPOSITORY, ORDER_ID), user);
        assertTrue(o.ok, "the fill succeeds");
        assertEq(o.B, 100, "B");
        assertEq(o.depositLogs, 1);
        assertEq(o.logAmount, 100, "the deposit log says 100");
        assertEq(o.recipientDelta, 99, "the depository gets 99");
    }

    // ================================================================ helpers

    /// @dev Signs and submits a fill of 100 STD with `calls` and `tail` like _fill, and asserts #83's refusal:
    ///      InvalidTail(), no call reached Permit2 or the router (so no solver call ran), no balance moved and the
    ///      nonce stays unused
    function _assertRefusedWithInvalidTail(
        Call3Value[] memory calls,
        RelayApprovalProxyBase.SweepWithMinimum memory tail
    ) internal returns (Outcome memory o) {
        uint256 usedNonce = nonce;
        uint256 userStd = std.balanceOf(user);
        uint256 venueStd = std.balanceOf(address(venue));
        uint256 recipientBefore =
            tail.token == address(0) ? tail.recipient.balance : TailToken(tail.token).balanceOf(tail.recipient);
        uint256 depositoryBefore =
            tail.token == address(0) ? DEPOSITORY.balance : TailToken(tail.token).balanceOf(DEPOSITORY);
        o = _fill(100, calls, tail, user);
        assertFalse(o.ok, "the fill must revert");
        assertEq(o.ret, abi.encodeWithSelector(RelayApprovalProxyBase.InvalidTail.selector), "InvalidTail()");
        assertFalse(_called(o.acc, address(router)), "no call reached the router, so no solver call ran");
        assertFalse(_called(o.acc, PERMIT2), "no call reached Permit2");
        assertEq(std.balanceOf(user), userStd, "the user's STD did not move");
        assertEq(std.balanceOf(address(router)), 0, "nothing reached the router");
        assertEq(std.balanceOf(address(venue)), venueStd, "the venue's STD did not move");
        assertEq(
            tail.token == address(0) ? tail.recipient.balance : TailToken(tail.token).balanceOf(tail.recipient),
            recipientBefore,
            "the recipient got nothing"
        );
        assertEq(
            tail.token == address(0) ? DEPOSITORY.balance : TailToken(tail.token).balanceOf(DEPOSITORY),
            depositoryBefore,
            "the depository got nothing"
        );
        assertEq(
            ISignatureTransfer(PERMIT2).nonceBitmap(user, usedNonce >> 8) & (1 << (usedNonce & 0xff)),
            0,
            "the nonce stays unused"
        );
    }

    /// @notice What the hook target and the recipient that calls out call when they call out
    function currentAttempts() external view returns (Attempt[] memory) {
        return attemptList;
    }

    function _setAttempts(Attempt[] memory attempts) internal {
        for (uint256 i; i < attempts.length; ++i) {
            attemptList.push(attempts[i]);
        }
    }

    function _tail(address token, uint256 minAmount, address to, bytes32 orderId)
        internal
        pure
        returns (RelayApprovalProxyBase.SweepWithMinimum memory)
    {
        return RelayApprovalProxyBase.SweepWithMinimum(token, minAmount, to, orderId);
    }

    /// @dev The router approves the venue for `pull` STD, and the venue pays `paid` of `tokenOut` for it
    function _swap(uint256 pull, address tokenOut, uint256 paid) internal view returns (Call3Value[] memory calls) {
        calls = new Call3Value[](2);
        calls[0] = Call3Value(
            address(std), false, 0, abi.encodeWithSignature("approve(address,uint256)", address(venue), pull)
        );
        calls[1] = Call3Value(
            address(venue), false, 0, abi.encodeCall(TailVenue.swap, (address(std), pull, tokenOut, paid, false))
        );
    }

    /// @dev The user signs a permit of `amount` STD with `tail` and `refundTo` for the multicaller, and the
    ///      multicaller's owner submits it with `calls` and the probe as the last solver call
    function _fill(
        uint256 amount,
        Call3Value[] memory calls,
        RelayApprovalProxyBase.SweepWithMinimum memory tail,
        address refundTo
    ) internal returns (Outcome memory o) {
        ISignatureTransfer.PermitBatchTransferFrom memory permit;
        permit.permitted = new ISignatureTransfer.TokenPermissions[](1);
        permit.permitted[0] = ISignatureTransfer.TokenPermissions(address(std), amount);
        permit.nonce = nonce++;
        permit.deadline = block.timestamp + 1 hours;
        bytes memory signature = _signDigest(userKey, _tailDigest(permit, address(proxy), MULTICALLER, refundTo, tail));

        Call3Value[] memory solverCalls = new Call3Value[](calls.length + 1);
        for (uint256 i; i < calls.length; ++i) {
            solverCalls[i] = calls[i];
        }
        solverCalls[calls.length] =
            Call3Value(address(probe), false, 0, abi.encodeCall(TailProbe.snap, (tail.token, tail.recipient)));

        uint256 before =
            tail.token == address(0) ? tail.recipient.balance : TailToken(tail.token).balanceOf(tail.recipient);
        vm.recordLogs();
        vm.startStateDiffRecording();
        (o.ok, o.ret) = _viaMulticaller(
            address(proxy),
            abi.encodeCall(
                RelayApprovalProxyBase.permit2TransferAndMulticallWithTail,
                (user, permit, solverCalls, tail, refundTo, META, signature)
            )
        );
        o.acc = vm.stopAndReturnStateDiff();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (!o.ok) return o;
        o.B = probe.routerBalance();
        uint256 afterwards =
            tail.token == address(0) ? tail.recipient.balance : TailToken(tail.token).balanceOf(tail.recipient);
        o.recipientDelta = afterwards - before;
        bytes32 tailHash = keccak256(_tailCalldata(user, tail));
        bool inTail;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0) continue;
            bytes32 topic = logs[i].topics[0];
            if (logs[i].emitter == address(probe) && topic == TAIL_STARTS) inTail = true;
            if (
                logs[i].emitter == address(router) && topic == SOLVER_CALL_EXECUTED
                    && keccak256(logs[i].data) == keccak256(abi.encode(address(router), tailHash, uint256(0)))
            ) inTail = false;
            if (
                inTail && (topic == ERC20_DEPOSIT || topic == NATIVE_DEPOSIT)
                    && (logs[i].emitter == DEPOSITORY || logs[i].emitter == tail.recipient)
            ) {
                ++o.depositLogs;
                o.logEmitter = logs[i].emitter;
                if (topic == ERC20_DEPOSIT) {
                    (,, o.logAmount,) = abi.decode(logs[i].data, (address, address, uint256, bytes32));
                } else {
                    (, o.logAmount,) = abi.decode(logs[i].data, (address, uint256, bytes32));
                }
            }
        }
    }
}
