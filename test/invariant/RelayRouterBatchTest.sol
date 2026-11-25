// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {Route, IRouteRace} from "../../src/interfaces/IRouteRace.sol";
import {packRoute} from "./RoutePacking.sol";
import {RouteRaceEngine} from "../../src/RouteRaceEngine.sol";
import {RelayRouterBase} from "../../src/RelayRouterBase.sol";
import {RelayRouter} from "../../src/RelayRouter.sol";
import {RelayRouter_NonTstore} from "../../src/RelayRouter_NonTstore.sol";
import {RelayApprovalProxy} from "../../src/RelayApprovalProxy.sol";
import {Call3Value, Result} from "../../src/common/Multicall3.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {TestERC20} from "../mocks/TestERC20.sol";

/// @dev Permit2's address on every chain. The approval proxy refuses a zero one.
address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

uint256 constant AMOUNTS = 4096; // every fuzzed amount is taken mod this, so that balances, amounts and outputs meet
uint256 constant MAX_COMMANDS = 5;
uint256 constant MAX_ROUTES = 3;
uint256 constant MAX_RACES = 2;
uint256 constant MAX_INNER = 2;
uint256 constant HUGE = 1 << 80; // a command value above anything the router holds

// The ERC-777 hook registries. The router refuses them, and the zero address, as the target of a command, and
// the registries as the callee of a ViaCall cleanup
address constant ERC1820_REGISTRY = 0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24;
address constant ERC820_REGISTRY = 0x820b586C8C28125366C998641B09DCbE7d4cBF06;

uint256 constant EMIT_EVENTS = 1;
uint256 constant DIRECT_OUTPUT = 4;
uint256 constant NO_INPUT_REFUND = 8;
uint256 constant LOG_FUNDS_MOVEMENT = 16;

// Ledger columns
uint256 constant ASSET_A = 0;
uint256 constant ASSET_B = 1;
uint256 constant ASSET_C = 2; // never a race's token: the other token F5 watches
uint256 constant ASSET_NATIVE = 3;
uint256 constant ASSETS = 4;

// Cmd.kind
uint256 constant K_ECHO = 0;
uint256 constant K_RACE = 1;
uint256 constant K_CLEANUP = 2;
uint256 constant K_VIA_ERC20 = 3;
uint256 constant K_CLEANUP_NATIVE = 4;
uint256 constant K_VIA_NATIVE = 5;
uint256 constant K_NESTED = 6;
uint256 constant K_PROBE = 7; // put before and after every race, not fuzzed

// CommandInput.kind % 9 at the top level (1, 2 and 8 are races); % 5 inside the nested multicall
uint8 constant IN_ECHO = 0;
uint8 constant IN_RACE = 1;
uint8 constant IN_CLEANUP = 3;
uint8 constant IN_VIA_ERC20 = 4;
uint8 constant IN_CLEANUP_NATIVE = 5;
uint8 constant IN_VIA_NATIVE = 6;
uint8 constant IN_NESTED = 7;
uint8 constant INNER_ECHO = 0;
uint8 constant INNER_CLEANUP_NATIVE = 3;
// CommandInput.to % 16 of an echo: 0-12 the echo contract, then the targets the router refuses
uint8 constant ECHO_AT_ZERO = 13;
uint8 constant ECHO_AT_ERC1820 = 14;
uint8 constant ECHO_AT_ERC820 = 15;
// CommandInput.to % 8 of a ViaCall cleanup: 0-5 the callee, then the two registries
uint8 constant VIA_TO_ERC1820 = 6;
uint8 constant VIA_TO_ERC820 = 7;

// Cmd.variant of the two cleanups of ERC-20s
uint256 constant V_WHOLE = 0;
uint256 constant V_EXPLICIT = 1;
uint256 constant V_MISMATCH = 2;

// Cmd.how: what a callee does with what it is approved (ERC-20) or sent (native)
uint256 constant TAKE_ALL = 0; // pulls all it is approved; keeps all it is sent
uint256 constant TAKE_PART = 1; // pulls half; sends half back
uint256 constant TAKE_NONE = 2; // pulls nothing; sends it all back
uint256 constant TAKE_FAIL = 3; // reverts

// RaceInput.entry % 3
uint8 constant R_RACE = 0;
uint8 constant R_SINGLE = 1;
uint8 constant R_BACKUPS = 2;
// RaceInput.assets % 4
uint8 constant A_TO_B = 0;
uint8 constant NATIVE_TO_B = 2;
uint8 constant A_TO_NATIVE = 3;
// RaceInput.recipient % 3
uint8 constant TO_RECIPIENT = 0;
uint8 constant TO_ROUTER = 2;
// RaceInput.minMode % 4
uint8 constant MIN_LOWEST = 0; // the lowest positive output of a route that does not revert
uint8 constant MIN_ABOVE_BEST = 2;
// RouteInput.kind % 8
uint8 constant FAILS = 0;
uint8 constant SPENDS_ALL = 1; // to 3
uint8 constant SPENDS_PART = 4; // and 5: spend % amountIn
uint8 constant SPENDS_NONE = 6; // and 7

// BatchInput.path % 3
uint8 constant VIA_PROXY = 0;
uint8 constant DIRECT_PATH = 2;
// BatchInput.refund % 8: 0-3 the fixed refund address, 4-5 the router, 6 a contract that rejects native,
// 7 zero on the direct path (the fixed address on the proxy path, which refuses zero)
uint8 constant REFUND_ADDR = 0;
uint8 constant REFUND_ROUTER = 4;
uint8 constant REFUND_REJECTER = 6;
uint8 constant REFUND_ZERO = 7;
// BatchInput.seedMask
uint8 constant SEED_A = 1;
uint8 constant SEED_B = 2;
uint8 constant SEED_C = 4;
uint8 constant SEED_NATIVE = 8;
uint8 constant TRANSFER_FIRST = 16; // the transfer brings the first race's input only

/// @dev An honest route: takes `spend` of its input and delivers `out`, or reverts
contract BatchRoute {
    error Scripted();

    receive() external payable {}

    function run(address tokenIn, uint256 spend, address tokenOut, uint256 out, address to, bool fail)
        external
        payable
    {
        if (fail) revert Scripted();
        if (tokenIn != address(0) && spend != 0) TestERC20(tokenIn).transferFrom(msg.sender, address(this), spend);
        if (tokenOut == address(0)) {
            (bool ok,) = to.call{value: out}("");
            require(ok, "native delivery failed");
        } else {
            TestERC20(tokenOut).mint(to, out);
        }
    }
}

/// @dev The target of an ordinary command: returns its tag, or reverts with it
contract BatchEcho {
    error Scripted(uint256 tag);

    function echo(uint256 tag, bool fail) external payable returns (uint256) {
        if (fail) revert Scripted(tag);
        return tag;
    }
}

/// @dev The callee of the two ViaCall cleanups
contract BatchCallee {
    error Refused();

    function take(address token, uint256 how) external {
        if (how == TAKE_FAIL) revert Refused();
        uint256 approved = TestERC20(token).allowance(msg.sender, address(this));
        uint256 pull = how == TAKE_ALL ? approved : how == TAKE_PART ? approved / 2 : 0;
        if (pull != 0) TestERC20(token).transferFrom(msg.sender, address(this), pull);
    }

    function takeNative(uint256 how) external payable {
        if (how == TAKE_FAIL) revert Refused();
        uint256 back = how == TAKE_ALL ? 0 : how == TAKE_PART ? msg.value / 2 : msg.value;
        if (back != 0) {
            (bool ok,) = msg.sender.call{value: back}("");
            require(ok, "send back failed");
        }
    }
}

/// @dev Rejects native: no receive, no fallback
contract BatchRejecter {}

/// @dev Called right before and right after each race: returns its caller's balances
contract BatchProbe {
    TestERC20 internal immutable a;
    TestERC20 internal immutable b;
    TestERC20 internal immutable c;

    constructor(TestERC20 a_, TestERC20 b_, TestERC20 c_) {
        (a, b, c) = (a_, b_, c_);
    }

    function snap() external view returns (uint256[4] memory s) {
        s = [a.balanceOf(msg.sender), b.balanceOf(msg.sender), c.balanceOf(msg.sender), msg.sender.balance];
    }
}

struct RouteInput {
    uint8 kind; // % 8: 0 reverts, 1-3 spends all of amountIn, 4-5 spends `spend` % amountIn, 6-7 spends nothing
    uint64 out; // % AMOUNTS, raised until it differs from every earlier route's
    uint64 spend;
    uint64 value; // odd, with ERC-20 in and out: the route carries (value >> 1) % (budget + 1) native
}

struct RaceInput {
    uint8 entry; // % 3: race, raceSingle, raceWithBackups
    uint8 routeCount; // 1 + routeCount % MAX_ROUTES
    uint8 mainCount; // 1 + mainCount % routes, for raceWithBackups
    uint8 flags; // & 29: no flag 2
    uint8 assets; // % 4: A to B, B to A, native to B, A to native
    uint8 recipient; // % 3: 0-1 the fixed recipient, 2 the router
    uint8 minMode; // % 4: the lowest positive output, the best, the best + 1, 1 + minOut
    uint64 amountIn;
    uint64 minOut;
    uint64 value; // the command's value: the native budget, plus amountIn for a native input
    RouteInput[MAX_ROUTES] routes;
}

struct CommandInput {
    uint8 kind;
    uint8 mode; // bit 0: allowFailure. The rest is per kind, see _decode
    uint8 pick; // the token, % 3
    uint8 to; // the recipient, % 4; an echo's target, % 16; a ViaCall cleanup's callee, % 8
    uint64 amount;
}

struct BatchInput {
    uint8 path;
    uint8 refund;
    uint8 count; // 1 + count % MAX_COMMANDS commands, not counting the probes
    uint8 seedMask;
    uint64 seedA; // put on the router before the multicall, on top of what earlier batches left there
    uint64 seedB;
    uint64 seedC;
    uint64 seedNative;
    uint64 surplus; // msg.value above what the commands carry
    uint64 extraIn; // tokenA the transfer brings on top of the races' input
    uint8 innerCount; // 1 + innerCount % MAX_INNER commands in every nested multicall of the batch
    uint8 innerRefund; // % 4: 0 and 3 zero (the router), 1 the sink, 2 the rejecter
    CommandInput[MAX_COMMANDS] commands;
    RaceInput[MAX_RACES] races; // the k-th race command is races[k]
    CommandInput[MAX_INNER] inner;
}

/// @dev One resolved command
struct Cmd {
    uint256 kind;
    bool allowFailure;
    uint256 value;
    uint256 variant;
    uint256 asset;
    address to;
    uint256 amount; // as passed: 0 is the router's whole balance. The echo's tag
    uint256 how;
    bool fail;
    uint256 race;
}

struct RaceSpec {
    uint256 entry;
    uint256 mainCount;
    uint256 flags;
    uint256 assetIn;
    uint256 assetOut;
    uint256 amountIn;
    uint256 minOut;
    address recipient;
    uint256 value;
    bool[] fail;
    uint256[] spend;
    uint256[] out;
    uint256[] rvalue; // the route's value
}

struct Batch {
    bool direct;
    address refundTo; // as passed
    address refundAddr; // where the sweep and race refunds go
    address caller; // of the router's multicall
    bool transferFirst;
    uint256 msgValue;
    uint256 surplus;
    uint256 transferA;
    uint256 transferB;
    uint256[4] seed;
    Cmd[] cmds;
    RaceSpec[] races;
    Cmd[] inner;
    address innerRefund;
}

/// @dev The model's state: balances [holder * ASSETS + asset], and the router's allowances
/// [spender * 3 + token] to the callee (spender 0) and the three routes
struct Sim {
    uint256[] bal;
    uint256[] allow;
}

struct Expect {
    bool reverts;
    bool sweepReverts;
    bytes revertData;
    uint256 failedAt; // the command that reverts the multicall; NO_ROUTE for the final sweep
    Result[] results;
    Sim s;
    uint256 swept; // the router's native when the final sweep starts
    // The router's tokenA and tokenB when the proxy's sweep starts, once the multicall has returned. Zero for a
    // token the proxy did not transfer, and on the direct path
    uint256[2] proxySwept;
    uint256[] winner; // per race
    uint256[] amountAt; // per command: what a cleanup resolved its amount to
    uint256[] innerSwept; // per nested command: the router's native when its own sweep starts
    bool[] innerRefused; // per nested command: a command of its own to a refused target reverted it
}

contract BatchHandler is Test {
    uint256 internal constant ROUTE_GAS = 500_000;
    address public constant RECIPIENT = address(0xA11CE);
    address public constant REFUND = address(0xFEED);
    address public constant SINK = address(0x5171C);
    bytes internal constant META = "batch-invariant";
    uint256 internal constant NO_ROUTE = type(uint256).max;

    // Ledger rows
    uint256 internal constant H_USER = 0;
    uint256 internal constant H_ROUTER = 1;
    uint256 internal constant H_REFUND = 3;
    uint256 internal constant H_CALLEE = 7;
    uint256 internal constant H_REJECTER = 8;
    uint256 internal constant H_ROUTE = 9;
    uint256 internal constant SPENDERS = 1 + MAX_ROUTES;

    RelayRouterBase public immutable router;
    RelayApprovalProxy public immutable proxy;
    TestERC20 public immutable tokenA;
    TestERC20 public immutable tokenB;
    TestERC20 public immutable tokenC;
    BatchEcho public immutable echo;
    BatchCallee public immutable callee;
    BatchRejecter public immutable rejecter;
    BatchProbe public immutable probe;
    BatchRoute[MAX_ROUTES] public routes;
    address[] internal holders;
    string[] internal holderNames;

    uint256 public batches;
    uint256 public violationCount;
    mapping(string => uint256) public violations;
    mapping(string => string) public firstViolation;
    mapping(string => uint256) public reach;

    constructor(RelayRouterBase router_) {
        router = router_;
        proxy = new RelayApprovalProxy(address(this), address(router_), PERMIT2);
        tokenA = new TestERC20();
        tokenB = new TestERC20();
        tokenC = new TestERC20();
        echo = new BatchEcho();
        callee = new BatchCallee();
        rejecter = new BatchRejecter();
        probe = new BatchProbe(tokenA, tokenB, tokenC);
        tokenA.approve(address(proxy), type(uint256).max);
        tokenB.approve(address(proxy), type(uint256).max);
        _track(address(this), "user");
        _track(address(router_), "router");
        _track(RECIPIENT, "recipient");
        _track(REFUND, "refund");
        _track(SINK, "sink");
        _track(address(proxy), "proxy");
        _track(address(echo), "echo");
        _track(address(callee), "callee");
        _track(address(rejecter), "rejecter");
        for (uint256 i; i < MAX_ROUTES; ++i) {
            routes[i] = new BatchRoute();
            vm.deal(address(routes[i]), 1 << 100);
            _track(address(routes[i]), string.concat("route", vm.toString(i)));
        }
    }

    receive() external payable {}

    /// @dev The one fuzzed entry point: one multicall of several commands
    function batch(BatchInput calldata p) external {
        ++batches;
        Batch memory b = _plan(p);
        _fund(b);
        uint256[] memory ledger = _ledger();
        uint256[] memory allowed = _allowances();
        Expect memory e = _expect(b, ledger, allowed);
        Call3Value[] memory calls = new Call3Value[](b.cmds.length);
        for (uint256 i; i < calls.length; ++i) {
            calls[i] = _call(b, b.cmds[i]);
        }
        uint256 before = violationCount;
        try this.submit(calls, b.direct, b.refundTo, b.msgValue, b.transferA, b.transferB) returns (
            Result[] memory rs
        ) {
            _checkSuccess(b, e, rs);
            if (violationCount == before) _countSuccess(b, e, rs);
        } catch (bytes memory err) {
            _checkRevert(e, err, ledger, allowed);
            if (violationCount == before) _countRevert(b, e);
        }
    }

    /// @dev Self-call so that one try/catch covers everything the multicall can revert
    function submit(
        Call3Value[] calldata calls,
        bool direct,
        address refundTo,
        uint256 value,
        uint256 transferA,
        uint256 transferB
    ) external returns (Result[] memory) {
        require(msg.sender == address(this), "handler only");
        if (direct) {
            if (transferA != 0) tokenA.transfer(address(router), transferA);
            if (transferB != 0) tokenB.transfer(address(router), transferB);
            return router.multicall{value: value}(calls, refundTo, address(0), META);
        }
        uint256 n = (transferA != 0 ? 1 : 0) + (transferB != 0 ? 1 : 0);
        address[] memory tokens = new address[](n);
        uint256[] memory amounts = new uint256[](n);
        uint256 j;
        if (transferA != 0) (tokens[j], amounts[j++]) = (address(tokenA), transferA);
        if (transferB != 0) (tokens[j], amounts[j]) = (address(tokenB), transferB);
        return proxy.transferAndMulticall{value: value}(tokens, amounts, calls, refundTo, address(0), META);
    }

    // ---------------------------------------------------------------- plan

    function _plan(BatchInput calldata p) internal view returns (Batch memory b) {
        b.direct = p.path % 3 == DIRECT_PATH;
        uint256 rf = p.refund % 8;
        if (rf == 4 || rf == 5) b.refundTo = address(router);
        else if (rf == REFUND_REJECTER) b.refundTo = address(rejecter);
        else if (rf == REFUND_ZERO && b.direct) b.refundTo = address(0);
        else b.refundTo = REFUND;
        b.caller = b.direct ? address(this) : address(proxy);
        b.refundAddr = b.refundTo == address(0) ? b.caller : b.refundTo;
        b.seed[ASSET_A] = p.seedMask & SEED_A != 0 ? p.seedA % AMOUNTS : 0;
        b.seed[ASSET_B] = p.seedMask & SEED_B != 0 ? p.seedB % AMOUNTS : 0;
        b.seed[ASSET_C] = p.seedMask & SEED_C != 0 ? p.seedC % AMOUNTS : 0;
        b.seed[ASSET_NATIVE] = p.seedMask & SEED_NATIVE != 0 ? p.seedNative % AMOUNTS : 0;
        b.transferFirst = p.seedMask & TRANSFER_FIRST != 0;
        b.surplus = p.surplus % AMOUNTS;
        b.msgValue = b.surplus;

        uint256 n = 1 + p.count % MAX_COMMANDS;
        uint256[] memory kinds = new uint256[](n);
        uint256 raceCount;
        for (uint256 i; i < n; ++i) {
            uint256 k = _topKind(p.commands[i].kind);
            if (k == K_RACE) {
                if (raceCount == MAX_RACES) k = K_ECHO;
                else ++raceCount;
            }
            kinds[i] = k;
        }
        b.races = new RaceSpec[](raceCount);
        b.cmds = new Cmd[](n + 2 * raceCount);
        uint256 at;
        uint256 r;
        for (uint256 i; i < n; ++i) {
            if (kinds[i] != K_RACE) {
                Cmd memory c = _decode(p.commands[i], kinds[i]);
                if (c.value != HUGE) b.msgValue += c.value;
                b.cmds[at++] = c;
                continue;
            }
            RaceSpec memory race = _raceSpec(p.races[r]);
            b.races[r] = race;
            b.cmds[at++].kind = K_PROBE;
            b.cmds[at].kind = K_RACE;
            b.cmds[at++].race = r;
            b.cmds[at++].kind = K_PROBE;
            b.msgValue += race.value;
            if (r == 0 || !b.transferFirst) {
                if (race.assetIn == ASSET_A) b.transferA += race.amountIn;
                else if (race.assetIn == ASSET_B) b.transferB += race.amountIn;
            }
            ++r;
        }
        b.transferA += p.extraIn % AMOUNTS;
        b.inner = new Cmd[](1 + p.innerCount % MAX_INNER);
        for (uint256 j; j < b.inner.length; ++j) {
            b.inner[j] = _decode(p.inner[j], _innerKind(p.inner[j].kind));
        }
        uint256 ir = p.innerRefund % 4;
        b.innerRefund = ir == 1 ? SINK : ir == 2 ? address(rejecter) : address(0);
    }

    function _topKind(uint8 raw) internal pure returns (uint256) {
        uint256 k = raw % 9;
        if (k == IN_ECHO) return K_ECHO;
        if (k == IN_CLEANUP) return K_CLEANUP;
        if (k == IN_VIA_ERC20) return K_VIA_ERC20;
        if (k == IN_CLEANUP_NATIVE) return K_CLEANUP_NATIVE;
        if (k == IN_VIA_NATIVE) return K_VIA_NATIVE;
        if (k == IN_NESTED) return K_NESTED;
        return K_RACE;
    }

    /// @dev No race and no nested multicall inside a nested multicall
    function _innerKind(uint8 raw) internal pure returns (uint256) {
        uint256 k = raw % 5;
        return k == 0 ? K_ECHO : k == 1 ? K_CLEANUP : k == 2 ? K_VIA_ERC20 : k == 3 ? K_CLEANUP_NATIVE : K_VIA_NATIVE;
    }

    function _decode(CommandInput calldata c, uint256 kind) internal view returns (Cmd memory d) {
        d.kind = kind;
        d.allowFailure = c.mode & 1 != 0;
        uint256 m = c.mode >> 1;
        if (kind == K_ECHO) {
            // m % 4 == 0 reverts; (m >> 2) % 4: 0 no value, 1-2 amount % 64, 3 more than the router holds;
            // to % 16: 13 the zero address, 14 and 15 the two registries, otherwise the echo contract
            d.fail = m % 4 == 0;
            uint256 v = (m >> 2) % 4;
            d.value = v == 0 ? 0 : v == 3 ? HUGE : c.amount % 64;
            d.amount = c.amount;
            uint256 t = c.to % 16;
            d.to = t == ECHO_AT_ZERO
                ? address(0)
                : t == ECHO_AT_ERC1820 ? ERC1820_REGISTRY : t == ECHO_AT_ERC820 ? ERC820_REGISTRY : address(echo);
        } else if (kind == K_CLEANUP) {
            // m % 8: 0-2 the whole balance, 3-6 amount, 7 arrays of different lengths
            d.asset = c.pick % 3;
            uint256 t = c.to % 4;
            d.to = t == 0 ? SINK : t == 1 ? address(callee) : t == 2 ? address(router) : address(rejecter);
            uint256 v = m % 8;
            d.variant = v < 3 ? V_WHOLE : v < 7 ? V_EXPLICIT : V_MISMATCH;
            if (d.variant == V_EXPLICIT) d.amount = c.amount % AMOUNTS;
        } else if (kind == K_VIA_ERC20) {
            // m % 4: how; (m >> 4) % 2: the whole balance, amount;
            // to % 8: 6 and 7 the two registries, otherwise the callee
            d.asset = c.pick % 3;
            d.how = m % 4;
            d.variant = (m >> 4) % 2 == 0 ? V_WHOLE : V_EXPLICIT;
            if (d.variant == V_EXPLICIT) d.amount = c.amount % AMOUNTS;
            d.to = _viaCallee(c.to);
        } else if (kind == K_CLEANUP_NATIVE) {
            // to % 4: the sink, zero (the router), the rejecter, the sink; m % 2: the whole balance, amount
            uint256 t = c.to % 4;
            d.to = t == 1 ? address(0) : t == 2 ? address(rejecter) : SINK;
            if (m % 2 == 1) d.amount = c.amount % AMOUNTS;
        } else if (kind == K_VIA_NATIVE) {
            // m % 4: how; (m >> 2) % 2: the whole balance, amount; to % 8 as for cleanupErc20sViaCall
            d.how = m % 4;
            if ((m >> 2) % 2 == 1) d.amount = c.amount % AMOUNTS;
            d.to = _viaCallee(c.to);
        } else {
            // nested: m % 4 == 0 carries amount % 64, which the router sends to itself
            if (m % 4 == 0) d.value = c.amount % 64;
        }
    }

    function _viaCallee(uint8 raw) internal view returns (address) {
        uint256 t = raw % 8;
        return t == VIA_TO_ERC1820 ? ERC1820_REGISTRY : t == VIA_TO_ERC820 ? ERC820_REGISTRY : address(callee);
    }

    /// @dev A command to the zero address or a hook registry. The router refuses it before it makes the call, and
    /// allowFailure does not cover it: the multicall the command is in reverts
    function _refused(Cmd memory c) internal view returns (bool) {
        return c.kind == K_ECHO && c.to != address(echo);
    }

    function _raceSpec(RaceInput calldata ri) internal view returns (RaceSpec memory r) {
        uint256 n = 1 + ri.routeCount % MAX_ROUTES;
        r.entry = ri.entry % 3;
        r.mainCount = 1 + ri.mainCount % n;
        r.flags = ri.flags & (EMIT_EVENTS | DIRECT_OUTPUT | NO_INPUT_REFUND | LOG_FUNDS_MOVEMENT);
        uint256 assets = ri.assets % 4;
        if (assets == 0) (r.assetIn, r.assetOut) = (ASSET_A, ASSET_B);
        else if (assets == 1) (r.assetIn, r.assetOut) = (ASSET_B, ASSET_A);
        else if (assets == 2) (r.assetIn, r.assetOut) = (ASSET_NATIVE, ASSET_B);
        else (r.assetIn, r.assetOut) = (ASSET_A, ASSET_NATIVE);
        r.amountIn = ri.amountIn % AMOUNTS;
        r.recipient = ri.recipient % 3 == 2 ? address(router) : RECIPIENT;
        r.value = ri.value % AMOUNTS;
        if (r.assetIn == ASSET_NATIVE) r.value += r.amountIn;
        r.fail = new bool[](n);
        r.spend = new uint256[](n);
        r.out = new uint256[](n);
        r.rvalue = new uint256[](n);
        uint256 lo = type(uint256).max;
        uint256 hi;
        for (uint256 i; i < n; ++i) {
            RouteInput calldata rt = ri.routes[i];
            uint256 k = rt.kind % 8;
            r.fail[i] = k == FAILS;
            r.spend[i] = k < SPENDS_PART ? r.amountIn : k < SPENDS_NONE && r.amountIn != 0 ? rt.spend % r.amountIn : 0;
            // Distinct outputs, so that the winner is one route and not a tie broken by gas
            uint256 out = rt.out % AMOUNTS;
            for (bool clash = true; clash;) {
                clash = false;
                for (uint256 j; j < i; ++j) {
                    if (r.out[j] == out) (out, clash) = (out + 1, true);
                }
            }
            r.out[i] = out;
            if (r.assetIn == ASSET_NATIVE) r.rvalue[i] = r.spend[i];
            else if (r.assetOut != ASSET_NATIVE && rt.value % 2 == 1) r.rvalue[i] = (rt.value >> 1) % (r.value + 1);
            if (!r.fail[i]) {
                if (out != 0 && out < lo) lo = out;
                if (out > hi) hi = out;
            }
        }
        uint256 mode = ri.minMode % 4;
        r.minOut = mode == 0 ? lo : mode == 1 ? hi : mode == 2 ? hi + 1 : 1 + ri.minOut % AMOUNTS;
        if (r.minOut == 0 || r.minOut == type(uint256).max) r.minOut = 1;
    }

    function _fund(Batch memory b) internal {
        if (b.seed[ASSET_A] != 0) tokenA.mint(address(router), b.seed[ASSET_A]);
        if (b.seed[ASSET_B] != 0) tokenB.mint(address(router), b.seed[ASSET_B]);
        if (b.seed[ASSET_C] != 0) tokenC.mint(address(router), b.seed[ASSET_C]);
        if (b.seed[ASSET_NATIVE] != 0) vm.deal(address(router), address(router).balance + b.seed[ASSET_NATIVE]);
        if (b.transferA != 0) tokenA.mint(address(this), b.transferA);
        if (b.transferB != 0) tokenB.mint(address(this), b.transferB);
        vm.deal(address(this), address(this).balance + b.msgValue);
    }

    // ---------------------------------------------------------------- commands

    function _call(Batch memory b, Cmd memory c) internal view returns (Call3Value memory) {
        if (c.kind == K_PROBE) return Call3Value(address(probe), false, 0, abi.encodeCall(BatchProbe.snap, ()));
        if (c.kind == K_ECHO) {
            return Call3Value(c.to, c.allowFailure, c.value, abi.encodeCall(BatchEcho.echo, (c.amount, c.fail)));
        }
        if (c.kind == K_RACE) {
            return Call3Value(address(router), false, b.races[c.race].value, _raceData(b.races[c.race]));
        }
        bytes memory data;
        if (c.kind == K_CLEANUP) {
            address[] memory tokens = new address[](1);
            address[] memory recipients = new address[](c.variant == V_MISMATCH ? 2 : 1);
            uint256[] memory amounts = new uint256[](1);
            tokens[0] = _token(c.asset);
            for (uint256 i; i < recipients.length; ++i) {
                recipients[i] = c.to;
            }
            amounts[0] = c.amount;
            data = abi.encodeCall(RelayRouterBase.cleanupErc20s, (tokens, recipients, amounts, META));
        } else if (c.kind == K_VIA_ERC20) {
            address[] memory tokens = new address[](1);
            address[] memory tos = new address[](1);
            bytes[] memory datas = new bytes[](1);
            uint256[] memory amounts = new uint256[](1);
            tokens[0] = _token(c.asset);
            tos[0] = c.to;
            datas[0] = abi.encodeCall(BatchCallee.take, (tokens[0], c.how));
            amounts[0] = c.amount;
            data = abi.encodeCall(RelayRouterBase.cleanupErc20sViaCall, (tokens, tos, datas, amounts));
        } else if (c.kind == K_CLEANUP_NATIVE) {
            data = abi.encodeCall(RelayRouterBase.cleanupNative, (c.amount, c.to, META));
        } else if (c.kind == K_VIA_NATIVE) {
            data = abi.encodeCall(
                RelayRouterBase.cleanupNativeViaCall, (c.amount, c.to, abi.encodeCall(BatchCallee.takeNative, (c.how)))
            );
        } else {
            Call3Value[] memory inner = new Call3Value[](b.inner.length);
            for (uint256 j; j < inner.length; ++j) {
                inner[j] = _call(b, b.inner[j]);
            }
            data = abi.encodeCall(RelayRouterBase.multicall, (inner, b.innerRefund, address(0), META));
        }
        return Call3Value(address(router), c.allowFailure, c.value, data);
    }

    function _raceData(RaceSpec memory r) internal view returns (bytes memory) {
        uint256 n = r.out.length;
        Route[] memory rs = new Route[](n);
        address tokenIn = _token(r.assetIn);
        address tokenOut = _token(r.assetOut);
        address holder = r.flags & DIRECT_OUTPUT != 0 ? r.recipient : address(router);
        for (uint256 i; i < n; ++i) {
            rs[i] = packRoute(
                address(routes[i]),
                address(routes[i]),
                r.rvalue[i],
                ROUTE_GAS,
                0,
                abi.encodeCall(BatchRoute.run, (tokenIn, r.spend[i], tokenOut, r.out[i], holder, r.fail[i]))
            );
        }
        if (r.entry == R_RACE) {
            return abi.encodeCall(IRouteRace.race, (tokenIn, r.amountIn, tokenOut, r.minOut, r.recipient, r.flags, rs));
        }
        if (r.entry == R_SINGLE) {
            return
                abi.encodeCall(
                    IRouteRace.raceSingle, (tokenIn, r.amountIn, tokenOut, r.minOut, r.recipient, r.flags, rs)
                );
        }
        return abi.encodeCall(
            IRouteRace.raceWithBackups, (tokenIn, r.amountIn, tokenOut, r.minOut, r.recipient, r.flags, rs, r.mainCount)
        );
    }

    // ---------------------------------------------------------------- model

    /// @dev What the multicall must do, command by command, from the balances before it, and what the proxy that
    /// sent it does once it has returned
    function _expect(Batch memory b, uint256[] memory ledger, uint256[] memory allowed)
        internal
        view
        returns (Expect memory e)
    {
        Sim memory s = Sim(_dup(ledger), _dup(allowed));
        e.results = new Result[](b.cmds.length);
        e.winner = new uint256[](b.races.length);
        e.amountAt = new uint256[](b.cmds.length);
        e.innerSwept = new uint256[](b.cmds.length);
        e.innerRefused = new bool[](b.cmds.length);
        for (uint256 k; k < b.races.length; ++k) {
            e.winner[k] = NO_ROUTE;
        }
        _move(s, H_USER, H_ROUTER, ASSET_NATIVE, b.msgValue);
        _move(s, H_USER, H_ROUTER, ASSET_A, b.transferA);
        _move(s, H_USER, H_ROUTER, ASSET_B, b.transferB);
        for (uint256 i; i < b.cmds.length; ++i) {
            (bool ok, bytes memory data) = _sim(s, b, e, b.cmds[i], i);
            if (!ok && (!b.cmds[i].allowFailure || _refused(b.cmds[i]))) {
                (e.reverts, e.revertData, e.failedAt) = (true, data, i);
                return e;
            }
            e.results[i] = Result(ok, data);
        }
        e.swept = _get(s, H_ROUTER, ASSET_NATIVE);
        if (e.swept != 0) {
            uint256 to = _h(b.refundAddr);
            if (to == H_REJECTER) {
                (e.reverts, e.sweepReverts, e.failedAt) = (true, true, NO_ROUTE);
                e.revertData = abi.encodeWithSelector(SafeTransferLib.ETHTransferFailed.selector);
                return e;
            }
            _move(s, H_ROUTER, to, ASSET_NATIVE, e.swept);
        }
        // Once a multicall it sent has returned, the proxy has the router send all it holds of each token the
        // proxy transferred to the refund address: input no race took, and with it what stood on the router
        // before and an output a race kept there. A token the proxy did not transfer stays, and so does every
        // token after a multicall sent straight to the router
        if (!b.direct) {
            if (b.transferA != 0) e.proxySwept[ASSET_A] = _get(s, H_ROUTER, ASSET_A);
            if (b.transferB != 0) e.proxySwept[ASSET_B] = _get(s, H_ROUTER, ASSET_B);
            _move(s, H_ROUTER, _h(b.refundAddr), ASSET_A, e.proxySwept[ASSET_A]);
            _move(s, H_ROUTER, _h(b.refundAddr), ASSET_B, e.proxySwept[ASSET_B]);
        }
        e.s = s;
    }

    /// @dev One command. Changes `s` only when the command succeeds
    function _sim(Sim memory s, Batch memory b, Expect memory e, Cmd memory c, uint256 i)
        internal
        view
        returns (bool, bytes memory)
    {
        uint256 native = _get(s, H_ROUTER, ASSET_NATIVE);
        if (c.kind == K_PROBE) {
            uint256[4] memory snap;
            for (uint256 a; a < ASSETS; ++a) {
                snap[a] = _get(s, H_ROUTER, a);
            }
            return (true, abi.encode(snap));
        }
        if (c.kind == K_ECHO) {
            if (_refused(c)) return (false, abi.encodeWithSelector(RelayRouterBase.InvalidTarget.selector, c.to));
            if (c.value > native) return (false, "");
            if (c.fail) return (false, abi.encodeWithSelector(BatchEcho.Scripted.selector, c.amount));
            _move(s, H_ROUTER, _h(address(echo)), ASSET_NATIVE, c.value);
            return (true, abi.encode(c.amount));
        }
        if (c.kind == K_RACE) return _simRace(s, b, e, c.race);
        if (c.kind == K_NESTED) return _simNested(s, b, e, c, i);
        if (c.kind == K_CLEANUP_NATIVE || c.kind == K_VIA_NATIVE) {
            uint256 sent = c.amount == 0 ? native : c.amount;
            if (i < e.amountAt.length) e.amountAt[i] = sent;
            if (sent == 0) return (true, "");
            if (c.kind == K_CLEANUP_NATIVE) {
                address to = c.to == address(0) ? address(router) : c.to;
                if (sent > native || to == address(rejecter)) {
                    return (false, abi.encodeWithSelector(SafeTransferLib.ETHTransferFailed.selector));
                }
                _move(s, H_ROUTER, _h(to), ASSET_NATIVE, sent);
                return (true, "");
            }
            // A registry is refused before the call is made, and only when there is something to send
            if (c.to != address(callee)) {
                return (false, abi.encodeWithSelector(RelayRouterBase.InvalidTarget.selector, c.to));
            }
            if (sent > native || c.how == TAKE_FAIL) {
                return (false, abi.encodeWithSelector(RelayRouterBase.CallFailed.selector));
            }
            uint256 back = c.how == TAKE_ALL ? 0 : c.how == TAKE_PART ? sent / 2 : sent;
            _move(s, H_ROUTER, H_CALLEE, ASSET_NATIVE, sent - back);
            return (true, "");
        }
        // The two cleanups of ERC-20s
        if (c.variant == V_MISMATCH) {
            return (false, abi.encodeWithSelector(RelayRouterBase.ArrayLengthsMismatch.selector));
        }
        uint256 balance = _get(s, H_ROUTER, c.asset);
        uint256 amount = c.amount == 0 ? balance : c.amount;
        if (i < e.amountAt.length) e.amountAt[i] = amount;
        if (amount == 0) return (true, "");
        if (c.kind == K_CLEANUP) {
            if (amount > balance) return (false, abi.encodeWithSelector(SafeTransferLib.TransferFailed.selector));
            _move(s, H_ROUTER, _h(c.to), c.asset, amount);
            return (true, "");
        }
        if (c.to != address(callee)) {
            return (false, abi.encodeWithSelector(RelayRouterBase.InvalidTarget.selector, c.to));
        }
        uint256 pull = c.how == TAKE_ALL ? amount : c.how == TAKE_PART ? amount / 2 : 0;
        if (c.how == TAKE_FAIL || pull > balance) {
            return (false, abi.encodeWithSelector(RelayRouterBase.CallFailed.selector));
        }
        s.allow[c.asset] = amount - pull;
        _move(s, H_ROUTER, H_CALLEE, c.asset, pull);
        return (true, "");
    }

    function _simNested(Sim memory s, Batch memory b, Expect memory e, Cmd memory c, uint256 i)
        internal
        view
        returns (bool, bytes memory)
    {
        // The router sends the command's value to itself
        if (c.value > _get(s, H_ROUTER, ASSET_NATIVE)) return (false, "");
        Sim memory t = Sim(_dup(s.bal), _dup(s.allow));
        Result[] memory rs = new Result[](b.inner.length);
        for (uint256 j; j < rs.length; ++j) {
            (bool ok, bytes memory data) = _sim(t, b, e, b.inner[j], NO_ROUTE);
            bool refused = _refused(b.inner[j]);
            if (refused) e.innerRefused[i] = true;
            if (!ok && (!b.inner[j].allowFailure || refused)) return (false, data);
            rs[j] = Result(ok, data);
        }
        // Its own final sweep. Its caller, and so its zero refundTo, is the router
        uint256 left = _get(t, H_ROUTER, ASSET_NATIVE);
        if (left != 0) {
            address to = b.innerRefund == address(0) ? address(router) : b.innerRefund;
            if (to == address(rejecter)) {
                return (false, abi.encodeWithSelector(SafeTransferLib.ETHTransferFailed.selector));
            }
            _move(t, H_ROUTER, _h(to), ASSET_NATIVE, left);
        }
        (s.bal, s.allow) = (t.bal, t.allow);
        e.innerSwept[i] = left;
        return (true, abi.encode(rs));
    }

    function _simRace(Sim memory s, Batch memory b, Expect memory e, uint256 k)
        internal
        view
        returns (bool, bytes memory)
    {
        RaceSpec memory r = b.races[k];
        uint256 native = _get(s, H_ROUTER, ASSET_NATIVE);
        if (r.assetIn != ASSET_NATIVE) {
            uint256 balance = _get(s, H_ROUTER, r.assetIn);
            if (balance < r.amountIn) {
                return (false, abi.encodeWithSelector(RouteRaceEngine.InsufficientInput.selector, balance, r.amountIn));
            }
        }
        // A route whose value the router cannot pay reverts in every run
        uint256 n = r.out.length;
        bool[] memory ok = new bool[](n);
        bool any;
        uint256 best;
        for (uint256 i; i < n; ++i) {
            ok[i] = !r.fail[i] && r.rvalue[i] <= native;
            if (ok[i]) {
                any = true;
                if (r.out[i] > best) best = r.out[i];
            }
        }
        uint256 w = _winner(r, ok);
        if (w == NO_ROUTE) {
            if (!any) return (false, abi.encodeWithSelector(RouteRaceEngine.AllRoutesFailed.selector));
            return (false, abi.encodeWithSelector(RouteRaceEngine.InsufficientOutput.selector, best, r.minOut));
        }
        e.winner[k] = w;
        uint256 route = H_ROUTE + w;
        if (r.assetIn == ASSET_NATIVE) {
            _move(s, H_ROUTER, route, ASSET_NATIVE, r.spend[w]);
        } else {
            _move(s, H_ROUTER, route, r.assetIn, r.spend[w]);
            _move(s, H_ROUTER, route, ASSET_NATIVE, r.rvalue[w]);
        }
        uint256 holder = r.flags & DIRECT_OUTPUT != 0 ? _h(r.recipient) : H_ROUTER;
        if (r.assetOut == ASSET_NATIVE) _move(s, route, holder, ASSET_NATIVE, r.out[w]);
        else s.bal[holder * ASSETS + r.assetOut] += r.out[w];
        _move(s, H_ROUTER, _h(r.recipient), r.assetOut, holder == H_ROUTER ? r.out[w] : 0);
        if (r.assetIn != ASSET_NATIVE && r.flags & NO_INPUT_REFUND == 0) {
            _move(s, H_ROUTER, _h(b.refundAddr), r.assetIn, r.amountIn - r.spend[w]);
        }
        return (true, abi.encode(w, r.out[w]));
    }

    /// @dev With fee 0 and distinct outputs: the first route in order that reaches the minimum, or among mains
    /// the one that delivers most
    function _winner(RaceSpec memory r, bool[] memory ok) internal pure returns (uint256) {
        uint256 n = r.out.length;
        uint256 mains = r.entry == R_RACE ? n : r.entry == R_BACKUPS && r.mainCount > 1 ? r.mainCount : 0;
        uint256 w = NO_ROUTE;
        for (uint256 i; i < mains; ++i) {
            if (ok[i] && r.out[i] >= r.minOut && (w == NO_ROUTE || r.out[i] > r.out[w])) w = i;
        }
        if (w != NO_ROUTE) return w;
        for (uint256 i = mains; i < n; ++i) {
            if (ok[i] && r.out[i] >= r.minOut) return i;
        }
        return NO_ROUTE;
    }

    // ---------------------------------------------------------------- checks

    function _checkSuccess(Batch memory b, Expect memory e, Result[] memory rs) internal {
        if (e.reverts) {
            _violate(
                "L1", string.concat("the multicall succeeded; expected it to revert with ", vm.toString(e.revertData))
            );
            if (e.sweepReverts) {
                _violate(
                    "F2",
                    string.concat(
                        "the multicall succeeded though its final sweep of ",
                        vm.toString(e.swept),
                        " native to a refund address that rejects native must revert it"
                    )
                );
            }
            return;
        }
        _checkSweep(b, e);
        _checkRaces(b, rs);
        if (rs.length != e.results.length) {
            _violate("L1", string.concat("the multicall returned ", vm.toString(rs.length), " results"));
        } else {
            for (uint256 i; i < rs.length; ++i) {
                if (
                    rs[i].success != e.results[i].success
                        || keccak256(rs[i].returnData) != keccak256(e.results[i].returnData)
                ) {
                    _violate(
                        "L1",
                        string.concat(
                            "command ",
                            vm.toString(i),
                            " (",
                            _kindName(b.cmds[i].kind),
                            ") returned ",
                            _result(rs[i]),
                            ", expected ",
                            _result(e.results[i])
                        )
                    );
                    break;
                }
            }
        }
        _checkLedger(e.s.bal, e.s.allow, "after the multicall");
    }

    /// @dev F2. The router's native after a multicall that succeeded, and what its refund address got
    function _checkSweep(Batch memory b, Expect memory e) internal {
        uint256 left = address(router).balance;
        bool kept = b.refundAddr == address(router);
        if (left != (kept ? e.swept : 0)) {
            _violate(
                "F2",
                string.concat(
                    "the router holds ",
                    vm.toString(left),
                    " native after the multicall, expected ",
                    vm.toString(kept ? e.swept : 0),
                    "; the refund address is the ",
                    holderNames[_h(b.refundAddr)],
                    ", the model sweeps ",
                    vm.toString(e.swept)
                )
            );
        }
        uint256 h = _h(b.refundAddr);
        if (!kept && _balance(h, ASSET_NATIVE) != _get(e.s, h, ASSET_NATIVE)) {
            _violate(
                "F2",
                string.concat(
                    "the refund address (",
                    holderNames[h],
                    ") holds ",
                    vm.toString(_balance(h, ASSET_NATIVE)),
                    " native, expected ",
                    vm.toString(_get(e.s, h, ASSET_NATIVE)),
                    " with a sweep of ",
                    vm.toString(e.swept)
                )
            );
        }
    }

    /// @dev F5, from the probes around each race: what the race took from the router
    function _checkRaces(Batch memory b, Result[] memory rs) internal {
        for (uint256 i; i < b.cmds.length; ++i) {
            if (b.cmds[i].kind != K_RACE) continue;
            (bool ok, uint256[4] memory pre, uint256[4] memory post) = _probes(rs, i);
            if (!ok) continue;
            RaceSpec memory r = b.races[b.cmds[i].race];
            string memory what = string.concat(
                "race ",
                vm.toString(b.cmds[i].race),
                " (",
                _entryName(r.entry),
                ", ",
                _assetName(r.assetIn),
                " to ",
                _assetName(r.assetOut),
                ", amountIn ",
                vm.toString(r.amountIn),
                ", value ",
                vm.toString(r.value),
                ", flags ",
                vm.toString(r.flags),
                ")"
            );
            uint256 nativeBound = r.assetIn == ASSET_NATIVE ? r.amountIn : r.value;
            for (uint256 a; a < ASSETS; ++a) {
                uint256 bound = a == r.assetIn ? r.amountIn : a == ASSET_NATIVE ? nativeBound : 0;
                if (a == r.assetOut) bound = 0;
                bool falls = post[a] + bound < pre[a];
                bool other = a != r.assetIn && a != r.assetOut && a != ASSET_NATIVE;
                if (falls || (other && post[a] != pre[a])) {
                    _violate(
                        "F5",
                        string.concat(
                            what,
                            ": the router's ",
                            _assetName(a),
                            " went from ",
                            vm.toString(pre[a]),
                            " to ",
                            vm.toString(post[a]),
                            other
                                ? "; it is no token of the race"
                                : string.concat(", more than the ", vm.toString(bound), " it may lose")
                        )
                    );
                }
            }
        }
    }

    function _checkRevert(Expect memory e, bytes memory err, uint256[] memory ledger, uint256[] memory allowed)
        internal
    {
        if (!e.reverts) {
            _violate("L1", string.concat("the multicall reverted with ", vm.toString(err), "; expected it to succeed"));
            return;
        }
        if (keccak256(err) != keccak256(e.revertData)) {
            _violate(
                "L1",
                string.concat(
                    "the multicall reverted with ", vm.toString(err), ", expected ", vm.toString(e.revertData)
                )
            );
        }
        _checkLedger(ledger, allowed, "after a multicall that reverted");
    }

    function _checkLedger(uint256[] memory bal, uint256[] memory allow, string memory when) internal {
        for (uint256 h; h < holders.length; ++h) {
            for (uint256 a; a < ASSETS; ++a) {
                uint256 got = _balance(h, a);
                if (got != bal[h * ASSETS + a]) {
                    _violate(
                        "L1",
                        string.concat(
                            holderNames[h],
                            " holds ",
                            vm.toString(got),
                            " ",
                            _assetName(a),
                            " ",
                            when,
                            ", expected ",
                            vm.toString(bal[h * ASSETS + a])
                        )
                    );
                    return;
                }
            }
        }
        uint256[] memory now_ = _allowances();
        for (uint256 j; j < now_.length; ++j) {
            if (now_[j] != allow[j]) {
                _violate(
                    "L1",
                    string.concat(
                        "the router's ",
                        _assetName(j % 3),
                        " allowance to ",
                        holderNames[j < 3 ? H_CALLEE : H_ROUTE + j / 3 - 1],
                        " is ",
                        vm.toString(now_[j]),
                        " ",
                        when,
                        ", expected ",
                        vm.toString(allow[j])
                    )
                );
                return;
            }
        }
    }

    function _probes(Result[] memory rs, uint256 i)
        internal
        pure
        returns (bool ok, uint256[4] memory pre, uint256[4] memory post)
    {
        if (i == 0 || i + 1 >= rs.length) return (false, pre, post);
        if (!rs[i - 1].success || !rs[i + 1].success) return (false, pre, post);
        if (rs[i - 1].returnData.length != 128 || rs[i + 1].returnData.length != 128) return (false, pre, post);
        pre = abi.decode(rs[i - 1].returnData, (uint256[4]));
        post = abi.decode(rs[i + 1].returnData, (uint256[4]));
        ok = true;
    }

    // ---------------------------------------------------------------- reach

    function _countSuccess(Batch memory b, Expect memory e, Result[] memory rs) internal {
        uint256 firstRace = NO_ROUTE;
        uint256 lastRace;
        for (uint256 i; i < b.cmds.length; ++i) {
            if (b.cmds[i].kind == K_RACE) {
                if (firstRace == NO_ROUTE) firstRace = i;
                lastRace = i;
            }
        }
        for (uint256 i; i < b.cmds.length; ++i) {
            Cmd memory c = b.cmds[i];
            if (c.kind == K_PROBE) continue;
            bool ok = e.results[i].success;
            _reach(string.concat("L1.", _kindName(c.kind), ok ? ".ok" : ".failAllowed"));
            if (firstRace != NO_ROUTE && i < lastRace && c.kind != K_RACE) _reach("L1.commandBeforeRace");
            if (firstRace != NO_ROUTE && i > firstRace && ok) {
                if (c.kind == K_VIA_ERC20 || c.kind == K_VIA_NATIVE) _reach("L1.viaCallAfterRace");
                if (c.kind == K_NESTED) _reach("L1.nestedAfterRace");
            }
            _countHow(c, e.amountAt[i]);
            if (e.innerRefused[i]) _reach("L1.refusedTarget.inNested");
            if (c.kind == K_NESTED && ok && e.innerSwept[i] != 0) {
                _reach(b.innerRefund == address(0) ? "F2.nestedZeroRefund" : "F2.nestedRefund");
            }
        }
        for (uint256 j; j < 3; ++j) {
            if (_allowances()[j] != 0) _reach("L1.approvalLeft");
        }
        _countSweep(b, e);
        _countLeftover(b, e);
        _countRaces(b, e, rs);
    }

    function _countHow(Cmd memory c, uint256 amount) internal {
        if (c.kind != K_VIA_ERC20 && c.kind != K_VIA_NATIVE) return;
        if (c.to != address(callee)) {
            // A registry as the callee: refused when there is something to send, never called when there is not
            _reach(
                string.concat(
                    c.kind == K_VIA_ERC20 ? "L1.viaErc20." : "L1.viaNative.",
                    amount == 0 ? "registryUnused" : "registryRefused"
                )
            );
            return;
        }
        if (amount == 0) return;
        if (c.kind == K_VIA_ERC20) {
            if (c.how == TAKE_PART && amount < 2) return;
            _reach(
                c.how == TAKE_ALL
                    ? "L1.viaErc20.takesAll"
                    : c.how == TAKE_PART
                        ? "L1.viaErc20.takesPart"
                        : c.how == TAKE_NONE ? "L1.viaErc20.takesNothing" : "L1.viaErc20.fails"
            );
        } else if (c.kind == K_VIA_NATIVE) {
            if (c.how == TAKE_PART && amount < 2) return;
            _reach(
                c.how == TAKE_ALL
                    ? "L1.viaNative.keepsAll"
                    : c.how == TAKE_PART
                        ? "L1.viaNative.returnsPart"
                        : c.how == TAKE_NONE ? "L1.viaNative.returnsAll" : "L1.viaNative.fails"
            );
        }
    }

    function _countSweep(Batch memory b, Expect memory e) internal {
        if (e.swept == 0) {
            _reach("F2.nothingToSweep");
            return;
        }
        if (b.refundAddr == address(router)) {
            _reach("F2.refundIsRouter");
            return;
        }
        if (b.surplus != 0) _reach("F2.surplusValue");
        if (b.seed[ASSET_NATIVE] != 0) _reach("F2.standingNative");
        if (!b.direct) _reach("F2.proxyPath");
        if (b.direct && b.refundTo == address(0)) _reach("F2.directZeroRefund");
        for (uint256 k; k < b.races.length; ++k) {
            RaceSpec memory r = b.races[k];
            uint256 w = e.winner[k];
            if (r.assetOut == ASSET_NATIVE && r.recipient == address(router)) _reach("F2.raceNativeOutput");
            if (r.assetIn == ASSET_NATIVE && r.spend[w] < r.value) _reach("F2.unusedNativeInput");
        }
    }

    /// @dev What became of the tokenA and tokenB the router held when the multicall returned. The proxy's sweep
    /// sends a token the proxy transferred to the refund address, which moves nothing when that is the router. A
    /// token it did not transfer stays, and so does every token after a multicall sent straight to the router.
    /// `kept` is the most a race of the batch left of its input under flag 8, counted where the router still held
    /// as much when the multicall returned
    function _countLeftover(Batch memory b, Expect memory e) internal {
        for (uint256 a; a < 2; ++a) {
            uint256 transferred = a == ASSET_A ? b.transferA : b.transferB;
            uint256 left = _get(e.s, H_ROUTER, a); // after the sweep
            uint256 kept;
            for (uint256 k; k < b.races.length; ++k) {
                RaceSpec memory r = b.races[k];
                if (r.assetIn != a || r.flags & NO_INPUT_REFUND == 0) continue;
                uint256 unspent = r.amountIn - r.spend[e.winner[k]];
                if (unspent > kept) kept = unspent;
            }
            if (b.direct) {
                // A token the handler transferred itself, which the proxy would have swept
                if (transferred == 0 || left == 0) continue;
                _reach(kept != 0 && left >= kept ? "L1.direct.keptInputStays" : "L1.direct.standingStays");
            } else if (transferred == 0) {
                if (left != 0) _reach("L1.proxySweep.notTransferred");
            } else if (b.refundAddr == address(router)) {
                if (left != 0) _reach("L1.proxySweep.refundIsRouter");
            } else if (e.proxySwept[a] == 0) {
                _reach("L1.proxySweep.nothing");
            } else {
                if (kept != 0 && e.proxySwept[a] >= kept) _reach("L1.proxySweep.keptInput");
                // More than the proxy brought: what stood on the router went with it
                if (e.proxySwept[a] > transferred) _reach("L1.proxySweep.standing");
            }
        }
    }

    /// @dev The standing balances F5 is about, each counted only when it is still on the router after the race
    function _countRaces(Batch memory b, Expect memory e, Result[] memory rs) internal {
        for (uint256 i; i < b.cmds.length; ++i) {
            if (b.cmds[i].kind != K_RACE) continue;
            uint256 k = b.cmds[i].race;
            RaceSpec memory r = b.races[k];
            (bool ok, uint256[4] memory pre, uint256[4] memory post) = _probes(rs, i);
            if (!ok) continue;
            uint256 x = r.assetIn;
            if (x != ASSET_NATIVE) {
                uint256 standing = pre[x] - r.amountIn;
                bool refunds = r.flags & NO_INPUT_REFUND == 0 && b.refundAddr != address(router);
                if (r.spend[e.winner[k]] < r.amountIn && refunds && standing != 0 && post[x] >= standing) {
                    _reach("F5.unspentWhileStanding");
                }
                for (uint256 k2 = k + 1; k2 < b.races.length; ++k2) {
                    uint256 later = b.races[k2].amountIn;
                    if (
                        !b.transferFirst && b.races[k2].assetIn == x && later != 0 && standing >= later
                            && post[x] >= later
                    ) _reach("F5.sharedTransfer");
                }
                for (uint256 k0; k0 < k; ++k0) {
                    RaceSpec memory r0 = b.races[k0];
                    if (
                        b.transferFirst && r0.flags & NO_INPUT_REFUND != 0 && r0.assetIn == x
                            && r0.spend[e.winner[k0]] < r0.amountIn && r.amountIn != 0 && post[x] + r.amountIn >= pre[x]
                    ) _reach("F5.flag8Reused");
                }
            }
            uint256 y = r.assetOut;
            if (
                y != ASSET_NATIVE && r.flags & DIRECT_OUTPUT == 0 && r.recipient != address(router) && pre[y] != 0
                    && post[y] >= pre[y]
            ) _reach("F5.outputStandsAtDelivery");
            for (uint256 k0; k0 < k; ++k0) {
                uint256 z = b.races[k0].assetOut;
                if (b.races[k0].recipient == address(router) && z != x && pre[z] != 0 && post[z] >= pre[z]) {
                    _reach("F5.earlierOutputStands");
                }
            }
        }
    }

    function _countRevert(Batch memory b, Expect memory e) internal {
        if (e.failedAt == NO_ROUTE) {
            _reach("F2.rejectedSweepReverts");
            return;
        }
        Cmd memory c = b.cmds[e.failedAt];
        if (_refused(c)) {
            _reach(
                c.to == address(0)
                    ? "L1.refusedTarget.zero"
                    : c.to == ERC1820_REGISTRY ? "L1.refusedTarget.erc1820" : "L1.refusedTarget.erc820"
            );
            if (c.allowFailure) _reach("L1.refusedTarget.underAllowFailure");
            return;
        }
        _reach(string.concat("L1.", _kindName(c.kind), ".failReverts"));
        _countHow(c, c.amount == 0 ? 1 : c.amount);
        if (e.innerRefused[e.failedAt]) _reach("L1.refusedTarget.inNested");
    }

    // ---------------------------------------------------------------- helpers

    function _ledger() internal view returns (uint256[] memory all) {
        all = new uint256[](holders.length * ASSETS);
        for (uint256 h; h < holders.length; ++h) {
            for (uint256 a; a < ASSETS; ++a) {
                all[h * ASSETS + a] = _balance(h, a);
            }
        }
    }

    function _allowances() internal view returns (uint256[] memory all) {
        all = new uint256[](SPENDERS * 3);
        for (uint256 j; j < SPENDERS; ++j) {
            address spender = j == 0 ? address(callee) : address(routes[j - 1]);
            for (uint256 a; a < 3; ++a) {
                all[j * 3 + a] = TestERC20(_token(a)).allowance(address(router), spender);
            }
        }
    }

    function _balance(uint256 h, uint256 a) internal view returns (uint256) {
        return a == ASSET_NATIVE ? holders[h].balance : TestERC20(_token(a)).balanceOf(holders[h]);
    }

    function _token(uint256 a) internal view returns (address) {
        return
            a == ASSET_A
                ? address(tokenA)
                : a == ASSET_B ? address(tokenB) : a == ASSET_C ? address(tokenC) : address(0);
    }

    function _get(Sim memory s, uint256 h, uint256 a) internal pure returns (uint256) {
        return s.bal[h * ASSETS + a];
    }

    function _move(Sim memory s, uint256 from, uint256 to, uint256 a, uint256 amount) internal pure {
        if (amount == 0 || from == to) return;
        s.bal[from * ASSETS + a] -= amount;
        s.bal[to * ASSETS + a] += amount;
    }

    function _dup(uint256[] memory x) internal pure returns (uint256[] memory y) {
        y = new uint256[](x.length);
        for (uint256 i; i < x.length; ++i) {
            y[i] = x[i];
        }
    }

    function _h(address holder) internal view returns (uint256 h) {
        while (holders[h] != holder) ++h;
    }

    function _track(address holder, string memory name) internal {
        holders.push(holder);
        holderNames.push(name);
    }

    function _result(Result memory r) internal pure returns (string memory) {
        return string.concat("(", r.success ? "true, " : "false, ", vm.toString(r.returnData), ")");
    }

    function _kindName(uint256 k) internal pure returns (string memory) {
        if (k == K_ECHO) return "echo";
        if (k == K_RACE) return "race";
        if (k == K_CLEANUP) return "cleanupErc20s";
        if (k == K_VIA_ERC20) return "cleanupErc20sViaCall";
        if (k == K_CLEANUP_NATIVE) return "cleanupNative";
        if (k == K_VIA_NATIVE) return "cleanupNativeViaCall";
        if (k == K_NESTED) return "nested";
        return "probe";
    }

    function _entryName(uint256 entry) internal pure returns (string memory) {
        return entry == R_RACE ? "race" : entry == R_SINGLE ? "raceSingle" : "raceWithBackups";
    }

    function _assetName(uint256 a) internal pure returns (string memory) {
        return a == ASSET_A ? "tokenA" : a == ASSET_B ? "tokenB" : a == ASSET_C ? "tokenC" : "native";
    }

    function _reach(string memory key) internal {
        ++reach[key];
    }

    function _violate(string memory id, string memory what) internal {
        ++violationCount;
        if (violations[id]++ == 0) {
            firstViolation[id] = string.concat(id, " in batch #", vm.toString(batches), ": ", what);
        }
    }
}

contract RelayRouterBatchTest is Test {
    BatchHandler handler;

    function _deployRouter() internal virtual returns (RelayRouterBase) {
        return new RelayRouter();
    }

    function setUp() public {
        handler = new BatchHandler(_deployRouter());
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = BatchHandler.batch.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_F2_nativeSwept() public view {
        _clean("F2");
    }

    function invariant_F5_raceTakesOnlyItsInput() public view {
        _clean("F5");
    }

    function invariant_L1_batchOutcome() public view {
        _clean("L1");
    }

    /// @dev Fixed batches. Fails unless every case the campaign is meant to cover occurred and held
    function test_reach() public {
        _reachSweep();
        _reachStanding();
        _reachLeftover();
        _reachCommands();
        _reachRefused();
        _clean("F2");
        _clean("F5");
        _clean("L1");

        _reached("F2.nothingToSweep");
        _reached("F2.surplusValue");
        _reached("F2.proxyPath");
        _reached("F2.standingNative");
        _reached("F2.directZeroRefund");
        _reached("F2.raceNativeOutput");
        _reached("F2.unusedNativeInput");
        _reached("F2.refundIsRouter");
        _reached("F2.nestedZeroRefund");
        _reached("F2.nestedRefund");
        _reached("F2.rejectedSweepReverts");

        _reached("F5.sharedTransfer");
        _reached("F5.earlierOutputStands");
        _reached("F5.outputStandsAtDelivery");
        _reached("F5.flag8Reused");
        _reached("F5.unspentWhileStanding");

        _reached("L1.proxySweep.keptInput");
        _reached("L1.proxySweep.standing");
        _reached("L1.proxySweep.nothing");
        _reached("L1.proxySweep.refundIsRouter");
        _reached("L1.proxySweep.notTransferred");
        _reached("L1.direct.keptInputStays");
        _reached("L1.direct.standingStays");

        string[6] memory kinds =
            ["echo", "cleanupErc20s", "cleanupErc20sViaCall", "cleanupNative", "cleanupNativeViaCall", "nested"];
        for (uint256 i; i < kinds.length; ++i) {
            _reached(string.concat("L1.", kinds[i], ".ok"));
            _reached(string.concat("L1.", kinds[i], ".failAllowed"));
            _reached(string.concat("L1.", kinds[i], ".failReverts"));
        }
        _reached("L1.race.ok");
        _reached("L1.race.failReverts");
        _reached("L1.viaErc20.takesAll");
        _reached("L1.viaErc20.takesPart");
        _reached("L1.viaErc20.takesNothing");
        _reached("L1.viaErc20.fails");
        _reached("L1.viaNative.keepsAll");
        _reached("L1.viaNative.returnsPart");
        _reached("L1.viaNative.returnsAll");
        _reached("L1.viaNative.fails");
        _reached("L1.approvalLeft");
        _reached("L1.commandBeforeRace");
        _reached("L1.viaCallAfterRace");
        _reached("L1.nestedAfterRace");
        _reached("L1.refusedTarget.zero");
        _reached("L1.refusedTarget.erc1820");
        _reached("L1.refusedTarget.erc820");
        _reached("L1.refusedTarget.underAllowFailure");
        _reached("L1.refusedTarget.inNested");
        _reached("L1.viaErc20.registryRefused");
        _reached("L1.viaErc20.registryUnused");
        _reached("L1.viaNative.registryRefused");
        _reached("L1.viaNative.registryUnused");
    }

    // Modes of CommandInput (bit 0 is allowFailure)
    uint8 internal constant ECHO_OK = 2;
    uint8 internal constant ECHO_FAILS = 0;
    uint8 internal constant CLEANUP_WHOLE = 0;
    uint8 internal constant CLEANUP_EXPLICIT = 6;
    uint8 internal constant CLEANUP_MISMATCH = 14;
    uint8 internal constant VIA_EXPLICIT = 32; // with how << 1; ERC-20
    uint8 internal constant VIA_NATIVE_EXPLICIT = 8; // with how << 1; native
    uint8 internal constant NATIVE_EXPLICIT = 2; // cleanupNative
    uint8 internal constant NESTED_OK = 2;
    uint8 internal constant MAY_FAIL = 1;
    uint8 internal constant TO_SINK = 0;
    uint8 internal constant TO_REJECTER = 2;
    uint8 internal constant PICK_B = 1;
    uint8 internal constant PICK_C = 2;

    /// @dev F2: where the final sweep's native comes from, and where it goes
    function _reachSweep() internal {
        // Nothing to sweep: the router holds no native yet
        BatchInput memory p = _batch(VIA_PROXY, REFUND_ADDR);
        p.commands[0] = _cmd(IN_ECHO, ECHO_OK, 0, 0, 7);
        handler.batch(p);

        // Surplus msg.value, through the proxy
        p.surplus = 500;
        handler.batch(p);

        // Native that stood on the router, straight to the router with a zero refundTo
        p = _batch(DIRECT_PATH, REFUND_ZERO);
        p.commands[0] = _cmd(IN_ECHO, ECHO_OK, 0, 0, 7);
        (p.seedMask, p.seedNative) = (SEED_NATIVE, 300);
        handler.batch(p);

        // Native output of a race whose recipient is the router
        p = _batch(VIA_PROXY, REFUND_ADDR);
        p.commands[0] = _cmd(IN_RACE, 0, 0, 0, 0);
        p.races[0] = _race(R_RACE, A_TO_NATIVE, TO_ROUTER, 0, 100);
        handler.batch(p);

        // Native input the winner did not use: it takes 40 of a value of 150
        p.races[0] = _race(R_RACE, NATIVE_TO_B, TO_RECIPIENT, 0, 100);
        p.races[0].value = 50;
        p.races[0].routes[0] = _route(SPENDS_PART, 100, 40);
        p.races[0].routes[1] = _route(SPENDS_PART, 120, 40);
        handler.batch(p);

        // A nested multicall with a zero refundTo, then with the sink as its refundTo
        p = _batch(VIA_PROXY, REFUND_ADDR);
        p.surplus = 200;
        p.commands[0] = _cmd(IN_NESTED, NESTED_OK, 0, 0, 0);
        p.inner[0] = _cmd(INNER_ECHO, ECHO_OK, 0, 0, 9);
        handler.batch(p);
        p.innerRefund = 1;
        handler.batch(p);

        // The router as refund address: it keeps the surplus, which the batches after this one sweep
        p = _batch(VIA_PROXY, REFUND_ROUTER);
        p.surplus = 100;
        p.commands[0] = _cmd(IN_ECHO, ECHO_OK, 0, 0, 7);
        handler.batch(p);

        // A refund address that rejects native, with native to sweep: the multicall reverts
        p.refund = REFUND_REJECTER;
        handler.batch(p);
    }

    /// @dev F5: balances that stand on the router while a race runs
    function _reachStanding() internal {
        // Two races fed by one transfer: the second race's 80 stand during the first
        BatchInput memory p = _batch(VIA_PROXY, REFUND_ADDR);
        p.count = 1;
        p.commands[0] = _cmd(IN_RACE, 0, 0, 0, 0);
        p.commands[1] = _cmd(IN_RACE, 0, 0, 0, 0);
        p.races[0] = _race(R_RACE, A_TO_B, TO_RECIPIENT, 0, 100);
        p.races[1] = _race(R_SINGLE, A_TO_B, TO_RECIPIENT, 0, 80);
        handler.batch(p);

        // The first race keeps its tokenB output on the router; the second delivers tokenB to the recipient
        p.races[0] = _race(R_RACE, A_TO_B, TO_ROUTER, 0, 100);
        p.races[1] = _race(R_RACE, A_TO_B, TO_RECIPIENT, 0, 100);
        handler.batch(p);

        // Flag 8 keeps 60 of 100 on the router; the transfer brings only those 100, and the second race uses 60
        p.seedMask = TRANSFER_FIRST;
        p.races[0] = _race(R_RACE, A_TO_B, TO_RECIPIENT, uint8(NO_INPUT_REFUND), 100);
        p.races[0].routes[0] = _route(SPENDS_PART, 100, 40);
        p.races[0].routes[1] = _route(SPENDS_PART, 120, 40);
        p.races[1] = _race(R_RACE, A_TO_B, TO_RECIPIENT, 0, 60);
        handler.batch(p);

        // The winner takes 30 of 100 while 500 tokenA stand on the router; the refund is on
        p = _batch(VIA_PROXY, REFUND_ADDR);
        (p.seedMask, p.seedA) = (SEED_A, 500);
        p.commands[0] = _cmd(IN_RACE, 0, 0, 0, 0);
        p.races[0] = _race(R_RACE, A_TO_B, TO_RECIPIENT, 0, 100);
        p.races[0].routes[0] = _route(SPENDS_PART, 100, 30);
        p.races[0].routes[1] = _route(SPENDS_PART, 120, 30);
        handler.batch(p);
    }

    /// @dev L1: the tokens the router holds when the multicall returns. The proxy's sweep sends those the proxy
    /// transferred to the refund address. Nothing follows a multicall sent straight to the router
    function _reachLeftover() internal {
        // The 500 tokenA of the batch before were the proxy's to sweep. Straight to the router the same batch
        // leaves its 500 there
        BatchInput memory p = _batch(DIRECT_PATH, REFUND_ADDR);
        (p.seedMask, p.seedA) = (SEED_A, 500);
        p.commands[0] = _cmd(IN_RACE, 0, 0, 0, 0);
        p.races[0] = _race(R_RACE, A_TO_B, TO_RECIPIENT, 0, 100);
        p.races[0].routes[0] = _route(SPENDS_PART, 100, 30);
        p.races[0].routes[1] = _route(SPENDS_PART, 120, 30);
        handler.batch(p);

        // Through the proxy, a race that takes all of its input: the sweep sends the 500 to the refund address
        p = _batch(VIA_PROXY, REFUND_ADDR);
        p.commands[0] = _cmd(IN_RACE, 0, 0, 0, 0);
        p.races[0] = _race(R_RACE, A_TO_B, TO_RECIPIENT, 0, 100);
        handler.batch(p);
        // Again, and the sweep finds nothing
        handler.batch(p);

        // Flag 8 keeps 60 of 100 on the router. Straight to the router they stay there
        p.path = DIRECT_PATH;
        p.races[0] = _race(R_RACE, A_TO_B, TO_RECIPIENT, uint8(NO_INPUT_REFUND), 100);
        p.races[0].routes[0] = _route(SPENDS_PART, 100, 40);
        p.races[0].routes[1] = _route(SPENDS_PART, 120, 40);
        handler.batch(p);

        // Through the proxy with the router as refund address they stay too: the sweep sends them to the router
        (p.path, p.refund) = (VIA_PROXY, REFUND_ROUTER);
        handler.batch(p);

        // With another refund address the sweep sends them there, and the 120 of the two batches before as well
        p.refund = REFUND_ADDR;
        handler.batch(p);

        // A token the proxy did not transfer stays: the input is native, and the router keeps the tokenB output
        p.races[0] = _race(R_RACE, NATIVE_TO_B, TO_ROUTER, 0, 100);
        handler.batch(p);
    }

    /// @dev L1: every kind of command succeeding, failing under allowFailure and failing without it
    function _reachCommands() internal {
        BatchInput memory p = _batch(VIA_PROXY, REFUND_ADDR);
        (p.seedMask, p.seedB) = (SEED_B, 1000);
        p.count = 4;
        p.commands[0] = _cmd(IN_ECHO, ECHO_FAILS | MAY_FAIL, 0, 0, 3);
        p.commands[1] = _cmd(IN_CLEANUP, CLEANUP_EXPLICIT, PICK_B, TO_SINK, 100);
        p.commands[2] = _cmd(IN_CLEANUP, CLEANUP_MISMATCH | MAY_FAIL, PICK_B, TO_SINK, 0);
        p.commands[3] = _cmd(IN_VIA_ERC20, VIA_EXPLICIT | uint8(TAKE_ALL << 1), PICK_B, 0, 100);
        p.commands[4] = _cmd(IN_VIA_ERC20, VIA_EXPLICIT | uint8(TAKE_PART << 1), PICK_B, 0, 100);
        handler.batch(p);

        p.surplus = 1000;
        p.commands[0] = _cmd(IN_VIA_ERC20, VIA_EXPLICIT | uint8(TAKE_NONE << 1), PICK_B, 0, 100);
        p.commands[1] = _cmd(IN_VIA_ERC20, VIA_EXPLICIT | uint8(TAKE_FAIL << 1) | MAY_FAIL, PICK_B, 0, 100);
        p.commands[2] = _cmd(IN_CLEANUP_NATIVE, MAY_FAIL, 0, TO_REJECTER, 0);
        p.commands[3] = _cmd(IN_CLEANUP_NATIVE, NATIVE_EXPLICIT, 0, TO_SINK, 50);
        p.commands[4] = _cmd(IN_VIA_NATIVE, VIA_NATIVE_EXPLICIT | uint8(TAKE_ALL << 1), 0, 0, 100);
        handler.batch(p);

        p.commands[0] = _cmd(IN_VIA_NATIVE, VIA_NATIVE_EXPLICIT | uint8(TAKE_PART << 1), 0, 0, 100);
        p.commands[1] = _cmd(IN_VIA_NATIVE, VIA_NATIVE_EXPLICIT | uint8(TAKE_NONE << 1), 0, 0, 100);
        p.commands[2] = _cmd(IN_VIA_NATIVE, VIA_NATIVE_EXPLICIT | uint8(TAKE_FAIL << 1) | MAY_FAIL, 0, 0, 100);
        p.commands[3] = _cmd(IN_NESTED, NESTED_OK, 0, 0, 0);
        p.commands[4] = _cmd(IN_ECHO, ECHO_OK, 0, 0, 5);
        p.inner[0] = _cmd(INNER_ECHO, ECHO_OK, 0, 0, 9);
        handler.batch(p);

        // A nested multicall whose command fails, under allowFailure
        p = _batch(VIA_PROXY, REFUND_ADDR);
        p.commands[0] = _cmd(IN_NESTED, NESTED_OK | MAY_FAIL, 0, 0, 0);
        p.inner[0] = _cmd(INNER_ECHO, ECHO_FAILS, 0, 0, 9);
        handler.batch(p);

        // Each kind failing without allowFailure: the multicall reverts with the command's revert data
        p.commands[0] = _cmd(IN_NESTED, NESTED_OK, 0, 0, 0);
        handler.batch(p);
        p.commands[0] = _cmd(IN_ECHO, ECHO_FAILS, 0, 0, 3);
        handler.batch(p);
        p.commands[0] = _cmd(IN_CLEANUP, CLEANUP_MISMATCH, PICK_B, TO_SINK, 0);
        handler.batch(p);
        p.commands[0] = _cmd(IN_VIA_ERC20, VIA_EXPLICIT | uint8(TAKE_FAIL << 1), PICK_B, 0, 100);
        handler.batch(p);
        p.surplus = 100;
        p.commands[0] = _cmd(IN_CLEANUP_NATIVE, 0, 0, TO_REJECTER, 0);
        handler.batch(p);
        p.commands[0] = _cmd(IN_VIA_NATIVE, VIA_NATIVE_EXPLICIT | uint8(TAKE_FAIL << 1), 0, 0, 100);
        handler.batch(p);
        p.commands[0] = _cmd(IN_RACE, 0, 0, 0, 0);
        p.races[0] = _race(R_RACE, A_TO_B, TO_RECIPIENT, 0, 100);
        p.races[0].minMode = MIN_ABOVE_BEST;
        handler.batch(p);

        // A command before a race, a ViaCall cleanup and a nested multicall after it
        p = _batch(VIA_PROXY, REFUND_ADDR);
        p.surplus = 100;
        p.count = 3;
        p.commands[0] = _cmd(IN_ECHO, ECHO_OK, 0, 0, 1);
        p.commands[1] = _cmd(IN_RACE, 0, 0, 0, 0);
        p.commands[2] = _cmd(IN_VIA_ERC20, uint8(TAKE_ALL << 1), PICK_B, 0, 0);
        p.commands[3] = _cmd(IN_NESTED, NESTED_OK, 0, 0, 0);
        p.races[0] = _race(R_RACE, A_TO_B, TO_ROUTER, 0, 100);
        p.inner[0] = _cmd(INNER_CLEANUP_NATIVE, 0, 0, TO_SINK, 0);
        handler.batch(p);
    }

    /// @dev L1: the targets the router refuses
    function _reachRefused() internal {
        // A command to the zero address, then to each registry: the multicall reverts, under allowFailure too
        BatchInput memory p = _batch(VIA_PROXY, REFUND_ADDR);
        p.commands[0] = _cmd(IN_ECHO, ECHO_OK, 0, ECHO_AT_ZERO, 7);
        handler.batch(p);
        p.commands[0] = _cmd(IN_ECHO, ECHO_OK, 0, ECHO_AT_ERC1820, 7);
        handler.batch(p);
        p.commands[0] = _cmd(IN_ECHO, ECHO_OK | MAY_FAIL, 0, ECHO_AT_ERC820, 7);
        handler.batch(p);

        // Inside a nested multicall, with allowFailure on both levels: the nested multicall reverts and fails
        // as one command, and the command after it runs
        p = _batch(DIRECT_PATH, REFUND_ADDR);
        p.count = 1;
        p.commands[0] = _cmd(IN_NESTED, NESTED_OK | MAY_FAIL, 0, 0, 0);
        p.commands[1] = _cmd(IN_ECHO, ECHO_OK, 0, 0, 5);
        p.inner[0] = _cmd(INNER_ECHO, ECHO_OK | MAY_FAIL, 0, ECHO_AT_ZERO, 9);
        handler.batch(p);

        // A ViaCall cleanup whose callee is a registry is refused when it has something to send
        p = _batch(VIA_PROXY, REFUND_ADDR);
        p.count = 1;
        p.commands[0] = _cmd(IN_VIA_ERC20, VIA_EXPLICIT | uint8(TAKE_ALL << 1) | MAY_FAIL, PICK_B, VIA_TO_ERC1820, 100);
        p.commands[1] =
            _cmd(IN_VIA_NATIVE, VIA_NATIVE_EXPLICIT | uint8(TAKE_ALL << 1) | MAY_FAIL, 0, VIA_TO_ERC820, 100);
        handler.batch(p);

        // With nothing to send it makes no call, so there is nothing to refuse: the router holds no tokenC, and
        // its native has just gone to the sink
        p.surplus = 100;
        p.count = 2;
        p.commands[0] = _cmd(IN_VIA_ERC20, uint8(TAKE_ALL << 1), PICK_C, VIA_TO_ERC820, 0);
        p.commands[1] = _cmd(IN_CLEANUP_NATIVE, 0, 0, TO_SINK, 0);
        p.commands[2] = _cmd(IN_VIA_NATIVE, uint8(TAKE_ALL << 1), 0, VIA_TO_ERC1820, 0);
        handler.batch(p);
    }

    function _batch(uint8 path, uint8 refund) internal pure returns (BatchInput memory p) {
        (p.path, p.refund) = (path, refund);
    }

    function _cmd(uint8 kind, uint8 mode, uint8 pick, uint8 to, uint64 amount)
        internal
        pure
        returns (CommandInput memory)
    {
        return CommandInput(kind, mode, pick, to, amount);
    }

    /// @dev Two routes that take all of amountIn and deliver 100 and 120; the minimum is 100
    function _race(uint8 entry, uint8 assets, uint8 recipient, uint8 flags, uint64 amountIn)
        internal
        pure
        returns (RaceInput memory r)
    {
        (r.entry, r.routeCount, r.assets, r.recipient, r.flags, r.amountIn) =
        (entry, 1, assets, recipient, flags, amountIn);
        r.minMode = MIN_LOWEST;
        r.routes[0] = _route(SPENDS_ALL, 100, 0);
        r.routes[1] = _route(SPENDS_ALL, 120, 0);
    }

    function _route(uint8 kind, uint64 out, uint64 spend) internal pure returns (RouteInput memory r) {
        (r.kind, r.out, r.spend) = (kind, out, spend);
    }

    function _clean(string memory id) internal view {
        assertEq(handler.violations(id), 0, handler.firstViolation(id));
    }

    function _reached(string memory key) internal {
        uint256 count = handler.reach(key);
        emit log_named_uint(key, count);
        assertGt(count, 0, string.concat("not reached: ", key));
    }
}

contract RelayRouterNonTstoreBatchTest is RelayRouterBatchTest {
    function _deployRouter() internal override returns (RelayRouterBase) {
        return new RelayRouter_NonTstore();
    }
}
