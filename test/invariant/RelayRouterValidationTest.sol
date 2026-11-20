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
import {TestERC20} from "../mocks/TestERC20.sol";

/// @dev Permit2's address on every chain. The approval proxy refuses a zero one.
address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

// V1: a race with an invalid argument, or one that reaches a malformed route, reverts the whole multicall with
// exactly the error the router names for that defect. With several defects, the error is that of the first one
// in the router's order of checks. A malformed route that the race never reaches has no effect: the race ends as
// it would if that route were well formed. A race without a defect is not refused.
//
// The handler sends one race per call, in one multicall, through the proxy or straight to the router. It draws
// no defect, one, a pair of neighbours in the order of checks, or one and any of those after it. From the
// concrete arguments it works out which defects the race has, which routes the race reaches, and so the exact
// revert data. Every route is honest or reverts, never touches the input, and delivers a scripted output, so the
// routes a race reaches follow from the outputs and the minimum alone:
// - raceSingle, and raceWithBackups with one main: the routes in order, up to the first that reaches the minimum;
// - race: every route;
// - raceWithBackups with two or more mains: every main, then, if no main reaches the minimum, the backups in order
//   up to the first that does.
// A race that fills and has a malformed route it did not reach is first run with that route well formed, and
// rolled back; the race itself has to end the same way.

uint256 constant SLOTS = 4;

// Defects, in the router's order of checks: the multicall, `_open`, `_raceWithBackups`, then per route `_attempt`
uint8 constant NFT_ROUTER = 0; // the multicall's nftRecipient is the router
uint8 constant NO_ROUTES = 1;
uint8 constant ZERO_RECIPIENT = 2;
uint8 constant ZERO_MIN = 3;
uint8 constant IDENTICAL = 4;
// Native input: the command's value is below amountIn. ERC-20 input: tokenIn is not a token, or the router holds
// less than amountIn
uint8 constant BAD_INPUT = 5;
uint8 constant BAD_OUTPUT = 6; // tokenOut is neither native nor a token
// raceWithBackups only: a mainCount of zero or above the route count. With no routes no mainCount is valid, so
// there the defect is NO_ROUTES alone
uint8 constant MAIN_COUNT = 7;
uint8 constant ROUTE_GAS = 8; // a gas limit of zero
uint8 constant ROUTE_TARGET = 9; // a target the router refuses: itself, or an ERC-777 hook registry
uint8 constant ROUTE_FEE = 10; // a fee of 1_000_000 ppm or more
uint8 constant DEFECTS = 11;

// RaceSpec.entry
uint8 constant RACE = 0;
uint8 constant RACE_SINGLE = 1;
uint8 constant RACE_WITH_BACKUPS = 2;

// RaceSpec.mode
uint8 constant NO_DEFECT = 0;
uint8 constant ONE = 1; // defect `pick`
uint8 constant PAIR = 2; // defects `pick` and `pick + 1`
uint8 constant FROM = 3; // defect `pick` and any of those after it

// RaceSpec.input: % 2 without BAD_INPUT, % 3 with it
uint8 constant NATIVE_IN = 0; // with BAD_INPUT: a command value below amountIn
uint8 constant TOKEN_IN = 1; // with BAD_INPUT: less than amountIn on the router
uint8 constant NOT_A_TOKEN_IN = 2;

// RaceSpec.feeForm: the fee of a route with ROUTE_FEE
uint8 constant WHOLE_OUTPUT = 0; // 1_000_000
uint8 constant MAX_FEE = 1; // 2^31 - 1, the largest fee a route can carry
uint8 constant FEE_BETWEEN = 2;

// RaceSpec.targetForm: the target of a route with ROUTE_TARGET
uint8 constant ROUTER_TARGET = 0;
uint8 constant ERC1820_TARGET = 1;
uint8 constant ERC820_TARGET = 2;

address constant ERC1820_REGISTRY = 0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24;
address constant ERC820_REGISTRY = 0x820b586C8C28125366C998641B09DCbE7d4cBF06;

// RaceSpec.path
uint8 constant DIRECT = 1;

// The clauses of V1, each counted and asserted on its own
string constant REFUSED = "V1 refused"; // a race with a defect it reaches reverts with exactly the first one's error
string constant UNREACHED = "V1 unreached"; // a malformed route the race does not reach changes nothing
string constant VALID = "V1 valid"; // a race without a defect fills when a route reaches the minimum

uint256 constant FEE_DENOMINATOR = 1_000_000;
uint256 constant MAX_PACKED_FEE = type(uint32).max >> 1;

struct RouteSpec {
    uint8 kind; // % 4: 0 reverts, 1-3 delivers `out`
    uint16 out; // % 1000
    uint8 defect; // FROM mode: the route defects of the race that this route carries too, bit 0 gas, 1 target, 2 fee
    uint8 feeMode; // % 4: 0 and 3 no fee, 1 999_999 ppm, 2 `fee` % 1_000_000
    uint32 fee;
}

struct RaceSpec {
    uint8 entry; // % 3
    uint8 mode; // % 4
    uint8 pick; // % 11 for ONE and FROM, % 10 for PAIR
    uint16 more; // FROM: bit j adds defect `pick + 1 + j`
    uint8 at; // % routes: the route that carries the drawn route defects
    uint8 routeCount; // 1 + % SLOTS routes, none with NO_ROUTES
    uint8 mainCount; // raceWithBackups: 1 + % routes mains; with MAIN_COUNT, even 0, odd routes + 1 + % 3
    uint8 input;
    uint8 output; // % 2: tokenB or native; tokenB when the input is native
    uint8 path; // % 2: through the proxy, straight to the router
    uint8 flags; // & 31
    uint8 nft; // % 2: no nftRecipient, an account
    uint8 minMode; // % 3: 1 + minOut % 1000, the output of route minOut % routes, above every output
    uint16 minOut;
    uint64 amountIn; // 1 + % 1e18
    uint64 slack; // the shortfall of BAD_INPUT, otherwise what the command or the router has beyond amountIn
    uint8 feeForm; // % 3
    uint32 between; // FEE_BETWEEN: 1_000_000 + between % (2^31 - 1_000_000)
    uint8 targetForm; // % 3
    RouteSpec[SLOTS] routes;
}

/// @dev One resolved race
struct Plan {
    uint256 entry;
    bool direct;
    address nftRecipient;
    address tokenIn; // address(0) is native
    uint256 amountIn;
    address tokenOut;
    uint256 minOut;
    address recipient;
    uint256 flags;
    uint256 value; // of the command and of the multicall
    uint256 funded; // tokenIn put on the router for the race
    uint256 mainCount;
    uint256 n;
    bool[SLOTS] fails;
    uint256[SLOTS] outs;
    uint256[SLOTS] fees;
    uint256[SLOTS] defects; // bit 0 gas, 1 target, 2 fee
    uint256 badFee;
    uint256 targetForm;
    address badTarget;
}

/// @dev What the order of checks makes of a plan
struct Verdict {
    uint256 present; // bit d: argument defect d, as the concrete arguments have it
    uint256 total; // argument defects plus every route defect bit, reached or not
    uint256 reachedCount; // the race reaches routes 0 .. reachedCount - 1, unless a defect stops it first
    bool fills; // some route reaches the minimum
    bool reject;
    uint256 first; // the defect whose error comes back
    uint256 at; // the route of a route defect
    bytes expected; // the exact revert data when `reject`
    uint256 balance; // ERC-20 input: what the router holds of tokenIn when the race opens
}

function entryName(uint256 entry) pure returns (string memory) {
    if (entry == RACE) return "race";
    if (entry == RACE_SINGLE) return "raceSingle";
    return "raceWithBackups";
}

function defectName(uint256 d) pure returns (string memory) {
    if (d == NFT_ROUTER) return "NftRecipientRouter";
    if (d == NO_ROUTES) return "NoRoutes";
    if (d == ZERO_RECIPIENT) return "ZeroRecipient";
    if (d == ZERO_MIN) return "ZeroMinimum";
    if (d == IDENTICAL) return "IdenticalTokens";
    if (d == BAD_INPUT) return "BadInput";
    if (d == BAD_OUTPUT) return "BadOutputToken";
    if (d == MAIN_COUNT) return "MainCount";
    if (d == ROUTE_GAS) return "RouteGas";
    if (d == ROUTE_TARGET) return "RouteTarget";
    return "RouteFee";
}

function targetFormName(uint256 form) pure returns (string memory) {
    if (form == ROUTER_TARGET) return "router";
    if (form == ERC1820_TARGET) return "erc1820Registry";
    return "erc820Registry";
}

/// @dev BAD_INPUT has three forms, each its own error
function inputDefectName(uint256 form) pure returns (string memory) {
    if (form == NATIVE_IN) return "LowValue";
    if (form == TOKEN_IN) return "ShortInput";
    return "BadInputToken";
}

/// @dev A route target: delivers `out` of tokenOut to `to`, or reverts
contract ValidationRoute {
    error Scripted();

    receive() external payable {}

    function run(address tokenOut, address to, uint256 out, bool fail) external {
        if (fail) revert Scripted();
        if (tokenOut == address(0)) {
            (bool ok,) = to.call{value: out}("");
            require(ok, "native delivery failed");
        } else {
            TestERC20(tokenOut).mint(to, out);
        }
    }
}

contract ValidationHandler is Test {
    uint256 internal constant ROUTE_GAS_LIMIT = 300_000;
    address public constant RECIPIENT = address(0xA11CE);
    address public constant REFUND = address(0xFEED);
    address public constant NFT_ACCOUNT = address(0xA7F7);
    bytes internal constant META = "race-validation";

    RelayRouterBase public immutable router;
    RelayApprovalProxy public immutable proxy;
    TestERC20 public immutable tokenA;
    TestERC20 public immutable tokenB;
    address public immutable bogusIn; // no code: not a token
    address public immutable bogusOut;
    ValidationRoute[SLOTS] public routes;

    uint256 public races;
    mapping(string => uint256) public violations;
    mapping(string => string) public firstViolation;
    mapping(string => uint256) public reach;

    constructor(RelayRouterBase router_) {
        router = router_;
        proxy = new RelayApprovalProxy(address(this), address(router_), PERMIT2);
        tokenA = new TestERC20();
        tokenB = new TestERC20();
        tokenA.approve(address(proxy), type(uint256).max);
        bogusIn = address(uint160(uint256(keccak256("validation: bogus tokenIn"))));
        bogusOut = address(uint160(uint256(keccak256("validation: bogus tokenOut"))));
        for (uint256 i; i < SLOTS; ++i) {
            routes[i] = new ValidationRoute();
            vm.deal(address(routes[i]), 1e30);
        }
    }

    receive() external payable {}

    /// @dev The one fuzzed entry point: one race command in one multicall
    function race(RaceSpec calldata s) external {
        ++races;
        vm.deal(address(this), 1e30);
        _sweep();
        Plan memory p = _plan(s);
        Verdict memory v = _verdict(p);

        bool twinOk;
        bytes memory twinData;
        uint256 twinDelivered;
        bool unreachedDefect = !v.reject && v.total != 0;
        if (unreachedDefect) {
            // The same race with every route well formed, rolled back
            uint256[SLOTS] memory defects;
            for (uint256 i; i < SLOTS; ++i) {
                (defects[i], p.defects[i]) = (p.defects[i], 0);
            }
            uint256 snap = vm.snapshot();
            (twinOk, twinData, twinDelivered) = _run(p);
            vm.revertToAndDelete(snap);
            p.defects = defects;
        }

        (bool ok, bytes memory data, uint256 delivered) = _run(p);
        string memory where = string.concat(entryName(p.entry), p.direct ? " direct" : " via proxy");

        if (v.reject) {
            if (ok) {
                _violate(REFUSED, string.concat(where, ": accepted, expected ", vm.toString(v.expected)));
                return;
            }
            if (keccak256(data) != keccak256(v.expected)) {
                _violate(
                    REFUSED,
                    string.concat(where, ": reverted with ", vm.toString(data), ", expected ", vm.toString(v.expected))
                );
                return;
            }
            _countRejected(p, v);
            return;
        }

        if (unreachedDefect) {
            if (!twinOk || !ok || keccak256(data) != keccak256(twinData) || delivered != twinDelivered) {
                _violate(
                    UNREACHED,
                    string.concat(
                        where,
                        ": with an unreached malformed route ",
                        ok ? "filled " : "reverted ",
                        vm.toString(data),
                        " delivering ",
                        vm.toString(delivered),
                        "; well formed it ",
                        twinOk ? "filled " : "reverted ",
                        vm.toString(twinData),
                        " delivering ",
                        vm.toString(twinDelivered)
                    )
                );
                return;
            }
            _countUnreached(p, v);
            return;
        }

        if (v.fills) {
            if (!ok) {
                _violate(VALID, string.concat(where, ": valid race refused with ", vm.toString(data)));
                return;
            }
            ++reach[string.concat("fill.", entryName(p.entry))];
            ++reach[p.direct ? "path.direct.filled" : "path.proxy.filled"];
            return;
        }
        bytes4 selector = data.length >= 4 ? bytes4(data) : bytes4(0);
        if (
            ok
                || (selector != RouteRaceEngine.AllRoutesFailed.selector
                    && selector != RouteRaceEngine.InsufficientOutput.selector)
        ) {
            _violate(
                VALID,
                string.concat(
                    where,
                    ": valid race without a filler ",
                    ok ? "filled " : "reverted with ",
                    vm.toString(data),
                    ", expected AllRoutesFailed or InsufficientOutput"
                )
            );
            return;
        }
        ++reach["valid.noFill"];
    }

    /// @dev Self-call so that one try/catch covers everything the router can revert
    function submit(Plan calldata p) external returns (Result[] memory) {
        require(msg.sender == address(this), "handler only");
        address holder = p.flags & 4 != 0 ? p.recipient : address(router);
        Route[] memory rs = new Route[](p.n);
        for (uint256 i; i < p.n; ++i) {
            uint256 d = p.defects[i];
            address target = d & 2 != 0 ? p.badTarget : address(routes[i]);
            rs[i] = packRoute(
                target,
                target,
                0,
                d & 1 != 0 ? 0 : ROUTE_GAS_LIMIT,
                d & 4 != 0 ? p.badFee : p.fees[i],
                abi.encodeCall(ValidationRoute.run, (p.tokenOut, holder, p.outs[i], p.fails[i]))
            );
        }
        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = Call3Value(address(router), false, p.value, _command(p, rs));

        bool fundsToken = p.tokenIn == address(tokenA);
        if (fundsToken) tokenA.mint(address(this), p.funded);
        if (p.direct) {
            if (fundsToken) tokenA.transfer(address(router), p.funded);
            return router.multicall{value: p.value}(calls, address(0), p.nftRecipient, META);
        }
        address[] memory tokens = new address[](fundsToken ? 1 : 0);
        uint256[] memory amounts = new uint256[](tokens.length);
        if (fundsToken) {
            tokens[0] = address(tokenA);
            amounts[0] = p.funded;
        }
        return proxy.transferAndMulticall{value: p.value}(tokens, amounts, calls, REFUND, p.nftRecipient, META);
    }

    function _command(Plan calldata p, Route[] memory rs) internal pure returns (bytes memory) {
        if (p.entry == RACE) {
            return
                abi.encodeCall(IRouteRace.race, (p.tokenIn, p.amountIn, p.tokenOut, p.minOut, p.recipient, p.flags, rs));
        }
        if (p.entry == RACE_SINGLE) {
            return abi.encodeCall(
                IRouteRace.raceSingle, (p.tokenIn, p.amountIn, p.tokenOut, p.minOut, p.recipient, p.flags, rs)
            );
        }
        return abi.encodeCall(
            IRouteRace.raceWithBackups,
            (p.tokenIn, p.amountIn, p.tokenOut, p.minOut, p.recipient, p.flags, rs, p.mainCount)
        );
    }

    /// @dev Runs the race and measures what the recipient got
    function _run(Plan memory p) internal returns (bool ok, bytes memory data, uint256 delivered) {
        uint256 before = _recipientHolds(p);
        try this.submit(p) returns (Result[] memory results) {
            ok = true;
            data = results.length == 1 ? results[0].returnData : abi.encode(results);
        } catch (bytes memory err) {
            data = err;
        }
        delivered = _recipientHolds(p) - before;
    }

    function _recipientHolds(Plan memory p) internal view returns (uint256) {
        if (p.tokenOut == address(0)) return p.recipient.balance;
        if (p.tokenOut == address(tokenA) || p.tokenOut == address(tokenB)) {
            return TestERC20(p.tokenOut).balanceOf(p.recipient);
        }
        return 0;
    }

    /// @dev Whatever tokenA a race left on the router, so that the next race opens with only what it funds
    function _sweep() internal {
        if (tokenA.balanceOf(address(router)) == 0) return;
        address[] memory tokens = new address[](1);
        address[] memory to = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = address(tokenA);
        to[0] = address(this);
        router.cleanupErc20s(tokens, to, amounts, META);
    }

    function _plan(RaceSpec calldata s) internal view returns (Plan memory p) {
        uint256 mode = s.mode % 4;
        uint256 chosen;
        if (mode == ONE) {
            chosen = 1 << (s.pick % DEFECTS);
        } else if (mode == PAIR) {
            chosen = 3 << (s.pick % (DEFECTS - 1));
        } else if (mode == FROM) {
            uint256 k = s.pick % DEFECTS;
            chosen = ((uint256(s.more) << (k + 1)) | (1 << k)) & ((1 << DEFECTS) - 1);
        }

        p.entry = _has(chosen, MAIN_COUNT) ? RACE_WITH_BACKUPS : s.entry % 3;
        p.direct = s.path % 2 == DIRECT;
        p.nftRecipient = _has(chosen, NFT_ROUTER) ? address(router) : (s.nft % 2 == 0 ? address(0) : NFT_ACCOUNT);
        p.n = _has(chosen, NO_ROUTES) ? 0 : 1 + s.routeCount % SLOTS;
        if (p.entry == RACE_WITH_BACKUPS) {
            if (_has(chosen, MAIN_COUNT)) p.mainCount = s.mainCount % 2 == 0 ? 0 : p.n + 1 + s.mainCount % 3;
            else p.mainCount = p.n == 0 ? s.mainCount % 2 : 1 + s.mainCount % p.n;
        }
        p.recipient = _has(chosen, ZERO_RECIPIENT) ? address(0) : RECIPIENT;
        p.flags = s.flags & 31;
        p.amountIn = 1 + s.amountIn % 1e18;

        bool badInput = _has(chosen, BAD_INPUT);
        uint256 form = badInput ? s.input % 3 : s.input % 2;
        p.tokenIn = form == NATIVE_IN ? address(0) : form == TOKEN_IN ? address(tokenA) : bogusIn;
        if (p.tokenIn == address(0)) {
            p.value = badInput ? p.amountIn - 1 - s.slack % p.amountIn : p.amountIn + s.slack % 3 * (s.slack % 1000);
        } else {
            p.value = s.slack % 2 * (s.slack % 1000); // a native budget no route uses
            if (p.tokenIn == address(tokenA)) {
                p.funded =
                    badInput ? p.amountIn - 1 - s.slack % p.amountIn : p.amountIn + s.slack % 3 * (s.slack % 1000);
            }
        }
        if (_has(chosen, IDENTICAL)) p.tokenOut = p.tokenIn;
        else if (_has(chosen, BAD_OUTPUT)) p.tokenOut = bogusOut;
        else p.tokenOut = s.output % 2 == 0 || p.tokenIn == address(0) ? address(tokenB) : address(0);

        uint256 routeBits = (chosen >> ROUTE_GAS) & 7;
        uint256 at = p.n == 0 ? 0 : s.at % p.n;
        uint256 maxOut;
        for (uint256 i; i < p.n; ++i) {
            RouteSpec calldata r = s.routes[i];
            p.fails[i] = r.kind % 4 == 0;
            p.outs[i] = r.out % 1000;
            uint256 feeMode = r.feeMode % 4;
            p.fees[i] = feeMode == 1 ? FEE_DENOMINATOR - 1 : feeMode == 2 ? r.fee % FEE_DENOMINATOR : 0;
            if (i == at) p.defects[i] = routeBits;
            else if (mode == FROM) p.defects[i] = routeBits & r.defect;
            if (!p.fails[i] && p.outs[i] > maxOut) maxOut = p.outs[i];
        }
        uint256 feeForm = s.feeForm % 3;
        p.badFee = feeForm == WHOLE_OUTPUT
            ? FEE_DENOMINATOR
            : feeForm == MAX_FEE ? MAX_PACKED_FEE : FEE_DENOMINATOR + s.between % (MAX_PACKED_FEE - FEE_DENOMINATOR);
        p.targetForm = s.targetForm % 3;
        p.badTarget = p.targetForm == ROUTER_TARGET
            ? address(router)
            : p.targetForm == ERC1820_TARGET ? ERC1820_REGISTRY : ERC820_REGISTRY;

        if (_has(chosen, ZERO_MIN)) {
            p.minOut = 0;
        } else {
            uint256 minMode = s.minMode % 3;
            if (minMode == 0 || p.n == 0) p.minOut = 1 + s.minOut % 1000;
            else if (minMode == 1) p.minOut = p.outs[s.minOut % p.n];
            else p.minOut = maxOut + 1;
            if (p.minOut == 0) p.minOut = 1;
        }
    }

    /// @dev The router's order of checks, applied to the concrete arguments
    function _verdict(Plan memory p) internal view returns (Verdict memory v) {
        address r = address(router);
        bool nativeIn = p.tokenIn == address(0);
        bool tokenIn = p.tokenIn == address(tokenA);
        if (tokenIn) v.balance = tokenA.balanceOf(r) + p.funded;
        if (p.nftRecipient == r) v.present |= 1 << NFT_ROUTER;
        if (p.n == 0) v.present |= 1 << NO_ROUTES;
        if (p.recipient == address(0)) v.present |= 1 << ZERO_RECIPIENT;
        if (p.minOut == 0) v.present |= 1 << ZERO_MIN;
        if (p.tokenIn == p.tokenOut) v.present |= 1 << IDENTICAL;
        if (nativeIn ? p.value < p.amountIn : !tokenIn || v.balance < p.amountIn) v.present |= 1 << BAD_INPUT;
        if (p.tokenOut != address(0) && !_isToken(p.tokenOut)) v.present |= 1 << BAD_OUTPUT;
        if (p.entry == RACE_WITH_BACKUPS && p.n != 0 && (p.mainCount == 0 || p.mainCount > p.n)) {
            v.present |= 1 << MAIN_COUNT;
        }
        v.total = _popcount(v.present);
        for (uint256 i; i < p.n; ++i) {
            v.total += _popcount(p.defects[i]);
            if (_accepts(p, i)) v.fills = true;
        }
        v.reachedCount = _reachedCount(p);

        if (v.present != 0) {
            v.reject = true;
            v.first = _lowestBit(v.present);
            v.expected = _argumentError(p, v);
            return v;
        }
        for (uint256 i; i < v.reachedCount; ++i) {
            uint256 d = p.defects[i];
            if (d == 0) continue;
            v.reject = true;
            v.at = i;
            v.first = ROUTE_GAS + _lowestBit(d);
            if (v.first == ROUTE_GAS) {
                v.expected = abi.encodeWithSelector(RouteRaceEngine.RouteGasLimitRequired.selector);
            } else if (v.first == ROUTE_TARGET) {
                v.expected = abi.encodeWithSelector(RouteRaceEngine.InvalidRouteTarget.selector, p.badTarget);
            } else {
                v.expected = abi.encodeWithSelector(RouteRaceEngine.InvalidRouteFee.selector, i, p.badFee);
            }
            return v;
        }
    }

    function _argumentError(Plan memory p, Verdict memory v) internal view returns (bytes memory) {
        uint256 d = v.first;
        if (d == NFT_ROUTER) return abi.encodeWithSelector(RouteRaceEngine.InvalidRecipient.selector, address(router));
        if (d == NO_ROUTES) return abi.encodeWithSelector(RouteRaceEngine.NoRoutes.selector);
        if (d == ZERO_RECIPIENT) return abi.encodeWithSelector(RouteRaceEngine.RecipientCannotBeZeroAddress.selector);
        if (d == ZERO_MIN) return abi.encodeWithSelector(RouteRaceEngine.MinAmountOutRequired.selector);
        if (d == IDENTICAL) return abi.encodeWithSelector(RouteRaceEngine.IdenticalTokens.selector);
        if (d == BAD_INPUT) {
            if (p.tokenIn == address(0)) return abi.encodeWithSelector(RouteRaceEngine.InvalidMsgValue.selector);
            if (p.tokenIn != address(tokenA)) {
                return abi.encodeWithSelector(RouteRaceEngine.BalanceReadFailed.selector);
            }
            return abi.encodeWithSelector(RouteRaceEngine.InsufficientInput.selector, v.balance, p.amountIn);
        }
        if (d == BAD_OUTPUT) return abi.encodeWithSelector(RouteRaceEngine.BalanceReadFailed.selector);
        return abi.encodeWithSelector(RouteRaceEngine.InvalidMainCount.selector, p.mainCount, p.n);
    }

    /// @dev The routes a race reaches are always a prefix: 0 .. count - 1
    function _reachedCount(Plan memory p) internal pure returns (uint256) {
        if (p.entry == RACE) return p.n;
        if (p.entry == RACE_SINGLE || p.mainCount == 1) return _upToFirstAcceptable(p, 0);
        for (uint256 i; i < p.mainCount && i < p.n; ++i) {
            if (_accepts(p, i)) return p.mainCount;
        }
        return _upToFirstAcceptable(p, p.mainCount);
    }

    function _upToFirstAcceptable(Plan memory p, uint256 from) internal pure returns (uint256) {
        for (uint256 i = from; i < p.n; ++i) {
            if (_accepts(p, i)) return i + 1;
        }
        return p.n;
    }

    function _accepts(Plan memory p, uint256 i) internal pure returns (bool) {
        return !p.fails[i] && p.outs[i] >= p.minOut;
    }

    function _isToken(address a) internal view returns (bool) {
        return a == address(tokenA) || a == address(tokenB);
    }

    function _countRejected(Plan memory p, Verdict memory v) internal {
        ++reach[p.direct ? "path.direct.rejected" : "path.proxy.rejected"];
        string memory name = _firstName(p, v);
        if (v.total == 1) ++reach[string.concat("alone.", name, ".", entryName(p.entry))];
        if (v.total == 2 && v.first + 1 < DEFECTS && _carries(p, v, v.first + 1)) {
            ++reach[string.concat("pair.", defectName(v.first), "+", defectName(v.first + 1))];
        }
        if (v.first < ROUTE_GAS) return;
        ++reach[string.concat("route.", name, ".", _position(p, v.at))];
        if (v.first == ROUTE_TARGET) ++reach[string.concat("target.", targetFormName(p.targetForm))];
        if (v.first != ROUTE_FEE) return;
        if (p.badFee == MAX_PACKED_FEE) ++reach["fee.max31Bit"];
        uint256 mains = p.entry == RACE ? p.n : p.entry == RACE_WITH_BACKUPS ? p.mainCount : 0;
        if (p.badFee == FEE_DENOMINATOR && mains >= 2 && v.at + 1 == mains) {
            for (uint256 i; i < v.at; ++i) {
                if (_accepts(p, i)) {
                    ++reach["fee.wholeOutput.lastMainAfterEligibleMain"];
                    break;
                }
            }
        }
    }

    /// @dev Whether the race carries defect `d` next to `v.first`: an argument defect, MAIN_COUNT's neighbour on
    /// any route, or a route defect's neighbour on the same route
    function _carries(Plan memory p, Verdict memory v, uint256 d) internal pure returns (bool) {
        if (d < ROUTE_GAS) return _has(v.present, d);
        uint256 bit = 1 << (d - ROUTE_GAS);
        if (v.first < ROUTE_GAS) {
            for (uint256 i; i < p.n; ++i) {
                if (p.defects[i] & bit != 0) return true;
            }
            return false;
        }
        return p.defects[v.at] & bit != 0;
    }

    function _countUnreached(Plan memory p, Verdict memory v) internal {
        ++reach[p.direct ? "path.direct.filled" : "path.proxy.filled"];
        bool mainWon;
        if (p.entry == RACE_WITH_BACKUPS && p.mainCount >= 2) {
            for (uint256 i; i < p.mainCount; ++i) {
                if (_accepts(p, i)) mainWon = true;
            }
        }
        for (uint256 i = v.reachedCount; i < p.n; ++i) {
            for (uint256 b; b < 3; ++b) {
                if (p.defects[i] & (1 << b) == 0) continue;
                string memory name = defectName(ROUTE_GAS + b);
                if (ROUTE_GAS + b == ROUTE_TARGET) {
                    ++reach[string.concat("unreached.target.", targetFormName(p.targetForm))];
                }
                if (p.entry == RACE_SINGLE) ++reach[string.concat("unreached.", name, ".afterRaceSingleWinner")];
                else if (mainWon) ++reach[string.concat("unreached.", name, ".backupAfterMainWin")];
                else ++reach[string.concat("unreached.", name, ".afterBackupWinner")];
            }
        }
    }

    function _firstName(Plan memory p, Verdict memory v) internal view returns (string memory) {
        if (v.first != BAD_INPUT) return defectName(v.first);
        if (p.tokenIn == address(0)) return inputDefectName(NATIVE_IN);
        return inputDefectName(p.tokenIn == address(tokenA) ? TOKEN_IN : NOT_A_TOKEN_IN);
    }

    function _position(Plan memory p, uint256 i) internal pure returns (string memory) {
        if (p.entry == RACE_SINGLE) return "raceSingle";
        uint256 mains = p.entry == RACE ? p.n : p.mainCount;
        if (mains == 1 && p.entry == RACE_WITH_BACKUPS) return i == 0 ? "loneMain" : "reachedBackup";
        if (i >= mains) return "reachedBackup";
        if (i == 0) return "firstMain";
        if (i + 1 == mains) return "lastMain";
        return "middleMain";
    }

    function _has(uint256 mask, uint256 d) internal pure returns (bool) {
        return mask & (1 << d) != 0;
    }

    function _lowestBit(uint256 mask) internal pure returns (uint256 i) {
        while (mask & (1 << i) == 0) ++i;
    }

    function _popcount(uint256 mask) internal pure returns (uint256 c) {
        for (; mask != 0; mask &= mask - 1) {
            ++c;
        }
    }

    function _violate(string memory clause, string memory what) internal {
        if (violations[clause]++ == 0) {
            firstViolation[clause] = string.concat(clause, " in race #", vm.toString(races), ": ", what);
        }
    }
}

contract RelayRouterValidationTest is Test {
    ValidationHandler handler;

    function _deployRouter() internal virtual returns (RelayRouterBase) {
        return new RelayRouter();
    }

    function setUp() public {
        handler = new ValidationHandler(_deployRouter());
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ValidationHandler.race.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_V1_refused() public view {
        _clean(REFUSED);
    }

    function invariant_V1_unreached() public view {
        _clean(UNREACHED);
    }

    function invariant_V1_valid() public view {
        _clean(VALID);
    }

    /// @dev Fixed inputs. Fails unless every case class the campaign is meant to cover occurred
    function test_reach() public {
        RaceSpec memory s;

        // Each defect alone, on every entry point it exists on, through the proxy and straight to the router
        for (uint8 path; path < 2; ++path) {
            for (uint8 entry; entry < 3; ++entry) {
                for (uint8 d; d < DEFECTS; ++d) {
                    if (d == MAIN_COUNT && entry != RACE_WITH_BACKUPS) continue;
                    for (uint8 form = d == BAD_INPUT ? 0 : 1; form < (d == BAD_INPUT ? 3 : 2); ++form) {
                        s = _base(entry, 3);
                        s.path = path;
                        s.mode = ONE;
                        s.pick = d;
                        s.input = form;
                        handler.race(s);
                    }
                }
            }
        }

        // Each pair of neighbours: the earlier one's error comes back. The pair BAD_INPUT and IDENTICAL takes
        // native input, which makes tokenOut native too and leaves it a token
        for (uint8 k; k + 1 < DEFECTS; ++k) {
            s = _base(RACE_WITH_BACKUPS, 3);
            s.mode = PAIR;
            s.pick = k;
            if (k == IDENTICAL) s.input = NATIVE_IN;
            handler.race(s);
        }

        for (uint8 d = ROUTE_GAS; d < DEFECTS; ++d) {
            // On each main of a race of three: first, middle, last
            for (uint8 at; at < 3; ++at) {
                s = _base(RACE, 3);
                _routeDefect(s, d, at);
                handler.race(s);
            }
            // On the reached backup of raceWithBackups, after two mains below the minimum
            s = _base(RACE_WITH_BACKUPS, 3);
            s.routes[0].out = 50;
            s.routes[1].out = 60;
            _routeDefect(s, d, 2);
            handler.race(s);
            // On the second route of raceSingle, after one below the minimum
            s = _base(RACE_SINGLE, 2);
            s.routes[0].out = 50;
            _routeDefect(s, d, 1);
            handler.race(s);

            // Not reached, in a race that fills: after the winner of raceSingle, and on a backup when a main wins
            s = _base(RACE_SINGLE, 2);
            _routeDefect(s, d, 1);
            handler.race(s);
            s = _base(RACE_WITH_BACKUPS, 3);
            _routeDefect(s, d, 2);
            handler.race(s);
        }

        // Each target the router refuses, on a route the race reaches and on one it does not
        for (uint8 form; form < 3; ++form) {
            for (uint8 entry; entry < 3; ++entry) {
                s = _base(entry, 3);
                _routeDefect(s, ROUTE_TARGET, 0);
                s.targetForm = form;
                handler.race(s);
            }
            s = _base(RACE_SINGLE, 2);
            _routeDefect(s, ROUTE_TARGET, 1);
            s.targetForm = form;
            handler.race(s);
        }

        // A fee of exactly 1_000_000 on the last main after a main that reached the minimum, and the largest fee
        // a route can carry
        for (uint8 entry; entry < 3; entry += 2) {
            s = _base(entry, 2);
            if (entry == RACE_WITH_BACKUPS) s.mainCount = 1;
            _routeDefect(s, ROUTE_FEE, 1);
            s.feeForm = WHOLE_OUTPUT;
            handler.race(s);
        }
        s = _base(RACE, 2);
        _routeDefect(s, ROUTE_FEE, 0);
        s.feeForm = MAX_FEE;
        handler.race(s);

        // Valid races that fill, on each entry point and path, with each kind of input and output; and one that
        // does not
        for (uint8 entry; entry < 3; ++entry) {
            for (uint8 path; path < 2; ++path) {
                for (uint8 assets; assets < 3; ++assets) {
                    s = _base(entry, 3);
                    s.path = path;
                    s.input = assets == 0 ? NATIVE_IN : TOKEN_IN;
                    s.output = assets == 2 ? 1 : 0;
                    s.flags = assets == 2 ? 4 : 0;
                    handler.race(s);
                }
            }
        }
        s = _base(RACE, 2);
        s.minMode = 2;
        handler.race(s);

        // Violations first: a wrong router should fail here with its description, not as a missed class
        _clean(REFUSED);
        _clean(UNREACHED);
        _clean(VALID);

        for (uint8 entry; entry < 3; ++entry) {
            for (uint8 d; d < DEFECTS; ++d) {
                if (d == MAIN_COUNT && entry != RACE_WITH_BACKUPS) continue;
                if (d == BAD_INPUT) {
                    for (uint8 form; form < 3; ++form) {
                        _reached(string.concat("alone.", inputDefectName(form), ".", entryName(entry)));
                    }
                } else {
                    _reached(string.concat("alone.", defectName(d), ".", entryName(entry)));
                }
            }
            _reached(string.concat("fill.", entryName(entry)));
        }
        for (uint8 k; k + 1 < DEFECTS; ++k) {
            _reached(string.concat("pair.", defectName(k), "+", defectName(k + 1)));
        }
        string[5] memory positions = [string("firstMain"), "middleMain", "lastMain", "reachedBackup", "raceSingle"];
        for (uint8 d = ROUTE_GAS; d < DEFECTS; ++d) {
            for (uint256 i; i < positions.length; ++i) {
                _reached(string.concat("route.", defectName(d), ".", positions[i]));
            }
            _reached(string.concat("unreached.", defectName(d), ".afterRaceSingleWinner"));
            _reached(string.concat("unreached.", defectName(d), ".backupAfterMainWin"));
        }
        for (uint8 form; form < 3; ++form) {
            _reached(string.concat("target.", targetFormName(form)));
            _reached(string.concat("unreached.target.", targetFormName(form)));
        }
        _reached("fee.wholeOutput.lastMainAfterEligibleMain");
        _reached("fee.max31Bit");
        _reached("path.proxy.rejected");
        _reached("path.direct.rejected");
        _reached("path.proxy.filled");
        _reached("path.direct.filled");
        _reached("valid.noFill");
    }

    /// @dev `routes` routes, each delivering 150 against a minimum of 100; tokenA to tokenB through the proxy.
    /// raceWithBackups gets two mains when it has three routes, one otherwise
    function _base(uint8 entry, uint8 routes) internal pure returns (RaceSpec memory s) {
        s.entry = entry;
        s.routeCount = routes - 1;
        s.mainCount = routes == 3 ? 1 : 0;
        s.input = TOKEN_IN;
        s.minOut = 99;
        s.amountIn = 1 ether;
        s.slack = 5;
        for (uint256 i; i < SLOTS; ++i) {
            s.routes[i].kind = 1;
            s.routes[i].out = 150;
        }
    }

    function _routeDefect(RaceSpec memory s, uint8 d, uint8 at) internal pure {
        s.mode = ONE;
        s.pick = d;
        s.at = at;
    }

    function _clean(string memory clause) internal view {
        assertEq(handler.violations(clause), 0, handler.firstViolation(clause));
    }

    function _reached(string memory class) internal {
        uint256 count = handler.reach(class);
        emit log_named_uint(class, count);
        assertGt(count, 0, string.concat("not reached: ", class));
    }
}

contract RelayRouterNonTstoreValidationTest is RelayRouterValidationTest {
    function _deployRouter() internal override returns (RelayRouterBase) {
        return new RelayRouter_NonTstore();
    }
}
