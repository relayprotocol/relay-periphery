// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, Vm} from "forge-std/Test.sol";
import {Route, IRouteRace} from "../../src/interfaces/IRouteRace.sol";
import {packRoute} from "./RoutePacking.sol";
import {RouteRaceEngine} from "../../src/RouteRaceEngine.sol";
import {RelayRouterBase} from "../../src/RelayRouterBase.sol";
import {RelayRouter} from "../../src/RelayRouter.sol";
import {RelayRouter_NonTstore} from "../../src/RelayRouter_NonTstore.sol";
import {RelayApprovalProxy} from "../../src/RelayApprovalProxy.sol";
import {Call3Value, Result} from "../../src/common/Multicall3.sol";
import {TestERC20} from "../mocks/TestERC20.sol";
import {TestERC721} from "../mocks/TestERC721.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

/// @dev Permit2's address on every chain. The approval proxy refuses a zero one.
address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

// G1: after any top-level call into the router has ended, the router is idle again: a caller that has never
// touched it can run a multicall with a race, the NFT hooks answer NoRecipientSet(), and on the storage router the
// context slot and the recipient slot hold zero. Inside a multicall the same holds one level down: when a nested
// multicall returns, the outer multicall's nftRecipient is in force again and a race command may run again.
//
// G3: a race runs only as a command of a top-level multicall that is not allowed to fail, and callRoute runs only
// from the router's own race.
//
// forge runs this suite with `isolate = true` (its default), so every call the handler makes is a transaction of
// its own, and the router's transient storage does not outlive it. The handler's one fuzzed function therefore
// calls `session` on itself: inside that one call, and so inside one transaction, it probes the router, performs
// one top-level action, checks the action's result against what the router's code says, and probes again. A probe
// runs in a call that always reverts, so it leaves nothing behind for the next action.

// Action kinds: Action.kind % KINDS
uint256 constant MULTICALL = 0; // a multicall of ordinary commands, possibly nested, with or without a race
uint256 constant CLEANUP = 1; // one of the four cleanups, called on its own
uint256 constant RACE_ALLOW_FAILURE = 2; // a race command that may fail, in a top-level multicall
uint256 constant NESTED_RACE = 3; // a race command in a nested multicall
uint256 constant DIRECT_CALL = 4; // race, raceSingle or raceWithBackups called as a function; callRoute by others
uint256 constant CALLROUTE_COMMAND = 5; // a multicall command that calls callRoute on the router
uint256 constant CALLROUTE_VIA_CLEANUP = 6; // cleanupErc20sViaCall that makes the router call its own callRoute
uint256 constant KINDS = 7;

// Plan.race
uint256 constant NO_RACE = 0;
uint256 constant FILLS = 1;
uint256 constant FALLS_SHORT = 2;

// Plan.entry
uint256 constant ENTRY_RACE = 0;
uint256 constant ENTRY_SINGLE = 1;
uint256 constant ENTRY_BACKUPS = 2;

// Plan.nest
uint256 constant NOT_NESTED = 0;
uint256 constant VIA_ROUTER = 1; // a command whose target is the router

// Action.flags
uint8 constant RACE_AFTER_NESTED = 1;
uint8 constant INNER_FAILS = 2;
uint8 constant CARRIER_MAY_FAIL = 4;
uint8 constant TAIL_FAILS = 8;
uint8 constant COMMAND_MAY_FAIL = 16;
uint8 constant FAILS = 32;

// Plan.caller for DIRECT_CALL
uint256 constant BY_HANDLER = 0;
uint256 constant BY_NEWCOMER = 1;
uint256 constant BY_ROUTE = 2;
uint256 constant BY_PROXY = 3;

bytes32 constant CONTEXT_SLOT = bytes32(uint256(keccak256("RelayRouterV4.context")) - 1);
bytes32 constant RECIPIENT_SLOT = bytes32(uint256(keccak256("RelayRouterV4.recipient")) - 1);

struct Action {
    uint8 kind;
    uint8 path; // even: the handler calls the router; odd: the handler calls the proxy
    uint8 nft; // % 3: the outer nftRecipient: none, an account, a contract
    uint8 innerNft; // % 3: the nested nftRecipient: none, another account, another contract
    uint8 race; // % 3: no race, fills, falls short; / 3 % 3: race, raceSingle, raceWithBackups
    uint8 nest; // % 2: not nested, through the router; / 2 % 2: one or two levels
    uint8 flags;
    uint8 sub; // % 4: the cleanup or the function called; / 4 % 4: the caller of DIRECT_CALL
}

struct Plan {
    uint256 kind;
    bool proxy;
    uint256 nft;
    uint256 innerNft;
    uint256 race;
    uint256 entry;
    uint256 nest;
    uint256 depth;
    uint8 flags;
    uint256 sub;
    uint256 caller;
}

function pathName(bool proxy) pure returns (string memory) {
    return proxy ? "via proxy" : "direct";
}

function nftName(uint256 nft) pure returns (string memory) {
    if (nft == 0) return "no nftRecipient";
    return nft == 1 ? "an account as nftRecipient" : "a contract as nftRecipient";
}

function raceName(uint256 race) pure returns (string memory) {
    if (race == NO_RACE) return "no race";
    return race == FILLS ? "a race that fills" : "a race that falls short";
}

function entryName(uint256 entry) pure returns (string memory) {
    if (entry == ENTRY_RACE) return "race";
    return entry == ENTRY_SINGLE ? "raceSingle" : "raceWithBackups";
}

function nestName(uint256 nest) pure returns (string memory) {
    return nest == NOT_NESTED ? "not nested" : "nested through the router";
}

function mayFail(bool allowFailure) pure returns (string memory) {
    return allowFailure ? "allowFailure" : "must not fail";
}

function cleanupName(uint256 sub) pure returns (string memory) {
    if (sub == 0) return "cleanupErc20s";
    if (sub == 1) return "cleanupErc20sViaCall";
    return sub == 2 ? "cleanupNative" : "cleanupNativeViaCall";
}

function callerName(uint256 caller) pure returns (string memory) {
    if (caller == BY_HANDLER) return "the handler";
    if (caller == BY_NEWCOMER) return "a new caller";
    return caller == BY_ROUTE ? "the route target" : "the proxy";
}

function kindName(uint256 kind) pure returns (string memory) {
    if (kind == MULTICALL) return "a multicall";
    if (kind == CLEANUP) return "a cleanup";
    if (kind == RACE_ALLOW_FAILURE) return "a race command with allowFailure";
    if (kind == NESTED_RACE) return "a race in a nested multicall";
    if (kind == DIRECT_CALL) return "a direct call of a race function or callRoute";
    if (kind == CALLROUTE_COMMAND) return "a callRoute command";
    return "callRoute through cleanupErc20sViaCall";
}

/// @dev A route target that delivers what it is told to and records each run in an event, which survives a
/// rollback in the recorded logs
contract GuardRoute {
    event Ran();

    function deliver(address token, uint256 amount, address to) external {
        emit Ran();
        TestERC20(token).transfer(to, amount);
    }

    function ping() external {}
}

contract Thrower {
    error Boom();

    function boom() external pure {
        revert Boom();
    }
}

/// @dev An nftRecipient that is a contract
contract GuardNftHolder is ERC721Holder, ERC1155Holder {}

contract GuardsHandler is Test {
    error ProbeDone(string failure);

    uint256 internal constant ROUTE_GAS = 1_000_000;
    uint256 internal constant OUT = 1000;
    address public constant RECIPIENT = address(0xA11CE);
    address public constant PROBE_RECIPIENT = address(0xA11CE2);
    address public constant PAYLOAD_HOLDER = address(0xB01D);
    address public constant REFUND = address(0xFEED);
    address public constant ACCOUNT = address(0xB0B);
    address public constant ACCOUNT2 = address(0xB0B2);
    bytes internal constant META = "guards";

    RelayRouterBase public immutable router;
    RelayApprovalProxy public immutable proxy;
    TestERC20 public immutable tokenA;
    TestERC20 public immutable tokenB;
    TestERC721 public immutable nft721;
    GuardRoute public immutable route;
    Thrower public immutable thrower;
    GuardNftHolder public immutable holder;
    GuardNftHolder public immutable holder2;

    uint256 public calls;
    // Set when the probe at the start of this call found the router not idle: what goes wrong next may follow from it
    bool internal notIdleAtStart;
    uint256 internal newcomers;
    uint256 internal nftIds;

    mapping(string => uint256) public violations;
    mapping(string => string) public firstViolation;
    mapping(string => uint256) public reach;

    constructor(RelayRouterBase router_) {
        router = router_;
        proxy = new RelayApprovalProxy(address(this), address(router_), PERMIT2);
        tokenA = new TestERC20();
        tokenB = new TestERC20();
        nft721 = new TestERC721();
        route = new GuardRoute();
        thrower = new Thrower();
        holder = new GuardNftHolder();
        holder2 = new GuardNftHolder();
        tokenB.mint(address(route), 1 << 128);
    }

    receive() external payable {}

    /// @dev The one fuzzed entry point: one top-level action, with a probe before and after it
    function act(Action calldata a) external {
        ++calls;
        this.session(a);
    }

    function session(Action calldata a) external {
        require(msg.sender == address(this));
        Plan memory plan = _plan(a);
        string memory name = _describe(plan);
        notIdleAtStart = false;
        _probe(string.concat("at the start of a call, before ", name));
        _reach("G1 idle at the start of a call");
        vm.recordLogs();
        if (plan.kind == MULTICALL) _multicall(plan, name);
        else if (plan.kind == CLEANUP) _cleanup(plan, name);
        else if (plan.kind == RACE_ALLOW_FAILURE) _raceAllowFailure(plan, name);
        else if (plan.kind == NESTED_RACE) _nestedRace(plan, name);
        else if (plan.kind == DIRECT_CALL) _directCall(plan, name);
        else if (plan.kind == CALLROUTE_COMMAND) _callRouteCommand(plan, name);
        else _callRouteViaCleanup(plan, name);
        _probe(string.concat("after ", name));
    }

    // ---------------------------------------------------------------- G1: the probe

    /// @dev Runs the probe in a call that always reverts and records what it found under G1.idle
    function _probe(string memory when) internal {
        uint256 idleBefore = violations["G1.idle"];
        address newcomer = _newcomer();
        try this.probe(newcomer) {
            _violate("G1.idle", when, "the probe returned instead of reverting");
        } catch (bytes memory out) {
            if (bytes4(out) != ProbeDone.selector) {
                _violate("G1.idle", when, string.concat("the probe itself failed: ", _answer(false, out)));
                return;
            }
            string memory failure = abi.decode(_tail(out), (string));
            if (bytes(failure).length != 0) _violate("G1.idle", when, failure);
        }
        if (violations["G1.idle"] != idleBefore) notIdleAtStart = true;
    }

    function probe(address newcomer) external {
        require(msg.sender == address(this));
        revert ProbeDone(_probeBody(newcomer));
    }

    function _probeBody(address newcomer) internal returns (string memory) {
        bytes32 context = vm.load(address(router), CONTEXT_SLOT);
        if (context != 0) return string.concat("the context slot holds ", vm.toString(context));
        bytes32 recipient = vm.load(address(router), RECIPIENT_SLOT);
        if (recipient != 0) return string.concat("the recipient slot holds ", vm.toString(recipient));

        uint256[] memory ones = new uint256[](1);
        ones[0] = 1;
        bytes[3] memory hooks = [
            abi.encodeCall(RelayRouterBase.onERC721Received, (newcomer, newcomer, 1, "")),
            abi.encodeCall(RelayRouterBase.onERC1155Received, (newcomer, newcomer, 1, 1, "")),
            abi.encodeCall(RelayRouterBase.onERC1155BatchReceived, (newcomer, newcomer, ones, ones, ""))
        ];
        string[3] memory hookNames = ["onERC721Received", "onERC1155Received", "onERC1155BatchReceived"];
        for (uint256 i; i < hooks.length; ++i) {
            vm.prank(newcomer);
            (bool ok, bytes memory ret) = address(router).call(hooks[i]);
            if (ok || !_is(ret, abi.encodeWithSelector(RelayRouterBase.NoRecipientSet.selector))) {
                return string.concat(
                    hookNames[i], " from a new caller ", _answer(ok, ret), ", expected NoRecipientSet() (0xf36675c3)"
                );
            }
        }

        Call3Value[] memory cmds = new Call3Value[](1);
        cmds[0] = _raceCall(FILLS, ENTRY_RACE, false, PROBE_RECIPIENT);
        uint256 before = tokenB.balanceOf(PROBE_RECIPIENT);
        vm.prank(newcomer);
        (bool success, bytes memory returned) =
            address(router).call(abi.encodeCall(RelayRouterBase.multicall, (cmds, address(0), address(0), META)));
        if (!success) return string.concat("a multicall with a race by a new caller ", _answer(false, returned));
        Result[] memory results = abi.decode(returned, (Result[]));
        if (
            results.length != 1 || !results[0].success || !_is(results[0].returnData, abi.encode(uint256(0), OUT))
                || tokenB.balanceOf(PROBE_RECIPIENT) != before + OUT
        ) {
            return "a multicall with a race by a new caller succeeded without filling the race";
        }
        return "";
    }

    // ---------------------------------------------------------------- G1: the actions

    function _multicall(Plan memory plan, string memory name) internal {
        uint256 outerId = ++nftIds;
        uint256 innerId = ++nftIds;
        bool raceBefore = plan.race != NO_RACE && plan.flags & RACE_AFTER_NESTED == 0;
        bool raceAfter = plan.race != NO_RACE && !raceBefore;
        bool nested = plan.nest != NOT_NESTED;
        bool innerFails = nested && plan.flags & INNER_FAILS != 0;
        bool carrierMayFail = plan.flags & CARRIER_MAY_FAIL != 0;

        Call3Value[] memory cmds = new Call3Value[](5);
        uint256 n;
        if (raceBefore) cmds[n++] = _raceCall(plan.race, plan.entry, false, RECIPIENT);
        uint256 carrierAt = n;
        if (nested) {
            Call3Value[] memory inner = new Call3Value[](innerFails ? 2 : 1);
            inner[0] = _nftProbeCall(innerId);
            if (innerFails) inner[1] = _boomCall();
            cmds[n++] = _carrier(carrierMayFail, inner, _nftAddress(plan.innerNft, true));
        }
        uint256 probeAt = n;
        cmds[n++] = _nftProbeCall(outerId);
        uint256 raceAt = raceBefore ? 0 : n;
        if (raceAfter) cmds[n++] = _raceCall(plan.race, plan.entry, false, RECIPIENT);
        if (plan.flags & TAIL_FAILS != 0) cmds[n++] = _boomCall();
        assembly ("memory-safe") {
            mstore(cmds, n)
        }

        bytes memory expected;
        bytes memory shortfall = abi.encodeWithSelector(RouteRaceEngine.InsufficientOutput.selector, OUT, OUT + 1);
        if (raceBefore && plan.race == FALLS_SHORT) expected = shortfall;
        else if (innerFails && !carrierMayFail) expected = abi.encodeWithSelector(Thrower.Boom.selector);
        else if (raceAfter && plan.race == FALLS_SHORT) expected = shortfall;
        else if (plan.flags & TAIL_FAILS != 0) expected = abi.encodeWithSelector(Thrower.Boom.selector);

        uint256 before = tokenB.balanceOf(RECIPIENT);
        (bool ok, bytes memory ret) = _send(plan, cmds);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        string memory p = pathName(plan.proxy);
        _reach(string.concat("G1 idle after a multicall, ", p, ", ", nftName(plan.nft)));
        _reach(string.concat("G1 idle after a multicall, ", p, ", ", raceName(plan.race)));
        _reach(string.concat("G1 idle after a multicall, ", p, ", ", nestName(plan.nest)));
        _reach(string.concat("G1 idle after a multicall, ", p, ", ", expected.length == 0 ? "succeeded" : "reverted"));

        if (expected.length != 0) {
            if (ok || !_is(ret, expected)) {
                string memory what = string.concat("expected: ", _answer(false, expected));
                // A race after the nested multicall is the only command that can tell a context left at depth 2
                if (raceAfter && nested) {
                    _violate("G1.nested", name, string.concat(what, ", router ", _answer(ok, ret)));
                } else {
                    _violate("G1.result", name, string.concat(what, ", router ", _answer(ok, ret)));
                }
            }
            return;
        }
        if (!ok) {
            string memory what = string.concat("expected success, router ", _answer(ok, ret));
            if (raceAfter && nested) _violate("G1.nested", name, what);
            else _violate("G1.result", name, what);
            return;
        }
        Result[] memory results = abi.decode(ret, (Result[]));
        if (results.length != n) {
            _violate("G1.result", name, string.concat("returned ", vm.toString(results.length), " results"));
            return;
        }
        if (plan.race == FILLS) {
            if (
                !results[raceAt].success || !_is(results[raceAt].returnData, abi.encode(uint256(0), OUT))
                    || tokenB.balanceOf(RECIPIENT) != before + OUT
            ) {
                _violate(raceAfter && nested ? "G1.nested" : "G1.result", name, "the race did not fill as it should");
            } else if (_runs(logs) == 0) {
                _violate("G1.result", name, "the race filled but no run of the route was recorded");
            }
            if (raceAfter && nested) _reach(string.concat("G1 race after a multicall ", nestName(plan.nest), ", ", p));
        }
        if (nested) {
            address innerExpected = plan.innerNft != 0 ? _nftAddress(plan.innerNft, true) : _nftAddress(plan.nft, false);
            Result memory carrier = results[carrierAt];
            if (innerFails) {
                if (carrier.success || !_is(carrier.returnData, abi.encodeWithSelector(Thrower.Boom.selector))) {
                    _violate(
                        "G1.result",
                        name,
                        string.concat(
                            "the nested multicall ", _answer(carrier.success, carrier.returnData), ", expected Boom()"
                        )
                    );
                }
            } else if (!carrier.success) {
                _violate("G1.result", name, string.concat("the nested multicall ", _answer(false, carrier.returnData)));
            } else {
                Result[] memory inner = abi.decode(carrier.returnData, (Result[]));
                string memory wrong = _nftProbeWrong(inner[0], innerId, innerExpected);
                if (bytes(wrong).length != 0) {
                    _violate("G1.result", name, string.concat("inside the nested multicall the NFT ", wrong));
                }
            }
        }
        string memory wrongOuter = _nftProbeWrong(results[probeAt], outerId, _nftAddress(plan.nft, false));
        if (bytes(wrongOuter).length != 0) {
            _violate(
                nested ? "G1.nested" : "G1.result",
                name,
                string.concat(nested ? "after the nested multicall returned, the NFT " : "the NFT ", wrongOuter)
            );
        }
        if (nested && !innerFails) {
            _reach(
                string.concat(
                    "G1 nested restores the nftRecipient, ",
                    p,
                    ", ",
                    nestName(plan.nest),
                    ", outer ",
                    nftName(plan.nft),
                    ", inner ",
                    nftName(plan.innerNft)
                )
            );
        }
    }

    /// @dev What is wrong with an NFT probe command's result, or "" when nothing is: the NFT has to reach
    /// `expected`, or the hook has to answer NoRecipientSet() when nothing is expected
    function _nftProbeWrong(Result memory result, uint256 id, address expected) internal view returns (string memory) {
        if (expected == address(0)) {
            if (
                !result.success
                    && _is(result.returnData, abi.encodeWithSelector(RelayRouterBase.NoRecipientSet.selector))
            ) {
                return "";
            }
            return string.concat(
                "mint without an nftRecipient ",
                _answer(result.success, result.returnData),
                ", expected NoRecipientSet()"
            );
        }
        if (!result.success) {
            return string.concat("mint to ", vm.toString(expected), " ", _answer(false, result.returnData));
        }
        address owner = nft721.ownerOf(id);
        if (owner != expected) {
            return string.concat("went to ", vm.toString(owner), ", expected ", vm.toString(expected));
        }
        return "";
    }

    function _cleanup(Plan memory plan, string memory name) internal {
        bool fails = plan.flags & FAILS != 0;
        address[] memory tokens = new address[](1);
        tokens[0] = address(tokenA);
        uint256[] memory amounts = new uint256[](1);
        bytes memory data;
        bytes memory expected;
        if (plan.sub == 0) {
            address[] memory recipients = new address[](fails ? 0 : 1);
            if (!fails) recipients[0] = REFUND;
            data = abi.encodeCall(RelayRouterBase.cleanupErc20s, (tokens, recipients, amounts, META));
            if (fails) expected = abi.encodeWithSelector(RelayRouterBase.ArrayLengthsMismatch.selector);
        } else if (plan.sub == 1) {
            address[] memory tos = new address[](1);
            tos[0] = fails ? address(thrower) : address(route);
            bytes[] memory datas = new bytes[](1);
            datas[0] = fails ? abi.encodeCall(Thrower.boom, ()) : abi.encodeCall(GuardRoute.ping, ());
            amounts[0] = 1;
            data = abi.encodeCall(RelayRouterBase.cleanupErc20sViaCall, (tokens, tos, datas, amounts));
            if (fails) expected = abi.encodeWithSelector(RelayRouterBase.CallFailed.selector);
        } else if (plan.sub == 2) {
            // The router holds no native, so an amount of 1 cannot be sent: solady's ETHTransferFailed()
            data = abi.encodeCall(RelayRouterBase.cleanupNative, (fails ? 1 : 0, REFUND, META));
            if (fails) expected = abi.encodeWithSelector(bytes4(0xb12d13eb));
        } else {
            data = abi.encodeCall(
                RelayRouterBase.cleanupNativeViaCall,
                (fails ? 1 : 0, address(route), abi.encodeCall(GuardRoute.ping, ()))
            );
            if (fails) expected = abi.encodeWithSelector(RelayRouterBase.CallFailed.selector);
        }
        (bool ok, bytes memory ret) = address(router).call(data);
        _reach(string.concat("G1 idle after ", cleanupName(plan.sub), ", ", fails ? "reverted" : "succeeded"));
        if (fails ? ok || !_is(ret, expected) : !ok) {
            _violate(
                "G1.result",
                name,
                string.concat("expected ", fails ? _answer(false, expected) : "success", ", router ", _answer(ok, ret))
            );
        }
    }

    // ---------------------------------------------------------------- G3

    function _raceAllowFailure(Plan memory plan, string memory name) internal {
        uint256 outcome = plan.race == NO_RACE ? FILLS : plan.race;
        Call3Value[] memory cmds = new Call3Value[](1);
        cmds[0] = _raceCall(outcome, plan.entry, true, RECIPIENT);
        _expectRefused(
            plan, name, "G3.race", cmds, false, abi.encodeWithSelector(RelayRouterBase.InvalidNativeCommand.selector)
        );
        _reach(string.concat("G1 idle after ", kindName(plan.kind)));
        _reach(
            string.concat(
                "G3 race with allowFailure, ",
                pathName(plan.proxy),
                ", ",
                entryName(plan.entry),
                ", ",
                raceName(outcome)
            )
        );
    }

    function _nestedRace(Plan memory plan, string memory name) internal {
        uint256 outcome = plan.race == NO_RACE ? FILLS : plan.race;
        bool raceMayFail = plan.flags & COMMAND_MAY_FAIL != 0;
        bool carrierMayFail = plan.flags & CARRIER_MAY_FAIL != 0;
        Call3Value[] memory inner = new Call3Value[](1);
        inner[0] = _raceCall(outcome, plan.entry, raceMayFail, RECIPIENT);
        if (plan.depth == 2) {
            Call3Value[] memory deeper = inner;
            inner = new Call3Value[](1);
            inner[0] = _carrier(false, deeper, address(0));
        }
        Call3Value[] memory cmds = new Call3Value[](1);
        cmds[0] = _carrier(carrierMayFail, inner, address(0));
        _expectRefused(
            plan,
            name,
            "G3.race",
            cmds,
            carrierMayFail,
            abi.encodeWithSelector(RelayRouterBase.InvalidNativeCommand.selector)
        );
        _reach(string.concat("G1 idle after ", kindName(plan.kind)));
        _reach(
            string.concat(
                "G3 race in a multicall ",
                nestName(VIA_ROUTER),
                ", ",
                pathName(plan.proxy),
                ", depth ",
                vm.toString(plan.depth + 1),
                ", race ",
                mayFail(raceMayFail),
                ", carrier ",
                mayFail(carrierMayFail),
                ", ",
                raceName(outcome)
            )
        );
    }

    function _directCall(Plan memory plan, string memory name) internal {
        address caller = plan.caller == BY_HANDLER
            ? address(this)
            : plan.caller == BY_NEWCOMER ? _newcomer() : plan.caller == BY_ROUTE ? address(route) : address(proxy);
        bytes memory data;
        bytes memory expected;
        string memory key;
        if (plan.sub < 3) {
            data = _raceCall(FILLS, plan.sub, false, RECIPIENT).callData;
            key = string.concat("G3 ", entryName(plan.sub), " called as a function, by ", callerName(plan.caller));
        } else {
            data = _callRoutePayload();
            expected = abi.encodeWithSelector(RouteRaceEngine.OnlySelf.selector);
            key = string.concat("G3 callRoute called by ", callerName(plan.caller));
        }
        uint256 recipientBefore = tokenB.balanceOf(RECIPIENT);
        uint256 holderBefore = tokenB.balanceOf(PAYLOAD_HOLDER);
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(router).call(data);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        string memory id = plan.sub < 3 ? "G3.race" : "G3.callRoute";
        if (ok || !_is(ret, expected)) {
            _violate(id, name, string.concat("expected: ", _answer(false, expected), ", router ", _answer(ok, ret)));
        }
        _checkUntouched(id, name, logs, recipientBefore, holderBefore);
        _reach(string.concat("G1 idle after ", kindName(plan.kind)));
        _reach(key);
    }

    function _callRouteCommand(Plan memory plan, string memory name) internal {
        bool commandMayFail = plan.flags & COMMAND_MAY_FAIL != 0;
        bool carrierMayFail = plan.flags & CARRIER_MAY_FAIL != 0;
        Call3Value memory command = Call3Value(address(router), commandMayFail, 0, _callRoutePayload());
        Call3Value[] memory cmds = new Call3Value[](1);
        string memory key = string.concat("G3 callRoute command, ", pathName(plan.proxy), ", ", nestName(plan.nest));
        key = string.concat(key, ", command ", mayFail(commandMayFail));
        if (plan.nest == NOT_NESTED) {
            cmds[0] = command;
            carrierMayFail = false;
        } else {
            Call3Value[] memory inner = new Call3Value[](1);
            inner[0] = command;
            cmds[0] = _carrier(carrierMayFail, inner, address(0));
            key = string.concat(key, ", carrier ", mayFail(carrierMayFail));
        }
        _expectRefused(
            plan,
            name,
            "G3.callRoute",
            cmds,
            carrierMayFail,
            abi.encodeWithSelector(RelayRouterBase.UnauthorizedAttempt.selector)
        );
        _reach(string.concat("G1 idle after ", kindName(plan.kind)));
        _reach(key);
    }

    function _callRouteViaCleanup(Plan memory plan, string memory name) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = address(tokenA);
        address[] memory tos = new address[](1);
        tos[0] = address(router);
        bytes[] memory datas = new bytes[](1);
        datas[0] = _callRoutePayload();
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1;
        bytes memory data = abi.encodeCall(RelayRouterBase.cleanupErc20sViaCall, (tokens, tos, datas, amounts));
        bytes memory expected = abi.encodeWithSelector(RelayRouterBase.CallFailed.selector);
        if (plan.sub % 2 == 0) {
            uint256 recipientBefore = tokenB.balanceOf(RECIPIENT);
            uint256 holderBefore = tokenB.balanceOf(PAYLOAD_HOLDER);
            (bool ok, bytes memory ret) = address(router).call(data);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            if (ok || !_is(ret, expected)) {
                _violate(
                    "G3.callRoute",
                    name,
                    string.concat("expected: ", _answer(false, expected), ", router ", _answer(ok, ret))
                );
            }
            _checkUntouched("G3.callRoute", name, logs, recipientBefore, holderBefore);
            _reach("G3 callRoute through cleanupErc20sViaCall, top level");
        } else {
            bool commandMayFail = plan.flags & COMMAND_MAY_FAIL != 0;
            Call3Value[] memory cmds = new Call3Value[](1);
            cmds[0] = Call3Value(address(router), commandMayFail, 0, data);
            _expectRefused(plan, name, "G3.callRoute", cmds, commandMayFail, expected);
            _reach(
                string.concat(
                    "G3 callRoute through cleanupErc20sViaCall, a command, ",
                    pathName(plan.proxy),
                    ", ",
                    mayFail(commandMayFail)
                )
            );
        }
        _reach(string.concat("G1 idle after ", kindName(plan.kind)));
    }

    /// @dev Sends `cmds` on the plan's path. Its one command has to fail with `refusal`: the multicall reverts with
    /// it, or, when that command may fail, succeeds with it as the command's result. No route runs and no balance
    /// of the race moves.
    function _expectRefused(
        Plan memory plan,
        string memory name,
        string memory id,
        Call3Value[] memory cmds,
        bool commandMayFail,
        bytes memory refusal
    ) internal {
        uint256 recipientBefore = tokenB.balanceOf(RECIPIENT);
        uint256 holderBefore = tokenB.balanceOf(PAYLOAD_HOLDER);
        (bool ok, bytes memory ret) = _send(plan, cmds);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        if (!commandMayFail) {
            if (ok || !_is(ret, refusal)) {
                _violate(id, name, string.concat("expected: ", _answer(false, refusal), ", router ", _answer(ok, ret)));
            }
        } else if (!ok) {
            _violate(id, name, string.concat("expected success with a failed command, router ", _answer(false, ret)));
        } else {
            Result[] memory results = abi.decode(ret, (Result[]));
            if (results.length != 1 || results[0].success || !_is(results[0].returnData, refusal)) {
                _violate(
                    id,
                    name,
                    string.concat(
                        "expected the command's result: ",
                        _answer(false, refusal),
                        ", its result ",
                        results.length == 1 ? _answer(results[0].success, results[0].returnData) : "is missing"
                    )
                );
            }
        }
        _checkUntouched(id, name, logs, recipientBefore, holderBefore);
    }

    function _checkUntouched(
        string memory id,
        string memory name,
        Vm.Log[] memory logs,
        uint256 recipientBefore,
        uint256 holderBefore
    ) internal {
        uint256 runs = _runs(logs);
        if (runs != 0) _violate(id, name, string.concat("the route ran ", vm.toString(runs), " times"));
        if (tokenB.balanceOf(RECIPIENT) != recipientBefore || tokenB.balanceOf(PAYLOAD_HOLDER) != holderBefore) {
            _violate(id, name, "tokenOut moved to the race's recipient");
        }
    }

    // ---------------------------------------------------------------- building calls

    function _raceCall(uint256 outcome, uint256 entry, bool allowFailure, address recipient)
        internal
        view
        returns (Call3Value memory)
    {
        Route[] memory routes = new Route[](1);
        routes[0] = packRoute(
            address(route),
            address(0),
            0,
            ROUTE_GAS,
            0,
            abi.encodeCall(GuardRoute.deliver, (address(tokenB), OUT, address(router)))
        );
        uint256 min = outcome == FILLS ? OUT : OUT + 1;
        bytes memory data;
        if (entry == ENTRY_RACE) {
            data = abi.encodeCall(IRouteRace.race, (address(tokenA), 0, address(tokenB), min, recipient, 0, routes));
        } else if (entry == ENTRY_SINGLE) {
            data =
                abi.encodeCall(IRouteRace.raceSingle, (address(tokenA), 0, address(tokenB), min, recipient, 0, routes));
        } else {
            data = abi.encodeCall(
                IRouteRace.raceWithBackups, (address(tokenA), 0, address(tokenB), min, recipient, 0, routes, 1)
            );
        }
        return Call3Value(address(router), allowFailure, 0, data);
    }

    /// @dev A well-formed call of callRoute: it would pay PAYLOAD_HOLDER 1 tokenB through the route
    function _callRoutePayload() internal view returns (bytes memory) {
        return abi.encodePacked(
            RouteRaceEngine.callRoute.selector,
            abi.encode(uint256(0), address(tokenB), uint256(0), PAYLOAD_HOLDER, address(route), uint256(0), ROUTE_GAS),
            abi.encodeCall(GuardRoute.deliver, (address(tokenB), 1, PAYLOAD_HOLDER))
        );
    }

    function _carrier(bool allowFailure, Call3Value[] memory inner, address nftRecipient)
        internal
        view
        returns (Call3Value memory)
    {
        return Call3Value(
            address(router),
            allowFailure,
            0,
            abi.encodeCall(RelayRouterBase.multicall, (inner, REFUND, nftRecipient, META))
        );
    }

    /// @dev Mints an NFT to the router, whose hook passes it on to the nftRecipient in force
    function _nftProbeCall(uint256 id) internal view returns (Call3Value memory) {
        return
            Call3Value(
                address(nft721), true, 0, abi.encodeWithSignature("safeMint(address,uint256)", address(router), id)
            );
    }

    function _boomCall() internal view returns (Call3Value memory) {
        return Call3Value(address(thrower), false, 0, abi.encodeCall(Thrower.boom, ()));
    }

    function _send(Plan memory plan, Call3Value[] memory cmds) internal returns (bool ok, bytes memory ret) {
        address nftRecipient = _nftAddress(plan.nft, false);
        if (plan.proxy) {
            (ok, ret) = address(proxy)
                .call(
                    abi.encodeCall(
                        RelayApprovalProxy.transferAndMulticall,
                        (new address[](0), new uint256[](0), cmds, REFUND, nftRecipient, META)
                    )
                );
        } else {
            (ok, ret) =
                address(router).call(abi.encodeCall(RelayRouterBase.multicall, (cmds, REFUND, nftRecipient, META)));
        }
    }

    // ---------------------------------------------------------------- helpers

    function _plan(Action calldata a) internal pure returns (Plan memory plan) {
        plan.kind = a.kind % KINDS;
        plan.proxy = a.path % 2 == 1;
        plan.nft = a.nft % 3;
        plan.innerNft = a.innerNft % 3;
        plan.race = a.race % 3;
        plan.entry = (a.race / 3) % 3;
        plan.nest = a.nest % 2;
        plan.depth = (a.nest / 2) % 2 + 1;
        plan.flags = a.flags;
        plan.sub = a.sub % 4;
        plan.caller = (a.sub / 4) % 4;
    }

    function _describe(Plan memory plan) internal pure returns (string memory s) {
        s = string.concat(kindName(plan.kind), " (");
        if (plan.kind == MULTICALL) {
            s = string.concat(s, pathName(plan.proxy), ", ", nftName(plan.nft), ", ", raceName(plan.race));
            if (plan.race != NO_RACE) s = string.concat(s, " (", entryName(plan.entry), ")");
            s = string.concat(s, ", ", nestName(plan.nest));
            if (plan.nest != NOT_NESTED) {
                s = string.concat(s, " with ", nftName(plan.innerNft));
                if (plan.flags & INNER_FAILS != 0) s = string.concat(s, " that fails");
                s = string.concat(s, ", carrier ", mayFail(plan.flags & CARRIER_MAY_FAIL != 0));
                if (plan.race != NO_RACE && plan.flags & RACE_AFTER_NESTED != 0) {
                    s = string.concat(s, ", race after it");
                }
            }
            if (plan.flags & TAIL_FAILS != 0) s = string.concat(s, ", last command fails");
        } else if (plan.kind == CLEANUP) {
            s = string.concat(s, cleanupName(plan.sub), plan.flags & FAILS != 0 ? " that fails" : " that succeeds");
        } else if (plan.kind == DIRECT_CALL) {
            s = string.concat(s, plan.sub < 3 ? entryName(plan.sub) : "callRoute", " by ", callerName(plan.caller));
        } else if (plan.kind == CALLROUTE_VIA_CLEANUP && plan.sub % 2 == 0) {
            s = string.concat(s, "called on its own");
        } else {
            s = string.concat(s, pathName(plan.proxy));
            uint256 outcome = plan.race == NO_RACE ? FILLS : plan.race;
            if (plan.kind == RACE_ALLOW_FAILURE) {
                s = string.concat(s, ", ", entryName(plan.entry), ", ", raceName(outcome));
            } else if (plan.kind == NESTED_RACE) {
                s = string.concat(s, ", ", entryName(plan.entry), ", ", raceName(outcome), " at depth ");
                s = string.concat(s, vm.toString(plan.depth + 1), ", ", nestName(VIA_ROUTER), ", race ");
                s = string.concat(s, mayFail(plan.flags & COMMAND_MAY_FAIL != 0), ", carrier ");
                s = string.concat(s, mayFail(plan.flags & CARRIER_MAY_FAIL != 0));
            } else if (plan.kind == CALLROUTE_COMMAND) {
                s = string.concat(s, ", ", nestName(plan.nest), ", command ");
                s = string.concat(s, mayFail(plan.flags & COMMAND_MAY_FAIL != 0));
                if (plan.nest != NOT_NESTED) {
                    s = string.concat(s, ", carrier ", mayFail(plan.flags & CARRIER_MAY_FAIL != 0));
                }
            } else {
                s = string.concat(s, ", as a command, ", mayFail(plan.flags & COMMAND_MAY_FAIL != 0));
            }
        }
        s = string.concat(s, ")");
    }

    function _nftAddress(uint256 nft, bool inner) internal view returns (address) {
        if (nft == 0) return address(0);
        if (nft == 1) return inner ? ACCOUNT2 : ACCOUNT;
        return inner ? address(holder2) : address(holder);
    }

    function _newcomer() internal returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("guards.newcomer", ++newcomers)))));
    }

    function _runs(Vm.Log[] memory logs) internal view returns (uint256 runs) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(route) && logs[i].topics[0] == GuardRoute.Ran.selector) ++runs;
        }
    }

    function _is(bytes memory a, bytes memory b) internal pure returns (bool) {
        return keccak256(a) == keccak256(b);
    }

    function _tail(bytes memory data) internal pure returns (bytes memory rest) {
        rest = new bytes(data.length - 4);
        for (uint256 i; i < rest.length; ++i) {
            rest[i] = data[i + 4];
        }
    }

    /// @dev "succeeded" or "reverted with <name> (<data>)"
    function _answer(bool ok, bytes memory ret) internal pure returns (string memory) {
        if (ok) return "succeeded";
        if (ret.length == 0) return "reverted without return data";
        return string.concat("reverted with ", _errorName(ret), " (", vm.toString(ret), ")");
    }

    function _errorName(bytes memory ret) internal pure returns (string memory) {
        if (ret.length < 4) return "?";
        bytes4 s = bytes4(ret);
        if (s == RelayRouterBase.InvalidNativeCommand.selector) return "InvalidNativeCommand()";
        if (s == RelayRouterBase.UnauthorizedAttempt.selector) return "UnauthorizedAttempt()";
        if (s == RelayRouterBase.NoRecipientSet.selector) return "NoRecipientSet()";
        if (s == RelayRouterBase.InvalidMsgSender.selector) return "InvalidMsgSender(address,address)";
        if (s == RelayRouterBase.Reentrancy.selector) return "Reentrancy()";
        if (s == RelayRouterBase.CallFailed.selector) return "CallFailed()";
        if (s == RelayRouterBase.ArrayLengthsMismatch.selector) return "ArrayLengthsMismatch()";
        if (s == RouteRaceEngine.OnlySelf.selector) return "OnlySelf()";
        if (s == RouteRaceEngine.InsufficientOutput.selector) return "InsufficientOutput(uint256,uint256)";
        if (s == RouteRaceEngine.TrialResult.selector) return "TrialResult(uint256)";
        if (s == Thrower.Boom.selector) return "Boom()";
        if (s == bytes4(0xb12d13eb)) return "ETHTransferFailed()";
        return "an unnamed error";
    }

    function _violate(string memory id, string memory name, string memory what) internal {
        if (violations[id]++ == 0) {
            firstViolation[id] = string.concat(id, " in call #", vm.toString(calls), ", ", name, ": ", what);
            if (notIdleAtStart) {
                firstViolation[id] =
                    string.concat(firstViolation[id], " (the router was not idle at the start of this call)");
            }
        }
    }

    function _reach(string memory key) internal {
        ++reach[key];
    }
}

contract RelayRouterGuardsTest is Test {
    GuardsHandler handler;

    function _deployRouter() internal virtual returns (RelayRouterBase) {
        return new RelayRouter();
    }

    function setUp() public {
        handler = new GuardsHandler(_deployRouter());
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = GuardsHandler.act.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_G1_idleAfterCall() public view {
        assertEq(handler.violations("G1.idle"), 0, handler.firstViolation("G1.idle"));
    }

    function invariant_G1_nestedRestores() public view {
        assertEq(handler.violations("G1.nested"), 0, handler.firstViolation("G1.nested"));
    }

    function invariant_G1_actionResult() public view {
        assertEq(handler.violations("G1.result"), 0, handler.firstViolation("G1.result"));
    }

    function invariant_G3_raceOnlyWhereAllowed() public view {
        assertEq(handler.violations("G3.race"), 0, handler.firstViolation("G3.race"));
    }

    function invariant_G3_callRouteOnlyFromRace() public view {
        assertEq(handler.violations("G3.callRoute"), 0, handler.firstViolation("G3.callRoute"));
    }

    function _act(
        uint256 kind,
        uint256 path,
        uint256 nft,
        uint256 innerNft,
        uint256 race,
        uint256 nest,
        uint8 flags,
        uint256 sub
    ) internal {
        handler.act(
            Action(uint8(kind), uint8(path), uint8(nft), uint8(innerNft), uint8(race), uint8(nest), flags, uint8(sub))
        );
    }

    function _fixedCases() internal {
        for (uint256 path; path < 2; ++path) {
            // G1: nested multicalls with every pair of nftRecipients
            for (uint256 nft; nft < 3; ++nft) {
                for (uint256 innerNft; innerNft < 3; ++innerNft) {
                    _act(MULTICALL, path, nft, innerNft, NO_RACE, VIA_ROUTER, 0, 0);
                }
            }
            // a race after the nested multicall; a nested multicall that fails, may fail or must not
            _act(MULTICALL, path, 1, 2, FILLS, VIA_ROUTER, RACE_AFTER_NESTED, 0);
            _act(MULTICALL, path, 2, 1, NO_RACE, VIA_ROUTER, INNER_FAILS | CARRIER_MAY_FAIL, 0);
            _act(MULTICALL, path, 1, 1, NO_RACE, VIA_ROUTER, INNER_FAILS, 0);
            // G1: races, a multicall that reverts at its last command, one without anything
            for (uint256 entry; entry < 3; ++entry) {
                _act(MULTICALL, path, entry, 0, FILLS + 3 * entry, NOT_NESTED, 0, 0);
            }
            _act(MULTICALL, path, 1, 0, FALLS_SHORT, NOT_NESTED, 0, 0);
            _act(MULTICALL, path, 2, 0, NO_RACE, NOT_NESTED, TAIL_FAILS, 0);
            _act(MULTICALL, path, 0, 0, NO_RACE, NOT_NESTED, 0, 0);

            // G3 case 1
            for (uint256 entry; entry < 3; ++entry) {
                _act(RACE_ALLOW_FAILURE, path, 0, 0, FILLS + 3 * entry, 0, 0, 0);
                _act(RACE_ALLOW_FAILURE, path, 0, 0, FALLS_SHORT + 3 * entry, 0, 0, 0);
            }
            // G3 case 2
            for (uint256 depth; depth < 2; ++depth) {
                for (uint8 carrier; carrier < 2; ++carrier) {
                    uint8 flags = carrier == 1 ? CARRIER_MAY_FAIL : 0;
                    _act(NESTED_RACE, path, 0, 0, FILLS + 3 * depth, VIA_ROUTER + 2 * depth, flags, 0);
                    _act(NESTED_RACE, path, 0, 0, FALLS_SHORT + 3 * carrier, VIA_ROUTER + 2 * depth, flags, 0);
                }
            }
            _act(NESTED_RACE, path, 0, 0, FILLS + 6, VIA_ROUTER, COMMAND_MAY_FAIL | CARRIER_MAY_FAIL, 0);
            // G3 case 5
            for (uint8 command; command < 2; ++command) {
                uint8 flags = command == 1 ? COMMAND_MAY_FAIL : 0;
                _act(CALLROUTE_COMMAND, path, 0, 0, 0, NOT_NESTED, flags, 0);
                _act(CALLROUTE_COMMAND, path, 0, 0, 0, VIA_ROUTER, flags, 0);
                _act(CALLROUTE_COMMAND, path, 0, 0, 0, VIA_ROUTER, flags | CARRIER_MAY_FAIL, 0);
                // G3 case 6, as a command
                _act(CALLROUTE_VIA_CLEANUP, path, 0, 0, 0, 0, flags, 1);
            }
        }
        // G1: the four cleanups, succeeding and failing
        for (uint256 sub; sub < 4; ++sub) {
            _act(CLEANUP, 0, 0, 0, 0, 0, 0, sub);
            _act(CLEANUP, 0, 0, 0, 0, 0, FAILS, sub);
        }
        // G3 cases 3 and 4
        for (uint256 sub; sub < 4; ++sub) {
            for (uint256 caller; caller < 4; ++caller) {
                _act(DIRECT_CALL, 0, 0, 0, 0, 0, 0, sub + 4 * caller);
            }
        }
        // G3 case 6, on its own
        _act(CALLROUTE_VIA_CLEANUP, 0, 0, 0, 0, 0, 0, 0);
    }

    function test_reach() public {
        _fixedCases();

        invariant_G1_idleAfterCall();
        invariant_G1_nestedRestores();
        invariant_G1_actionResult();
        invariant_G3_raceOnlyWhereAllowed();
        invariant_G3_callRouteOnlyFromRace();

        _reached("G1 idle at the start of a call");
        for (uint256 path; path < 2; ++path) {
            bool proxy = path == 1;
            string memory p = string.concat("G1 idle after a multicall, ", pathName(proxy), ", ");
            for (uint256 nft; nft < 3; ++nft) {
                _reached(string.concat(p, nftName(nft)));
            }
            for (uint256 race; race < 3; ++race) {
                _reached(string.concat(p, raceName(race)));
            }
            for (uint256 nest; nest <= VIA_ROUTER; ++nest) {
                _reached(string.concat(p, nestName(nest)));
            }
            _reached(string.concat(p, "succeeded"));
            _reached(string.concat(p, "reverted"));
            for (uint256 nft; nft < 3; ++nft) {
                for (uint256 innerNft; innerNft < 3; ++innerNft) {
                    _reached(
                        string.concat(
                            "G1 nested restores the nftRecipient, ",
                            pathName(proxy),
                            ", ",
                            nestName(VIA_ROUTER),
                            ", outer ",
                            nftName(nft),
                            ", inner ",
                            nftName(innerNft)
                        )
                    );
                }
            }
            _reached(string.concat("G1 race after a multicall ", nestName(VIA_ROUTER), ", ", pathName(proxy)));

            for (uint256 entry; entry < 3; ++entry) {
                for (uint256 race = FILLS; race <= FALLS_SHORT; ++race) {
                    _reached(
                        string.concat(
                            "G3 race with allowFailure, ", pathName(proxy), ", ", entryName(entry), ", ", raceName(race)
                        )
                    );
                }
            }
            for (uint256 depth = 2; depth <= 3; ++depth) {
                for (uint256 carrier; carrier < 2; ++carrier) {
                    for (uint256 race = FILLS; race <= FALLS_SHORT; ++race) {
                        _reached(
                            string.concat(
                                "G3 race in a multicall ",
                                nestName(VIA_ROUTER),
                                ", ",
                                pathName(proxy),
                                ", depth ",
                                vm.toString(depth),
                                ", race must not fail, carrier ",
                                mayFail(carrier == 1),
                                ", ",
                                raceName(race)
                            )
                        );
                    }
                }
            }
            _reached(
                string.concat(
                    "G3 race in a multicall ",
                    nestName(VIA_ROUTER),
                    ", ",
                    pathName(proxy),
                    ", depth 2, race allowFailure, carrier allowFailure, a race that fills"
                )
            );
            for (uint256 command; command < 2; ++command) {
                string memory c = string.concat("G3 callRoute command, ", pathName(proxy), ", ");
                _reached(string.concat(c, nestName(NOT_NESTED), ", command ", mayFail(command == 1)));
                for (uint256 carrier; carrier < 2; ++carrier) {
                    _reached(
                        string.concat(
                            c,
                            nestName(VIA_ROUTER),
                            ", command ",
                            mayFail(command == 1),
                            ", carrier ",
                            mayFail(carrier == 1)
                        )
                    );
                }
                _reached(
                    string.concat(
                        "G3 callRoute through cleanupErc20sViaCall, a command, ",
                        pathName(proxy),
                        ", ",
                        mayFail(command == 1)
                    )
                );
            }
        }
        for (uint256 sub; sub < 4; ++sub) {
            _reached(string.concat("G1 idle after ", cleanupName(sub), ", succeeded"));
            _reached(string.concat("G1 idle after ", cleanupName(sub), ", reverted"));
            for (uint256 caller; caller < 4; ++caller) {
                if (sub < 3) {
                    _reached(string.concat("G3 ", entryName(sub), " called as a function, by ", callerName(caller)));
                } else {
                    _reached(string.concat("G3 callRoute called by ", callerName(caller)));
                }
            }
        }
        for (uint256 kind = RACE_ALLOW_FAILURE; kind < KINDS; ++kind) {
            _reached(string.concat("G1 idle after ", kindName(kind)));
        }
        _reached("G3 callRoute through cleanupErc20sViaCall, top level");
    }

    function _reached(string memory key) internal {
        uint256 count = handler.reach(key);
        emit log_named_uint(key, count);
        assertGt(count, 0, string.concat("not reached: ", key));
    }
}

contract RelayRouterNonTstoreGuardsTest is RelayRouterGuardsTest {
    function _deployRouter() internal override returns (RelayRouterBase) {
        return new RelayRouter_NonTstore();
    }
}
