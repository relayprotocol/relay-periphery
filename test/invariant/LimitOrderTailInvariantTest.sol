// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {TailEtcher} from "./LimitOrderTailBase.sol";
import {TailHandler, Action} from "./LimitOrderTailHandler.sol";

// The invariants T1 and T2 of the router 4.0 limit-order tail (permit2TransferAndMulticallWithTail): see the comment
// at the top of LimitOrderTailHandler.sol for the statements and for how the handler measures them.
//
// LimitOrderTailInvariantTest runs the fuzzed handler without a fork: Relay's Permit2, depository and
// OnlyOwnerMulticaller run from their Base runtime code, etched at their Base addresses with chain id 8453
// (LimitOrderTailCode.sol). The tokens, the venue, the recipients and the attackers are test contracts.
// LimitOrderTailForkInvariantTest runs the same handler on a Base fork with real USDC, WETH and Uniswap V3 as the
// venue, at fewer runs.
//
// The handler models #83: a tail with an orderId deposits only into DEPOSITORY or a depository the proxy's owner
// allowed (invariant_depositoryRule); everything else reverts with InvalidTail and is checked under T1.3.
//
// Every invariant failure on the current contracts has a reproduction with fixed inputs in
// LimitOrderTailReproTest.sol, and the behaviour T2 leaves to the solver (fee-on-transfer and rounding tokens) is
// pinned by its test_knownLimit_* tests.

abstract contract TailInvariants is Test {
    TailHandler internal handler;

    /// @dev The fuzzer calls only `act` of `target`: the handler, or on the fork the entry that forwards to it
    function _target(address target) internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = TailHandler.act.selector;
        targetSelector(FuzzSelector({addr: target, selectors: selectors}));
        targetContract(target);
    }

    function invariant_T1_1_noDebitWithoutSignature() public view {
        assertEq(handler.violations("T1.1"), 0, handler.firstViolation("T1.1"));
    }

    function invariant_T1_2_fillMovesExactlyTheSignedAmounts() public view {
        assertEq(handler.violations("T1.2"), 0, handler.firstViolation("T1.2"));
    }

    function invariant_T1_3_revertChangesNothing() public view {
        assertEq(handler.violations("T1.3"), 0, handler.firstViolation("T1.3"));
    }

    function invariant_T2_1_recipientGetsB() public view {
        assertEq(handler.violations("T2.1"), 0, handler.firstViolation("T2.1"));
    }

    function invariant_T2_2_oneExactDeposit() public view {
        assertEq(handler.violations("T2.2"), 0, handler.firstViolation("T2.2"));
    }

    function invariant_T2_3_noDepositWithoutOrderId() public view {
        assertEq(handler.violations("T2.3"), 0, handler.firstViolation("T2.3"));
    }

    function invariant_T2_4_tailRunsLast() public view {
        assertEq(handler.violations("T2.4"), 0, handler.firstViolation("T2.4"));
    }

    /// @dev #83: a tail with an orderId to a recipient that is not a known depository reverts with InvalidTail()
    /// before any solver call runs, no other fill reverts with it, and nobody but the owner allows a depository
    function invariant_depositoryRule() public view {
        assertEq(handler.violations("depository rule"), 0, handler.firstViolation("depository rule"));
    }

    /// @dev The handler's own measurements agree with each other: the probe ran once, the tail's frame and logs
    /// were found, and the deposit logs match the successful deposit calls
    function invariant_harness() public view {
        assertEq(handler.violations("harness"), 0, handler.firstViolation("harness"));
    }

    /// @dev Logs at the end of each run how many checks of each kind the run made, so a run that never reached a
    /// successful fill shows as such
    function afterInvariant() public {
        string[7] memory keys = [
            "T1.1 a user's balance decreased",
            "T1.2 checked a successful fill",
            "T1.3 checked a call that reverted",
            "T1.3 checked a tail refused with InvalidTail",
            "T2 checked a successful tail fill",
            "T2.2 checked a fill with an orderId",
            "T2.3 checked a fill without an orderId"
        ];
        emit log_named_uint("handler calls in this run", handler.calls());
        for (uint256 i; i < keys.length; ++i) {
            emit log_named_uint(keys[i], handler.reach(keys[i]));
        }
    }

    function _act(Action memory a) internal {
        handler.act(a);
    }

    /// @dev A fill of 100 STD for STD (a buy, no venue) by the EOA user through the multicaller, deposited under
    /// ID_A for at least the planned B. Each fixed case changes some fields of it
    function _base() internal pure returns (Action memory a) {
        a.mutation = 20; // none
        a.orderId = 1;
        a.amount = 396; // 1 + 396 / 4 = 100
    }

    function _logParts() internal {
        string[9] memory parts = ["T1.1", "T1.2", "T1.3", "T2.1", "T2.2", "T2.3", "T2.4", "depository rule", "harness"];
        for (uint256 p; p < parts.length; ++p) {
            string[] memory list = handler.classesOf(parts[p]);
            emit log_named_uint(string.concat(parts[p], " violations"), handler.violations(parts[p]));
            for (uint256 i; i < list.length; ++i) {
                emit log(string.concat(
                        "  ",
                        parts[p],
                        " [",
                        vm.toString(handler.classCount(parts[p], list[i])),
                        "x] ",
                        list[i],
                        ": ",
                        handler.firstOfClass(parts[p], list[i])
                    ));
            }
        }
    }

    function _reached(string memory key) internal {
        uint256 count = handler.reach(key);
        emit log_named_uint(key, count);
        assertGt(count, 0, string.concat("not reached: ", key));
    }
}

/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 48
/// forge-config: default.invariant.shrink-run-limit = 100
contract LimitOrderTailInvariantTest is TailInvariants {
    // tokensIn: STD, FEE, ROUND, HOOK, USDT, NOZERO. tokensOut: STD, HOOK, USDT, NOZERO, native
    uint8 internal constant IN_HOOK = 3;
    uint8 internal constant IN_USDT = 4;
    uint8 internal constant OUT_HOOK = 1;
    uint8 internal constant OUT_USDT = 2;
    uint8 internal constant OUT_NATIVE = 4;
    // recipients
    uint8 internal constant R_EOA = 1;
    uint8 internal constant R_CALLOUT = 2;
    uint8 internal constant R_HALF = 4;
    uint8 internal constant R_ALLOWED_DEPOSITORY = 6;
    // refundTo
    uint8 internal constant RF_THIRD = 4;
    uint8 internal constant RF_PROXY = 6;
    uint8 internal constant RF_ROUTER = 7;

    function setUp() public {
        new TailEtcher().etch();
        handler = new TailHandler(false);
        _target(address(handler));
    }

    /// @dev Every class of case once: about 120 actions, which keeps test_reach near half of forge's gas limit
    function _fixedCases() internal {
        // T1: every user with every relayer, as signed; a replay after success per user
        for (uint8 u; u < 2; ++u) {
            for (uint8 r; r < 3; ++r) {
                Action memory a = _base();
                a.user = u;
                a.relayer = r;
                _act(a);
            }
            Action memory replay = _base();
            replay.kind = 5;
            replay.mutation = 0;
            replay.aux = uint64(handler.orderCount() - 1);
            _act(replay);
        }
        // T1: each signed field changed, the signatures swapped, the deadline, the user's code, a cancel; the
        // wallet user for the user field, its code, the relayer and the deadline
        for (uint8 m = 1; m < 20; ++m) {
            Action memory a = _base();
            a.mutation = m;
            a.aux = 5;
            _act(a);
        }
        uint8[4] memory walletMutations = [12, 18, 5, 16];
        for (uint256 i; i < walletMutations.length; ++i) {
            Action memory a = _base();
            a.user = 1;
            a.mutation = walletMutations[i];
            a.aux = 5;
            _act(a);
        }
        // T1: RelayerWitness orders in permit2TransferAndMulticall, as signed and changed
        for (uint8 sub; sub < 4; ++sub) {
            Action memory a = _base();
            a.kind = 4;
            a.mutation = sub;
            _act(a);
        }
        // T1: the fee and rounding tokens, and the others, as permitted tokens; two permitted tokens
        for (uint8 t; t < 6; ++t) {
            Action memory a = _base();
            a.tokenIn = t;
            a.minMode = 2;
            _act(a);
        }
        {
            Action memory a = _base();
            a.second = 1;
            a.minMode = 2;
            _act(a);
        }
        // T2: an ERC-20 and native to every recipient, with and without an orderId, for at least half of B. With an
        // orderId, every recipient but the two depositories is refused with InvalidTail (#83). The other tail
        // tokens to the depository with an orderId and to an EOA without one
        uint8[2] memory everyRecipient = [OUT_USDT, OUT_NATIVE];
        for (uint256 i; i < everyRecipient.length; ++i) {
            for (uint8 r; r < 7; ++r) {
                for (uint8 id; id < 2; ++id) {
                    Action memory a = _base();
                    a.tokenOut = everyRecipient[i];
                    a.recipient = r;
                    a.orderId = id;
                    a.minMode = 3;
                    _act(a);
                }
            }
        }
        uint8[3] memory otherTokens = [0, OUT_HOOK, 3];
        for (uint256 i; i < otherTokens.length; ++i) {
            Action memory a = _base();
            a.tokenOut = otherTokens[i];
            _act(a);
            a.recipient = R_EOA;
            a.orderId = 0;
            _act(a);
        }
        // T2: the venue pays less, takes less, calls back, pays more
        for (uint8 sw; sw < 6; ++sw) {
            Action memory a = _base();
            a.tokenOut = OUT_USDT;
            a.swap = sw;
            a.minMode = 2;
            a.aux = 3;
            _act(a);
        }
        // T2: each of the malicious relayer's extras; stealing and donating native too
        for (uint8 bit; bit < 8; ++bit) {
            Action memory a = _base();
            a.tokenOut = OUT_USDT;
            a.extras = uint8(1 << bit);
            a.attempts = 47;
            a.minMode = 2;
            _act(a);
        }
        for (uint8 bit; bit < 4; bit += 3) {
            Action memory a = _base();
            a.tokenOut = OUT_NATIVE;
            a.extras = uint8(1 << bit);
            a.minMode = 2;
            _act(a);
        }
        // T2: the hook token as the tail token and as the permitted token, the recipient that calls out with and
        // without an orderId, the venue's callback: with every attempt but the depository log, and with all of them
        uint8[2] memory attemptSets = [47, 63];
        for (uint256 i; i < attemptSets.length; ++i) {
            Action memory a = _base();
            a.tokenOut = OUT_HOOK;
            a.attempts = attemptSets[i];
            a.minMode = 2;
            _act(a);
            a.tokenOut = 0;
            a.tokenIn = IN_HOOK;
            _act(a);
            a.tokenIn = 0;
            a.tokenOut = OUT_NATIVE;
            a.recipient = R_CALLOUT;
            a.orderId = 0;
            _act(a);
            a.orderId = 1;
            _act(a);
            a.recipient = 0;
            a.tokenOut = OUT_USDT;
            a.swap = 3;
            _act(a);
        }
        // T1.2: every refundTo, with input left over
        uint8[4] memory refunds = [0, RF_THIRD, RF_PROXY, RF_ROUTER];
        for (uint256 i; i < refunds.length; ++i) {
            Action memory a = _base();
            a.tokenOut = OUT_USDT;
            a.swap = 2;
            a.minMode = 2;
            a.refundTo = refunds[i];
            a.aux = 9;
            _act(a);
        }
        // griefers: dust on the router, deposits under an order id, a cancel, the thief sweeping
        for (uint8 sub; sub < 5; ++sub) {
            Action memory a = _base();
            a.kind = 7;
            a.mutation = sub;
            a.tokenIn = sub == 4 ? 0 : IN_USDT;
            a.amount = 1 + 4 * 7;
            a.aux = 1;
            _act(a);
        }
        {
            // the half-pulling recipient without an orderId gets a plain transfer of B; then the thief sweeps
            Action memory a = _base();
            a.tokenOut = OUT_USDT;
            a.recipient = R_HALF;
            a.orderId = 0;
            a.minMode = 3;
            _act(a);
            Action memory sweep = _base();
            sweep.kind = 7;
            sweep.mutation = 4;
            _act(sweep);
        }
        // attackers: every function, with the signature of a pending order
        {
            Action memory pending = _base();
            pending.mutation = 3; // signed, never submitted as signed
            _act(pending);
            uint64 index = uint64(handler.orderCount() - 1);
            for (uint8 sub; sub < 10; ++sub) {
                Action memory a = _base();
                a.kind = 6;
                a.mutation = sub;
                a.aux = index;
                _act(a);
            }
            // the user cancels it, and a replay fails
            Action memory cancel = _base();
            cancel.kind = 7;
            cancel.mutation = 3;
            cancel.aux = index;
            _act(cancel);
            Action memory replay = _base();
            replay.kind = 5;
            replay.aux = index;
            _act(replay);
        }
        // the wallet user through the venue to native, deposited, by the malicious relayer
        {
            Action memory a = _base();
            a.user = 1;
            a.tokenOut = OUT_NATIVE;
            a.relayer = 2;
            _act(a);
        }
    }

    function test_reach() public {
        _fixedCases();
        _logParts();
        emit log_named_uint("fixed actions", handler.calls());
        emit log_named_uint("gas left", gasleft());

        _reached("T1.1 a user's balance decreased");
        _reached("T1.2 checked a successful fill");
        _reached("T1.3 checked a call that reverted");
        _reached("T2 checked a successful tail fill");
        _reached("T2.2 checked a fill with an orderId");
        _reached("T2.3 checked a fill without an orderId");

        _reached("fill succeeded, the EOA user");
        _reached("fill succeeded, the wallet user");
        _reached("fill succeeded, relayer the multicaller");
        _reached("fill succeeded, relayer the other relayer");
        _reached("fill succeeded, relayer the malicious relayer");
        _reached("replay of a filled order, reverted");
        _reached("replay of a cancelled order, reverted");
        string[20] memory mutations = [
            "none",
            "permitted token",
            "permitted amount",
            "nonce",
            "deadline",
            "submitted by another relayer",
            "refundTo",
            "tail.token",
            "tail.minAmount",
            "tail.recipient",
            "tail.orderId",
            "spender",
            "user",
            "RelayerWitness signature in the tail entry point",
            "tail signature in permit2TransferAndMulticall",
            "submitted at deadline + 1",
            "submitted at the deadline",
            "the EOA user gets ERC-1271 code after signing",
            "the user gets code without isValidSignature after signing",
            "the user cancelled the nonce"
        ];
        for (uint256 m = 1; m < 20; ++m) {
            bool succeeds = m == 16 || m == 17;
            _reached(string.concat("mutation ", mutations[m], succeeds ? ", succeeded" : ", reverted"));
        }
        _reached("RelayerWitness order as signed, succeeded");
        _reached("RelayerWitness order by another relayer, reverted");
        _reached("RelayerWitness order with changed calls, reverted");
        _reached("RelayerWitness order in the tail entry point, reverted");

        string[6] memory ins = ["STD", "FEE", "ROUND", "HOOK", "USDT", "NOZERO"];
        for (uint256 i; i < ins.length; ++i) {
            _reached(string.concat("T2 success, permitted ", ins[i]));
        }
        string[5] memory outs = ["STD", "HOOK", "USDT", "NOZERO", "native"];
        for (uint256 i; i < outs.length; ++i) {
            _reached(string.concat("T2 success, tail token ", outs[i]));
        }
        _reached("T2 success, two permitted tokens");
        // every recipient x orderId class was tried: it filled, or #83 refused it, or the recipient reverts
        string[8] memory recipients = [
            "the depository with an orderId",
            "the depository without an orderId",
            "the allowed depository with an orderId",
            "the allowed depository without an orderId",
            "the EOA recipient without an orderId",
            "the recipient that calls out without an orderId",
            "the address without code without an orderId",
            "the half-pulling recipient without an orderId"
        ];
        for (uint256 i; i < recipients.length; ++i) {
            _reached(string.concat("T2 success, recipient ", recipients[i]));
        }
        string[5] memory refused = [
            "the EOA recipient",
            "the recipient that calls out",
            "the address without code",
            "the half-pulling recipient",
            "the reverting recipient"
        ];
        for (uint256 i; i < refused.length; ++i) {
            _reached(string.concat("refused with InvalidTail, recipient ", refused[i], " with an orderId"));
        }
        _reached("refused with InvalidTail, tail token USDT");
        _reached("refused with InvalidTail, tail token native");
        _reached("depository rule: a tail with an orderId to an unknown recipient was submitted");
        _reached("T1.3 checked a tail refused with InvalidTail");
        string[5] memory venues = ["honest", "pays less", "takes less", "calls back", "pays more"];
        for (uint256 i; i < venues.length; ++i) {
            _reached(string.concat("T2 success, venue ", venues[i]));
        }
        string[7] memory extras = [
            "steals a little",
            "a nested multicall steals a little",
            "donates to the proxy",
            "calls the proxy",
            "calls Permit2",
            "calls the depository",
            "calls the malicious relayer back"
        ];
        for (uint256 i; i < extras.length; ++i) {
            _reached(string.concat("T2 success, the relayer ", extras[i]));
        }
        _reached("T2 success, the hook target made its attempts");
        _reached("T2 success, the recipient that calls out made its attempts");
        _reached("T2 success, the venue made its attempts");
        _reached("T2 success, the malicious relayer made its attempts");
        string[4] memory refunds = ["the EOA user", "the third party", "the proxy", "the router"];
        for (uint256 i; i < refunds.length; ++i) {
            _reached(string.concat("T2 success, refundTo ", refunds[i]));
        }

        string[10] memory attacks = [
            "Permit2 permitWitnessTransferFrom with the user's signature",
            "the proxy's tail entry point, not by the signed relayer",
            "permit2TransferAndMulticall with no signature, pulling the user's funds",
            "transferAndMulticall, pulling the user's funds",
            "permitTransferAndMulticall for the user",
            "permit3009TransferAndMulticall for the user",
            "the router's multicall, pulling the user's funds",
            "the router's sweeps and cleanups of its residue",
            "the proxy's withdraw",
            "the proxy's setDepository, allowing the thief"
        ];
        for (uint256 i; i < attacks.length; ++i) {
            // the multicalls with allowFailure succeed without pulling anything
            bool succeeds = i == 2 || i == 3 || i == 6 || i == 7;
            _reached(string.concat("attack ", attacks[i], succeeds ? ", succeeded" : ", reverted"));
        }
        _reached("griefer dust, token, succeeded");
        _reached("griefer dust, native, succeeded");
        _reached("griefer deposit under an order id, succeeded");
        _reached("user cancels, succeeded");
        _reached("thief sweeps, succeeded");
        _reached("the thief took residue from the router");
    }
}

/// @dev The fuzzed entry point of the fork suite: one call of `act` is one call of the handler, in one transaction
contract TailForkEntry {
    TailHandler internal immutable handler;

    constructor(TailHandler handler_) {
        handler = handler_;
    }

    function act(Action calldata a) external {
        handler.act(a);
    }
}

/// forge-config: default.invariant.runs = 8
/// forge-config: default.invariant.depth = 24
/// forge-config: default.invariant.shrink-run-limit = 20
contract LimitOrderTailForkInvariantTest is TailInvariants {
    /// @dev The block the runtime code in LimitOrderTailCode.sol was read at
    uint256 internal constant FORK_BLOCK = 60052299;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("base"), FORK_BLOCK);
        // The handler is far above the 24 KB code size limit, which forge enforces on the Base fork: deployCodeTo
        // runs its constructor as a call and etches the code it returns. On a fork, cheatcodes are enabled only for
        // the contracts the test created, so the handler's address is allowed explicitly
        address at = makeAddr("limit-order-tail fork handler");
        vm.allowCheatcodes(at);
        deployCodeTo("LimitOrderTailHandler.sol:TailHandler", abi.encode(true), at);
        handler = TailHandler(payable(at));
        // forge targets only contracts it saw created, so the fuzzer calls the handler through a small entry
        _target(address(new TailForkEntry(handler)));
    }

    function test_forkReach() public {
        // tokensIn: WETH, USDC. tokensOut: USDC, WETH, native. Uniswap V3 is the venue
        for (uint8 out; out < 3; ++out) {
            for (uint8 r; r < 2; ++r) {
                Action memory a = _base();
                a.tokenOut = out;
                a.recipient = r;
                a.orderId = r == 0 ? 1 : 0;
                a.amount = 4e17;
                _act(a);
                a.tokenIn = 1;
                a.amount = 4e8;
                _act(a);
            }
        }
        Action memory takesLess = _base();
        takesLess.swap = 2;
        takesLess.amount = 4e17;
        _act(takesLess);
        // #83: the allowed depository takes a deposit, an EOA with an orderId is refused
        Action memory allowed = _base();
        allowed.recipient = 6;
        allowed.amount = 4e17;
        _act(allowed);
        allowed.recipient = 1;
        _act(allowed);
        for (uint8 m = 1; m < 6; ++m) {
            Action memory a = _base();
            a.mutation = m;
            a.amount = 4e17;
            _act(a);
        }
        _logParts();
        _reached("T2 success, tail token USDC");
        _reached("T2 success, tail token WETH");
        _reached("T2 success, tail token native");
        _reached("T2 success, permitted WETH");
        _reached("T2 success, permitted USDC");
        _reached("T2 success, venue honest");
        _reached("T2 success, venue takes less");
        _reached("T2 success, recipient the depository with an orderId");
        _reached("T2 success, recipient the EOA recipient without an orderId");
        _reached("T2 success, recipient the allowed depository with an orderId");
        _reached("refused with InvalidTail, recipient the EOA recipient with an orderId");
        _reached("T1.3 checked a call that reverted");
    }
}
