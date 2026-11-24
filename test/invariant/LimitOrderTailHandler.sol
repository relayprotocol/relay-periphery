// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {ISignatureTransfer} from "permit2-relay/src/interfaces/ISignatureTransfer.sol";
import {IAllowanceTransfer} from "permit2-relay/src/interfaces/IAllowanceTransfer.sol";
import {RelayRouter} from "../../src/RelayRouter.sol";
import {RelayRouterBase} from "../../src/RelayRouterBase.sol";
import {RelayApprovalProxy} from "../../src/RelayApprovalProxy.sol";
import {RelayApprovalProxyBase} from "../../src/RelayApprovalProxyBase.sol";
import {Call3Value, Result} from "../../src/common/Multicall3.sol";
import {Permit2612, Permit3009} from "../../src/common/Permits.sol";
import {TailTyped} from "./LimitOrderTailBase.sol";
import {
    TailToken,
    TailWallet,
    TailCodeWithoutSignatures,
    Attempt,
    TailHookTarget,
    TailVenue,
    TailCalloutRecipient,
    TailHalfPullingRecipient,
    TailRevertingRecipient,
    TailEvilRelayer,
    TailProbe,
    TailTransientReader,
    STANDARD,
    FEE_ON_TRANSFER,
    ROUNDS_DOWN,
    HOOK,
    USDT_APPROVE,
    NO_ZERO_APPROVE
} from "./LimitOrderTailActors.sol";

// T1. Nothing of a user moves without that user's signature. A fill is all or nothing.
//   1. A user's balance decreases only in a call that the user makes, or in a successful fill where the digest is in
//      `signed`, msg.sender is the signed relayer, block.timestamp <= deadline, and the nonce bit is 0. This is true
//      for all proxy and router functions.
//   2. A successful fill moves exactly the signed amount of each permitted token from the user to the router in one
//      transfer. It sets exactly one bit of nonceBitmap[user]. It changes no other balance or allowance of the user.
//      The proxy's balances do not change.
//   3. After a call that reverts, the ledger, all allowances, the nonce word and the three slots (proxy lock, router
//      CONTEXT_SLOT, router RECIPIENT_SLOT) are the same as before.
//   4. The handler computes the digest with vm.eip712HashTypedData on the JSON typed data (TailTyped).
//
// T2. The recipient gets at least minAmount, measured at the recipient. A cross-chain fill makes exactly one exact
// deposit. Let B be the router's balance of tail.token immediately before the tail. On success:
//   1. B >= minAmount. ERC-20: the recipient's balance increases by exactly B. Native: the router sends B in one call.
//   2. orderId != 0: the recipient has code. The tail makes exactly one depository log, RelayErc20Deposit(user,
//      tail.token, B, orderId) or RelayNativeDeposit(user, B, orderId). The depository's balance increases by B.
//   3. orderId == 0: the tail makes no depository log.
//   4. The last SolverCallExecuted of the fill is (router, keccak256(tailCalldata), 0), where the test builds
//      tailCalldata itself from the signed fields. returnData.length == solverCalls.length + 1.
//
// How the handler measures:
// - B: the handler appends a call to TailProbe as the last solver call. It records the router's balance of
//   tail.token and the recipient's balance, and emits TailStarts. Nothing runs between it and the tail.
// - The tail's logs: those after TailStarts up to the tail's own SolverCallExecuted. A "depository log" is a
//   RelayErc20Deposit or RelayNativeDeposit emitted by Relay's depository or by tail.recipient (a recipient that
//   is a depository look-alike). Recorded logs include those of reverted frames, so the handler also counts the
//   successful deposit calls inside the tail frame from the state diff and flags a harness error if they disagree.
// - A user's debit: a transferFrom (or transfer by the user) of a ledger token whose `from` is the user, in a frame
//   that did not revert (state diff), or any net decrease of a balance. A refund to the user in the same fill does
//   not hide a debit. T1.2 counts credits to the user (refundTo or recipient is the user) as not "moving" the user's
//   funds; every debit and every allowance is checked exactly. A token that lowers even an unlimited allowance
//   (USDC) lowers the user's allowance for Permit2 by what Permit2 pulled: that decrease is the permitted transfer.
// - "Native: the router sends B in one call": the calls with value that the router makes inside the tail frame.
// - The one-token rule ("one-token rule"): a tail whose permit does not hold exactly one token reverts with
//   InvalidTail(). The handler signs tail permits with no token and with two (Action.second).
//   permit2TransferAndMulticall has no such rule and takes both.
// - The depository rule (#83, "depository rule"): a tail with an orderId whose recipient is neither DEPOSITORY nor
//   allowed by the spender proxy's owner (isDepository) reverts with InvalidTail(). The owner (the handler) allows
//   one more contract with the depository's code, `depository2`, and nothing else.
// - A tail that either rule refuses reverts before any call reaches Permit2 or the router, so before any solver
//   call runs, and T1.3 is checked for it like for any other revert. No tail that both rules allow reverts with
//   InvalidTail(). The calls are read from the state diff, which keeps the calls of frames that reverted: a counter
//   that a solver call raises would be undone by the revert itself.
// - Refunds ("refund"): after a successful tail fill whose refundTo is the user or the third party, refundTo gets
//   the router's balance of the permitted token after the venue, as the token delivers it, and the router keeps
//   none of it. That balance is what the router held before the fill, plus the permitted amount as the router
//   received it, minus what the venue took. No extra of the relayer sends or takes the permitted token. A tail of
//   the permitted token itself takes it all, so those fills are not checked, and neither is the hook token as the
//   permitted token when its hook tries the router's sweeps or cleanups: while Permit2 moves it to the router,
//   before the proxy calls the router, those calls can take it, as a token that runs code of its choosing can.
// - Fills from callbacks (A_FRESH_FILL): during a fill, the hook target, the venue, the recipient that calls out
//   and the malicious relayer each submit a tail fill of 1 unit of another token that the user signed for it as the
//   relayer, with an unused nonce. Only the proxy's guard stops it; were it to succeed, the outer fill would move a
//   second amount of the user's and set a second nonce bit, which T1.2 reports.
// - A "depository log" in T2 is a deposit event from Relay's depository, from the allowed depository or from
//   tail.recipient.
// - T2's token set (tokensOut) leaves out the fee-on-transfer and the rounding tokens: the solver signs tails only in
//   its fee-free deposit currencies. Both stay permitted tokens for T1. LimitOrderTailReproTest's test_knownLimit_*
//   tests pin what the tail does with them today.

uint256 constant KINDS = 8; // Action.kind % KINDS: 0-3 a new tail fill, 4 a permit2TransferAndMulticall fill,
// 5 a replay of an earlier order, 6 an attacker calls a proxy, router or Permit2 function, 7 a griefer or the user

// Fill mutations: the field the submitter changes after the user signed. Action.mutation % 40, 20 and above: none
uint256 constant M_NONE = 0;
uint256 constant M_TOKEN = 1;
uint256 constant M_AMOUNT = 2;
uint256 constant M_NONCE = 3;
uint256 constant M_DEADLINE = 4;
uint256 constant M_RELAYER = 5;
uint256 constant M_REFUND_TO = 6;
uint256 constant M_TAIL_TOKEN = 7;
uint256 constant M_MIN_AMOUNT = 8;
uint256 constant M_RECIPIENT = 9;
uint256 constant M_ORDER_ID = 10;
uint256 constant M_SPENDER = 11;
uint256 constant M_USER = 12;
uint256 constant M_RELAYER_WITNESS_SIGNATURE = 13; // the user's RelayerWitness signature, in the tail entry point
uint256 constant M_TAIL_SIGNATURE_OLD_ENTRY = 14; // the tail signature, in permit2TransferAndMulticall
uint256 constant M_AFTER_DEADLINE = 15; // submitted at deadline + 1
uint256 constant M_AT_DEADLINE = 16; // submitted at the deadline: not a change
uint256 constant M_WALLET_CODE = 17; // the EOA user gets ERC-1271 code that checks its own key: not a change
uint256 constant M_CODE_WITHOUT_1271 = 18; // the EOA user gets code without isValidSignature
uint256 constant M_CANCELLED = 19; // the user invalidates the nonce first
uint256 constant MUTATIONS = 20;

// Fill.swapMode, Action.swap % 6
uint8 constant SWAP_HONEST = 0;
uint8 constant SWAP_PAYS_LESS = 1;
uint8 constant SWAP_TAKES_LESS = 2;
uint8 constant SWAP_CALLS_BACK = 3;
uint8 constant SWAP_NONE = 4;
uint8 constant SWAP_PAYS_MORE = 5;

// Action.extras: what the relayer adds to the solver calls
uint8 constant X_STEAL = 1; // sends a little of tail.token to the thief
uint8 constant X_NESTED = 2; // a nested multicall that sends a little of tail.token to the thief
uint8 constant X_SWEEP = 4; // sweepWithMinimum(tail.token, 0, thief, "") as a command
uint8 constant X_DONATE_PROXY = 8; // sends a little of tail.token to the proxy
uint8 constant X_CALL_PROXY = 16; // calls the proxy with the user's signature
uint8 constant X_CALL_PERMIT2 = 32; // calls Permit2 with the user's signature, and Permit2's allowance transfer
uint8 constant X_CALL_DEPOSITORY = 64; // deposits under the order id before the tail
uint8 constant X_EVIL_CALLBACK = 128; // calls the evil relayer, which runs the attempts

// Action.attempts: what a hook token's hook, the venue, a recipient that calls out and the evil relayer try
uint8 constant A_PROXY = 1; // the proxy's tail entry point with the user's signature
uint8 constant A_SWEEP = 2; // the router's sweepWithMinimum of tokenIn and tail.token to the thief
uint8 constant A_PERMIT2 = 4; // Permit2 with the user's signature, to the thief
uint8 constant A_CLEANUP = 8; // the router's cleanupErc20s and cleanupNative to the thief
uint8 constant A_DEPOSIT_LOG = 16; // the depository's depositNative(user, orderId)
uint8 constant A_WITHDRAW = 32; // the proxy's withdraw to the thief
uint8 constant A_FRESH_FILL = 64; // the proxy's tail entry point with a fresh permit the user signed for the caller

uint256 constant NONCE_WORDS = 4;

struct Action {
    uint8 kind;
    uint8 user; // % 2: the EOA, the ERC-1271 wallet
    uint8 relayer; // % 3: the multicaller, another relayer (an EOA), a malicious relayer (a contract)
    uint8 tokenIn; // % tokensIn.length
    uint8 second; // % 8: 0-5 one permitted token, 6 two (second >> 3 picks the other one), 7 none
    uint8 tokenOut; // % tokensOut.length
    uint8 recipient; // % 7: the depository, an EOA, calls out, no code, pulls half, reverts, the allowed depository
    uint8 orderId; // % 3: none, ID_A, ID_B
    uint8 refundTo; // % 8: 0-3 the user, 4-5 a third party, 6 the proxy, 7 the router
    uint8 minMode; // % 5: planned B, B + 1, 1, B / 2, B - 1
    uint8 swap; // % 6
    uint8 extras;
    uint8 attempts;
    uint8 mutation;
    uint64 amount;
    uint64 aux;
}

struct Fill {
    uint8 userIdx;
    uint8 relayerIdx;
    address tokenIn;
    uint256 amount;
    uint256 received;
    uint8 count; // the number of permitted tokens: 0, 1 or 2
    address second;
    uint256 secondAmount;
    uint8 swapMode;
    uint256 pull;
    uint256 out;
    uint256 plannedB;
    uint8 recipientIdx;
    uint8 refundIdx;
    RelayApprovalProxyBase.SweepWithMinimum tail;
    address refundTo;
    uint256 nonce;
    uint256 deadline;
    uint8 extras;
    uint8 attempts;
    uint64 aux;
}

/// @dev One call into a proxy entry point, as submitted
struct Sub {
    bool tailEntry;
    uint8 userIdx;
    address user;
    address spender;
    uint8 relayerIdx;
    address relayer;
    ISignatureTransfer.PermitBatchTransferFrom permit;
    RelayApprovalProxyBase.SweepWithMinimum tail;
    address refundTo;
    Call3Value[] calls;
    bytes signature;
    bytes32 digest;
    bytes tailCalldata;
    string name;
    string cls;
    uint8 extras;
    bool refused; // a tail with an orderId to a recipient that is not a depository the spender knows
    bool ok;
    bytes ret;
}

struct Snap {
    uint256[] bal;
    uint256[] allow;
    uint256[] p2;
    uint256[] words;
    uint256[] slots;
}

struct Debit {
    address token;
    address from;
    address to;
    uint256 amount;
    address by; // the caller of the token
}

struct Order {
    bool oldEntry;
    bool filled;
    uint8 userIdx;
    uint8 relayerIdx;
    uint8 swapMode;
    uint8 count;
    address[2] tokens;
    uint256[2] amounts;
    uint256 nonce;
    uint256 deadline;
    RelayApprovalProxyBase.SweepWithMinimum tail;
    address refundTo;
    bytes signature;
}

interface ITailSwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface ITailQuoter {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

interface ITailWeth {
    function withdraw(uint256 amount) external;
}

contract TailHandler is TailTyped {
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address internal constant QUOTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;

    bytes32 public constant ID_A = keccak256("limit-order-tail order A");
    bytes32 internal constant ATTEMPTS_SLOT = keccak256("limit-order-tail attempts");
    bytes32 internal constant FRESH_FILLS_SLOT = keccak256("limit-order-tail fresh fills");
    bytes32 public constant ID_B = keccak256("limit-order-tail order B");

    // Only for the attackers' calls with a stolen signature, never for the handler's digests
    bytes32 internal constant TAIL_WITNESS_TYPEHASH = keccak256(
        "TailWitness(address relayer,address refundTo,SweepWithMinimum tail)SweepWithMinimum(address token,uint256 minAmount,address recipient,bytes32 orderId)"
    );
    bytes32 internal constant SWEEP_TYPEHASH =
        keccak256("SweepWithMinimum(address token,uint256 minAmount,address recipient,bytes32 orderId)");
    string internal constant TAIL_WITNESS_TYPE_STRING =
        "TailWitness witness)SweepWithMinimum(address token,uint256 minAmount,address recipient,bytes32 orderId)TailWitness(address relayer,address refundTo,SweepWithMinimum tail)TokenPermissions(address token,uint256 amount)";
    bytes4 internal constant PERMIT2_BATCH_WITNESS = bytes4(
        keccak256(
            "permitWitnessTransferFrom(((address,uint256)[],uint256,uint256),(address,uint256)[],address,bytes32,string,bytes)"
        )
    );
    bytes4 internal constant PERMIT2_ALLOWANCE_TRANSFER =
        bytes4(keccak256("transferFrom(address,address,uint160,address)"));

    bool public immutable fork;
    RelayRouter public immutable router;
    RelayApprovalProxy public immutable proxy;
    RelayApprovalProxy public immutable proxy2; // the same contract at another address: a spender nobody signed
    address public immutable venue;
    TailVenue public immutable tailVenue;
    TailHookTarget public immutable hookTarget;
    TailCalloutRecipient public immutable callout;
    TailHalfPullingRecipient public immutable halfPull;
    TailRevertingRecipient public immutable reverting;
    address public immutable depository2; // the depository's code at another address, allowed by the owner
    TailEvilRelayer public immutable evil;
    TailProbe public immutable probe;
    TailWallet public immutable wallet;
    address internal immutable eoaWalletCode; // a TailWallet whose signer is the EOA user, to etch onto it
    address public immutable userEoa;
    uint256 internal immutable userKey;
    uint256 internal immutable walletKey;
    address public immutable relayerEoa;
    address public immutable eoaRecipient;
    address public immutable noCode;
    address public immutable thief;
    address public immutable griefer;
    address public immutable thirdParty;

    address[] public tokensIn;
    address[] public tokensOut; // address(0): native
    address[] internal ledgerTokens;
    address[] internal accts;
    string[] internal acctNames;
    address[] internal allowOwners;
    address[] internal spenders;
    address[] internal p2Spenders;
    mapping(address => string) internal tokenNames;

    Order[] internal orders;
    mapping(address => uint256) internal nextNonce;
    // user => digest => the relayer it names; zero when the user never signed the digest
    mapping(address => mapping(bytes32 => address)) public signedBy;

    uint256 public calls;
    mapping(string => uint256) public violations;
    mapping(string => string) public firstViolation;
    mapping(string => uint256) public reach;
    // every distinct class of violation, per invariant part, with its first occurrence
    mapping(string => string[]) internal classes;
    mapping(string => mapping(string => uint256)) public classCount;
    mapping(string => mapping(string => string)) public firstOfClass;

    constructor(bool fork_) {
        fork = fork_;
        router = new RelayRouter();
        proxy = new RelayApprovalProxy(address(this), address(router), PERMIT2);
        proxy2 = new RelayApprovalProxy(address(this), address(router), PERMIT2);
        (address eoa, uint256 eoaKey) = makeAddrAndKey("limit-order-tail invariant user");
        (address walletSigner, uint256 signerKey) = makeAddrAndKey("limit-order-tail invariant wallet signer");
        require(eoa.code.length == 0 && walletSigner.code.length == 0, "fresh keys only");
        userEoa = eoa;
        userKey = eoaKey;
        walletKey = signerKey;
        wallet = new TailWallet(walletSigner);
        eoaWalletCode = address(new TailWallet(eoa));
        relayerEoa = makeAddr("limit-order-tail invariant other relayer");
        eoaRecipient = makeAddr("limit-order-tail invariant EOA recipient");
        noCode = address(uint160(uint256(keccak256("limit-order-tail invariant address without code"))));
        thief = makeAddr("limit-order-tail invariant thief");
        griefer = makeAddr("limit-order-tail invariant griefer");
        thirdParty = makeAddr("limit-order-tail invariant refund third party");
        hookTarget = new TailHookTarget();
        callout = new TailCalloutRecipient();
        halfPull = new TailHalfPullingRecipient();
        reverting = new TailRevertingRecipient();
        evil = new TailEvilRelayer();
        probe = new TailProbe();
        tailVenue = new TailVenue();
        // The owner allows the chain's depository, as the deploy does
        proxy.setDepository(DEPOSITORY, true);
        proxy2.setDepository(DEPOSITORY, true);
        // As on a chain where the depository has another address: its code elsewhere, allowed by the owner
        depository2 = makeAddr("limit-order-tail invariant allowed depository");
        vm.etch(depository2, DEPOSITORY.code);
        proxy.setDepository(depository2, true);
        proxy2.setDepository(depository2, true);

        if (fork_) {
            venue = SWAP_ROUTER;
            tokensIn.push(WETH);
            tokensIn.push(USDC);
            tokensOut.push(USDC);
            tokensOut.push(WETH);
            tokensOut.push(address(0));
            ledgerTokens.push(WETH);
            ledgerTokens.push(USDC);
            tokenNames[WETH] = "WETH";
            tokenNames[USDC] = "USDC";
            deal(WETH, eoa, 1000 ether);
            deal(USDC, eoa, 10_000_000e6);
            deal(WETH, address(wallet), 1000 ether);
            deal(USDC, address(wallet), 10_000_000e6);
        } else {
            venue = address(tailVenue);
            string[6] memory names = ["STD", "FEE", "ROUND", "HOOK", "USDT", "NOZERO"];
            for (uint8 kind; kind < 6; ++kind) {
                TailToken token = new TailToken(kind, names[kind]);
                tokenNames[address(token)] = names[kind];
                tokensIn.push(address(token));
                ledgerTokens.push(address(token));
                token.mint(eoa, 1e30);
                token.mint(address(wallet), 1e30);
                token.mint(address(tailVenue), 1e30);
                if (kind == HOOK) token.setHook(address(hookTarget));
                // the fee and rounding tokens are not in T2's token set: test_knownLimit_* cover them
                if (kind != FEE_ON_TRANSFER && kind != ROUNDS_DOWN) tokensOut.push(address(token));
            }
            tokensOut.push(address(0));
            vm.deal(address(tailVenue), 1e30);
        }
        tokenNames[address(0)] = "native";

        for (uint256 t; t < ledgerTokens.length; ++t) {
            // the USDT-style token returns nothing from approve
            vm.prank(eoa);
            SafeTransferLib.safeApprove(ledgerTokens[t], PERMIT2, type(uint256).max);
            vm.prank(address(wallet));
            SafeTransferLib.safeApprove(ledgerTokens[t], PERMIT2, type(uint256).max);
            // The EOA has also approved the proxy, as users of transferAndMulticall do
            vm.prank(eoa);
            SafeTransferLib.safeApprove(ledgerTokens[t], address(proxy), type(uint256).max);
        }

        address[21] memory a = [
            eoa,
            address(wallet),
            address(router),
            address(proxy),
            address(proxy2),
            DEPOSITORY,
            eoaRecipient,
            address(callout),
            noCode,
            address(halfPull),
            address(reverting),
            venue,
            thief,
            griefer,
            thirdParty,
            MULTICALLER,
            relayerEoa,
            address(evil),
            address(hookTarget),
            address(probe),
            depository2
        ];
        string[21] memory n = [
            "the EOA user",
            "the wallet user",
            "the router",
            "the proxy",
            "the second proxy",
            "the depository",
            "the EOA recipient",
            "the recipient that calls out",
            "the address without code",
            "the half-pulling recipient",
            "the reverting recipient",
            "the venue",
            "the thief",
            "the griefer",
            "the third party",
            "the multicaller",
            "the other relayer",
            "the malicious relayer",
            "the hook target",
            "the probe",
            "the allowed depository"
        ];
        for (uint256 i; i < a.length; ++i) {
            accts.push(a[i]);
            acctNames.push(n[i]);
        }
        address[4] memory owners = [eoa, address(wallet), address(router), address(proxy)];
        for (uint256 i; i < owners.length; ++i) {
            allowOwners.push(owners[i]);
        }
        address[12] memory sp = [
            PERMIT2,
            address(proxy),
            address(proxy2),
            address(router),
            DEPOSITORY,
            depository2,
            venue,
            address(halfPull),
            thief,
            address(evil),
            address(hookTarget),
            address(callout)
        ];
        for (uint256 i; i < sp.length; ++i) {
            spenders.push(sp[i]);
        }
        address[6] memory p2 = [address(proxy), address(proxy2), address(router), thief, address(evil), MULTICALLER];
        for (uint256 i; i < p2.length; ++i) {
            p2Spenders.push(p2[i]);
        }
    }

    receive() external payable {}

    // ================================================================ the fuzzed entry point

    function act(Action calldata a) external {
        ++calls;
        _clearFreshFills();
        uint256 kind = a.kind % KINDS;
        if (kind == 4) _oldEntry(a);
        else if (kind == 5 && orders.length != 0) _replay(a);
        else if (kind == 6 && orders.length != 0) _attack(a);
        else if (kind == 7) _grief(a);
        else _fill(a);
    }

    // ================================================================ new tail fills

    function _fill(Action calldata a) internal {
        Fill memory f = _plan(a);
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _permit(f);
        address signedRelayer = _relayer(f.relayerIdx);
        address user = _user(f.userIdx);
        bytes32 digest = _tailDigest(permit, address(proxy), signedRelayer, f.refundTo, f.tail);
        bytes memory signature = _sign(f.userIdx, digest);
        signedBy[user][digest] = signedRelayer;
        uint256 orderIndex = _store(f, false, signature);

        uint256 mutation = a.mutation % 40;
        if (mutation >= MUTATIONS) mutation = M_NONE;
        // the wallet already has code: only code without isValidSignature changes anything for it
        if (f.userIdx == 1 && mutation == M_WALLET_CODE) mutation = M_NONE;
        // a permit without a token has no permitted token to change
        if (f.count == 0 && (mutation == M_TOKEN || mutation == M_AMOUNT)) mutation = M_NONE;

        Sub memory s;
        s.tailEntry = true;
        s.userIdx = f.userIdx;
        s.user = user;
        s.spender = address(proxy);
        s.relayerIdx = f.relayerIdx;
        s.permit = permit;
        s.tail = f.tail;
        s.refundTo = f.refundTo;
        s.signature = signature;
        s.extras = f.extras;
        _mutate(s, f, mutation);
        s.relayer = _relayer(s.relayerIdx);
        s.calls = _solverCalls(f, s);
        // the tail signature in permit2TransferAndMulticall: the same calls, without the probe
        if (!s.tailEntry) s.calls = _withoutLast(s.calls);
        _finishSub(s);
        s.name = string.concat(
            "tail fill #",
            vm.toString(orderIndex),
            " of ",
            acctNames[f.userIdx],
            ", mutation: ",
            _mutationName(mutation),
            ", ",
            _fillName(f)
        );
        s.cls = string.concat("mutation: ", _mutationName(mutation));

        bytes memory code = s.user.code;
        _sideEffects(s, f, mutation);
        _setAttempts(f, s);
        uint256[4] memory made = _attemptsMade();
        uint256[4] memory succeeded = _attemptsSucceeded();
        _execute(s, f);
        if (mutation == M_WALLET_CODE || mutation == M_CODE_WITHOUT_1271) vm.etch(s.user, code);
        if (s.ok && s.digest == digest) orders[orderIndex].filled = true;

        _reach(string.concat("fill ", s.ok ? "succeeded" : "reverted", ", ", acctNames[f.userIdx]));
        _reach(string.concat("mutation ", _mutationName(mutation), s.ok ? ", succeeded" : ", reverted"));
        if (s.ok && mutation == M_NONE) {
            _reach(string.concat("fill succeeded, relayer ", _relayerName(f.relayerIdx)));
            _reachFill(f, made, succeeded);
        }
        if (s.refused && f.count == 1 && _isInvalidTail(s) && mutation == M_NONE) {
            _reach(
                string.concat("refused with InvalidTail, recipient ", _acctName(f.tail.recipient), " with an orderId")
            );
            _reach(string.concat("refused with InvalidTail, tail token ", tokenNames[f.tail.token]));
        }
    }

    function _plan(Action calldata a) internal returns (Fill memory f) {
        f.userIdx = a.user % 2;
        f.relayerIdx = a.relayer % 3;
        f.aux = a.aux;
        uint256 inIdx = a.tokenIn % tokensIn.length;
        f.tokenIn = tokensIn[inIdx];
        f.tail.token = tokensOut[a.tokenOut % tokensOut.length];
        f.amount = _amountFor(f.tokenIn, a.amount);
        f.received = _received(f.tokenIn, f.amount);
        uint256 shape = a.second % 8;
        f.count = shape == 6 ? 2 : shape == 7 ? 0 : 1;
        if (f.count == 2) {
            f.second = tokensIn[(inIdx + 1 + uint256(a.second >> 3) % (tokensIn.length - 1)) % tokensIn.length];
            f.secondAmount = _amountFor(f.second, a.aux);
        }
        f.swapMode = a.swap % 6;
        if (fork && (f.swapMode == SWAP_PAYS_LESS || f.swapMode == SWAP_CALLS_BACK || f.swapMode == SWAP_PAYS_MORE)) {
            f.swapMode = SWAP_HONEST;
        }
        if (f.tail.token != f.tokenIn) {
            if (f.swapMode == SWAP_TAKES_LESS) {
                f.pull = f.received > 1 ? f.received - 1 - uint256(a.aux) % (f.received / 2) : f.received;
            } else if (f.swapMode != SWAP_NONE) {
                f.pull = f.received;
            }
            f.out = f.pull == 0 ? 0 : _quote(f.tokenIn, f.tail.token, f.pull);
            if (f.swapMode == SWAP_PAYS_LESS && f.out > 1) f.out -= 1 + uint256(a.aux) % (f.out / 2);
            if (f.swapMode == SWAP_PAYS_MORE) f.out += 1 + uint256(a.aux) % 1000;
            f.plannedB = f.out;
        } else {
            f.plannedB = f.received;
        }
        if (f.second != address(0) && f.second == f.tail.token) f.plannedB += _received(f.second, f.secondAmount);
        f.plannedB += _balance(f.tail.token, address(router));

        uint256 minMode = a.minMode % 5;
        uint256 b = f.plannedB;
        if (minMode == 0) f.tail.minAmount = b;
        else if (minMode == 1) f.tail.minAmount = b + 1;
        else if (minMode == 2) f.tail.minAmount = 1;
        else if (minMode == 3) f.tail.minAmount = b / 2;
        else f.tail.minAmount = b > 1 ? b - 1 : 1;
        if (f.tail.minAmount == 0) f.tail.minAmount = 1;

        f.recipientIdx = a.recipient % 7;
        f.tail.recipient = _recipient(f.recipientIdx);
        uint256 idChoice = a.orderId % 3;
        f.tail.orderId = idChoice == 0 ? bytes32(0) : idChoice == 1 ? ID_A : ID_B;
        uint256 r = a.refundTo % 8;
        f.refundIdx = r < 4 ? 0 : r < 6 ? 1 : r == 6 ? 2 : 3;
        f.refundTo = _refundTo(f.refundIdx, _user(f.userIdx));
        address user = _user(f.userIdx);
        f.nonce = nextNonce[user]++;
        require(f.nonce < 256 * NONCE_WORDS, "nonce space");
        f.deadline = block.timestamp + 1 + uint256(a.aux) % 1000;
        f.extras = a.extras;
        f.attempts = a.attempts;
    }

    function _permit(Fill memory f) internal pure returns (ISignatureTransfer.PermitBatchTransferFrom memory permit) {
        permit.permitted = new ISignatureTransfer.TokenPermissions[](f.count);
        if (f.count != 0) permit.permitted[0] = ISignatureTransfer.TokenPermissions(f.tokenIn, f.amount);
        if (f.count == 2) permit.permitted[1] = ISignatureTransfer.TokenPermissions(f.second, f.secondAmount);
        permit.nonce = f.nonce;
        permit.deadline = f.deadline;
    }

    /// @dev Changes one signed field of the submission, or the signature, the entry point, the time or the user's
    /// code. Everything except M_NONE, M_AT_DEADLINE and M_WALLET_CODE must make the fill revert
    function _mutate(Sub memory s, Fill memory f, uint256 mutation) internal {
        uint256 aux = f.aux;
        if (mutation == M_TOKEN) {
            address other = tokensIn[(_indexIn(f.tokenIn) + 1 + aux % (tokensIn.length - 1)) % tokensIn.length];
            s.permit.permitted[0] = ISignatureTransfer.TokenPermissions(other, f.amount);
        } else if (mutation == M_AMOUNT) {
            uint256 amount = aux % 2 == 0 || f.amount < 2 ? f.amount + 1 : f.amount - 1;
            s.permit.permitted[0] = ISignatureTransfer.TokenPermissions(f.tokenIn, amount);
        } else if (mutation == M_NONCE) {
            s.permit.nonce = f.nonce + 1;
        } else if (mutation == M_DEADLINE) {
            s.permit.deadline = f.deadline + 1;
        } else if (mutation == M_RELAYER) {
            s.relayerIdx = uint8((f.relayerIdx + 1 + aux % 2) % 3);
        } else if (mutation == M_REFUND_TO) {
            s.refundTo = _refundTo((f.refundIdx + 1 + uint8(aux % 3)) % 4, s.user);
        } else if (mutation == M_TAIL_TOKEN) {
            uint256 i = _indexOut(f.tail.token);
            s.tail.token = tokensOut[(i + 1 + aux % (tokensOut.length - 1)) % tokensOut.length];
        } else if (mutation == M_MIN_AMOUNT) {
            s.tail.minAmount = f.tail.minAmount > 1 ? f.tail.minAmount - 1 : f.tail.minAmount + 1;
        } else if (mutation == M_RECIPIENT) {
            s.tail.recipient = _recipient(uint8((f.recipientIdx + 1 + aux % 6) % 7));
        } else if (mutation == M_ORDER_ID) {
            s.tail.orderId = f.tail.orderId == ID_A ? ID_B : ID_A;
        } else if (mutation == M_SPENDER) {
            s.spender = address(proxy2);
        } else if (mutation == M_USER) {
            s.userIdx = 1 - f.userIdx;
            s.user = _user(s.userIdx);
        } else if (mutation == M_RELAYER_WITNESS_SIGNATURE) {
            // The user signed a RelayerWitness order with the same permit for the same relayer
            Call3Value[] memory oldCalls = _oldCalls(s.permit);
            bytes32 digest = _relayerDigest(s.permit, address(proxy), _relayer(f.relayerIdx), f.refundTo, oldCalls);
            s.signature = _sign(f.userIdx, digest);
            signedBy[s.user][digest] = _relayer(f.relayerIdx);
        } else if (mutation == M_TAIL_SIGNATURE_OLD_ENTRY) {
            s.tailEntry = false;
        }
    }

    function _sideEffects(Sub memory s, Fill memory f, uint256 mutation) internal {
        if (mutation == M_AFTER_DEADLINE) vm.warp(f.deadline + 1);
        if (mutation == M_AT_DEADLINE) vm.warp(f.deadline);
        if (mutation == M_CANCELLED) {
            vm.prank(s.user);
            ISignatureTransfer(PERMIT2).invalidateUnorderedNonces(f.nonce >> 8, 1 << (f.nonce & 0xff));
        }
        if (mutation == M_WALLET_CODE) vm.etch(s.user, eoaWalletCode.code);
        if (mutation == M_CODE_WITHOUT_1271) vm.etch(s.user, type(TailCodeWithoutSignatures).runtimeCode);
    }

    /// @dev The relayer's calls: the venue, the extras, and last the probe
    function _solverCalls(Fill memory f, Sub memory s) internal view returns (Call3Value[] memory cmds) {
        cmds = new Call3Value[](16);
        uint256 n;
        address tokenOut = f.tail.token;
        if (tokenOut != f.tokenIn && f.pull != 0) n = _swapCalls(cmds, n, f);
        uint256 x = 1 + uint256(f.aux) % 7;
        bool af = (f.aux >> 8) & 1 == 1;
        uint8 e = f.extras;
        if (e & X_STEAL != 0) {
            cmds[n++] = tokenOut == address(0)
                ? Call3Value(thief, af, x, "")
                : Call3Value(tokenOut, af, 0, abi.encodeCall(IERC20.transfer, (thief, x)));
        }
        if (e & X_NESTED != 0) {
            Call3Value[] memory inner = new Call3Value[](1);
            inner[0] = tokenOut == address(0)
                ? Call3Value(address(router), false, 0, abi.encodeCall(RelayRouterBase.cleanupNative, (x, thief, "")))
                : Call3Value(
                    address(router),
                    false,
                    0,
                    abi.encodeCall(RelayRouterBase.cleanupErc20s, (_one(tokenOut), _one(thief), _oneU(x), ""))
                );
            cmds[n++] = Call3Value(
                address(router), af, 0, abi.encodeCall(RelayRouterBase.multicall, (inner, address(0), address(0), META))
            );
        }
        if (e & X_SWEEP != 0) {
            cmds[n++] = tokenOut == address(0)
                ? Call3Value(
                    address(router), true, 0, abi.encodeCall(RelayRouterBase.sweepNativeWithMinimum, (0, thief, ""))
                )
                : Call3Value(
                    address(router), true, 0, abi.encodeCall(RelayRouterBase.sweepWithMinimum, (tokenOut, 0, thief, ""))
                );
        }
        if (e & X_DONATE_PROXY != 0) {
            cmds[n++] = tokenOut == address(0)
                ? Call3Value(address(proxy), true, x, "")
                : Call3Value(tokenOut, true, 0, abi.encodeCall(IERC20.transfer, (address(proxy), x)));
        }
        if (e & X_CALL_PROXY != 0) {
            cmds[n++] = Call3Value(address(proxy), true, 0, _tailEntryCall(s, new Call3Value[](0)));
        }
        if (e & X_CALL_PERMIT2 != 0) {
            cmds[n++] = Call3Value(PERMIT2, true, 0, _stolenPermit2Call(s, f.relayerIdx));
            cmds[n++] = Call3Value(
                PERMIT2,
                true,
                0,
                abi.encodeWithSelector(PERMIT2_ALLOWANCE_TRANSFER, s.user, thief, uint160(1), f.tokenIn)
            );
        }
        if (e & X_CALL_DEPOSITORY != 0) {
            cmds[n++] = Call3Value(
                DEPOSITORY, true, 0, abi.encodeWithSignature("depositNative(address,bytes32)", s.user, f.tail.orderId)
            );
            if (tokenOut != address(0)) {
                cmds[n++] = Call3Value(
                    DEPOSITORY,
                    true,
                    0,
                    abi.encodeWithSignature("depositErc20(address,address,bytes32)", s.user, tokenOut, f.tail.orderId)
                );
            }
        }
        if (e & X_EVIL_CALLBACK != 0) {
            cmds[n++] = Call3Value(address(evil), true, 0, abi.encodeCall(TailEvilRelayer.reenter, ()));
        }
        cmds[n++] = Call3Value(address(probe), false, 0, abi.encodeCall(TailProbe.snap, (tokenOut, s.tail.recipient)));
        assembly ("memory-safe") {
            mstore(cmds, n)
        }
    }

    function _swapCalls(Call3Value[] memory cmds, uint256 n, Fill memory f) internal view returns (uint256) {
        address tokenOut = f.tail.token;
        if (!fork) {
            cmds[n++] = Call3Value(f.tokenIn, false, 0, abi.encodeCall(IERC20.approve, (venue, f.pull)));
            cmds[n++] = Call3Value(
                venue,
                false,
                0,
                abi.encodeCall(TailVenue.swap, (f.tokenIn, f.pull, tokenOut, f.out, f.swapMode == SWAP_CALLS_BACK))
            );
            return n;
        }
        if (tokenOut == address(0) && f.tokenIn == WETH) {
            cmds[n++] = Call3Value(WETH, false, 0, abi.encodeCall(ITailWeth.withdraw, (f.pull)));
            return n;
        }
        cmds[n++] = Call3Value(f.tokenIn, false, 0, abi.encodeCall(IERC20.approve, (SWAP_ROUTER, f.pull)));
        cmds[n++] = Call3Value(
            SWAP_ROUTER,
            false,
            0,
            abi.encodeCall(
                ITailSwapRouter.exactInputSingle,
                (ITailSwapRouter.ExactInputSingleParams(
                        f.tokenIn,
                        tokenOut == address(0) ? WETH : tokenOut,
                        500,
                        tokenOut == address(0) ? address(2) : address(router),
                        f.pull,
                        0,
                        0
                    ))
            )
        );
        if (tokenOut == address(0)) {
            cmds[n++] = Call3Value(
                SWAP_ROUTER, false, 0, abi.encodeWithSignature("unwrapWETH9(uint256,address)", 0, address(router))
            );
        }
        return n;
    }

    // ================================================================ permit2TransferAndMulticall fills

    /// @dev A RelayerWitness order: the calls are signed. Action.mutation % 4: 0 as signed, 1 another relayer
    /// submits, 2 the calls are changed, 3 the RelayerWitness signature is used in the tail entry point
    function _oldEntry(Action calldata a) internal {
        Fill memory f = _plan(a);
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _permit(f);
        address user = _user(f.userIdx);
        address signedRelayer = _relayer(f.relayerIdx);
        Call3Value[] memory oldCalls = _oldCalls(permit);
        bytes32 digest = _relayerDigest(permit, address(proxy), signedRelayer, f.refundTo, oldCalls);
        bytes memory signature = _sign(f.userIdx, digest);
        signedBy[user][digest] = signedRelayer;
        uint256 orderIndex = _store(f, true, signature);
        uint256 sub = a.mutation % 4;

        Sub memory s;
        s.tailEntry = sub == 3;
        s.userIdx = f.userIdx;
        s.user = user;
        s.spender = address(proxy);
        s.relayerIdx = sub == 1 ? uint8((f.relayerIdx + 1) % 3) : f.relayerIdx;
        s.relayer = _relayer(s.relayerIdx);
        s.permit = permit;
        s.tail = f.tail;
        s.refundTo = f.refundTo;
        s.signature = signature;
        s.extras = f.extras;
        if (sub == 2) {
            oldCalls[0].callData = abi.encodeCall(
                RelayRouterBase.cleanupErc20s,
                (_tokens(permit), _repeat(thief, permit.permitted.length), new uint256[](permit.permitted.length), "")
            );
        }
        s.calls = sub == 3 ? _solverCalls(f, s) : oldCalls;
        _finishSub(s);
        string[4] memory subs = ["as signed", "by another relayer", "with changed calls", "in the tail entry point"];
        s.name = string.concat(
            "permit2TransferAndMulticall order #",
            vm.toString(orderIndex),
            " of ",
            acctNames[f.userIdx],
            ", ",
            subs[sub]
        );
        s.cls = string.concat("RelayerWitness order ", subs[sub]);
        _setAttempts(f, s);
        _execute(s, f);
        if (s.ok && s.digest == digest) orders[orderIndex].filled = true;
        _reach(string.concat("RelayerWitness order ", subs[sub], s.ok ? ", succeeded" : ", reverted"));
        if (permit.permitted.length != 1) {
            _reach(
                string.concat(
                    "RelayerWitness order ",
                    subs[sub],
                    " with ",
                    vm.toString(permit.permitted.length),
                    " permitted tokens",
                    s.ok ? ", succeeded" : ", reverted"
                )
            );
        }
    }

    function _oldCalls(ISignatureTransfer.PermitBatchTransferFrom memory permit)
        internal
        view
        returns (Call3Value[] memory c)
    {
        c = new Call3Value[](1);
        c[0] = Call3Value(
            address(router),
            false,
            0,
            abi.encodeCall(
                RelayRouterBase.cleanupErc20s,
                (
                    _tokens(permit),
                    _repeat(eoaRecipient, permit.permitted.length),
                    new uint256[](permit.permitted.length),
                    ""
                )
            )
        );
    }

    // ================================================================ replays

    /// @dev Submits an earlier order again, by its own relayer (Action.mutation even) or another one, with a fresh
    /// honest plan. A filled or cancelled order must not fill again
    function _replay(Action calldata a) internal {
        uint256 index = uint256(a.aux) % orders.length;
        Order memory o = orders[index];
        Fill memory f;
        f.userIdx = o.userIdx;
        f.relayerIdx = o.relayerIdx;
        f.tokenIn = o.tokens[0];
        f.amount = o.amounts[0];
        f.received = _received(f.tokenIn, f.amount);
        f.count = o.count;
        if (o.count == 2) {
            f.second = o.tokens[1];
            f.secondAmount = o.amounts[1];
        }
        f.swapMode = o.swapMode == SWAP_NONE ? SWAP_NONE : SWAP_HONEST;
        f.tail = o.tail;
        f.refundTo = o.refundTo;
        f.nonce = o.nonce;
        f.deadline = o.deadline;
        f.aux = a.aux;
        if (f.tail.token != f.tokenIn && f.swapMode != SWAP_NONE) {
            f.pull = f.received;
            f.out = _quote(f.tokenIn, f.tail.token, f.pull);
        }
        Sub memory s;
        s.tailEntry = !o.oldEntry;
        s.userIdx = o.userIdx;
        s.user = _user(o.userIdx);
        s.spender = address(proxy);
        s.relayerIdx = a.mutation % 2 == 0 ? o.relayerIdx : uint8((o.relayerIdx + 1) % 3);
        s.relayer = _relayer(s.relayerIdx);
        s.permit = _permit(f);
        s.tail = o.tail;
        s.refundTo = o.refundTo;
        s.signature = o.signature;
        s.calls = o.oldEntry ? _oldCalls(s.permit) : _solverCalls(f, s);
        _finishSub(s);
        string memory state = o.filled
            ? "filled"
            : _bitSet(s.user, o.nonce) ? "cancelled" : block.timestamp > o.deadline ? "expired" : "pending";
        s.name = string.concat(
            "replay of order #",
            vm.toString(index),
            " (",
            state,
            ") by ",
            _relayerName(s.relayerIdx),
            a.mutation % 2 == 0 ? ", its own relayer" : ", not its relayer"
        );
        s.cls = string.concat("replay of a ", state, " order");
        _setAttempts(f, s);
        _execute(s, f);
        if (s.ok && a.mutation % 2 == 0) orders[index].filled = true;
        _reach(string.concat("replay of a ", state, " order", s.ok ? ", succeeded" : ", reverted"));
    }

    // ================================================================ attackers

    /// @dev Someone who is not a relayer calls a proxy, router or Permit2 function with the user's signature of an
    /// earlier order, or pulls the user's funds through allowances. Action.mutation % 9 picks the function
    function _attack(Action calldata a) internal {
        uint256 index = uint256(a.aux) % orders.length;
        Order memory o = orders[index];
        Sub memory s;
        s.tailEntry = !o.oldEntry;
        s.userIdx = o.userIdx;
        s.user = _user(o.userIdx);
        s.permit.permitted = new ISignatureTransfer.TokenPermissions[](o.count);
        for (uint256 i; i < o.count; ++i) {
            s.permit.permitted[i] = ISignatureTransfer.TokenPermissions(o.tokens[i], o.amounts[i]);
        }
        s.permit.nonce = o.nonce;
        s.permit.deadline = o.deadline;
        s.tail = o.tail;
        s.refundTo = o.refundTo;
        s.signature = o.signature;
        s.relayer = thief;
        uint256 sub = a.mutation % 10;
        address token = o.tokens[0];
        Call3Value[] memory pulls = new Call3Value[](3);
        pulls[0] = Call3Value(PERMIT2, true, 0, _stolenPermit2Call(s, o.relayerIdx));
        pulls[1] = Call3Value(token, true, 0, abi.encodeCall(IERC20.transferFrom, (s.user, thief, 1)));
        pulls[2] = Call3Value(
            PERMIT2, true, 0, abi.encodeWithSelector(PERMIT2_ALLOWANCE_TRANSFER, s.user, thief, uint160(1), token)
        );
        address target;
        bytes memory data;
        string[10] memory names = [
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
        if (sub == 0) {
            target = PERMIT2;
            data = _stolenPermit2Call(s, o.relayerIdx);
        } else if (sub == 1) {
            target = address(proxy);
            data = o.oldEntry
                ? abi.encodeCall(
                    RelayApprovalProxyBase.permit2TransferAndMulticall,
                    (s.user, s.permit, _oldCalls(s.permit), s.refundTo, address(0), META, s.signature)
                )
                : _tailEntryCall(s, new Call3Value[](0));
        } else if (sub == 2) {
            target = address(proxy);
            data = abi.encodeCall(
                RelayApprovalProxyBase.permit2TransferAndMulticall,
                (s.user, s.permit, pulls, thief, address(0), META, "")
            );
        } else if (sub == 3) {
            target = address(proxy);
            data = abi.encodeCall(
                RelayApprovalProxyBase.transferAndMulticall,
                (new address[](0), new uint256[](0), pulls, thief, address(0), META)
            );
        } else if (sub == 4) {
            Permit2612[] memory permits = new Permit2612[](1);
            permits[0] = Permit2612(token, s.user, 1, block.timestamp, 27, bytes32(0), bytes32(0));
            target = address(proxy);
            data = abi.encodeCall(
                RelayApprovalProxyBase.permitTransferAndMulticall, (permits, pulls, thief, address(0), META)
            );
        } else if (sub == 5) {
            Permit3009[] memory permits = new Permit3009[](1);
            permits[0] = Permit3009(s.user, 1, 0, block.timestamp + 1, 27, bytes32(0), bytes32(0));
            bytes[] memory sigs = new bytes[](1);
            sigs[0] = s.signature;
            target = address(proxy);
            data = abi.encodeCall(
                RelayApprovalProxyBase.permit3009TransferAndMulticall,
                (permits, _one(token), pulls, thief, address(0), META, sigs)
            );
        } else if (sub == 6) {
            target = address(router);
            data = abi.encodeCall(RelayRouterBase.multicall, (pulls, thief, address(0), META));
        } else if (sub == 7) {
            Call3Value[] memory sweeps = new Call3Value[](ledgerTokens.length + 2);
            for (uint256 t; t < ledgerTokens.length; ++t) {
                sweeps[t] = Call3Value(
                    address(router),
                    true,
                    0,
                    abi.encodeCall(RelayRouterBase.sweepWithMinimum, (ledgerTokens[t], 0, thief, ""))
                );
            }
            sweeps[ledgerTokens.length] = Call3Value(
                address(router), true, 0, abi.encodeCall(RelayRouterBase.sweepNativeWithMinimum, (0, thief, ""))
            );
            sweeps[ledgerTokens.length + 1] = Call3Value(
                address(router),
                true,
                0,
                abi.encodeCall(
                    RelayRouterBase.cleanupErc20sViaCall,
                    (_one(token), _one(PERMIT2), _oneB(_stolenPermit2Call(s, o.relayerIdx)), _oneU(1))
                )
            );
            target = address(router);
            data = abi.encodeCall(RelayRouterBase.multicall, (sweeps, thief, address(0), META));
        } else if (sub == 8) {
            target = address(proxy);
            data = abi.encodeCall(RelayApprovalProxyBase.withdraw, (token, thief));
        } else {
            target = address(proxy);
            data = abi.encodeCall(RelayApprovalProxyBase.setDepository, (thief, true));
        }
        s.name = string.concat("attack on order #", vm.toString(index), ": ", names[sub]);
        s.cls = string.concat("attack: ", names[sub]);
        _call(s, thief, target, data);
        if (proxy.isDepository(thief)) {
            _violate("depository rule", s.cls, string.concat("the thief is an allowed depository. ", s.name));
        }
        _reach(string.concat("attack ", names[sub], s.ok ? ", succeeded" : ", reverted"));
    }

    // ================================================================ griefers and users

    /// @dev Action.mutation % 5: 0 token dust to the router, 1 native dust to the router, 2 a deposit under the id
    /// of an order, 3 the user cancels an order, 4 the thief takes the router's residue
    function _grief(Action calldata a) internal {
        uint256 sub = a.mutation % 5;
        if ((sub == 2 || sub == 3) && orders.length == 0) sub = 0;
        Sub memory s;
        address token = ledgerTokens[a.tokenIn % ledgerTokens.length];
        uint256 x = _amountFor(token, a.amount);
        address caller = griefer;
        address target;
        bytes memory data;
        uint256 value;
        if (sub == 0) {
            _fund(token, griefer, x);
            target = token;
            data = abi.encodeCall(IERC20.transfer, (address(router), x));
            s.name = string.concat("the griefer sends ", vm.toString(x), " ", tokenNames[token], " to the router");
        } else if (sub == 1) {
            value = 1 + uint256(a.aux) % 1e15;
            vm.deal(griefer, value);
            target = address(router);
            s.name = string.concat("the griefer sends ", vm.toString(value), " wei to the router");
        } else if (sub == 2) {
            Order memory o = orders[uint256(a.aux) % orders.length];
            bytes32 id = o.tail.orderId == bytes32(0) ? ID_A : o.tail.orderId;
            if (a.amount % 2 == 0) {
                value = 1 + uint256(a.aux) % 1e15;
                vm.deal(griefer, value);
                target = DEPOSITORY;
                data = abi.encodeWithSignature("depositNative(address,bytes32)", _user(o.userIdx), id);
            } else {
                _fund(token, griefer, x);
                vm.prank(griefer);
                SafeTransferLib.safeApprove(token, DEPOSITORY, x);
                target = DEPOSITORY;
                data = abi.encodeWithSignature("depositErc20(address,address,bytes32)", _user(o.userIdx), token, id);
            }
            s.name = "the griefer deposits under an order's id";
        } else if (sub == 3) {
            uint256 index = uint256(a.aux) % orders.length;
            Order memory o = orders[index];
            caller = _user(o.userIdx);
            target = PERMIT2;
            data = abi.encodeCall(ISignatureTransfer.invalidateUnorderedNonces, (o.nonce >> 8, 1 << (o.nonce & 0xff)));
            s.name = string.concat("the user cancels order #", vm.toString(index));
        } else {
            Call3Value[] memory sweeps = new Call3Value[](ledgerTokens.length + 1);
            for (uint256 t; t < ledgerTokens.length; ++t) {
                sweeps[t] = Call3Value(
                    address(router),
                    true,
                    0,
                    abi.encodeCall(RelayRouterBase.sweepWithMinimum, (ledgerTokens[t], 0, thief, ""))
                );
            }
            sweeps[ledgerTokens.length] = Call3Value(
                address(router), true, 0, abi.encodeCall(RelayRouterBase.sweepNativeWithMinimum, (0, thief, ""))
            );
            caller = thief;
            target = address(router);
            data = abi.encodeCall(RelayRouterBase.multicall, (sweeps, thief, address(0), META));
            s.name = "the thief sweeps the router's residue";
        }
        s.cls = s.name;
        s.relayer = caller;
        uint256 thiefBefore = _thiefHoldings();
        _callWithValue(s, caller, target, data, value);
        if (sub == 4 && s.ok && _thiefHoldings() > thiefBefore) _reach("the thief took residue from the router");
        string[5] memory names = [
            "griefer dust, token",
            "griefer dust, native",
            "griefer deposit under an order id",
            "user cancels",
            "thief sweeps"
        ];
        _reach(string.concat(names[sub], s.ok ? ", succeeded" : ", reverted"));
    }

    // ================================================================ execution and checks

    function _finishSub(Sub memory s) internal view {
        s.digest = s.tailEntry
            ? _tailDigest(s.permit, s.spender, s.relayer, s.refundTo, s.tail)
            : _relayerDigest(s.permit, s.spender, s.relayer, s.refundTo, s.calls);
        s.tailCalldata = _tailCalldata(s.user, s.tail);
    }

    /// @dev Submits a fill through its relayer and checks T1 and, for a tail fill that succeeded, T2
    function _execute(Sub memory s, Fill memory f) internal {
        bytes memory data = s.tailEntry
            ? _tailEntryCall(s, s.calls)
            : abi.encodeCall(
                RelayApprovalProxyBase.permit2TransferAndMulticall,
                (s.user, s.permit, s.calls, s.refundTo, address(0), META, s.signature)
            );
        _topUp(s);
        s.refused = s.tailEntry && s.tail.orderId != bytes32(0) && s.tail.recipient != DEPOSITORY
            && !RelayApprovalProxyBase(payable(s.spender)).isDepository(s.tail.recipient);
        Snap memory before = _snap();
        uint256 probeRuns = probe.runs();
        vm.recordLogs();
        vm.startStateDiffRecording();
        if (s.relayerIdx == 0) {
            (s.ok, s.ret) = _viaMulticaller(s.spender, data);
        } else if (s.relayerIdx == 1) {
            vm.prank(relayerEoa);
            (s.ok, s.ret) = s.spender.call(data);
        } else {
            (s.ok, s.ret) = evil.submit(s.spender, data);
        }
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Snap memory afterwards = _snap();
        _checkT1(s, before, afterwards, acc, true);
        _checkTailRules(s, acc);
        if (s.ok && s.tailEntry) {
            _checkT2(s, f, logs, acc, probeRuns);
            _checkRefund(s, f, before, afterwards);
        }
        if (s.ok) _reachFreshFills(acc);
    }

    /// @dev The tail's rules on its fields. The one-token rule: a tail whose permit does not hold exactly one token
    /// reverts with InvalidTail(). The depository rule (#83): so does a tail with an orderId to a recipient the
    /// spender does not know as a depository. A refused tail reverts before any call reaches Permit2 or the router,
    /// so before any solver call runs, and no tail that both rules allow reverts with InvalidTail()
    function _checkTailRules(Sub memory s, Vm.AccountAccess[] memory acc) internal {
        bool invalidTail = _isInvalidTail(s);
        uint256 count = s.permit.permitted.length;
        bool wrongCount = s.tailEntry && count != 1;
        if (wrongCount) {
            _reach(string.concat("one-token rule: a tail permit with ", vm.toString(count), " tokens was submitted"));
        }
        if (s.refused) _reach("depository rule: a tail with an orderId to an unknown recipient was submitted");
        if (!wrongCount && !s.refused) {
            if (invalidTail) {
                _violate(
                    "depository rule",
                    string.concat("InvalidTail() for ", _acctName(s.tail.recipient), ", ", s.cls),
                    string.concat("a fill the rules allow reverted with InvalidTail(). ", s.name)
                );
            }
            return;
        }
        // the proxy checks the permit's length first
        string memory rule = wrongCount ? "one-token rule" : "depository rule";
        string memory what = wrongCount
            ? string.concat(vm.toString(count), " permitted tokens, ", s.cls)
            : string.concat("an orderId to ", _acctName(s.tail.recipient), ", ", s.cls);
        if (!invalidTail) {
            _violate(
                rule,
                what,
                string.concat(
                    "the fill ", s.ok ? "succeeded" : "reverted otherwise", ", expected InvalidTail(). ", s.name
                )
            );
            return;
        }
        _reach("T1.3 checked a tail refused with InvalidTail");
        if (wrongCount) {
            _reach(string.concat("one-token rule: refused with InvalidTail, ", vm.toString(count), " permitted tokens"));
        }
        if (_called(acc, address(router))) {
            _violate(rule, what, string.concat("a call reached the router before InvalidTail(). ", s.name));
        }
        if (_called(acc, PERMIT2)) {
            _violate(rule, what, string.concat("a call reached Permit2 before InvalidTail(). ", s.name));
        }
    }

    function _isInvalidTail(Sub memory s) internal pure returns (bool) {
        return
            !s.ok && keccak256(s.ret) == keccak256(abi.encodeWithSelector(RelayApprovalProxyBase.InvalidTail.selector));
    }

    /// @dev Any other call, from `caller`: T1.1 and, if it reverts, T1.3
    function _call(Sub memory s, address caller, address target, bytes memory data) internal {
        _callWithValue(s, caller, target, data, 0);
    }

    function _callWithValue(Sub memory s, address caller, address target, bytes memory data, uint256 value) internal {
        Snap memory before = _snap();
        vm.recordLogs();
        vm.startStateDiffRecording();
        vm.prank(caller);
        (s.ok, s.ret) = target.call{value: value}(data);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        vm.getRecordedLogs();
        Snap memory afterwards = _snap();
        // a call the user makes may move the user's funds: only the user's cancel is one, and it moves nothing
        _checkT1(s, before, afterwards, acc, false);
    }

    // ---------------------------------------------------------------- T1

    function _checkT1(Sub memory s, Snap memory b, Snap memory e, Vm.AccountAccess[] memory acc, bool fill) internal {
        Debit[] memory debits = _debits(acc);
        for (uint8 u; u < 2; ++u) {
            address user = _user(u);
            string memory how = _decrease(u, user, b, e, debits);
            if (bytes(how).length == 0) continue;
            _reach("T1.1 a user's balance decreased");
            string memory why;
            if (!fill) {
                why = "the call is not a fill";
            } else if (!s.ok) {
                why = "the fill reverted";
            } else if (s.user != user) {
                why = "the fill was for the other user";
            } else if (signedBy[user][s.digest] == address(0)) {
                why = "the user never signed the digest of the submitted fields";
            } else if (signedBy[user][s.digest] != s.relayer) {
                why = "msg.sender is not the signed relayer";
            } else if (block.timestamp > s.permit.deadline) {
                why = "block.timestamp is after the deadline";
            } else if (_bitIn(b, u, s.permit.nonce)) {
                why = "the nonce bit was already set";
            }
            if (bytes(why).length != 0) {
                _violate("T1.1", s.cls, string.concat(acctNames[u], ": ", how, ", but ", why, ". ", s.name));
            }
        }
        if (fill && s.ok) {
            _reach("T1.2 checked a successful fill");
            _checkT1_2(s, b, e, debits);
        }
        if (!s.ok) {
            _reach("T1.3 checked a call that reverted");
            string memory diff = _diff(b, e);
            if (bytes(diff).length != 0) _violate("T1.3", s.cls, string.concat(diff, ". ", s.name));
        }
    }

    function _checkT1_2(Sub memory s, Snap memory b, Snap memory e, Debit[] memory debits) internal {
        uint256 n = s.permit.permitted.length;
        bool[] memory matched = new bool[](n);
        for (uint256 i; i < debits.length; ++i) {
            if (debits[i].from != s.user) continue;
            bool found;
            for (uint256 j; j < n && !found; ++j) {
                if (
                    !matched[j] && s.permit.permitted[j].token == debits[i].token
                        && s.permit.permitted[j].amount == debits[i].amount && debits[i].to == address(router)
                ) {
                    matched[j] = true;
                    found = true;
                }
            }
            if (!found) {
                _violate(
                    "T1.2",
                    s.cls,
                    string.concat(
                        "a debit of ",
                        vm.toString(debits[i].amount),
                        " ",
                        tokenNames[debits[i].token],
                        " to ",
                        _acctName(debits[i].to),
                        " is not one transfer of a permitted amount to the router. ",
                        s.name
                    )
                );
            }
        }
        for (uint256 j; j < n; ++j) {
            if (!matched[j]) {
                _violate(
                    "T1.2",
                    s.cls,
                    string.concat(
                        "permitted ",
                        tokenNames[s.permit.permitted[j].token],
                        " did not move in exactly one transfer. ",
                        s.name
                    )
                );
            }
        }
        // no balance of the user decreased beyond its debits
        uint256 nt = ledgerTokens.length;
        for (uint256 t; t <= nt; ++t) {
            uint256 debited;
            for (uint256 i; i < debits.length; ++i) {
                if (debits[i].from == s.user && t < nt && debits[i].token == ledgerTokens[t]) {
                    debited += debits[i].amount;
                }
            }
            uint256 k = s.userIdx * (nt + 1) + t;
            if (e.bal[k] + debited < b.bal[k]) {
                _violate(
                    "T1.2",
                    s.cls,
                    string.concat("the user's ", _ledgerTokenName(t), " fell beyond its debits. ", s.name)
                );
            }
        }
        // exactly one bit of the user's nonce bitmap is set: the signed nonce's
        for (uint256 u; u < 2; ++u) {
            for (uint256 w; w < NONCE_WORDS; ++w) {
                uint256 k = u * NONCE_WORDS + w;
                uint256 expected = b.words[k];
                if (u == s.userIdx && w == s.permit.nonce >> 8) expected |= 1 << (s.permit.nonce & 0xff);
                if (e.words[k] != expected) {
                    _violate(
                        "T1.2",
                        s.cls,
                        string.concat(
                            "nonce word ",
                            vm.toString(w),
                            " of ",
                            acctNames[u],
                            " is ",
                            vm.toString(bytes32(e.words[k])),
                            ", expected ",
                            vm.toString(bytes32(expected)),
                            ". ",
                            s.name
                        )
                    );
                }
            }
        }
        // no allowance of the user changed. A token that lowers even an unlimited allowance (USDC) lowers the user's
        // allowance for Permit2 by what Permit2 pulled: that is the permitted transfer itself, not another change
        uint256 per = nt * spenders.length;
        for (uint256 i = s.userIdx * per; i < (s.userIdx + 1) * per; ++i) {
            if (b.allow[i] == e.allow[i]) continue;
            if (spenders[i % spenders.length] == PERMIT2) {
                address token = ledgerTokens[(i % per) / spenders.length];
                uint256 pulled;
                for (uint256 d; d < debits.length; ++d) {
                    if (debits[d].from == s.user && debits[d].token == token && debits[d].by == PERMIT2) {
                        pulled += debits[d].amount;
                    }
                }
                if (e.allow[i] + pulled == b.allow[i]) continue;
            }
            _violate("T1.2", s.cls, string.concat("the user's ", _allowName(i), " changed. ", s.name));
        }
        uint256 per2 = nt * p2Spenders.length;
        for (uint256 i = s.userIdx * per2; i < (s.userIdx + 1) * per2; ++i) {
            if (b.p2[i] != e.p2[i]) {
                _violate("T1.2", s.cls, string.concat("a Permit2 allowance of the user changed. ", s.name));
            }
        }
        // the proxies' balances do not change
        for (uint256 a = 3; a <= 4; ++a) {
            for (uint256 t; t <= nt; ++t) {
                uint256 k = a * (nt + 1) + t;
                if (b.bal[k] != e.bal[k]) {
                    _violate(
                        "T1.2",
                        string.concat(
                            "the proxy's balance changed, refundTo ",
                            _acctName(s.refundTo),
                            s.extras & X_DONATE_PROXY != 0 ? ", the relayer sends tail.token to the proxy" : "",
                            ", ",
                            s.cls
                        ),
                        string.concat(
                            acctNames[a],
                            "'s ",
                            _ledgerTokenName(t),
                            " went from ",
                            vm.toString(b.bal[k]),
                            " to ",
                            vm.toString(e.bal[k]),
                            " in a successful fill. ",
                            s.name
                        )
                    );
                }
            }
        }
    }

    /// @dev "" if nothing of the user decreased, else what did
    function _decrease(uint8 u, address user, Snap memory b, Snap memory e, Debit[] memory debits)
        internal
        view
        returns (string memory)
    {
        for (uint256 i; i < debits.length; ++i) {
            if (debits[i].from == user) {
                return string.concat(
                    vm.toString(debits[i].amount),
                    " ",
                    tokenNames[debits[i].token],
                    " left the user to ",
                    _acctName(debits[i].to)
                );
            }
        }
        uint256 nt = ledgerTokens.length;
        for (uint256 t; t <= nt; ++t) {
            uint256 k = u * (nt + 1) + t;
            if (e.bal[k] < b.bal[k]) {
                return string.concat(
                    "the user's ",
                    _ledgerTokenName(t),
                    " fell from ",
                    vm.toString(b.bal[k]),
                    " to ",
                    vm.toString(e.bal[k])
                );
            }
        }
        return "";
    }

    function _debits(Vm.AccountAccess[] memory acc) internal view returns (Debit[] memory list) {
        list = new Debit[](acc.length);
        uint256 n;
        for (uint256 i; i < acc.length; ++i) {
            Vm.AccountAccess memory x = acc[i];
            if (
                x.kind != VmSafe.AccountAccessKind.Call || x.reverted || x.data.length < 68
                    || !_isLedgerToken(x.account)
            ) {
                continue;
            }
            bytes4 selector = bytes4(x.data);
            if (selector == IERC20.transferFrom.selector && x.data.length >= 100) {
                address from = address(uint160(_word(x.data, 0)));
                if (from == userEoa || from == address(wallet)) {
                    list[n++] = Debit(x.account, from, address(uint160(_word(x.data, 1))), _word(x.data, 2), x.accessor);
                }
            } else if (selector == IERC20.transfer.selector && (x.accessor == userEoa || x.accessor == address(wallet)))
            {
                list[n++] =
                    Debit(x.account, x.accessor, address(uint160(_word(x.data, 0))), _word(x.data, 1), x.accessor);
            }
        }
        assembly ("memory-safe") {
            mstore(list, n)
        }
    }

    // ---------------------------------------------------------------- refunds

    /// @dev "refund": see the comment at the top. `b` and `e` are the ledger before and after the fill
    function _checkRefund(Sub memory s, Fill memory f, Snap memory b, Snap memory e) internal {
        address token = s.permit.permitted[0].token;
        bool toUser = s.refundTo == s.user;
        if (token == s.tail.token || (!toUser && s.refundTo != thirdParty)) return;
        if (token == _hookToken() && f.attempts & (A_SWEEP | A_CLEANUP) != 0) return;
        _reach("refund checked a successful tail fill");
        _reach(string.concat("refund checked, refundTo ", _acctName(s.refundTo)));
        uint256 stride = ledgerTokens.length + 1;
        uint256 t = _ledgerIndex(token);
        uint256 routerAt = _acctIndex(address(router)) * stride + t;
        uint256 at = _acctIndex(s.refundTo) * stride + t;
        uint256 left = b.bal[routerAt] + f.received - f.pull;
        if (left != 0) _reach("refund checked, input left over");
        uint256 expected = _received(token, left);
        // the user's debit of the permitted amount, which T1.2 checks
        uint256 debit = toUser ? s.permit.permitted[0].amount : 0;
        string memory numbers = string.concat(
            "the router held ",
            vm.toString(b.bal[routerAt]),
            " before the fill and received ",
            vm.toString(f.received),
            ", the venue took ",
            vm.toString(f.pull),
            ". ",
            s.name
        );
        if (e.bal[at] + debit != b.bal[at] + expected) {
            uint256 got = e.bal[at] + debit >= b.bal[at] ? e.bal[at] + debit - b.bal[at] : 0;
            _violate(
                "refund",
                string.concat("refundTo ", _acctName(s.refundTo), " got another amount, ", s.cls),
                string.concat(
                    _acctName(s.refundTo),
                    " got ",
                    vm.toString(got),
                    " ",
                    tokenNames[token],
                    ", expected ",
                    vm.toString(expected),
                    "; ",
                    numbers
                )
            );
        }
        if (e.bal[routerAt] != 0) {
            _violate(
                "refund",
                string.concat("the router kept the permitted token, ", s.cls),
                string.concat("the router kept ", vm.toString(e.bal[routerAt]), " ", tokenNames[token], "; ", numbers)
            );
        }
    }

    // ---------------------------------------------------------------- T2

    function _checkT2(
        Sub memory s,
        Fill memory f,
        Vm.Log[] memory logs,
        Vm.AccountAccess[] memory acc,
        uint256 probeRuns
    ) internal {
        if (probe.runs() != probeRuns + 1) {
            _violate(
                "harness",
                "probe",
                string.concat("the probe ran ", vm.toString(probe.runs() - probeRuns), " times. ", s.name)
            );
            return;
        }
        _reach("T2 checked a successful tail fill");
        uint256 B = probe.routerBalance();
        uint256 recipientBefore = probe.recipientBalance();
        RelayApprovalProxyBase.SweepWithMinimum memory tail = s.tail;
        bytes32 tailHash = keccak256(s.tailCalldata);
        string memory cls = _t2Class(s, f);
        string memory numbers = string.concat(
            "B ", vm.toString(B), ", minAmount ", vm.toString(tail.minAmount), ", fill succeeded. ", s.name
        );

        // The tail's logs, the last SolverCallExecuted, and what reached the recipient after the tail
        uint256 start = type(uint256).max;
        uint256 end = type(uint256).max;
        uint256 lastSolverCall = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0) continue;
            bytes32 topic = logs[i].topics[0];
            if (logs[i].emitter == address(probe) && topic == TAIL_STARTS) start = i;
            if (logs[i].emitter == address(router) && topic == SOLVER_CALL_EXECUTED) {
                lastSolverCall = i;
                if (keccak256(logs[i].data) == keccak256(abi.encode(address(router), tailHash, uint256(0)))) end = i;
            }
        }
        // T2.4
        Result[] memory results = abi.decode(s.ret, (Result[]));
        if (end == type(uint256).max || lastSolverCall != end) {
            _violate(
                "T2.4",
                cls,
                string.concat("the last SolverCallExecuted is not (router, keccak256(tailCalldata), 0). ", numbers)
            );
        }
        if (results.length != s.calls.length + 1) {
            _violate(
                "T2.4",
                cls,
                string.concat(
                    "returnData has ",
                    vm.toString(results.length),
                    " results for ",
                    vm.toString(s.calls.length),
                    " solver calls. ",
                    numbers
                )
            );
        }
        if (start == type(uint256).max || end == type(uint256).max || start > end) {
            _violate("harness", "logs", string.concat("cannot find the tail's logs. ", s.name));
            return;
        }
        uint256 depositLogs;
        uint256 logAt;
        uint256 refunded;
        for (uint256 i = start + 1; i < logs.length; ++i) {
            if (logs[i].topics.length == 0) continue;
            bytes32 topic = logs[i].topics[0];
            if (
                i < end && (topic == ERC20_DEPOSIT || topic == NATIVE_DEPOSIT)
                    && (logs[i].emitter == DEPOSITORY
                        || logs[i].emitter == depository2
                        || logs[i].emitter == tail.recipient)
            ) {
                ++depositLogs;
                logAt = i;
            }
            if (i > end && logs[i].emitter == address(router) && topic == FUNDS_MOVEMENT) {
                (, address to, address currency, uint256 amount,) =
                    abi.decode(logs[i].data, (address, address, address, uint256, bytes));
                if (to == tail.recipient && currency == tail.token) refunded += amount;
            }
        }

        // The tail's frame in the state diff: the calls with value the router makes in it, and its deposit calls
        (uint256 valueCalls, address valueTo, uint256 value, uint256 depositCalls, bool found) =
            _tailFrame(acc, tailHash, tail.recipient);
        if (!found) {
            _violate("harness", "state diff", string.concat("cannot find the tail's frame. ", s.name));
            return;
        }
        if (depositCalls != _countLooksLikeDepositoryLogs(logs, start, end, tail.recipient)) {
            _violate(
                "harness", "deposit logs", string.concat("deposit logs and successful deposit calls disagree. ", s.name)
            );
        }

        // T2.1
        if (B < tail.minAmount) _violate("T2.1", cls, string.concat("B is below minAmount. ", numbers));
        uint256 delivered;
        if (tail.token != address(0)) {
            uint256 nowBalance = IERC20(tail.token).balanceOf(tail.recipient);
            delivered = nowBalance >= recipientBefore + refunded ? nowBalance - recipientBefore - refunded : 0;
            if (delivered != B) {
                _violate("T2.1", cls, string.concat("recipient +", vm.toString(delivered), ", ", numbers));
            }
        } else {
            if (valueCalls != 1 || valueTo != tail.recipient || value != B) {
                _violate(
                    "T2.1",
                    cls,
                    string.concat(
                        "the router made ",
                        vm.toString(valueCalls),
                        " calls with value in the tail, the last ",
                        vm.toString(value),
                        " wei to ",
                        _acctName(valueTo),
                        ". ",
                        numbers
                    )
                );
            }
            uint256 nowBalance = tail.recipient.balance;
            delivered = nowBalance >= recipientBefore + refunded ? nowBalance - recipientBefore - refunded : 0;
        }

        if (tail.orderId != bytes32(0)) {
            // T2.2
            _reach("T2.2 checked a fill with an orderId");
            if (tail.recipient.code.length == 0) {
                _violate(
                    "T2.2",
                    cls,
                    string.concat(
                        "the recipient has no code, ", vm.toString(depositLogs), " depository logs. ", numbers
                    )
                );
            }
            if (depositLogs != 1) {
                _violate(
                    "T2.2",
                    cls,
                    string.concat("the tail made ", vm.toString(depositLogs), " depository logs. ", numbers)
                );
            } else {
                bytes memory expected = tail.token == address(0)
                    ? abi.encode(s.user, B, tail.orderId)
                    : abi.encode(s.user, tail.token, B, tail.orderId);
                bytes32 topic = tail.token == address(0) ? NATIVE_DEPOSIT : ERC20_DEPOSIT;
                Vm.Log memory log = logs[logAt];
                if (
                    log.emitter != tail.recipient || log.topics[0] != topic
                        || keccak256(log.data) != keccak256(expected)
                ) {
                    _violate(
                        "T2.2",
                        cls,
                        string.concat(
                            "the depository log from ",
                            _acctName(log.emitter),
                            " says ",
                            _logAmount(log),
                            " for B ",
                            vm.toString(B),
                            ". ",
                            numbers
                        )
                    );
                }
            }
            if (delivered != B) {
                _violate(
                    "T2.2",
                    cls,
                    string.concat("the depository's balance increased by ", vm.toString(delivered), ". ", numbers)
                );
            }
        } else {
            // T2.3
            _reach("T2.3 checked a fill without an orderId");
            if (depositLogs != 0) {
                _violate(
                    "T2.3",
                    cls,
                    string.concat("the tail made ", vm.toString(depositLogs), " depository logs. ", numbers)
                );
            }
        }
    }

    function _tailFrame(Vm.AccountAccess[] memory acc, bytes32 tailHash, address recipient)
        internal
        view
        returns (uint256 valueCalls, address valueTo, uint256 value, uint256 depositCalls, bool found)
    {
        uint256 at;
        for (uint256 i; i < acc.length; ++i) {
            Vm.AccountAccess memory x = acc[i];
            if (
                x.kind == VmSafe.AccountAccessKind.Call && !x.reverted && x.accessor == address(router)
                    && x.account == address(router) && keccak256(x.data) == tailHash
            ) {
                at = i;
                found = true;
            }
        }
        if (!found) return (0, address(0), 0, 0, false);
        uint64 depth = acc[at].depth;
        for (uint256 i = at + 1; i < acc.length && acc[i].depth > depth; ++i) {
            Vm.AccountAccess memory x = acc[i];
            if (x.kind != VmSafe.AccountAccessKind.Call || x.reverted) continue;
            if (x.accessor == address(router) && x.value != 0) {
                ++valueCalls;
                valueTo = x.account;
                value = x.value;
            }
            if (
                (x.account == DEPOSITORY
                        || x.account == depository2
                        || (x.account == recipient && recipient == address(halfPull))) && x.data.length >= 4
            ) {
                bytes4 selector = bytes4(x.data);
                if (
                    selector == bytes4(keccak256("depositNative(address,bytes32)"))
                        || selector == bytes4(keccak256("depositErc20(address,address,bytes32)"))
                        || selector == bytes4(keccak256("depositErc20(address,address,uint256,bytes32)"))
                ) ++depositCalls;
            }
        }
    }

    /// @dev The deposit logs of the tail's window from contracts that log every deposit call: Relay's depository, the
    /// allowed depository and the half-pulling look-alike. They must match the successful deposit calls into them
    function _countLooksLikeDepositoryLogs(Vm.Log[] memory logs, uint256 start, uint256 end, address recipient)
        internal
        view
        returns (uint256 n)
    {
        for (uint256 i = start + 1; i < end; ++i) {
            if (logs[i].topics.length == 0) continue;
            bytes32 topic = logs[i].topics[0];
            if (topic != ERC20_DEPOSIT && topic != NATIVE_DEPOSIT) continue;
            if (
                logs[i].emitter == DEPOSITORY || logs[i].emitter == depository2
                    || (logs[i].emitter == recipient && recipient == address(halfPull))
            ) ++n;
        }
    }

    function _logAmount(Vm.Log memory log) internal pure returns (string memory) {
        if (log.topics[0] == ERC20_DEPOSIT) {
            (,, uint256 amount,) = abi.decode(log.data, (address, address, uint256, bytes32));
            return vm.toString(amount);
        }
        (, uint256 nativeAmount,) = abi.decode(log.data, (address, uint256, bytes32));
        return vm.toString(nativeAmount);
    }

    function _t2Class(Sub memory s, Fill memory f) internal view returns (string memory) {
        bool thirdPartyLog =
            f.attempts & A_DEPOSIT_LOG != 0 && (s.tail.token == _hookToken() || s.tail.recipient == address(callout));
        return string.concat(
            tokenNames[s.tail.token],
            " to ",
            _acctName(s.tail.recipient),
            s.tail.orderId == bytes32(0) ? " without an orderId" : " with an orderId",
            thirdPartyLog ? ", a hook or the recipient calls depositNative during the fill" : ""
        );
    }

    // ================================================================ the ledger

    function _snap() internal returns (Snap memory s) {
        uint256 nt = ledgerTokens.length;
        s.bal = new uint256[](accts.length * (nt + 1));
        for (uint256 a; a < accts.length; ++a) {
            for (uint256 t; t < nt; ++t) {
                s.bal[a * (nt + 1) + t] = IERC20(ledgerTokens[t]).balanceOf(accts[a]);
            }
            s.bal[a * (nt + 1) + nt] = accts[a].balance;
        }
        s.allow = new uint256[](allowOwners.length * nt * spenders.length);
        uint256 k;
        for (uint256 o; o < allowOwners.length; ++o) {
            for (uint256 t; t < nt; ++t) {
                for (uint256 sp; sp < spenders.length; ++sp) {
                    s.allow[k++] = IERC20(ledgerTokens[t]).allowance(allowOwners[o], spenders[sp]);
                }
            }
        }
        s.p2 = new uint256[](2 * nt * p2Spenders.length);
        k = 0;
        for (uint8 u; u < 2; ++u) {
            for (uint256 t; t < nt; ++t) {
                for (uint256 sp; sp < p2Spenders.length; ++sp) {
                    (uint160 amount, uint48 expiration, uint48 nonce) =
                        IAllowanceTransfer(PERMIT2).allowance(_user(u), ledgerTokens[t], p2Spenders[sp]);
                    s.p2[k++] = uint256(amount) | uint256(expiration) << 160 | uint256(nonce) << 208;
                }
            }
        }
        s.words = new uint256[](2 * NONCE_WORDS);
        for (uint8 u; u < 2; ++u) {
            for (uint256 w; w < NONCE_WORDS; ++w) {
                s.words[u * NONCE_WORDS + w] = ISignatureTransfer(PERMIT2).nonceBitmap(_user(u), w);
            }
        }
        s.slots = new uint256[](4);
        s.slots[0] = _tload(address(proxy), PROXY_GUARD_SLOT);
        s.slots[1] = _tload(address(proxy2), PROXY_GUARD_SLOT);
        s.slots[2] = _tload(address(router), ROUTER_CONTEXT_SLOT);
        s.slots[3] = _tload(address(router), ROUTER_RECIPIENT_SLOT);
    }

    /// @dev Reads a transient slot of `target` in this transaction: etches a reader over it for one staticcall
    function _tload(address target, bytes32 slot) internal returns (uint256 value) {
        uint256 freeMemory;
        assembly ("memory-safe") {
            freeMemory := mload(0x40)
        }
        bytes memory code = target.code;
        vm.etch(target, type(TailTransientReader).runtimeCode);
        (bool ok, bytes memory ret) = target.staticcall(abi.encode(slot));
        vm.etch(target, code);
        require(ok, "transient read");
        value = abi.decode(ret, (uint256));
        // nothing allocated here outlives the call: give the memory of the code copy back
        assembly ("memory-safe") {
            mstore(0x40, freeMemory)
        }
    }

    /// @dev "" if the two snapshots agree, else the first difference
    function _diff(Snap memory b, Snap memory e) internal view returns (string memory) {
        uint256 nt = ledgerTokens.length;
        for (uint256 i; i < b.bal.length; ++i) {
            if (b.bal[i] != e.bal[i]) {
                return string.concat(
                    acctNames[i / (nt + 1)],
                    "'s ",
                    _ledgerTokenName(i % (nt + 1)),
                    " went from ",
                    vm.toString(b.bal[i]),
                    " to ",
                    vm.toString(e.bal[i])
                );
            }
        }
        for (uint256 i; i < b.allow.length; ++i) {
            if (b.allow[i] != e.allow[i]) return string.concat(_allowName(i), " changed");
        }
        for (uint256 i; i < b.p2.length; ++i) {
            if (b.p2[i] != e.p2[i]) return "a Permit2 allowance changed";
        }
        for (uint256 i; i < b.words.length; ++i) {
            if (b.words[i] != e.words[i]) {
                return string.concat(
                    "nonce word ", vm.toString(i % NONCE_WORDS), " of ", acctNames[i / NONCE_WORDS], " changed"
                );
            }
        }
        string[4] memory slotNames =
            ["the proxy lock", "the second proxy's lock", "the router's CONTEXT_SLOT", "the router's RECIPIENT_SLOT"];
        for (uint256 i; i < 4; ++i) {
            if (b.slots[i] != e.slots[i]) {
                return
                    string.concat(slotNames[i], " went from ", vm.toString(b.slots[i]), " to ", vm.toString(e.slots[i]));
            }
        }
        return "";
    }

    // ================================================================ attempts by hooks, venues, recipients, relayers

    function _setAttempts(Fill memory f, Sub memory s) internal {
        Attempt[] memory list = new Attempt[](8);
        uint256 n;
        uint8 bits = f.attempts;
        if (bits & A_PROXY != 0) list[n++] = Attempt(address(proxy), _tailEntryCall(s, new Call3Value[](0)));
        if (bits & A_SWEEP != 0) {
            list[n++] =
                Attempt(address(router), abi.encodeCall(RelayRouterBase.sweepWithMinimum, (f.tokenIn, 0, thief, "")));
            list[n++] = Attempt(
                address(router),
                s.tail.token == address(0)
                    ? abi.encodeCall(RelayRouterBase.sweepNativeWithMinimum, (0, thief, ""))
                    : abi.encodeCall(RelayRouterBase.sweepWithMinimum, (s.tail.token, 0, thief, ""))
            );
        }
        if (bits & A_PERMIT2 != 0) list[n++] = Attempt(PERMIT2, _stolenPermit2Call(s, f.relayerIdx));
        if (bits & A_CLEANUP != 0) {
            list[n++] = Attempt(
                address(router),
                abi.encodeCall(RelayRouterBase.cleanupErc20s, (_one(f.tokenIn), _one(thief), _oneU(0), ""))
            );
            list[n++] = Attempt(address(router), abi.encodeCall(RelayRouterBase.cleanupNative, (0, thief, "")));
        }
        if (bits & A_DEPOSIT_LOG != 0) {
            list[n++] =
                Attempt(DEPOSITORY, abi.encodeWithSignature("depositNative(address,bytes32)", s.user, s.tail.orderId));
        }
        if (bits & A_WITHDRAW != 0) {
            list[n++] = Attempt(address(proxy), abi.encodeCall(RelayApprovalProxyBase.withdraw, (f.tokenIn, thief)));
        }
        assembly ("memory-safe") {
            mstore(list, n)
        }
        // Kept in transient storage for this transaction: the actors read them when they call out
        _tstoreBytes(ATTEMPTS_SLOT, abi.encode(list));
        if (bits & A_FRESH_FILL == 0) return;
        // Only for the actors that get control in this fill: each fresh fill uses a nonce of the user's
        address hook = _hookToken();
        if (f.tokenIn == hook || f.tail.token == hook) {
            _tstoreBytes(_freshSlot(address(hookTarget)), _freshFill(f, address(hookTarget)));
        }
        if (!fork && f.swapMode == SWAP_CALLS_BACK && f.pull != 0 && f.tail.token != f.tokenIn) {
            _tstoreBytes(_freshSlot(address(tailVenue)), _freshFill(f, address(tailVenue)));
        }
        if (f.tail.recipient == address(callout) && f.tail.token == address(0) && f.tail.orderId == bytes32(0)) {
            _tstoreBytes(_freshSlot(address(callout)), _freshFill(f, address(callout)));
        }
        if (f.extras & X_EVIL_CALLBACK != 0) _tstoreBytes(_freshSlot(address(evil)), _freshFill(f, address(evil)));
    }

    /// @notice The attempts of the current fill, for the hook target, the venue, the recipient that calls out and
    ///         the malicious relayer, and last the fill with a fresh permit that the user signed for the caller
    function currentAttempts() external view returns (Attempt[] memory list) {
        bytes memory encoded = _tloadBytes(ATTEMPTS_SLOT);
        list = encoded.length == 0 ? new Attempt[](0) : abi.decode(encoded, (Attempt[]));
        bytes memory fresh = _tloadBytes(_freshSlot(msg.sender));
        if (fresh.length == 0) return list;
        Attempt[] memory all = new Attempt[](list.length + 1);
        for (uint256 i; i < list.length; ++i) {
            all[i] = list[i];
        }
        all[list.length] = Attempt(address(proxy), fresh);
        return all;
    }

    /// @dev A tail fill of 1 unit of a token the fill does not use, which the user signs for `caller` as the
    /// relayer with the next nonce: to an EOA, without an orderId, refunds to the user, no solver calls. Nothing
    /// but the proxy's guard refuses it while a fill runs
    function _freshFill(Fill memory f, address caller) internal returns (bytes memory) {
        address user = _user(f.userIdx);
        address token = _freshToken(f);
        if (token == address(0)) return "";
        ISignatureTransfer.PermitBatchTransferFrom memory permit;
        permit.permitted = new ISignatureTransfer.TokenPermissions[](1);
        permit.permitted[0] = ISignatureTransfer.TokenPermissions(token, 1);
        permit.nonce = nextNonce[user]++;
        require(permit.nonce < 256 * NONCE_WORDS, "nonce space");
        permit.deadline = f.deadline;
        RelayApprovalProxyBase.SweepWithMinimum memory tail =
            RelayApprovalProxyBase.SweepWithMinimum(token, 1, eoaRecipient, bytes32(0));
        bytes32 digest = _tailDigest(permit, address(proxy), caller, user, tail);
        signedBy[user][digest] = caller;
        return abi.encodeCall(
            RelayApprovalProxyBase.permit2TransferAndMulticallWithTail,
            (user, permit, new Call3Value[](0), tail, user, META, _sign(f.userIdx, digest))
        );
    }

    /// @dev A permitted token that transfers exactly and that the fill does not use, else one that is not its tail
    /// token (on the fork, with two tokens), else zero: on the fork a two-token permit with a WETH tail uses both
    /// tokens, and the fill gets no fresh fill
    function _freshToken(Fill memory f) internal view returns (address fallbackToken) {
        for (uint256 i; i < tokensIn.length; ++i) {
            address t = tokensIn[i];
            if (t == f.tail.token || t == f.second) continue;
            if (!fork) {
                uint8 kind = TailToken(t).kind();
                if (kind != STANDARD && kind != USDT_APPROVE && kind != NO_ZERO_APPROVE) continue;
            }
            if (t != f.tokenIn) return t;
            fallbackToken = t;
        }
    }

    function _freshSlot(address caller) internal pure returns (bytes32) {
        return keccak256(abi.encode(FRESH_FILLS_SLOT, caller));
    }

    function _clearFreshFills() internal {
        address[4] memory actors = [address(hookTarget), address(callout), address(tailVenue), address(evil)];
        for (uint256 i; i < actors.length; ++i) {
            _tstoreBytes(_freshSlot(actors[i]), "");
        }
    }

    /// @dev Counts, in a successful submission, the first fill with a fresh permit that each callback submitted. A
    /// hook runs at every transferFrom of its token and may submit the same fill again, whose nonce the first one
    /// spent if it succeeded: only the first submission shows what the guard does
    function _reachFreshFills(Vm.AccountAccess[] memory acc) internal {
        address[4] memory actors = [address(hookTarget), address(callout), address(tailVenue), address(evil)];
        bool[4] memory seen;
        for (uint256 i; i < acc.length; ++i) {
            if (acc[i].kind != VmSafe.AccountAccessKind.Call || acc[i].account != address(proxy)) continue;
            for (uint256 j; j < actors.length; ++j) {
                if (seen[j] || acc[i].accessor != actors[j]) continue;
                bytes memory fresh = _tloadBytes(_freshSlot(actors[j]));
                if (fresh.length != 0 && keccak256(acc[i].data) == keccak256(fresh)) {
                    seen[j] = true;
                    _reach(
                        string.concat(
                            _acctName(actors[j]),
                            " submitted a fill with a fresh permit during a fill",
                            acc[i].reverted ? ", reverted" : ", succeeded"
                        )
                    );
                }
            }
        }
    }

    /// @dev Keeps `data` in transient storage at `slot`: its length, then its words
    function _tstoreBytes(bytes32 slot, bytes memory data) internal {
        assembly ("memory-safe") {
            let words := shr(5, add(mload(data), 31))
            tstore(slot, mload(data))
            for { let i := 0 } lt(i, words) { i := add(i, 1) } {
                tstore(add(add(slot, 1), i), mload(add(add(data, 32), shl(5, i))))
            }
        }
    }

    function _tloadBytes(bytes32 slot) internal view returns (bytes memory data) {
        uint256 length;
        assembly ("memory-safe") {
            length := tload(slot)
        }
        data = new bytes(length);
        assembly ("memory-safe") {
            let words := shr(5, add(length, 31))
            for { let i := 0 } lt(i, words) { i := add(i, 1) } {
                mstore(add(add(data, 32), shl(5, i)), tload(add(add(slot, 1), i)))
            }
        }
    }

    function _attemptsMade() internal view returns (uint256[4] memory made) {
        made = [hookTarget.attemptsMade(), callout.attemptsMade(), tailVenue.attemptsMade(), evil.attemptsMade()];
    }

    function _attemptsSucceeded() internal view returns (uint256[4] memory n) {
        n = [
            hookTarget.attemptsSucceeded(),
            callout.attemptsSucceeded(),
            tailVenue.attemptsSucceeded(),
            evil.attemptsSucceeded()
        ];
    }

    function _reachFill(Fill memory f, uint256[4] memory made, uint256[4] memory succeeded) internal {
        _reach(string.concat("T2 success, tail token ", tokenNames[f.tail.token]));
        _reach(string.concat("T2 success, permitted ", tokenNames[f.tokenIn]));
        _reach(
            string.concat(
                "T2 success, recipient ",
                _acctName(f.tail.recipient),
                f.tail.orderId == bytes32(0) ? " without an orderId" : " with an orderId"
            )
        );
        _reach(string.concat("T2 success, refundTo ", _acctName(f.refundTo)));
        if (f.tail.token != f.tokenIn) {
            string[6] memory swaps = ["honest", "pays less", "takes less", "calls back", "no swap", "pays more"];
            _reach(string.concat("T2 success, venue ", swaps[f.swapMode]));
        }
        string[8] memory extras = [
            "steals a little",
            "a nested multicall steals a little",
            "sweeps",
            "donates to the proxy",
            "calls the proxy",
            "calls Permit2",
            "calls the depository",
            "calls the malicious relayer back"
        ];
        for (uint256 i; i < 8; ++i) {
            if (f.extras & (1 << i) != 0) _reach(string.concat("T2 success, the relayer ", extras[i]));
        }
        uint256[4] memory madeNow = _attemptsMade();
        uint256[4] memory succeededNow = _attemptsSucceeded();
        string[4] memory who = ["the hook target", "the recipient that calls out", "the venue", "the malicious relayer"];
        for (uint256 i; i < 4; ++i) {
            if (madeNow[i] > made[i]) _reach(string.concat("T2 success, ", who[i], " made its attempts"));
            if (succeededNow[i] > succeeded[i]) {
                _reach(
                    string.concat(
                        "T2 success, an attempt of ", who[i], " succeeded, attempts ", vm.toString(f.attempts)
                    )
                );
            }
        }
    }

    // ================================================================ calls built from a submission

    function _tailEntryCall(Sub memory s, Call3Value[] memory solverCalls) internal pure returns (bytes memory) {
        return abi.encodeCall(
            RelayApprovalProxyBase.permit2TransferAndMulticallWithTail,
            (s.user, s.permit, solverCalls, s.tail, s.refundTo, META, s.signature)
        );
    }

    /// @dev Permit2's batch witness transfer of the user's order to the thief, called by whoever calls Permit2
    function _stolenPermit2Call(Sub memory s, uint8 relayerIdx) internal view returns (bytes memory) {
        ISignatureTransfer.SignatureTransferDetails[] memory details =
            new ISignatureTransfer.SignatureTransferDetails[](s.permit.permitted.length);
        for (uint256 i; i < details.length; ++i) {
            details[i] = ISignatureTransfer.SignatureTransferDetails(thief, s.permit.permitted[i].amount);
        }
        bytes32 witness = keccak256(
            abi.encode(
                TAIL_WITNESS_TYPEHASH,
                _relayer(relayerIdx),
                s.refundTo,
                keccak256(abi.encode(SWEEP_TYPEHASH, s.tail.token, s.tail.minAmount, s.tail.recipient, s.tail.orderId))
            )
        );
        return abi.encodeWithSelector(
            PERMIT2_BATCH_WITNESS, s.permit, details, s.user, witness, TAIL_WITNESS_TYPE_STRING, s.signature
        );
    }

    // ================================================================ helpers

    function _store(Fill memory f, bool oldEntry, bytes memory signature) internal returns (uint256 index) {
        index = orders.length;
        orders.push();
        Order storage o = orders[index];
        o.oldEntry = oldEntry;
        o.userIdx = f.userIdx;
        o.relayerIdx = f.relayerIdx;
        o.swapMode = f.swapMode;
        o.count = f.count;
        o.tokens[0] = f.tokenIn;
        o.amounts[0] = f.amount;
        o.tokens[1] = f.second;
        o.amounts[1] = f.secondAmount;
        o.nonce = f.nonce;
        o.deadline = f.deadline;
        o.tail = f.tail;
        o.refundTo = f.refundTo;
        o.signature = signature;
    }

    function _topUp(Sub memory s) internal {
        for (uint256 i; i < s.permit.permitted.length; ++i) {
            address token = s.permit.permitted[i].token;
            if (_isLedgerToken(token) && IERC20(token).balanceOf(s.user) < s.permit.permitted[i].amount) {
                _fund(token, s.user, s.permit.permitted[i].amount + IERC20(token).balanceOf(s.user));
            }
        }
    }

    function _fund(address token, address to, uint256 amount) internal {
        if (fork) deal(token, to, IERC20(token).balanceOf(to) + amount);
        else TailToken(token).mint(to, amount);
    }

    function _sign(uint8 userIdx, bytes32 digest) internal view returns (bytes memory) {
        return _signDigest(userIdx == 0 ? userKey : walletKey, digest);
    }

    function _user(uint8 i) internal view returns (address) {
        return i == 0 ? userEoa : address(wallet);
    }

    function _relayer(uint8 i) internal view returns (address) {
        return i == 0 ? MULTICALLER : i == 1 ? relayerEoa : address(evil);
    }

    function _relayerName(uint8 i) internal pure returns (string memory) {
        return i == 0 ? "the multicaller" : i == 1 ? "the other relayer" : "the malicious relayer";
    }

    function _recipient(uint8 i) internal view returns (address) {
        if (i == 0) return DEPOSITORY;
        if (i == 1) return eoaRecipient;
        if (i == 2) return address(callout);
        if (i == 3) return noCode;
        if (i == 4) return address(halfPull);
        if (i == 5) return address(reverting);
        return depository2;
    }

    function _refundTo(uint8 i, address user) internal view returns (address) {
        return i == 0 ? user : i == 1 ? thirdParty : i == 2 ? address(proxy) : address(router);
    }

    function _hookToken() internal view returns (address) {
        return fork ? address(1) : tokensIn[HOOK];
    }

    function _amountFor(address token, uint256 raw) internal view returns (uint256) {
        if (fork) return token == WETH ? 1e12 + raw % 1e18 : 1e4 + raw % 1e9;
        return raw % 4 == 0 ? 1 + (raw >> 2) % 1000 : 1 + (raw >> 2) % 1e24;
    }

    function _received(address token, uint256 amount) internal view returns (uint256) {
        if (fork || token == address(0)) return amount;
        uint8 kind = TailToken(token).kind();
        if (kind == FEE_ON_TRANSFER) return amount - amount / 100;
        if (kind == ROUNDS_DOWN && amount != 0) return amount - 1;
        return amount;
    }

    /// @dev What the venue pays for `amountIn`. The local venue pays 1:1; on a fork, Uniswap's quoter
    function _quote(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256) {
        if (!fork) return amountIn;
        if (tokenOut == address(0) && tokenIn == WETH) return amountIn;
        (uint256 out,,,) = ITailQuoter(QUOTER)
            .quoteExactInputSingle(
                ITailQuoter.QuoteExactInputSingleParams(
                    tokenIn, tokenOut == address(0) ? WETH : tokenOut, amountIn, 500, 0
                )
            );
        return out;
    }

    function _balance(address token, address holder) internal view returns (uint256) {
        return token == address(0) ? holder.balance : IERC20(token).balanceOf(holder);
    }

    function _thiefHoldings() internal view returns (uint256 total) {
        total = thief.balance;
        for (uint256 t; t < ledgerTokens.length; ++t) {
            total += IERC20(ledgerTokens[t]).balanceOf(thief);
        }
    }

    function _bitSet(address user, uint256 nonce) internal view returns (bool) {
        return ISignatureTransfer(PERMIT2).nonceBitmap(user, nonce >> 8) & (1 << (nonce & 0xff)) != 0;
    }

    function _bitIn(Snap memory b, uint8 u, uint256 nonce) internal pure returns (bool) {
        if (nonce >> 8 >= NONCE_WORDS) return false;
        return b.words[u * NONCE_WORDS + (nonce >> 8)] & (1 << (nonce & 0xff)) != 0;
    }

    function _isLedgerToken(address token) internal view returns (bool) {
        for (uint256 t; t < ledgerTokens.length; ++t) {
            if (ledgerTokens[t] == token) return true;
        }
        return false;
    }

    function _indexIn(address token) internal view returns (uint256) {
        for (uint256 i; i < tokensIn.length; ++i) {
            if (tokensIn[i] == token) return i;
        }
        revert("not a token in");
    }

    function _indexOut(address token) internal view returns (uint256) {
        for (uint256 i; i < tokensOut.length; ++i) {
            if (tokensOut[i] == token) return i;
        }
        revert("not a token out");
    }

    function _acctIndex(address a) internal view returns (uint256) {
        for (uint256 i; i < accts.length; ++i) {
            if (accts[i] == a) return i;
        }
        revert("not an account of the ledger");
    }

    function _ledgerIndex(address token) internal view returns (uint256) {
        for (uint256 t; t < ledgerTokens.length; ++t) {
            if (ledgerTokens[t] == token) return t;
        }
        revert("not a ledger token");
    }

    function _acctName(address a) internal view returns (string memory) {
        for (uint256 i; i < accts.length; ++i) {
            if (accts[i] == a) return acctNames[i];
        }
        return vm.toString(a);
    }

    function _ledgerTokenName(uint256 t) internal view returns (string memory) {
        return t == ledgerTokens.length ? "native" : tokenNames[ledgerTokens[t]];
    }

    function _allowName(uint256 i) internal view returns (string memory) {
        uint256 per = ledgerTokens.length * spenders.length;
        uint256 o = i / per;
        uint256 t = (i % per) / spenders.length;
        uint256 sp = i % spenders.length;
        return string.concat(
            "the allowance of ",
            _acctName(allowOwners[o]),
            " for ",
            _acctName(spenders[sp]),
            " on ",
            tokenNames[ledgerTokens[t]]
        );
    }

    function _mutationName(uint256 m) internal pure returns (string memory) {
        string[20] memory names = [
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
        return names[m];
    }

    function _fillName(Fill memory f) internal view returns (string memory) {
        string[6] memory swaps =
            ["honest venue", "venue pays less", "venue takes less", "venue calls back", "no swap", "venue pays more"];
        return string.concat(
            f.count == 0 ? "no permitted token" : string.concat(vm.toString(f.amount), " ", tokenNames[f.tokenIn]),
            f.count == 2 ? string.concat(" + ", vm.toString(f.secondAmount), " ", tokenNames[f.second]) : "",
            " for ",
            tokenNames[f.tail.token],
            ", ",
            swaps[f.swapMode],
            ", planned B ",
            vm.toString(f.plannedB),
            ", minAmount ",
            vm.toString(f.tail.minAmount),
            ", to ",
            _acctName(f.tail.recipient),
            f.tail.orderId == bytes32(0) ? " without an orderId" : " with an orderId",
            ", refundTo ",
            _acctName(f.refundTo),
            ", relayer ",
            _relayerName(f.relayerIdx),
            ", extras ",
            vm.toString(f.extras),
            ", attempts ",
            vm.toString(f.attempts)
        );
    }

    function _tokens(ISignatureTransfer.PermitBatchTransferFrom memory permit)
        internal
        pure
        returns (address[] memory t)
    {
        t = new address[](permit.permitted.length);
        for (uint256 i; i < t.length; ++i) {
            t[i] = permit.permitted[i].token;
        }
    }

    function _repeat(address a, uint256 n) internal pure returns (address[] memory list) {
        list = new address[](n);
        for (uint256 i; i < n; ++i) {
            list[i] = a;
        }
    }

    function _withoutLast(Call3Value[] memory list) internal pure returns (Call3Value[] memory out) {
        out = new Call3Value[](list.length - 1);
        for (uint256 i; i < out.length; ++i) {
            out[i] = list[i];
        }
    }

    function _one(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function _oneU(uint256 x) internal pure returns (uint256[] memory list) {
        list = new uint256[](1);
        list[0] = x;
    }

    function _oneB(bytes memory b) internal pure returns (bytes[] memory list) {
        list = new bytes[](1);
        list[0] = b;
    }

    function _word(bytes memory data, uint256 i) internal pure returns (uint256 w) {
        assembly ("memory-safe") {
            w := mload(add(add(data, 36), mul(i, 32)))
        }
    }

    function _violate(string memory part, string memory cls, string memory what) internal {
        if (violations[part]++ == 0) {
            firstViolation[part] = string.concat(part, " in call #", vm.toString(calls), ", ", cls, ": ", what);
        }
        if (classCount[part][cls]++ == 0) {
            classes[part].push(cls);
            firstOfClass[part][cls] = what;
        }
    }

    function _reach(string memory key) internal {
        ++reach[key];
    }

    function classesOf(string calldata part) external view returns (string[] memory) {
        return classes[part];
    }

    function orderCount() external view returns (uint256) {
        return orders.length;
    }
}
