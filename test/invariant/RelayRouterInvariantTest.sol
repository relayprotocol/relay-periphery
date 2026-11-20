// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
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

uint256 constant SLOTS = 4;

uint256 constant EMIT_EVENTS = 1;
uint256 constant KEEP_ALLOWANCES = 2;
uint256 constant DIRECT_OUTPUT = 4;
uint256 constant NO_INPUT_REFUND = 8;
uint256 constant LOG_FUNDS_MOVEMENT = 16;

// RaceInput.entry
uint8 constant RACE = 0;
uint8 constant RACE_SINGLE = 1;
uint8 constant RACE_WITH_BACKUPS = 2;

// RouteInput.kind
uint8 constant REVERTS = 0;
uint8 constant SPENDS_ALL = 2;
uint8 constant SPENDS_PART = 5;
uint8 constant SPENDS_NONE = 7;

// RaceInput.recipient and RaceInput.refund
uint8 constant TO_ROUTER = 2;

// RaceInput.assets
uint8 constant NATIVE_IN = 2;
uint8 constant NATIVE_OUT = 3;

// RaceInput.path
uint8 constant DIRECT = 3;

// RouteInput.fee
uint8 constant FEE_10_PERCENT = 4;
uint8 constant FEE_50_PERCENT = 5;

// RouteInput.twist
uint8 constant GREEDY = 8;
uint8 constant VALUE_WITHIN = 9;
uint8 constant VALUE_ABOVE = 10;
uint8 constant FADING = 11; // and 12
uint8 constant LOWERS_LESS = 13; // than it mints
uint8 constant LOWERS_ALL = 14;
uint8 constant LOWERS_MORE = 15;

// RouteInput.spender
uint8 constant NO_SPENDER = 3; // declares none, and pulls its input through its own target's allowance
uint8 constant SEPARATE = 4; // and 5, the other one
uint8 constant OTHER_TARGET = 6; // and 7. Each 8 more is one route further on

// RaceInput.budget
uint8 constant WITH_SURPLUS = 1;

// RaceInput.cleanup
uint8 constant CLEANUP_TOKEN_A = 4;
uint8 constant CLEANUP_TOKEN_B = 5;
uint8 constant CLEANUP_NATIVE = 6; // and 7

// RaceInput.cleanupMode
uint8 constant MAY_FAIL = 5;
uint8 constant EXPLICIT = 6;
uint8 constant EXPLICIT_MAY_FAIL = 7;

/// @dev What a route does in one run
struct Order {
    bool fail;
    address tokenIn; // address(0): the input arrives as msg.value
    address spender; // the allowance `spend` is pulled through
    uint256 spend;
    address via; // the allowance a greedy route pulls `extra` more through
    uint256 extra;
    address tokenOut;
    uint256 out;
    address watch; // a fading route delivers `cut` less once the router's tokenIn allowance to `watch` is non-zero
    uint256 cut;
    uint256 burn; // a lowering route removes this much tokenOut from `to` before it delivers
    address to;
}

/// @dev An output token that anyone may burn from any holder: all a route needs to lower the holder's balance
contract BurnableERC20 is TestERC20 {
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

/// @dev One per route slot. Every call carries its own script: a swap, honest or not, or a revert. Two more are
/// never a route's target: they are spenders only, which a route pulls its input through.
contract ScriptedRouteProvider {
    error ScriptedRevert();

    /// @dev One per run. Unlike `calls`, the recorded logs keep it for the runs the router rolls back
    event Ran();

    uint256 public calls;

    receive() external payable {}

    function run(Order calldata o) external payable {
        emit Ran();
        ++calls;
        if (o.fail) revert ScriptedRevert();
        uint256 out = o.out;
        if (o.tokenIn != address(0)) {
            // An approval made since its trial is all that tells a route it is run again. It looks before it
            // pulls, because the allowance it watches may be its own. A cut above `out` reverts
            if (o.cut != 0 && TestERC20(o.tokenIn).allowance(msg.sender, o.watch) != 0) out -= o.cut;
            _pull(o.tokenIn, o.spender, o.spend);
            _pull(o.tokenIn, o.via, o.extra);
        }
        if (o.tokenOut == address(0)) {
            (bool ok,) = o.to.call{value: out}("");
            require(ok, "native delivery failed");
        } else {
            // The token stops a burn of more than `to` holds
            if (o.burn != 0) BurnableERC20(o.tokenOut).burn(o.to, o.burn);
            TestERC20(o.tokenOut).mint(o.to, out);
        }
    }

    /// @dev Open to anyone, like a spender that moves whatever its caller names. Not a run of the route
    function pull(address token, address from, address to, uint256 amount) external {
        TestERC20(token).transferFrom(from, to, amount);
    }

    function _pull(address token, address through, uint256 amount) internal {
        if (amount == 0) return;
        if (through == address(this)) TestERC20(token).transferFrom(msg.sender, address(this), amount);
        else ScriptedRouteProvider(payable(through)).pull(token, msg.sender, address(this), amount);
    }
}

struct RouteInput {
    uint8 kind; // % 8: 0-1 reverts, 2-4 spends all of amountIn, 5-6 spends `spend` bounded to amountIn, 7 spends nothing
    uint64 out;
    uint64 spend;
    uint8 fee; // % 8 picks the fee: none, none, 1 ppm, 0.1%, 10%, 50%, 90%, 999_999 ppm
    // % 16: 0-7 as scripted by `kind`, 8 greedy, 9 a value within the native budget, 10 a value above it,
    // 11-12 fading: less output once another route's spender is approved, 13-15 lowering: removes tokenOut
    // from the output holder before it delivers, 13 less than it mints, 14 as much, 15 more
    uint8 twist;
    uint64 aux; // the amount a twist needs
    // % 8 picks the spender the route declares and pulls its input through: 0-2 its own target, 3 none, and it
    // pulls through its own target's allowance, 4-5 one of two contracts that are no route's target, 6-7 the
    // target of another route of the race: the next one, or the one `spender >> 3` further on. Two routes may
    // pick the same one
    uint8 spender;
}

struct RaceInput {
    uint8 entry; // % 3: race, raceSingle, raceWithBackups
    uint8 routeCount; // 1 + routeCount % SLOTS routes
    uint8 mainCount; // 1 + mainCount % routes mains, for raceWithBackups
    uint8 flags; // & 31
    uint8 assets; // % 4: 0-1 tokenA to tokenB, 2 native to tokenB, 3 tokenA to native
    uint8 path; // % 4: 0-2 through the proxy, 3 straight to the router with a zero refundTo
    uint8 recipient; // % 3: 0-1 the fixed recipient, 2 the router
    uint8 refund; // % 3: 0-1 the fixed refund address, 2 the router; ignored on the direct path
    uint8 minMode; // % 5: 0 minOut as given, 1 the best honest output, 2 that + 1, 3 some route's output, 4 the worst
    uint8 scale; // % 4 == 0: every amount is taken mod 8, for ties, zeros and boundaries
    uint64 amountIn;
    uint64 minOut;
    uint64 routerIn; // put on the router before the race, on top of what earlier races left there
    uint64 routerOut;
    uint64 routerNative;
    uint8 budget; // % 2 == 1: the command carries `surplus` more value than a native input needs: the native budget
    uint64 surplus;
    // % 8: 0-3 the race is the only command, 4-7 one of the router's cleanups follows it: 4 cleanupErc20s of
    // tokenA, 5 of tokenB, 6-7 cleanupNative
    uint8 cleanup;
    uint8 cleanupTo; // % 3: 0-1 the fixed cleanup address, 2 the router itself, for cleanupNative a zero recipient
    // % 8: 0-5 the amount is 0, the router's whole balance, 6-7 it is `cleanupAmount`, which fails the command
    // when the router holds less. 5 and 7 allow the command to fail
    uint8 cleanupMode;
    uint64 cleanupAmount;
    RouteInput[SLOTS] routes;
}

/// @dev What one route slot is told to do in one race
struct Script {
    bool fail;
    uint256 spend;
    uint256 out;
    uint256 feePpm;
    uint256 value; // sent with the call: the spend of a native input, otherwise a share of the native budget
    address spender; // what `spend` is pulled through. Not always the route's target
    address declared; // the spender declared to the router: `spender`, or zero for a route that declares none
    address via; // greedy: `extra` is pulled on top of `spend`, through the allowance of `via`
    uint256 extra;
    uint256 watch; // fading: `cut` less is delivered once the spender of route `watch` holds an allowance
    uint256 cut;
    uint256 burn; // lowering: removed from the output holder's tokenOut before `out` is minted to it
}

/// @dev One resolved race
struct Plan {
    uint256 entry;
    uint256 mainCount;
    uint256 flags;
    address tokenIn; // address(0) is native
    address tokenOut;
    uint256 amountIn;
    uint256 value; // of the command and of the multicall: a native input plus the surplus, or the native budget
    uint256 minOut;
    address recipient;
    bool direct;
    address refundTo; // as passed: zero on the direct path, where it means the caller
    uint256[3] seed; // put on the router beforehand: tokenA, tokenB, native
    uint256 held; // the output holder's tokenB when the race starts, and so when any route of it runs
    bool cleanup; // a second command follows the race: cleanupErc20s of one token, or cleanupNative
    uint256 cleanupAsset; // the ledger column it moves
    address cleanupTo; // the router itself is passed to cleanupNative as zero: the caller of a command
    uint256 cleanupAmount; // as passed: 0 is all the router holds when the command runs
    bool cleanupMayFail; // the command's allowFailure
    Script[] scripts;
}

/// @dev What the scripts allow. Which of several routes that can win is committed is not predicted
struct Verdict {
    uint256 fillers; // bit i: route i can win, and fills
    uint256 overspenders; // bit i: route i can win and takes more than amountIn, so the race reverts
    uint256 reached; // bit i: route i runs whichever route wins
    uint256 dropped; // bit i: main i reaches the minimum in its trial and delivers less, or reverts, when run again
    uint256 zeros; // bit i: main i delivers nothing in its trial. The router forgets it once a main is dropped
    uint256[] trials; // what route i delivers in its first run
    uint256[] delivers; // what route i delivers in the run that can commit it
    bytes expected; // the exact revert data when no route can win
}

contract RaceInvariantHandler is Test {
    uint256 internal constant ROUTE_GAS = 500_000;
    address public constant RECIPIENT = address(0xA11CE);
    address public constant REFUND = address(0xFEED);
    address public constant CLEANUP = address(0xC1EA2);
    bytes internal constant META = "race-invariant";
    uint256 internal constant NO_ROUTE = type(uint256).max;
    bytes32 internal constant APPROVAL = keccak256("Approval(address,address,uint256)");

    // Ledger columns
    uint256 internal constant TOKEN_A = 0;
    uint256 internal constant TOKEN_B = 1;
    uint256 internal constant NATIVE = 2;
    // Ledger rows
    uint256 internal constant ROUTER = 1;
    uint256 internal constant FIRST_PROVIDER = 5;

    RelayRouterBase public immutable router;
    RelayApprovalProxy public immutable proxy;
    TestERC20 public immutable tokenA;
    BurnableERC20 public immutable tokenB;
    ScriptedRouteProvider[] public providers;
    ScriptedRouteProvider[2] public spenders; // no route's target: only declared as a spender, and pulled through
    address[] internal holders;
    string[] internal holderNames;

    uint256 public races;
    mapping(string => uint256) public violations;
    mapping(string => string) public firstViolation;
    mapping(string => uint256) public reach;

    constructor(RelayRouterBase router_) {
        router = router_;
        proxy = new RelayApprovalProxy(address(this), address(router_), PERMIT2);
        tokenA = new TestERC20();
        tokenB = new BurnableERC20();
        tokenA.approve(address(proxy), type(uint256).max);
        _track(address(this), "user");
        _track(address(router_), "router");
        _track(RECIPIENT, "recipient");
        _track(REFUND, "refund");
        _track(CLEANUP, "cleanup");
        for (uint256 i; i < SLOTS; ++i) {
            providers.push(new ScriptedRouteProvider());
            _track(address(providers[i]), string.concat("provider", vm.toString(i)));
        }
        // After the providers in the ledger: whatever a race leaves on a spender is a loser's balance change
        for (uint256 i; i < spenders.length; ++i) {
            spenders[i] = new ScriptedRouteProvider();
            _track(address(spenders[i]), string.concat("spender", vm.toString(i)));
        }
    }

    receive() external payable {}

    /// @dev The one fuzzed entry point: one race command in one multicall, alone or followed by a cleanup command
    function race(RaceInput calldata p) external {
        ++races;
        Plan memory plan = _plan(p);
        _fund(plan);
        Verdict memory v = _model(plan);
        uint256[3][] memory before = _balances();
        uint256[] memory callsBefore = _calls();
        uint256[] memory allowed = _allowances();
        uint256 winner = NO_ROUTE;
        Vm.Log[] memory logs;

        vm.recordLogs();
        try this.submit(plan) returns (Result[] memory results) {
            logs = vm.getRecordedLogs();
            if (results.length != (plan.cleanup ? 2 : 1) || !results[0].success || results[0].returnData.length != 64) {
                _violate("F3", "malformed race result");
                return;
            }
            uint256 amountOut;
            (winner, amountOut) = abi.decode(results[0].returnData, (uint256, uint256));
            // Ahead of the other checks, which stop at a fill the model cannot follow
            _checkApprovals(plan, v, winner, logs);
            _checkAllowances(plan, winner, allowed);
            if (!_checkWinner(plan, v, winner)) return;
            // Counted here and not with the others below: `allowed` kept across the ledger check is one local too
            // many for the stack under the optimizer sequence of foundry.toml
            _countNoSpender(plan, v, winner, allowed);
            uint256 left = _checkFill(plan, v, winner, amountOut, before, callsBefore);
            if (plan.cleanup) _checkCleanup(plan, v, winner, results[1], left);
            _countFill(plan, v, winner, before);
        } catch (bytes memory err) {
            logs = vm.getRecordedLogs();
            _checkApprovals(plan, v, NO_ROUTE, logs);
            _checkAllowances(plan, NO_ROUTE, allowed);
            if (!_checkRevert(plan, v, err, before)) return;
            _countNoSpender(plan, v, NO_ROUTE, allowed);
        }
        _countRoutes(plan, v, before);
        _countFading(plan, v, winner, logs);
        _countLowering(plan, v, winner);
        _countSpenders(plan, v, winner);
    }

    /// @dev Self-call so that one try/catch covers everything the router can revert
    function submit(Plan calldata plan) external returns (Result[] memory) {
        require(msg.sender == address(this), "handler only");
        uint256 n = plan.scripts.length;
        bool nativeIn = plan.tokenIn == address(0);
        // The command's value is the native the routes may take; the multicall brings exactly that much
        uint256 value = plan.value;
        address holder = plan.flags & DIRECT_OUTPUT != 0 ? plan.recipient : address(router);
        Route[] memory routes = new Route[](n);
        for (uint256 i; i < n; ++i) {
            Script calldata s = plan.scripts[i];
            Order memory order = Order({
                fail: s.fail,
                tokenIn: plan.tokenIn,
                spender: s.spender,
                spend: s.spend,
                via: s.via,
                extra: s.extra,
                tokenOut: plan.tokenOut,
                out: s.out,
                watch: plan.scripts[s.watch].spender,
                cut: s.cut,
                burn: s.burn,
                to: holder
            });
            routes[i] = packRoute(
                address(providers[i]),
                s.declared,
                s.value,
                ROUTE_GAS,
                s.feePpm,
                abi.encodeCall(ScriptedRouteProvider.run, (order))
            );
        }
        Call3Value[] memory calls = new Call3Value[](plan.cleanup ? 2 : 1);
        calls[0] = Call3Value(address(router), false, value, _command(plan, routes));
        if (plan.cleanup) calls[1] = Call3Value(address(router), plan.cleanupMayFail, 0, _cleanupCommand(plan));

        if (plan.direct) {
            if (!nativeIn) TestERC20(plan.tokenIn).transfer(address(router), plan.amountIn);
            return router.multicall{value: value}(calls, plan.refundTo, address(0), META);
        }
        address[] memory tokens = new address[](nativeIn ? 0 : 1);
        uint256[] memory amounts = new uint256[](tokens.length);
        if (!nativeIn) {
            tokens[0] = plan.tokenIn;
            amounts[0] = plan.amountIn;
        }
        return proxy.transferAndMulticall{value: value}(tokens, amounts, calls, plan.refundTo, address(0), META);
    }

    function _command(Plan calldata plan, Route[] memory routes) internal pure returns (bytes memory) {
        if (plan.entry == RACE) {
            return abi.encodeCall(
                IRouteRace.race,
                (plan.tokenIn, plan.amountIn, plan.tokenOut, plan.minOut, plan.recipient, plan.flags, routes)
            );
        }
        if (plan.entry == RACE_SINGLE) {
            return abi.encodeCall(
                IRouteRace.raceSingle,
                (plan.tokenIn, plan.amountIn, plan.tokenOut, plan.minOut, plan.recipient, plan.flags, routes)
            );
        }
        return abi.encodeCall(
            IRouteRace.raceWithBackups,
            (
                plan.tokenIn,
                plan.amountIn,
                plan.tokenOut,
                plan.minOut,
                plan.recipient,
                plan.flags,
                routes,
                plan.mainCount
            )
        );
    }

    /// @dev The command after the race: one of the router's own cleanups, of one asset
    function _cleanupCommand(Plan calldata plan) internal view returns (bytes memory) {
        if (plan.cleanupAsset == NATIVE) {
            // A zero recipient is the caller, and the router calls its commands itself
            address to = plan.cleanupTo == address(router) ? address(0) : plan.cleanupTo;
            return abi.encodeCall(RelayRouterBase.cleanupNative, (plan.cleanupAmount, to, META));
        }
        address[] memory tokens = new address[](1);
        address[] memory recipients = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = plan.cleanupAsset == TOKEN_A ? address(tokenA) : address(tokenB);
        recipients[0] = plan.cleanupTo;
        amounts[0] = plan.cleanupAmount;
        return abi.encodeCall(RelayRouterBase.cleanupErc20s, (tokens, recipients, amounts, META));
    }

    function _plan(RaceInput calldata p) internal view returns (Plan memory plan) {
        bool tiny = p.scale % 4 == 0;
        uint256 n = 1 + p.routeCount % SLOTS;
        plan.entry = p.entry % 3;
        plan.mainCount = 1 + p.mainCount % n;
        plan.flags = p.flags & 31;
        plan.tokenIn = p.assets % 4 == NATIVE_IN ? address(0) : address(tokenA);
        plan.tokenOut = p.assets % 4 == NATIVE_OUT ? address(0) : address(tokenB);
        plan.amountIn = _amount(p.amountIn, tiny);
        bool nativeIn = plan.tokenIn == address(0);
        plan.value = (nativeIn ? plan.amountIn : 0) + (p.budget % 2 == WITH_SURPLUS ? _amount(p.surplus, tiny) : 0);
        plan.recipient = p.recipient % 3 == TO_ROUTER ? address(router) : RECIPIENT;
        plan.direct = p.path % 4 == DIRECT;
        plan.refundTo = plan.direct ? address(0) : p.refund % 3 == TO_ROUTER ? address(router) : REFUND;
        plan.seed = [_amount(p.routerIn, tiny), _amount(p.routerOut, tiny), _amount(p.routerNative, tiny)];
        plan.cleanup = p.cleanup % 8 >= CLEANUP_TOKEN_A;
        plan.cleanupAsset =
            p.cleanup % 8 == CLEANUP_TOKEN_A ? TOKEN_A : p.cleanup % 8 == CLEANUP_TOKEN_B ? TOKEN_B : NATIVE;
        plan.cleanupTo = p.cleanupTo % 3 == TO_ROUTER ? address(router) : CLEANUP;
        plan.cleanupAmount = p.cleanupMode % 8 >= EXPLICIT ? _amount(p.cleanupAmount, tiny) : 0;
        plan.cleanupMayFail = p.cleanupMode % 8 == MAY_FAIL || p.cleanupMode % 8 == EXPLICIT_MAY_FAIL;
        // Every run but the committed one is rolled back, so each route finds the holder as the race found it
        plan.held = plan.flags & DIRECT_OUTPUT != 0 && plan.recipient != address(router)
            ? tokenB.balanceOf(plan.recipient)
            : tokenB.balanceOf(address(router)) + plan.seed[TOKEN_B];
        plan.scripts = new Script[](n);
        for (uint256 i; i < n; ++i) {
            plan.scripts[i].out = _amount(p.routes[i].out, tiny); // set ahead, for a route that outbids the others
            plan.scripts[i].spender = _spender(p.routes[i].spender, i, n); // and for a twist that reads another's
            if (p.routes[i].spender % 8 != NO_SPENDER) plan.scripts[i].declared = plan.scripts[i].spender;
        }
        uint256 best;
        uint256 worst = type(uint256).max;
        for (uint256 i; i < n; ++i) {
            Script memory s = plan.scripts[i];
            uint256 kind = p.routes[i].kind % 8;
            s.fail = kind < SPENDS_ALL;
            s.spend = kind < SPENDS_PART
                ? plan.amountIn
                : kind < SPENDS_NONE ? _bound(_amount(p.routes[i].spend, tiny), 0, plan.amountIn) : 0;
            s.feePpm = _fee(p.routes[i].fee);
            if (nativeIn) s.value = s.spend;
            _twist(plan, i, p.routes[i].twist % 16, _amount(p.routes[i].aux, tiny));
            if (s.fail) continue;
            if (s.out > best) best = s.out;
            if (s.out < worst) worst = s.out;
        }
        if (worst > best) worst = best; // no honest route
        uint256 mode = p.minMode % 5;
        plan.minOut = mode == 0
            ? _amount(p.minOut, tiny)
            : mode == 1 ? best : mode == 2 ? best + 1 : mode == 3 ? plan.scripts[p.minOut % n].out : worst;
        if (plan.minOut == 0) plan.minOut = 1;
    }

    /// @dev Turns the script of route `i` into one that takes more than the race allows, or close to it, or
    /// that delivers less once the router has approved another route's spender, or that removes tokenOut from
    /// the output holder
    function _twist(Plan memory plan, uint256 i, uint256 twist, uint256 aux) internal view {
        Script memory s = plan.scripts[i];
        bool nativeIn = plan.tokenIn == address(0);
        if (twist == GREEDY && !nativeIn) {
            // All of amountIn through its own allowance, then more through a second one: its own again under
            // flag 2, where it is the maximum, otherwise the previous route's. Sized to what the router holds.
            // Where the two routes declare one spender, nothing is left of its allowance and the route reverts
            bool keep = plan.flags & KEEP_ALLOWANCES != 0;
            uint256 spare = tokenA.balanceOf(address(router)) + plan.seed[TOKEN_A];
            if (!keep && spare > plan.amountIn) spare = plan.amountIn;
            s.spend = plan.amountIn;
            s.extra = 1 + (spare == 0 ? aux : aux % spare);
            s.via = keep || i == 0 ? s.spender : plan.scripts[i - 1].spender;
        } else if (twist == VALUE_WITHIN && !nativeIn) {
            if (plan.value != 0) s.value = 1 + aux % plan.value;
        } else if (twist == VALUE_ABOVE) {
            // Above the limit, and within the native the router will hold, so that only the limit stops it
            uint256 limit = _valueLimit(plan);
            uint256 spare = address(router).balance + plan.seed[NATIVE] + plan.value - limit;
            s.value = limit + 1 + (spare == 0 ? aux : aux % spare);
        } else if ((twist == FADING || twist == FADING + 1) && !nativeIn) {
            uint256 amount = aux >> 4;
            // Half of them are a lure, the best output of the race, because only the leader is run again
            for (uint256 j; j < plan.scripts.length && amount % 2 == 1; ++j) {
                if (j != i && plan.scripts[j].out >= s.out) s.out = plan.scripts[j].out + 1;
            }
            // Three times in four it watches the next route's spender, which the router approves right after
            // this route's trial, unless this route or one before it declares that spender too. One time in
            // four the cut is more than it delivers, so it reverts instead
            s.watch = (i + 1 + (aux % 4 == 0 ? amount : 0)) % plan.scripts.length;
            s.cut = (aux >> 2) % 4 == 0 ? s.out + 1 : 1 + (amount >> 1) % (s.out == 0 ? 1 : s.out);
        } else if (twist >= LOWERS_LESS && plan.tokenOut != address(0)) {
            // Less than it mints, where it mints enough for that, or as much, or more. More is sized to what
            // the holder has above that, so that only the router's check stops the route, not the token
            uint256 spare = plan.held > s.out ? plan.held - s.out : 0;
            s.burn = twist == LOWERS_LESS
                ? s.out < 2 ? 0 : 1 + aux % (s.out - 1)
                : twist == LOWERS_ALL ? s.out : s.out + 1 + (spare == 0 ? aux : aux % spare);
        }
    }

    /// @dev The spender route `i` of `n` declares: its own target, a contract that is no route's target, or the
    /// target of another route of the race, which exists when there are two routes or more
    function _spender(uint256 choice, uint256 i, uint256 n) internal view returns (address) {
        uint256 kind = choice % 8;
        if (kind >= OTHER_TARGET && n > 1) return address(providers[(i + 1 + (choice >> 3) % (n - 1)) % n]);
        if (kind == SEPARATE || kind == SEPARATE + 1) return address(spenders[kind - SEPARATE]);
        return address(providers[i]);
    }

    /// @dev The most native one route may be sent
    function _valueLimit(Plan memory plan) internal pure returns (uint256) {
        return plan.tokenIn == address(0) ? plan.amountIn : plan.value;
    }

    function _amount(uint256 raw, bool tiny) internal pure returns (uint256) {
        return tiny ? raw % 8 : raw;
    }

    /// @dev Levels rather than raw values, so that fees are often large enough to change the ranking
    function _fee(uint8 raw) internal pure returns (uint256) {
        return [uint24(0), 0, 1, 1_000, 100_000, 500_000, 900_000, 999_999][raw % 8];
    }

    /// @dev Gives the user the input, the providers the native they are scripted to deliver, and
    /// the router the balances a race has to leave alone
    function _fund(Plan memory plan) internal {
        vm.deal(address(this), address(this).balance + plan.value);
        if (plan.tokenIn != address(0)) TestERC20(plan.tokenIn).mint(address(this), plan.amountIn);
        if (plan.tokenOut == address(0)) {
            for (uint256 i; i < plan.scripts.length; ++i) {
                vm.deal(address(providers[i]), address(providers[i]).balance + plan.scripts[i].out);
            }
        }
        tokenA.mint(address(router), plan.seed[TOKEN_A]);
        tokenB.mint(address(router), plan.seed[TOKEN_B]);
        vm.deal(address(router), address(router).balance + plan.seed[NATIVE]);
    }

    /// @dev L1: a race commits a route exactly when some route's run reaches the minimum. The route fills, or
    /// reverts the race if it took more than amountIn. A main that is not the last main has to reach the minimum
    /// in its trial and deliver no less when it is run again. Every run is worked out from the script and the
    /// state the race starts in
    function _model(Plan memory plan) internal view returns (Verdict memory v) {
        uint256 n = plan.scripts.length;
        uint256 mains = _mains(plan);
        v.trials = new uint256[](n);
        v.delivers = new uint256[](n);
        bool anyOutput;
        uint256 best;
        for (uint256 i; i < n; ++i) {
            if (i < mains || v.fillers | v.overspenders == 0) v.reached |= 1 << i;
            (bool ok, uint256 out) = _simulate(plan, i, i + 1);
            if (!ok) continue;
            (v.trials[i], v.delivers[i]) = (out, out);
            if (out >= plan.minOut) {
                // Only the last main can commit in its trial. Any other main is run again once every main is
                // approved, and is dropped unless it delivers at least as much as in its trial
                if (i + 1 < mains) {
                    (ok, v.delivers[i]) = _simulate(plan, i, mains);
                    if (!ok || v.delivers[i] < out) {
                        v.dropped |= 1 << i;
                        continue;
                    }
                }
                if (_overspends(plan, i)) v.overspenders |= 1 << i;
                else v.fillers |= 1 << i;
            } else if (out == 0 && i < mains) {
                v.zeros |= 1 << i;
            } else {
                anyOutput = true;
                if (out > best) best = out;
            }
        }
        if (v.fillers | v.overspenders != 0) return v;
        // A main that delivered nothing counts as an output, until a main is dropped: then the router forgets it
        if (v.zeros != 0 && v.dropped == 0) anyOutput = true;
        v.expected = anyOutput
            ? abi.encodeWithSelector(RouteRaceEngine.InsufficientOutput.selector, best, plan.minOut)
            : abi.encodeWithSelector(RouteRaceEngine.AllRoutesFailed.selector);
    }

    /// @dev The mains of a competition are all trialed. The routes after them run in order until one wins
    function _mains(Plan memory plan) internal pure returns (uint256) {
        if (plan.entry == RACE) return plan.scripts.length;
        return plan.entry == RACE_WITH_BACKUPS && plan.mainCount != 1 ? plan.mainCount : 0;
    }

    /// @dev One run of route `i` once the router has approved the spenders of the first `granted` routes.
    /// A route that fails softly or cannot pull what its script says counts as one that reverts
    function _simulate(Plan memory plan, uint256 i, uint256 granted) internal view returns (bool ok, uint256 out) {
        Script memory s = plan.scripts[i];
        if (s.fail || s.value > _valueLimit(plan) || (s.value != 0 && plan.tokenOut == address(0))) return (false, 0);
        if (plan.tokenIn != address(0)) {
            uint256 own = _allowance(plan, s.spender, granted);
            if (own < s.spend) return (false, 0);
            if (s.extra != 0) {
                // The token spends an allowance as it is used, unless it is the maximum
                uint256 second = s.via != s.spender
                    ? _allowance(plan, s.via, granted)
                    : own == type(uint256).max ? own : own - s.spend;
                uint256 left = tokenA.balanceOf(address(router)) + plan.amountIn - s.spend;
                if (second < s.extra || left < s.extra) return (false, 0);
            }
        }
        if (s.cut != 0 && _allowance(plan, plan.scripts[s.watch].spender, granted) != 0) {
            return s.cut > s.out ? (false, 0) : (true, s.out - s.cut);
        }
        // The token stops a route that removes more than the holder has. The router rejects one that leaves the
        // holder less than it had: one that removes more than it mints. The rest of the mint is its output
        if (s.burn > plan.held || s.burn > s.out) return (false, 0);
        return (true, s.out - s.burn);
    }

    /// @dev The router's tokenIn allowance to `spender` once the first `granted` routes have been approved
    function _allowance(Plan memory plan, address spender, uint256 granted) internal view returns (uint256 kept) {
        kept = tokenA.allowance(address(router), spender);
        for (uint256 j; j < granted; ++j) {
            if (plan.scripts[j].declared != spender) continue;
            if (plan.flags & KEEP_ALLOWANCES == 0) return plan.amountIn;
            return kept < plan.amountIn ? type(uint256).max : kept;
        }
    }

    function _overspends(Plan memory plan, uint256 i) internal pure returns (bool) {
        return plan.tokenIn != address(0) && plan.scripts[i].spend + plan.scripts[i].extra > plan.amountIn;
    }

    /// @dev F1 and F3 on the choice of winner. False when there is no ledger to check the fill against
    function _checkWinner(Plan memory plan, Verdict memory v, uint256 winner) internal returns (bool) {
        string memory who = string.concat("filled by route ", vm.toString(winner));
        uint256 mains = _mains(plan);
        // The routes after the mains run only when no main can be committed
        if (winner >= mains && (v.fillers | v.overspenders) & ((1 << mains) - 1) != 0) {
            _violate("L1", string.concat(who, ", which is not a main, though a main can win"));
        }
        if (v.fillers >> winner & 1 != 0) return true;
        if (v.dropped >> winner & 1 != 0) {
            _violate(
                "F3",
                string.concat(
                    who,
                    ", a main that delivered ",
                    vm.toString(v.trials[winner]),
                    " in its trial and ",
                    vm.toString(v.delivers[winner]),
                    " when run again; min ",
                    vm.toString(plan.minOut)
                )
            );
            return true;
        }
        if (winner >= plan.scripts.length) {
            _violate("F3", string.concat(who, ", which does not exist"));
            return false;
        }
        Script memory s = plan.scripts[winner];
        if (s.value > _valueLimit(plan)) {
            _violate("F1", string.concat(who, ", sent ", vm.toString(s.value), " native, more than the race allows"));
            return false;
        }
        if (_overspends(plan, winner)) {
            _violate("F1", string.concat(who, ", which takes ", vm.toString(s.extra), " more than amountIn"));
            return false;
        }
        (bool ok,) = _simulate(plan, winner, winner + 1);
        if (!ok) {
            _violate("F3", string.concat(who, ", which is not a route that can deliver"));
            return false;
        }
        _violate("L1", string.concat(who, ", which does not reach the minimum"));
        return true;
    }

    /// @dev L1 on a revert: exact data, and only where the scripts explain it. False on a violation
    function _checkRevert(Plan memory plan, Verdict memory v, bytes memory err, uint256[3][] memory before)
        internal
        returns (bool)
    {
        if (v.fillers | v.overspenders != 0) {
            // A route can win, so one revert left is the router committing a greedy route
            for (uint256 i; i < plan.scripts.length; ++i) {
                Script memory s = plan.scripts[i];
                bytes memory overspent = abi.encodeWithSelector(
                    RouteRaceEngine.InputOverspent.selector, plan.amountIn + s.extra, plan.amountIn
                );
                if (v.overspenders >> i & 1 == 0 || keccak256(err) != keccak256(overspent)) continue;
                ++reach["revert.InputOverspent"];
                ++reach[s.via == s.spender ? "greedy.ownAllowance" : "greedy.otherAllowance"];
                if (v.fillers != 0) ++reach["greedy.beatHonest"];
                return true;
            }
            // The other is the command after the race: told to move more than some route's fill leaves on the
            // router, and not allowed to fail. The race is rolled back with it
            bool unpaid = plan.cleanup && !plan.cleanupMayFail && keccak256(err) == keccak256(_unpaid(plan));
            for (uint256 i; unpaid && i < plan.scripts.length; ++i) {
                if (v.fillers >> i & 1 == 0) continue;
                (, uint256 left,) = _predict(plan, i, v.delivers[i], before);
                if (plan.cleanupAmount <= left) continue;
                ++reach[plan.cleanupAsset == NATIVE ? "cleanup.native.reverted" : "cleanup.erc20.reverted"];
                return true;
            }
            _violate(
                "L1",
                string.concat(
                    "reverted with ",
                    vm.toString(err),
                    v.fillers != 0 ? " though a route can fill" : ", expected InputOverspent from a greedy route"
                )
            );
            return false;
        }
        if (keccak256(err) != keccak256(v.expected)) {
            _violate("L1", string.concat("reverted with ", vm.toString(err), ", expected ", vm.toString(v.expected)));
            return false;
        }
        if (bytes4(err) == RouteRaceEngine.AllRoutesFailed.selector) {
            ++reach["revert.AllRoutesFailed"];
        } else {
            ++reach["revert.InsufficientOutput"];
            // An honest route that delivers nothing still counts as a route that ran
            bytes memory zero = abi.encodeWithSelector(RouteRaceEngine.InsufficientOutput.selector, 0, plan.minOut);
            if (keccak256(err) == keccak256(zero)) ++reach["revert.InsufficientOutputZero"];
        }
        return true;
    }

    /// @dev F3 on the returned amount, then F1, F3 and F4 as one exact ledger over every holder. Returns what
    /// the ledger says the race left on the router of the asset a cleanup command moves
    function _checkFill(
        Plan memory plan,
        Verdict memory v,
        uint256 winner,
        uint256 amountOut,
        uint256[3][] memory before,
        uint256[] memory callsBefore
    ) internal returns (uint256 left) {
        if (amountOut < plan.minOut) {
            _violate("F3", string.concat("amountOut ", vm.toString(amountOut), " < min ", vm.toString(plan.minOut)));
        }
        if (amountOut != v.delivers[winner]) {
            _violate(
                "F3",
                string.concat("amountOut ", vm.toString(amountOut), " != scripted ", vm.toString(v.delivers[winner]))
            );
        }

        int256[3][] memory want;
        (want, left,) = _predict(plan, winner, v.delivers[winner], before);
        uint256 outAsset = _asset(plan.tokenOut);
        for (uint256 h; h < holders.length; ++h) {
            for (uint256 a; a < 3; ++a) {
                int256 got = int256(_balance(holders[h], a)) - int256(before[h][a]);
                if (got == want[h][a]) continue;
                bool loser = h >= FIRST_PROVIDER && h != FIRST_PROVIDER + winner;
                _violate(
                    loser ? "F4" : holders[h] == plan.recipient && a == outAsset ? "F3" : "F1",
                    string.concat(
                        holderNames[h],
                        a == TOKEN_A ? " tokenA" : a == TOKEN_B ? " tokenB" : " native",
                        " changed by ",
                        vm.toString(got),
                        ", expected ",
                        vm.toString(want[h][a])
                    )
                );
            }
        }

        for (uint256 i; i < SLOTS; ++i) {
            uint256 ran = providers[i].calls() - callsBefore[i];
            if (ran != (i == winner ? 1 : 0)) {
                _violate("F4", string.concat(holderNames[FIRST_PROVIDER + i], " kept ", vm.toString(ran), " runs"));
            }
        }
    }

    /// @dev L1 on the command after the race, which found `left` of its asset on the router: it succeeds unless
    /// it is told to move more than that, and only a command that allows failure lets the multicall go on past
    /// its failure. The ledger has checked what it moved, which is counted here
    function _checkCleanup(Plan memory plan, Verdict memory v, uint256 winner, Result memory result, uint256 left)
        internal
    {
        bool paid = plan.cleanupAmount <= left;
        if (!paid && !plan.cleanupMayFail) {
            _violate("L1", "filled though the command after the race cannot be paid and may not fail");
            return;
        }
        if (result.success != paid || keccak256(result.returnData) != keccak256(paid ? bytes("") : _unpaid(plan))) {
            _violate(
                "L1",
                string.concat(
                    "the command after the race ",
                    result.success ? "returned " : "failed with ",
                    vm.toString(result.returnData),
                    paid ? ", expected it to succeed" : ", expected a failed transfer"
                )
            );
            return;
        }
        bool native = plan.cleanupAsset == NATIVE;
        string memory kind = native ? "cleanup.native" : "cleanup.erc20";
        if (!paid) {
            ++reach[string.concat(kind, ".failedAllowed")];
            return;
        }
        if (plan.cleanupMayFail) ++reach["cleanup.allowFailure"];
        if (left == 0) {
            ++reach["cleanup.nothingToMove"];
            return;
        }
        if (plan.cleanupAmount != 0) {
            ++reach[plan.cleanupAmount < left ? "cleanup.explicitBelowBalance" : "cleanup.explicitWholeBalance"];
        }
        if (plan.cleanupTo == address(router)) {
            ++reach[native ? "cleanup.native.zeroRecipient" : "cleanup.erc20.toRouter"];
            return;
        }
        Script memory won = plan.scripts[winner];
        bool unspent; // the race left input on the router
        if (native) {
            ++reach["cleanup.native.moved"];
            // The final sweep finds what an explicit amount leaves
            if (plan.cleanupAmount != 0 && plan.cleanupAmount < left && plan.refundTo != address(router)) {
                ++reach["cleanup.native.restSwept"];
            }
            unspent = plan.tokenIn == address(0) && won.value < plan.amountIn;
        } else if (plan.cleanupAsset == _asset(plan.tokenIn)) {
            ++reach["cleanup.erc20.tokenIn"];
            // The proxy's sweep of the token it transferred finds what an explicit amount leaves
            if (
                !plan.direct && plan.cleanupAmount != 0 && plan.cleanupAmount < left && plan.refundTo != address(router)
            ) ++reach["cleanup.erc20.restSwept"];
            unspent =
                won.spend < plan.amountIn && (plan.flags & NO_INPUT_REFUND != 0 || plan.refundTo == address(router));
        } else if (plan.cleanupAsset == _asset(plan.tokenOut)) {
            ++reach["cleanup.erc20.tokenOut"];
        }
        // All the router holds includes what the race left there
        if (plan.cleanupAmount != 0) return;
        if (unspent) ++reach[string.concat(kind, ".tookUnspentInput")];
        if (plan.cleanupAsset == _asset(plan.tokenOut) && plan.recipient == address(router) && v.delivers[winner] != 0)
        {
            ++reach[string.concat(kind, ".tookOutput")];
        }
    }

    /// @dev What a cleanup reverts with when it is told to move more than the router holds: the error of the
    /// router's transfer library, whatever the token says
    function _unpaid(Plan memory plan) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            plan.cleanupAsset == NATIVE
                ? SafeTransferLib.ETHTransferFailed.selector
                : SafeTransferLib.TransferFailed.selector
        );
    }

    /// @dev The balance changes the script predicts for a fill by `winner`, which delivers `out`, what the
    /// race then leaves on the router of the asset a cleanup command moves, and what the proxy's sweep sends to
    /// the refund address once the multicall has returned
    function _predict(Plan memory plan, uint256 winner, uint256 out, uint256[3][] memory before)
        internal
        view
        returns (int256[3][] memory want, uint256 left, uint256 swept)
    {
        want = new int256[3][](holders.length);
        Script memory won = plan.scripts[winner];
        address self = address(router);
        address provider = address(providers[winner]);
        address refund = plan.refundTo == address(0) ? address(this) : plan.refundTo;
        uint256 inAsset = _asset(plan.tokenIn);
        uint256 outAsset = _asset(plan.tokenOut);

        // Input: user to router, the winner's spend to the winner, the rest refunded or kept. Native goes
        // with the call, and what is left of it waits for the sweep
        _move(want, address(this), self, NATIVE, plan.value);
        _move(want, self, provider, NATIVE, won.value);
        if (inAsset != NATIVE) {
            _move(want, address(this), self, inAsset, plan.amountIn);
            _move(want, self, provider, inAsset, won.spend);
            if (plan.flags & NO_INPUT_REFUND == 0) _move(want, self, refund, inAsset, plan.amountIn - won.spend);
        }

        // Output: minted to the output holder, or paid to it by the winner, then on to the recipient
        address holder = plan.flags & DIRECT_OUTPUT != 0 ? plan.recipient : self;
        if (outAsset == NATIVE) _move(want, provider, holder, NATIVE, out);
        else want[_index(holder)][outAsset] += int256(out);
        _move(want, holder, plan.recipient, outAsset, out);

        // The command after the race moves the amount it is told, or all the router holds by then: what was
        // there before, unspent input, the output of a race the router is the recipient of. Told to move more
        // than that, it fails and moves nothing
        if (plan.cleanup) {
            int256 has = int256(before[ROUTER][plan.cleanupAsset]) + want[ROUTER][plan.cleanupAsset];
            left = has > 0 ? uint256(has) : 0;
            if (plan.cleanupAmount <= left) {
                _move(
                    want, self, plan.cleanupTo, plan.cleanupAsset, plan.cleanupAmount == 0 ? left : plan.cleanupAmount
                );
            }
        }

        // The multicall ends by sweeping the router's native to the refund address
        int256 rest = int256(before[ROUTER][NATIVE]) + want[ROUTER][NATIVE];
        if (rest > 0) _move(want, self, refund, NATIVE, uint256(rest));

        // Once a multicall it sent has returned, the proxy has the router send all it holds of the token the
        // proxy transferred to the refund address: input the race kept, and what stood on the router before the
        // multicall. Nothing follows a multicall sent straight to the router, and with a native input the proxy
        // transferred no token
        if (!plan.direct && inAsset != NATIVE) {
            rest = int256(before[ROUTER][inAsset]) + want[ROUTER][inAsset];
            if (rest > 0) {
                swept = uint256(rest);
                _move(want, self, refund, inAsset, swept);
            }
        }
    }

    /// @dev The hostile routes a race ran, counted once its outcome has matched the model
    function _countRoutes(Plan memory plan, Verdict memory v, uint256[3][] memory before) internal {
        for (uint256 i; i < plan.scripts.length; ++i) {
            Script memory s = plan.scripts[i];
            if (s.fail || v.reached >> i & 1 == 0) continue;
            if (s.value > _valueLimit(plan)) {
                ++reach["soft.ExcessiveRouteValue"];
                // The router holds that much native, so only the limit keeps it from the route
                if (s.value <= before[ROUTER][NATIVE] + plan.value) ++reach["soft.ExcessiveRouteValueFunded"];
            } else if (s.value != 0 && plan.tokenOut == address(0)) {
                ++reach["soft.ValueOnNativeOutput"];
            } else if (s.extra != 0) {
                (bool ok,) = _simulate(plan, i, i + 1);
                if (!ok) ++reach["greedy.cannotPull"];
            }
        }
    }

    /// @dev What became of the fading routes, once the race's outcome has matched the model
    function _countFading(Plan memory plan, Verdict memory v, uint256 winner, Vm.Log[] memory logs) internal {
        uint256[] memory runs = _runs(logs);
        uint256 mains = _mains(plan);
        uint256 removed;
        for (uint256 i; i < mains; ++i) {
            if (v.dropped >> i & 1 == 0) continue;
            Script memory s = plan.scripts[i];
            if (runs[i] < 2) {
                // Another main was committed before the router came back to this one
                if (winner != NO_ROUTE) ++reach["fade.neverRunAgain"];
                continue;
            }
            ++removed;
            ++reach[
                s.cut > s.out
                    ? "fade.revertsWhenRunAgain"
                    : s.out - s.cut < plan.minOut ? "fade.belowMinimum" : "fade.aboveMinimum"
            ];
        }
        if (removed > 1) ++reach["fade.twoDropped"];
        if (removed != 0 && winner != NO_ROUTE) {
            ++reach[winner < mains ? "fade.nextMainFills" : "fade.backupFills"];
        } else if (removed != 0 && v.expected.length != 0) {
            bool allFailed = v.expected.length == 4;
            ++reach[
                plan.entry == RACE
                    ? allFailed ? "fade.race.AllRoutesFailed" : "fade.race.InsufficientOutput"
                    : allFailed ? "fade.backups.AllRoutesFailed" : "fade.backups.InsufficientOutput"
            ];
            // Had no main been removed, a main that delivered nothing would have made it InsufficientOutput(0, min)
            if (allFailed && v.zeros != 0) ++reach["fade.zeroMainForgotten"];
        }
        if (winner == NO_ROUTE || plan.scripts[winner].cut == 0) return;

        // A fading route was committed. Its watched spender may be approved between its trial and its second run.
        // The router approves a spender at the first route that declares it, if one does
        Script memory won = plan.scripts[winner];
        uint256 watched;
        while (watched < plan.scripts.length && plan.scripts[watched].declared != plan.scripts[won.watch].spender) {
            ++watched;
        }
        bool between = watched > winner && watched < mains;
        if (v.delivers[winner] > v.trials[winner]) {
            ++reach["fade.deliversMore"];
        } else if (v.trials[winner] != won.out) {
            // It saw an allowance in its trial already: one of this race, or one kept from an earlier race
            if (watched <= winner) ++reach["fade.fadedInTrial"];
            else if (between && plan.amountIn != 0) ++reach["fade.hiddenByKeptAllowance"];
        } else if (between && plan.amountIn == 0) {
            ++reach["fade.zeroAmountIn"];
        }
    }

    /// @dev What became of the lowering routes, once the race's outcome has matched the model. A lowering route
    /// has no other twist, so one that does not revert by its script gets as far as its burn
    function _countLowering(Plan memory plan, Verdict memory v, uint256 winner) internal {
        uint256 mains = _mains(plan);
        for (uint256 i; i < plan.scripts.length; ++i) {
            Script memory s = plan.scripts[i];
            // The token, not the router, stops a route that removes more than the holder has
            if (s.fail || s.burn == 0 || s.burn > plan.held || v.reached >> i & 1 == 0) continue;
            if (s.burn == s.out) ++reach["lower.zeroOutput"];
            if (s.burn <= s.out) continue;
            // It removes more than it mints from a holder that has it: only the router's check rejects it
            ++reach[
                plan.recipient == address(router)
                    ? "lower.rejected.routerIsRecipient"
                    : plan.flags & DIRECT_OUTPUT != 0 ? "lower.rejected.recipientHolds" : "lower.rejected.routerPays"
            ];
            // A main that is not the last main is only trialed. Any other route is committed if its run suffices
            ++reach[i + 1 < mains ? "lower.rejected.inTrial" : "lower.rejected.couldCommit"];
            // A later route that delivers what it is scripted to fills all the same
            if (winner != NO_ROUTE && winner > i && plan.scripts[winner].burn | plan.scripts[winner].cut == 0) {
                ++reach["lower.rejected.honestFillsAfter"];
            }
        }
        // _checkFill has compared amountOut with what the route mints less what it removes
        if (winner != NO_ROUTE && plan.scripts[winner].burn != 0) ++reach["lower.fill"];
    }

    /// @dev The fills by a route that pulled input through a spender other than its own target, once the fill
    /// has matched the model: a separate spender, or the target of another route that declares itself, so that
    /// the two routes use one allowance
    function _countSpenders(Plan memory plan, Verdict memory v, uint256 winner) internal {
        if (winner == NO_ROUTE || v.fillers >> winner & 1 == 0) return;
        if (plan.tokenIn == address(0) || plan.scripts[winner].spend == 0) return;
        address spender = plan.scripts[winner].spender;
        string memory flag = plan.flags & KEEP_ALLOWANCES != 0 ? ".flag2" : "";
        if (spender == address(spenders[0]) || spender == address(spenders[1])) {
            // No other route can be committed, so without this allowance the race has no winner
            if (v.fillers | v.overspenders == 1 << winner) ++reach[string.concat("spender.separate.onlyFiller", flag)];
            for (uint256 j; j < winner; ++j) {
                if (plan.scripts[j].declared != spender) continue;
                ++reach[string.concat("spender.separate.sharedWithEarlier", flag)];
                break;
            }
            return;
        }
        for (uint256 j; j < plan.scripts.length; ++j) {
            if (j == winner || spender != address(providers[j]) || plan.scripts[j].declared != spender) continue;
            ++reach[string.concat(j > winner ? "spender.laterTarget" : "spender.earlierTarget", flag)];
        }
    }

    /// @dev A1 on the router's tokenA allowance to each spender a race can name: the four route targets and the
    /// two spenders that are no route's target. `allowed` is what each held before the multicall; `winner` is
    /// NO_ROUTE when it reverted
    function _checkAllowances(Plan memory plan, uint256 winner, uint256[] memory allowed) internal {
        // A winner that does not exist says nothing about the routes reached. _checkWinner reports it
        if (winner != NO_ROUTE && winner >= plan.scripts.length) return;
        for (uint256 k; k < allowed.length; ++k) {
            address spender = holders[FIRST_PROVIDER + k];
            uint256 want = _allowanceAfter(plan, winner, spender, allowed[k]);
            uint256 got = tokenA.allowance(address(router), spender);
            if (got == want) {
                _countAllowance(plan, winner, k, allowed[k], got);
                continue;
            }
            _violate(
                "A1",
                string.concat(
                    holderNames[FIRST_PROVIDER + k],
                    " tokenA allowance is ",
                    vm.toString(got),
                    " after ",
                    plan.entry == RACE ? "race" : plan.entry == RACE_SINGLE ? "raceSingle" : "raceWithBackups",
                    plan.flags & KEEP_ALLOWANCES != 0 ? " under flag 2" : "",
                    winner == NO_ROUTE
                        ? ", which reverted"
                        : string.concat(
                            ", filled by route ",
                            vm.toString(winner),
                            " with ",
                            vm.toString(_trialed(plan, winner)),
                            " reached"
                        ),
                    ", expected ",
                    vm.toString(want),
                    "; before ",
                    vm.toString(allowed[k])
                )
            );
        }
    }

    /// @dev What a race leaves of the tokenA allowance `spender` held before it. A revert and a native input
    /// leave it as it was. A fill without flag 2 leaves none to the spender of a route the router reached,
    /// whatever it held. Under flag 2 the router raises such a spender to the maximum unless it held amountIn
    /// or more. After that an allowance loses only what the committed run pulls through it, and the token takes
    /// nothing off the maximum
    function _allowanceAfter(Plan memory plan, uint256 winner, address spender, uint256 held)
        internal
        pure
        returns (uint256 kept)
    {
        if (winner == NO_ROUTE || plan.tokenIn == address(0)) return held;
        bool reached = _declares(plan, spender, 0, _trialed(plan, winner));
        if (reached && plan.flags & KEEP_ALLOWANCES == 0) return 0;
        kept = reached && held < plan.amountIn ? type(uint256).max : held;
        if (kept == type(uint256).max) return kept;
        uint256 pulled = _pulled(plan.scripts[winner], spender);
        return kept < pulled ? 0 : kept - pulled;
    }

    /// @dev The classes of A1, each counted per spender whose allowance `got` is the one the model expects. It
    /// held `held` before the multicall. A race without input grants nothing, so it shows no revoke either
    function _countAllowance(Plan memory plan, uint256 winner, uint256 k, uint256 held, uint256 got) internal {
        address spender = holders[FIRST_PROVIDER + k];
        bool keep = plan.flags & KEEP_ALLOWANCES != 0;
        if (winner == NO_ROUTE) {
            // Route 0 is the one route every race reaches. Without flag 2 the router approved amountIn over
            // what its spender held, and the revert brought that back
            if (plan.tokenIn != address(0) && !keep && held != 0 && plan.scripts[0].declared == spender) {
                ++reach["allowance.revert.kept"];
            }
            return;
        }
        uint256 trialed = _trialed(plan, winner);
        bool reached = _declares(plan, spender, 0, trialed);
        if (plan.tokenIn == address(0)) {
            if (reached && !keep && held != 0) ++reach["allowance.nativeIn.kept"];
            return;
        }
        if (keep) {
            if (!reached) return;
            if (held < plan.amountIn) ++reach["allowance.flag2.granted"];
            else if (held == type(uint256).max) ++reach["allowance.flag2.keptMaximum"];
            else if (got < held) ++reach["allowance.flag2.finiteSpent"];
            return;
        }
        if (!reached) {
            // The spender of a route the router did not get to, and of no route it did
            if (held != 0 && got == held && _declares(plan, spender, trialed, plan.scripts.length)) {
                ++reach["allowance.notReached.kept"];
            }
            return;
        }
        if (plan.amountIn == 0) return;
        if (held != 0) ++reach["allowance.earlier.cleared"];
        Script memory w = plan.scripts[winner];
        if (w.declared == spender) {
            if (_pulled(w, spender) < plan.amountIn) ++reach["allowance.winner.unspentCleared"];
            return;
        }
        // Only routes that lost declare it
        ++reach[
            plan.entry == RACE
                ? "allowance.loser.race"
                : plan.entry == RACE_SINGLE
                    ? "allowance.loser.raceSingle"
                    : winner < plan.mainCount ? "allowance.loser.backups.mainWon" : "allowance.loser.backups.backupWon"
        ];
        if (k >= SLOTS) {
            ++reach["allowance.loser.separateSpender"];
            return;
        }
        for (uint256 j; j < trialed; ++j) {
            if (j == k || plan.scripts[j].declared != spender) continue;
            ++reach["allowance.loser.otherTarget"];
            break;
        }
    }

    /// @dev The routes the router has reached when it commits `winner`: every main, or with no main to commit
    /// the routes up to the winner. The router calls it trialedCount
    function _trialed(Plan memory plan, uint256 winner) internal pure returns (uint256) {
        uint256 mains = _mains(plan);
        return winner < mains ? mains : winner + 1;
    }

    /// @dev Whether one of the routes `from` to `to - 1` declares `spender`
    function _declares(Plan memory plan, address spender, uint256 from, uint256 to) internal pure returns (bool) {
        for (uint256 j = from; j < to; ++j) {
            if (plan.scripts[j].declared == spender) return true;
        }
        return false;
    }

    /// @dev What one run of a route takes through the allowance of `spender`
    function _pulled(Script memory s, address spender) internal pure returns (uint256) {
        return (s.spender == spender ? s.spend : 0) + (s.via == spender ? s.extra : 0);
    }

    /// @dev A2 on every approval the router gave during the multicall, also one that reverted. The tokens' approve
    /// emits Approval and their transferFrom does not, so each Approval with the router as owner is one the
    /// router gave. Each has to name a spender that a reached route declares, on the input token, for amountIn
    /// (the maximum under flag 2) or for zero. A fill reached the routes below trialedCount
    function _checkApprovals(Plan memory plan, Verdict memory v, uint256 winner, Vm.Log[] memory logs) internal {
        uint256 n = plan.scripts.length;
        uint256 reached = winner == NO_ROUTE || winner >= n ? v.reached : (1 << _trialed(plan, winner)) - 1;
        uint256 grant = plan.flags & KEEP_ALLOWANCES != 0 ? type(uint256).max : plan.amountIn;
        uint256 seen;
        bool wrong;
        for (uint256 k; k < logs.length; ++k) {
            Vm.Log memory log = logs[k];
            if (log.topics.length != 3 || log.topics[0] != APPROVAL) continue;
            if (address(uint160(uint256(log.topics[1]))) != address(router)) continue;
            ++seen;
            address spender = address(uint160(uint256(log.topics[2])));
            uint256 amount = abi.decode(log.data, (uint256));
            bool declared;
            for (uint256 j; j < n && !declared; ++j) {
                declared = reached >> j & 1 != 0 && plan.scripts[j].declared == spender;
            }
            if (spender != address(0) && declared && log.emitter == plan.tokenIn && (amount == 0 || amount == grant)) {
                continue;
            }
            wrong = true;
            _violate(
                "A2",
                string.concat(
                    log.emitter == address(tokenA) ? "tokenA" : log.emitter == address(tokenB) ? "tokenB" : "a token",
                    " approval of ",
                    vm.toString(amount),
                    " to ",
                    _name(spender),
                    " in ",
                    plan.entry == RACE ? "race" : plan.entry == RACE_SINGLE ? "raceSingle" : "raceWithBackups",
                    plan.tokenIn == address(0) ? " with native input" : "",
                    plan.flags & KEEP_ALLOWANCES != 0 ? " under flag 2" : "",
                    winner == NO_ROUTE ? ", which reverted" : string.concat(", filled by route ", vm.toString(winner)),
                    declared ? "" : ", which no reached route declares",
                    "; amountIn ",
                    vm.toString(plan.amountIn)
                )
            );
        }
        if (seen == 0 || wrong) return;
        ++reach["approval.inOrder"];
        for (uint256 j; j < n; ++j) {
            if (reached >> j & 1 == 0 || plan.scripts[j].declared != address(0)) continue;
            ++reach["approval.withNoSpender"];
            break;
        }
    }

    /// @dev The routes that declare no spender, once the race's outcome has matched the model. `allowed` is what
    /// each provider and separate spender held before the multicall
    function _countNoSpender(Plan memory plan, Verdict memory v, uint256 winner, uint256[] memory allowed) internal {
        bool erc20 = plan.tokenIn != address(0);
        uint256 reached = winner == NO_ROUTE ? v.reached : (1 << _trialed(plan, winner)) - 1;
        for (uint256 i; i < plan.scripts.length; ++i) {
            Script memory s = plan.scripts[i];
            if (s.declared != address(0) || reached >> i & 1 == 0) continue;
            if (winner != NO_ROUTE && i != winner) ++reach["noSpender.loserTrialed"];
            // It gets as far as its pull, and nothing gave its target an allowance that covers it
            if (!erc20 || s.fail || s.spend == 0 || s.value > _valueLimit(plan)) continue;
            if (s.value != 0 && plan.tokenOut == address(0)) continue;
            if (_allowance(plan, s.spender, i + 1) < s.spend) ++reach["noSpender.noAllowance"];
        }
        if (winner == NO_ROUTE || plan.scripts[winner].declared != address(0)) return;
        Script memory w = plan.scripts[winner];
        ++reach["noSpender.won"];
        if (!erc20) {
            ++reach["noSpender.nativeIn"];
        } else if (w.spend == 0) {
            ++reach["noSpender.noPull"];
        } else if (_declares(plan, w.spender, 0, _trialed(plan, winner))) {
            ++reach["noSpender.otherDeclared"];
        } else if (allowed[winner] == type(uint256).max) {
            ++reach["noSpender.keptMaximum"];
        }
    }

    /// @dev The ledger name of a holder, or its address
    function _name(address holder) internal view returns (string memory) {
        for (uint256 h; h < holders.length; ++h) {
            if (holders[h] == holder) return holderNames[h];
        }
        return vm.toString(holder);
    }

    /// @dev The router's tokenA allowance to each provider and to each separate spender, in ledger order
    function _allowances() internal view returns (uint256[] memory all) {
        all = new uint256[](SLOTS + spenders.length);
        for (uint256 k; k < all.length; ++k) {
            all[k] = tokenA.allowance(address(router), holders[FIRST_PROVIDER + k]);
        }
    }

    /// @dev How often each provider ran since recordLogs, with the runs the router rolled back
    function _runs(Vm.Log[] memory logs) internal view returns (uint256[] memory runs) {
        runs = new uint256[](SLOTS);
        for (uint256 k; k < logs.length; ++k) {
            if (logs[k].topics.length != 1 || logs[k].topics[0] != ScriptedRouteProvider.Ran.selector) continue;
            for (uint256 i; i < SLOTS; ++i) {
                if (logs[k].emitter == address(providers[i])) ++runs[i];
            }
        }
    }

    function _countFill(Plan memory plan, Verdict memory v, uint256 winner, uint256[3][] memory before) internal {
        ++reach[
            plan.entry == RACE ? "fill.race" : plan.entry == RACE_SINGLE ? "fill.raceSingle" : "fill.raceWithBackups"
        ];
        if (v.overspenders != 0) ++reach["fill.besideGreedy"];
        if (plan.tokenIn == address(0) && plan.value > plan.amountIn) ++reach["fill.nativeSurplus"];
        if (plan.tokenIn != address(0) && plan.value != 0) ++reach["fill.nativeBudget"];
        if (plan.tokenIn != address(0) && plan.scripts[winner].value != 0) ++reach["fill.routeValue"];
        uint256[3] memory held = before[ROUTER];
        if (held[TOKEN_A] != 0 && held[TOKEN_B] != 0 && held[NATIVE] != 0) ++reach["fill.routerHeldBalances"];
        if (winner != 0) ++reach["fill.winnerNonZero"];
        if (plan.entry == RACE_WITH_BACKUPS && winner >= plan.mainCount) ++reach["fill.backup"];
        if (plan.flags & EMIT_EVENTS != 0) ++reach["fill.flag1"];
        if (plan.flags & KEEP_ALLOWANCES != 0) ++reach["fill.flag2"];
        if (plan.flags & DIRECT_OUTPUT != 0) ++reach["fill.flag4"];
        if (plan.tokenIn == address(0)) ++reach["fill.nativeIn"];
        if (plan.tokenOut == address(0)) ++reach["fill.nativeOut"];
        if (plan.direct) ++reach["fill.direct"];
        if (plan.scripts[winner].feePpm != 0) ++reach["fill.feeOnWinner"];
        for (uint256 i; i < plan.scripts.length && plan.entry == RACE; ++i) {
            // In a race of honest routes, one that delivers more than the winner can only lose on its fee
            Script memory s = plan.scripts[i];
            if (!s.fail && s.feePpm != 0 && s.out > plan.scripts[winner].out) {
                ++reach["fill.feeOutranked"];
                break;
            }
        }
        if (plan.flags & NO_INPUT_REFUND != 0) ++reach["fill.flag8"];
        if (plan.flags & LOG_FUNDS_MOVEMENT != 0) ++reach["fill.flag16"];
        if (plan.recipient == address(router)) ++reach["fill.recipientRouter"];
        if (plan.refundTo == address(router)) ++reach["fill.refundRouter"];
        if (plan.amountIn == 0) ++reach["fill.zeroAmountIn"];
        _countUnspent(plan, v, winner, before);
    }

    /// @dev What became of the input the winner left, and of the router's tokenA once the multicall had returned.
    /// A race refunds what its winner leaves, or keeps it on the router: under flag 8, or with the router as
    /// refund address. Nothing follows a multicall sent straight to the router, so there what the race keeps
    /// stays. The proxy follows its multicall with a sweep of the token it transferred: what the race kept goes
    /// to the refund address all the same, with what stood on the router before. With the router as refund
    /// address that moves nothing
    function _countUnspent(Plan memory plan, Verdict memory v, uint256 winner, uint256[3][] memory before) internal {
        bool unspent = plan.tokenIn != address(0) && plan.scripts[winner].spend < plan.amountIn;
        bool flag8 = plan.flags & NO_INPUT_REFUND != 0;
        if (plan.direct) {
            if (unspent) ++reach[flag8 ? "unspent.keptFlag8" : "unspent.refundedToCaller"];
            return;
        }
        if (plan.refundTo == address(router)) {
            if (unspent) ++reach[flag8 ? "unspent.keptFlag8.refundRouter" : "unspent.keptRefundRouter"];
            return;
        }
        if (unspent && !flag8) ++reach["unspent.refunded"];
        (int256[3][] memory want,, uint256 swept) = _predict(plan, winner, v.delivers[winner], before);
        if (plan.tokenIn == address(0)) {
            // The proxy transferred no token, so it sweeps none: the tokenA the router holds stays there
            if (int256(before[ROUTER][TOKEN_A]) + want[ROUTER][TOKEN_A] > 0) ++reach["sweep.noTokenListed"];
        } else if (swept == 0) {
            // A cleanup command took all the router held, or it held none
            ++reach["sweep.nothing"];
        } else {
            // Unless the race kept input, all the sweep moved stood on the router before the multicall
            ++reach[unspent && flag8 ? "unspent.sweptFlag8" : "sweep.standing"];
        }
    }

    function _move(int256[3][] memory want, address from, address to, uint256 asset, uint256 amount) internal view {
        want[_index(from)][asset] -= int256(amount);
        want[_index(to)][asset] += int256(amount);
    }

    function _balances() internal view returns (uint256[3][] memory all) {
        all = new uint256[3][](holders.length);
        for (uint256 h; h < holders.length; ++h) {
            for (uint256 a; a < 3; ++a) {
                all[h][a] = _balance(holders[h], a);
            }
        }
    }

    function _balance(address holder, uint256 asset) internal view returns (uint256) {
        return asset == NATIVE ? holder.balance : (asset == TOKEN_A ? tokenA : tokenB).balanceOf(holder);
    }

    function _calls() internal view returns (uint256[] memory counts) {
        counts = new uint256[](SLOTS);
        for (uint256 i; i < SLOTS; ++i) {
            counts[i] = providers[i].calls();
        }
    }

    function _asset(address token) internal view returns (uint256) {
        return token == address(0) ? NATIVE : token == address(tokenA) ? TOKEN_A : TOKEN_B;
    }

    function _index(address holder) internal view returns (uint256 h) {
        while (holders[h] != holder) ++h;
    }

    function _track(address holder, string memory name) internal {
        holders.push(holder);
        holderNames.push(name);
    }

    function _violate(string memory id, string memory what) internal {
        if (violations[id]++ == 0) {
            firstViolation[id] = string.concat(id, " in race #", vm.toString(races), ": ", what);
        }
    }
}

contract RelayRouterInvariantTest is Test {
    RaceInvariantHandler handler;

    function _deployRouter() internal virtual returns (RelayRouterBase) {
        return new RelayRouter();
    }

    function setUp() public {
        handler = new RaceInvariantHandler(_deployRouter());
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = RaceInvariantHandler.race.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_F1_input() public view {
        _clean("F1");
    }

    function invariant_F3_delivery() public view {
        _clean("F3");
    }

    function invariant_F4_losers() public view {
        _clean("F4");
    }

    function invariant_L1_liveness() public view {
        _clean("L1");
    }

    function invariant_A1_allowances() public view {
        _clean("A1");
    }

    function invariant_A2_approvals() public view {
        _clean("A2");
    }

    /// @dev Fixed inputs. Fails unless every case class the campaign is meant to cover occurred
    function test_reach() public {
        // race: the better route is the second one
        RaceInput memory p = _base(RACE, 2);
        p.routes[0].out = 90;
        p.routes[1].out = 120;
        handler.race(p);

        // The same race with the minimum one above the best output
        p.minOut = 121;
        handler.race(p);

        // raceSingle: the first route misses the minimum, the second fills
        p = _base(RACE_SINGLE, 2);
        p.routes[0].out = 99;
        p.routes[1].out = 100;
        handler.race(p);

        // raceWithBackups: one main reverts, the other misses the minimum, the backup fills
        p = _base(RACE_WITH_BACKUPS, 3);
        p.mainCount = 1; // two mains
        p.routes[0].kind = REVERTS;
        p.routes[1].out = 50;
        p.routes[2].out = 110;
        handler.race(p);

        // Every route reverts
        p = _base(RACE, 2);
        p.routes[0].kind = REVERTS;
        p.routes[1].kind = REVERTS;
        handler.race(p);

        // Each flag alone, then all four, on a route that spends 40% of the input, through the proxy: without
        // flag 8 the race refunds the rest. With it the race leaves the rest on the router, and the proxy's sweep
        // sends it to the refund address once the multicall has returned
        uint8[5] memory flagSets = [1, 2, 8, 16, 27];
        for (uint256 i; i < flagSets.length; ++i) {
            p = _base(RACE, 1);
            p.flags = flagSets[i];
            p.routes[0] = _route(SPENDS_PART, 150, 0.4 ether, 0);
            handler.race(p);
        }

        // The router as recipient, then as refund address, again with unspent input: the race keeps it, and the
        // proxy's sweep sends the router's tokens to the router itself, so it stays. The same under flag 8
        p = _base(RACE_SINGLE, 1);
        p.routes[0] = _route(SPENDS_PART, 150, 0.4 ether, 0);
        p.recipient = TO_ROUTER;
        handler.race(p);
        p.recipient = 0;
        p.refund = TO_ROUTER;
        handler.race(p);
        p.flags = uint8(NO_INPUT_REFUND);
        handler.race(p);

        // Fees only rank. At 50% the route that delivers 200 loses to the one that delivers 150;
        // at 10% it wins and delivers all 200
        p = _base(RACE, 2);
        p.routes[0] = _route(SPENDS_ALL, 200, 0, FEE_50_PERCENT);
        p.routes[1] = _route(SPENDS_ALL, 150, 0, 0);
        handler.race(p);
        p.routes[0].fee = FEE_10_PERCENT;
        handler.race(p);

        // Native input, native output, and both again with the output sent straight to the recipient.
        // The second route wins and takes 40% of the input
        for (uint256 i; i < 4; ++i) {
            p = _base(RACE, 2);
            p.assets = i % 2 == 0 ? NATIVE_IN : NATIVE_OUT;
            p.flags = i < 2 ? 0 : uint8(DIRECT_OUTPUT);
            p.routes[0] = _route(SPENDS_ALL, 120, 0, 0);
            p.routes[1] = _route(SPENDS_PART, 150, 0.4 ether, 0);
            handler.race(p);
        }

        // Straight to the router with a zero refundTo, for each pair of assets: the caller is refunded
        for (uint8 assets = 1; assets < 4; ++assets) {
            p = _base(RACE_WITH_BACKUPS, 2);
            p.assets = assets;
            p.path = DIRECT;
            p.routes[0] = _route(SPENDS_PART, 150, 0.4 ether, 0);
            handler.race(p);
        }
        // Under flag 8 the unspent 60% stays on the router: nothing follows a multicall sent straight to it
        p = _base(RACE, 1);
        p.path = DIRECT;
        p.flags = uint8(NO_INPUT_REFUND);
        p.routes[0] = _route(SPENDS_PART, 150, 0.4 ether, 0);
        handler.race(p);

        // The edges of the model: an honest route that delivers nothing is not a failed route, and
        // a race may have nothing to spend
        p = _base(RACE_SINGLE, 2);
        p.routes[0].kind = REVERTS;
        handler.race(p);
        p = _base(RACE, 1);
        p.amountIn = 0;
        p.routes[0].out = 150;
        handler.race(p);

        _reachTakers();
        _reachFading();
        _reachLowering();
        _reachSpenders();
        _reachCleanup();
        _reachAllowances();
        _reachNoSpender();

        // Violations first: a wrong router should fail here with its description, not as a missed class
        _clean("F1");
        _clean("F3");
        _clean("F4");
        _clean("L1");
        _clean("A1");
        _clean("A2");

        _reached("allowance.winner.unspentCleared");
        _reached("allowance.loser.race");
        _reached("allowance.loser.raceSingle");
        _reached("allowance.loser.backups.mainWon");
        _reached("allowance.loser.backups.backupWon");
        _reached("allowance.loser.separateSpender");
        _reached("allowance.loser.otherTarget");
        _reached("allowance.notReached.kept");
        _reached("allowance.earlier.cleared");
        _reached("allowance.flag2.granted");
        _reached("allowance.flag2.keptMaximum");
        _reached("allowance.flag2.finiteSpent");
        _reached("allowance.revert.kept");
        _reached("allowance.nativeIn.kept");

        _reached("cleanup.erc20.tokenIn");
        _reached("cleanup.erc20.tokenOut");
        _reached("cleanup.native.moved");
        _reached("cleanup.explicitBelowBalance");
        _reached("cleanup.explicitWholeBalance");
        _reached("cleanup.nothingToMove");
        _reached("cleanup.erc20.tookUnspentInput");
        _reached("cleanup.erc20.tookOutput");
        _reached("cleanup.native.tookUnspentInput");
        _reached("cleanup.native.tookOutput");
        _reached("cleanup.native.restSwept");
        _reached("cleanup.erc20.restSwept");
        _reached("cleanup.erc20.toRouter");
        _reached("cleanup.native.zeroRecipient");
        _reached("cleanup.allowFailure");
        _reached("cleanup.erc20.failedAllowed");
        _reached("cleanup.native.failedAllowed");
        _reached("cleanup.erc20.reverted");
        _reached("cleanup.native.reverted");

        _reached("spender.separate.onlyFiller");
        _reached("spender.separate.onlyFiller.flag2");
        _reached("spender.separate.sharedWithEarlier");
        _reached("spender.separate.sharedWithEarlier.flag2");
        _reached("spender.laterTarget");
        _reached("spender.laterTarget.flag2");
        _reached("spender.earlierTarget");
        _reached("spender.earlierTarget.flag2");

        _reached("noSpender.won");
        _reached("noSpender.noPull");
        _reached("noSpender.nativeIn");
        _reached("noSpender.otherDeclared");
        _reached("noSpender.keptMaximum");
        _reached("noSpender.noAllowance");
        _reached("noSpender.loserTrialed");
        _reached("approval.inOrder");
        _reached("approval.withNoSpender");

        _reached("lower.fill");
        _reached("lower.zeroOutput");
        _reached("lower.rejected.routerPays");
        _reached("lower.rejected.routerIsRecipient");
        _reached("lower.rejected.recipientHolds");
        _reached("lower.rejected.inTrial");
        _reached("lower.rejected.couldCommit");
        _reached("lower.rejected.honestFillsAfter");

        _reached("fade.nextMainFills");
        _reached("fade.backupFills");
        _reached("fade.race.AllRoutesFailed");
        _reached("fade.race.InsufficientOutput");
        _reached("fade.backups.AllRoutesFailed");
        _reached("fade.backups.InsufficientOutput");
        _reached("fade.zeroMainForgotten");
        _reached("fade.twoDropped");
        _reached("fade.neverRunAgain");
        _reached("fade.belowMinimum");
        _reached("fade.aboveMinimum");
        _reached("fade.revertsWhenRunAgain");
        _reached("fade.hiddenByKeptAllowance");
        _reached("fade.zeroAmountIn");
        _reached("fade.deliversMore");
        _reached("fade.fadedInTrial");

        _reached("revert.InputOverspent");
        _reached("greedy.ownAllowance");
        _reached("greedy.otherAllowance");
        _reached("greedy.beatHonest");
        _reached("greedy.cannotPull");
        _reached("fill.besideGreedy");
        _reached("fill.nativeBudget");
        _reached("fill.routeValue");
        _reached("fill.nativeSurplus");
        _reached("soft.ExcessiveRouteValue");
        _reached("soft.ExcessiveRouteValueFunded");
        _reached("soft.ValueOnNativeOutput");

        _reached("revert.InsufficientOutputZero");
        _reached("fill.zeroAmountIn");
        _reached("fill.feeOnWinner");
        _reached("fill.feeOutranked");
        _reached("fill.nativeIn");
        _reached("fill.nativeOut");
        _reached("fill.flag4");
        _reached("fill.direct");
        _reached("unspent.refundedToCaller");
        _reached("unspent.keptRefundRouter");

        _reached("fill.flag1");
        _reached("fill.flag2");
        _reached("fill.flag8");
        _reached("fill.flag16");
        _reached("fill.recipientRouter");
        _reached("fill.refundRouter");
        _reached("fill.routerHeldBalances");
        _reached("unspent.refunded");
        _reached("unspent.keptFlag8");
        _reached("unspent.keptFlag8.refundRouter");
        _reached("unspent.sweptFlag8");
        _reached("sweep.standing");
        _reached("sweep.nothing");
        _reached("sweep.noTokenListed");
        _reached("fill.race");
        _reached("fill.raceSingle");
        _reached("fill.raceWithBackups");
        _reached("fill.winnerNonZero");
        _reached("fill.backup");
        _reached("revert.AllRoutesFailed");
        _reached("revert.InsufficientOutput");
    }

    /// @dev Routes that take too much: more tokenIn than amountIn, more native than the race may send
    function _reachTakers() internal {
        // Greedy under flag 2: its own allowance is the maximum, and the router holds 7 more than the input.
        // The only route that reaches the minimum, so the race reverts with InputOverspent
        RaceInput memory p = _base(RACE, 2);
        p.flags = uint8(KEEP_ALLOWANCES);
        p.routes[0] = _twisted(120, GREEDY, 4);
        p.routes[1].out = 90;
        handler.race(p);

        // Greedy through the previous route's allowance, and the better of the two: the honest route is lost.
        // In order instead, the honest route wins before the greedy one runs
        p = _base(RACE, 2);
        p.routes[0].out = 110;
        p.routes[1] = _twisted(120, GREEDY, 4);
        handler.race(p);
        p.entry = RACE_SINGLE;
        handler.race(p);

        // Greedy with nothing to pull through: first in line, without flag 2. It reverts and the next one fills
        p = _base(RACE, 2);
        p.routes[0] = _twisted(120, GREEDY, 4);
        p.routes[1].out = 110;
        handler.race(p);
        // Under flag 2 the same route pulls through its own allowance, and wins again
        p.flags = uint8(KEEP_ALLOWANCES);
        handler.race(p);

        // ERC-20 input with a native budget of 1000 on top of the 13 the router holds. The first route is
        // sent 301 of it, the second asks for more than the budget and fails softly
        p = _base(RACE, 2);
        p.budget = WITH_SURPLUS;
        p.surplus = 1000;
        p.routes[0] = _twisted(120, VALUE_WITHIN, 300);
        p.routes[1] = _twisted(150, VALUE_ABOVE, 5);
        handler.race(p);

        // Native input with more value than amountIn: no route may be sent the surplus
        p.assets = NATIVE_IN;
        handler.race(p);

        // Native output: a route that is sent any value fails softly
        p = _base(RACE, 2);
        p.assets = NATIVE_OUT;
        p.budget = WITH_SURPLUS;
        p.surplus = 1000;
        p.routes[0] = _twisted(150, VALUE_WITHIN, 300);
        p.routes[1].out = 120;
        handler.race(p);
    }

    /// @dev A main that delivers less, or reverts, when the router runs it again
    function _reachFading() internal {
        // The best main delivers 150 in its trial and 120 when run again, so it is removed. The next best fills
        RaceInput memory p = _base(RACE, 3);
        p.routes[0] = _fading(150, 30);
        p.routes[1].out = 120;
        p.routes[2].out = 110;
        handler.race(p);
        // A better main beside it is committed first, and the fading one is never run again
        p.routes[1].out = 160;
        handler.race(p);
        // With nothing to spend the router approves nothing, so the two runs cannot be told apart
        p.routes[1].out = 120;
        p.amountIn = 0;
        handler.race(p);

        // Two fading mains are removed one after the other, then the third fills
        p = _base(RACE, 4);
        p.routes[0] = _fading(150, 30);
        p.routes[1] = _fading(140, 30);
        p.routes[2].out = 120;
        p.routes[3].out = 110;
        handler.race(p);

        // The second run reverts instead of delivering less
        p = _base(RACE, 2);
        p.routes[0] = _twisted(150, FADING, 1);
        p.routes[1].out = 110;
        handler.race(p);

        // No main is left at the minimum. The race reverts with the output of the main that is left, or with
        // AllRoutesFailed when the other main delivered nothing in its trial, or reverted
        p = _base(RACE, 2);
        p.routes[0] = _fading(150, 60);
        p.routes[1].out = 50;
        handler.race(p);
        p.routes[1].out = 0;
        handler.race(p);
        p.routes[1].kind = REVERTS;
        handler.race(p);

        // raceWithBackups with two mains: the backup fills, or reverts and the race ends with what the mains left
        p = _base(RACE_WITH_BACKUPS, 3);
        p.mainCount = 1;
        p.routes[0] = _fading(150, 60);
        p.routes[1].out = 50;
        p.routes[2].out = 110;
        handler.race(p);
        p.routes[2].kind = REVERTS;
        handler.race(p);
        p.routes[1].kind = REVERTS;
        handler.race(p);

        // In order, the spender it watches is approved before its only run, so it delivers 120 at once
        p = _base(RACE_SINGLE, 2);
        p.routes[0].kind = REVERTS;
        p.routes[1] = _fading(150, 30);
        handler.race(p);

        // An earlier race under flag 2 left the watched spender an allowance: the route delivers 120 in its
        // trial as well, and is committed with it
        _keepAllowances();
        p = _base(RACE, 3);
        p.routes[0] = _fading(150, 30);
        p.routes[1].out = 115;
        p.routes[2].out = 110;
        handler.race(p);
        // The same with nothing to spend: the router's approval of 0 clears that allowance after the trial, so
        // the second run delivers 150, more than the trial
        _keepAllowances();
        p.amountIn = 0;
        handler.race(p);
    }

    /// @dev A route that removes tokenOut from the output holder before it delivers
    function _reachLowering() internal {
        // The best main mints 150 once it has removed 30 of the 1000 or more the router holds: it delivers 120
        // in its trial and again when it is committed
        RaceInput memory p = _base(RACE, 2);
        p.routerOut = 1000;
        p.routes[0] = _twisted(150, LOWERS_LESS, 29);
        p.routes[1].out = 110;
        handler.race(p);

        // It removes all it mints. That is an output of zero, not a failed route: InsufficientOutput(0, min)
        p = _base(RACE_SINGLE, 1);
        p.routerOut = 1000;
        p.routes[0] = _twisted(150, LOWERS_ALL, 0);
        handler.race(p);

        // It removes 151, one more than it mints, from a holder that has it: the router, which pays the
        // recipient or is the recipient itself, or the recipient under flag 4. Only the router's check keeps
        // it from winning: first in its trial as a main, then in order, in a run that could commit. The honest
        // route behind it fills each time
        for (uint256 i; i < 6; ++i) {
            p = _base(i < 3 ? RACE : RACE_SINGLE, 2);
            p.routerOut = 1000;
            p.recipient = i % 3 == 1 ? TO_ROUTER : 0;
            p.flags = i % 3 == 2 ? uint8(DIRECT_OUTPUT) : 0;
            p.routes[0] = _twisted(150, LOWERS_MORE, 0);
            p.routes[1].out = 110;
            handler.race(p);
        }
    }

    /// @dev Routes that declare a spender other than their own target and pull their input through it
    function _reachSpenders() internal {
        // The only route that reaches the minimum pulls through a separate spender, in its trial and again as
        // the leader, which is run a second time without a second approval
        RaceInput memory p = _base(RACE, 2);
        p.routes[0].out = 120;
        p.routes[0].spender = SEPARATE;
        p.routes[1].out = 90;
        _withoutAndWithFlag2(p);

        // Routes 0 and 2 declare the other separate spender. Route 1 between them declares its own target, so
        // the router has approved another spender since. Route 2 delivers most and commits in its trial
        p = _base(RACE, 3);
        p.routes[0].out = 110;
        p.routes[0].spender = SEPARATE + 1;
        p.routes[1].out = 105;
        p.routes[2].out = 120;
        p.routes[2].spender = SEPARATE + 1;
        _withoutAndWithFlag2(p);

        // Route 0 declares the target of route 1, which declares itself: route 1 pulls through the same
        // allowance in its trial, and route 0, the leader, once more when it is run again
        p = _base(RACE, 2);
        p.routes[0].out = 120;
        p.routes[0].spender = OTHER_TARGET;
        p.routes[1].out = 110;
        _withoutAndWithFlag2(p);

        // Route 2 declares the target of route 0, the next route in the round, which declares itself and was
        // approved two routes earlier. Route 2 delivers most and commits in its trial
        p = _base(RACE, 3);
        p.routes[0].out = 110;
        p.routes[1].out = 105;
        p.routes[2].out = 120;
        p.routes[2].spender = OTHER_TARGET;
        _withoutAndWithFlag2(p);
    }

    /// @dev A cleanup command after a race that fills. The first cleanup of an asset takes all the router holds
    /// of it, so that the amounts after it are measured against what the next races put there
    function _reachCleanup() internal {
        // Flag 8 keeps the unspent 60% of the input on the router, and the cleanup takes all of its tokenA, so
        // the proxy's sweep finds none
        RaceInput memory p = _withCleanup(CLEANUP_TOKEN_A, 0, 0);
        p.flags = uint8(NO_INPUT_REFUND);
        p.routes[0] = _route(SPENDS_PART, 150, 0.4 ether, 0);
        handler.race(p);

        // Of the 7 put on the router: 3, and the proxy's sweep sends the other 4 to the refund address. Then 8 of
        // 7, which fails and reverts the multicall, so the 7 stay. Then the same command allowed to fail: it
        // moves nothing, and the sweep takes the 7. Then 7 of 7, all of it, and after that there is nothing to move
        p = _withCleanup(CLEANUP_TOKEN_A, EXPLICIT, 3);
        handler.race(p);
        p.cleanupAmount = 8;
        handler.race(p);
        p.routerIn = 0;
        p.cleanupMode = EXPLICIT_MAY_FAIL;
        handler.race(p);
        p.routerIn = 7;
        p.cleanupMode = EXPLICIT;
        p.cleanupAmount = 7;
        handler.race(p);
        p.routerIn = 0;
        p.cleanupMode = 0;
        handler.race(p);

        // Straight to the router, where the rest stays. Of the 7 put there: 3, which leaves 4. Then 5, which
        // fails and reverts the multicall, unless the command may fail. Then 4, all of it, and after that there
        // is nothing to move
        p = _withCleanup(CLEANUP_TOKEN_A, EXPLICIT, 3);
        p.path = DIRECT;
        handler.race(p);
        p.routerIn = 0;
        p.cleanupAmount = 5;
        handler.race(p);
        p.cleanupMode = EXPLICIT_MAY_FAIL;
        handler.race(p);
        p.cleanupMode = EXPLICIT;
        p.cleanupAmount = 4;
        handler.race(p);
        p.cleanupMode = 0;
        handler.race(p);

        // The router as refund address keeps the unspent input too. This cleanup may fail, and does not
        p = _withCleanup(CLEANUP_TOKEN_A, MAY_FAIL, 0);
        p.refund = TO_ROUTER;
        p.routes[0] = _route(SPENDS_PART, 150, 0.4 ether, 0);
        handler.race(p);

        // The router is the recipient, and the cleanup takes the output with the rest of its tokenB. Then a
        // cleanup that sends the router's tokenB to the router
        p = _withCleanup(CLEANUP_TOKEN_B, 0, 0);
        p.recipient = TO_ROUTER;
        handler.race(p);
        p.recipient = 0;
        p.cleanupTo = TO_ROUTER;
        handler.race(p);

        // Native: all of it, so that the final sweep finds nothing. Then 5 of the 13 put on the router, and
        // the sweep sends the other 8 to the refund address
        p = _withCleanup(CLEANUP_NATIVE, 0, 0);
        handler.race(p);
        p.cleanupMode = EXPLICIT;
        p.cleanupAmount = 5;
        handler.race(p);
        // 14 of 13 fails. The reverted multicall leaves the router its 13, so the next race adds nothing
        p.cleanupAmount = 14;
        handler.race(p);
        p.routerNative = 0;
        p.cleanupMode = EXPLICIT_MAY_FAIL;
        handler.race(p);
        // A zero recipient is the router itself: the 13 stay for the sweep
        p = _withCleanup(CLEANUP_NATIVE, 0, 0);
        p.cleanupTo = TO_ROUTER;
        handler.race(p);

        // A native input of which the route takes 40%: the cleanup takes what the sweep would have refunded.
        // Then a native output to the router, which the cleanup takes too
        p = _withCleanup(CLEANUP_NATIVE, 0, 0);
        p.assets = NATIVE_IN;
        p.routes[0] = _route(SPENDS_PART, 150, 0.4 ether, 0);
        handler.race(p);
        p = _withCleanup(CLEANUP_NATIVE, 0, 0);
        p.assets = NATIVE_OUT;
        p.recipient = TO_ROUTER;
        handler.race(p);
    }

    /// @dev What a race leaves of the allowances it granted, and of those an earlier race under flag 2 left
    function _reachAllowances() internal {
        // Route 1 wins on 40% of the input, so 60% of its allowance is unspent. Route 0 loses with a separate
        // spender, route 2 with the target of route 0, which declares another spender itself
        RaceInput memory p = _base(RACE, 3);
        p.routes[0].out = 110;
        p.routes[0].spender = SEPARATE;
        p.routes[1] = _route(SPENDS_PART, 120, 0.4 ether, 0);
        p.routes[2].out = 105;
        p.routes[2].spender = OTHER_TARGET;
        handler.race(p);

        // raceSingle: route 0 misses the minimum through the other separate spender, route 1 fills
        p = _base(RACE_SINGLE, 2);
        p.routes[0].out = 99;
        p.routes[0].spender = SEPARATE + 1;
        p.routes[1].out = 100;
        handler.race(p);

        // Flag 2 leaves the targets of three routes the maximum. raceWithBackups of two mains then clears the
        // winner's and the other main's, and the backup it never reaches keeps its own
        p = _base(RACE, 3);
        p.flags = uint8(KEEP_ALLOWANCES);
        p.routes[0].out = 120;
        p.routes[1].out = 110;
        p.routes[2].out = 105;
        handler.race(p);
        p = _base(RACE_WITH_BACKUPS, 3);
        p.mainCount = 1; // two mains
        p.routes[0].out = 120;
        p.routes[1].out = 110;
        p.routes[2].out = 130;
        handler.race(p);

        // No main can win, so the backup fills: both mains have lost, and the allowance the backup kept goes
        p.routes[0].kind = REVERTS;
        p.routes[1].out = 50;
        handler.race(p);

        // Flag 2 twice: the router has to approve the two spenders, then finds them at the maximum
        _keepAllowances();
        _keepAllowances();

        // Neither a race that reverts nor one with native input changes what the two hold
        p = _base(RACE, 2);
        p.routes[0].out = 90;
        p.routes[1].out = 95;
        handler.race(p);
        p.assets = NATIVE_IN;
        p.routes[0].out = 120;
        handler.race(p);

        // An allowance that covers amountIn and is not the maximum: under flag 2 the router leaves it, and
        // what the winner pulls comes off it
        TestERC20 tokenA = handler.tokenA();
        address separate = address(handler.spenders(0));
        vm.prank(address(handler.router()));
        tokenA.approve(separate, 3 ether);
        p = _base(RACE_SINGLE, 1);
        p.flags = uint8(KEEP_ALLOWANCES);
        p.routes[0] = _route(SPENDS_PART, 150, 0.4 ether, 0);
        p.routes[0].spender = SEPARATE;
        handler.race(p);
    }

    /// @dev Routes that declare no spender. The router approves nothing for one, so with ERC-20 input it can pull
    /// only through an allowance its target holds for another reason
    function _reachNoSpender() internal {
        // Without flag 2 a race whose routes declare their own targets leaves none of them an allowance
        RaceInput memory p = _base(RACE, 4);
        p.routes[0].out = 120;
        handler.race(p);

        // It spends nothing, so it needs no allowance, and fills. Then the same with native input
        p = _base(RACE_SINGLE, 1);
        p.routes[0] = _route(SPENDS_NONE, 150, 0, 0);
        p.routes[0].spender = NO_SPENDER;
        handler.race(p);
        p.assets = NATIVE_IN;
        p.routes[0].kind = SPENDS_ALL;
        handler.race(p);

        // It would pull all of amountIn through its own target, which holds no allowance: it reverts in its
        // trial, and the main after it fills
        p = _base(RACE, 2);
        p.routes[0].out = 150;
        p.routes[0].spender = NO_SPENDER;
        p.routes[1].out = 120;
        handler.race(p);

        // Route 0 declares the target of route 1 and misses the minimum. Route 1 declares none, pulls through
        // the allowance route 0's declaration gave its target, and fills
        p = _base(RACE, 2);
        p.routes[0].out = 90;
        p.routes[0].spender = OTHER_TARGET;
        p.routes[1].out = 120;
        p.routes[1].spender = NO_SPENDER;
        handler.race(p);

        // Flag 2 leaves the targets of routes 0 and 1 the maximum, which a route that declares none pulls through
        _keepAllowances();
        p = _base(RACE_SINGLE, 1);
        p.routes[0].out = 150;
        p.routes[0].spender = NO_SPENDER;
        handler.race(p);
    }

    /// @dev One route that fills, then a cleanup command
    function _withCleanup(uint8 cleanup, uint8 mode, uint64 amount) internal pure returns (RaceInput memory p) {
        p = _base(RACE, 1);
        p.routes[0].out = 150;
        (p.cleanup, p.cleanupMode, p.cleanupAmount) = (cleanup, mode, amount);
    }

    /// @dev Without flag 2 the race ends with the allowances of its routes cleared, so that under flag 2 the
    /// router has to approve the same spenders again
    function _withoutAndWithFlag2(RaceInput memory p) internal {
        handler.race(p);
        p.flags = uint8(KEEP_ALLOWANCES);
        handler.race(p);
    }

    /// @dev A race under flag 2, which leaves the spenders of routes 0 and 1 an allowance
    function _keepAllowances() internal {
        RaceInput memory p = _base(RACE, 2);
        p.flags = uint8(KEEP_ALLOWANCES);
        p.routes[0].out = 120;
        p.routes[1].out = 110;
        handler.race(p);
    }

    function _base(uint8 entry, uint8 routes) internal pure returns (RaceInput memory p) {
        p.entry = entry;
        p.routeCount = routes - 1;
        p.scale = 1;
        p.amountIn = 1 ether;
        p.minOut = 100;
        p.routerIn = 7;
        p.routerOut = 11;
        p.routerNative = 13;
        for (uint256 i; i < SLOTS; ++i) {
            p.routes[i].kind = SPENDS_ALL;
        }
    }

    function _route(uint8 kind, uint64 out, uint64 spend, uint8 fee) internal pure returns (RouteInput memory r) {
        (r.kind, r.out, r.spend, r.fee) = (kind, out, spend, fee);
    }

    function _twisted(uint64 out, uint8 twist, uint64 aux) internal pure returns (RouteInput memory r) {
        (r.kind, r.out, r.twist, r.aux) = (SPENDS_ALL, out, twist, aux);
    }

    /// @dev Delivers `cut` less than `out` once the next route's spender is approved
    function _fading(uint64 out, uint64 cut) internal pure returns (RouteInput memory) {
        return _twisted(out, FADING, 32 * (cut - 1) + 5);
    }

    function _clean(string memory id) internal view {
        assertEq(handler.violations(id), 0, handler.firstViolation(id));
    }

    function _reached(string memory class) internal {
        uint256 count = handler.reach(class);
        emit log_named_uint(class, count);
        assertGt(count, 0, string.concat("not reached: ", class));
    }
}

contract RelayRouterNonTstoreInvariantTest is RelayRouterInvariantTest {
    function _deployRouter() internal override returns (RelayRouterBase) {
        return new RelayRouter_NonTstore();
    }
}
