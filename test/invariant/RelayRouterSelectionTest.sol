// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, Vm} from "forge-std/Test.sol";
import {Route, IRouteRace} from "../../src/interfaces/IRouteRace.sol";
import {packRoute} from "./RoutePacking.sol";
import {RelayRouterBase} from "../../src/RelayRouterBase.sol";
import {RelayRouter} from "../../src/RelayRouter.sol";
import {RelayRouter_NonTstore} from "../../src/RelayRouter_NonTstore.sol";
import {RelayApprovalProxy} from "../../src/RelayApprovalProxy.sol";
import {Call3Value, Result} from "../../src/common/Multicall3.sol";
import {TestERC20} from "../mocks/TestERC20.sol";

/// @dev Permit2's address on every chain. The approval proxy refuses a zero one.
address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

uint256 constant SEL_SLOTS = 4;

// Entry points
uint256 constant SEL_RACE = 0;
uint256 constant SEL_SINGLE = 1;
uint256 constant SEL_BACKUPS = 2;

uint256 constant SEL_DIRECT_OUTPUT = 4;

/// @dev What a route does in one run
struct SelOrder {
    bool fail;
    address tokenIn; // address(0): the input arrives as msg.value
    address spender; // `spend` is pulled through it
    uint256 spend;
    address tokenOut;
    uint256 out;
    address watch; // `cut` less is delivered once the router's tokenIn allowance to `watch` is non-zero
    uint256 cut;
    uint256 burnGas; // burned before anything else, so that trial gas follows the script
    address to;
}

/// @dev Moves whatever its caller names, through its own allowance
contract SelSpender {
    function pull(address token, address from, address to, uint256 amount) external {
        TestERC20(token).transferFrom(from, to, amount);
    }
}

/// @dev One per route slot. Honest or reverting: every call carries its own script
contract SelRouteProvider is SelSpender {
    error ScriptedRevert();

    receive() external payable {}

    function run(SelOrder calldata o) external payable {
        if (o.burnGas != 0) {
            uint256 stop = gasleft() - o.burnGas;
            while (gasleft() > stop) {}
        }
        if (o.fail) revert ScriptedRevert();
        uint256 out = o.out;
        if (o.tokenIn != address(0)) {
            // An approval made since its trial is all that tells a route it runs again. A cut above `out` reverts
            if (o.cut != 0 && TestERC20(o.tokenIn).allowance(msg.sender, o.watch) != 0) out -= o.cut;
            if (o.spend != 0) SelSpender(o.spender).pull(o.tokenIn, msg.sender, address(this), o.spend);
        }
        if (o.tokenOut == address(0)) {
            (bool ok,) = o.to.call{value: out}("");
            require(ok, "native delivery failed");
        } else {
            TestERC20(o.tokenOut).mint(o.to, out);
        }
    }
}

struct SelRouteInput {
    uint8 kind; // % 8: 0 reverts, 1-3 spends all of amountIn, 4-5 `spend` bounded to amountIn, 6-7 nothing
    uint64 out;
    uint8 fee; // % 8 picks the fee: none, none, 1 ppm, 0.1%, 10%, 50%, 90%, 999_999 ppm
    uint8 burn; // % 8: 0-4 no extra gas, 5-7 one to three BURN_STEPs, which orders the trial gas of the routes
    uint8 spender; // % 4: 0 its own target, 1 a shared spender that is no route's target, 2 none, 3 the next route's target
    uint64 spend;
    // % 4 == 0, with ERC-20 input and two routes or more: delivers less once the spender of route
    // (i + 1 + (fade >> 2) % (n - 1)) % n is approved. (fade >> 4) % 4 == 0: the cut is out + 1, so it reverts
    uint8 fade;
    uint64 cut;
}

struct SelInput {
    uint8 routeCount; // 1 + routeCount % SEL_SLOTS routes
    uint8 mainCount; // 1 + mainCount % routes mains, for the raceWithBackups that is kept
    uint8 flags; // & 31
    uint8 assets; // % 4: 0-1 tokenA to tokenB, 2 native to tokenB, 3 tokenA to native
    uint8 minMode; // % 5: 0 minOut as given, 1 the best scripted output, 2 that + 1, 3 some route's output, 4 the worst
    uint8 scale; // % 4: 0-1 every amount mod 8, for ties, 2 mod 1000, 3 as given
    uint64 amountIn;
    uint64 minOut;
    SelRouteInput[SEL_SLOTS] routes;
}

/// @dev What one route slot is told to do in one race
struct SelScript {
    bool fail;
    uint256 out;
    uint256 feePpm;
    uint256 burn; // in BURN_STEPs
    address spender;
    uint256 spend;
    uint256 watch; // the route whose spender's approval cuts the output
    uint256 cut;
}

struct SelPlan {
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint256 minOut;
    uint256 flags;
    uint256 mainCount;
    SelScript[] scripts;
}

struct SelOutcome {
    bool ok;
    uint256 winner;
    uint256 amountOut;
    bytes err;
}

/// @dev What the scripts say a race must do. `allowed` holds every route that may win: more than one only where
/// trial gas, which the scripts do not separate, breaks a tie on net
struct SelExpect {
    bool fills;
    uint256 allowed;
    uint256[SEL_SLOTS] delivers;
    bool laterBeats; // an earlier main reached the minimum, and a later one wins
    bool lastTie; // the last main commits on a net equal to the leader's
    bool gasTie; // the winner's trial burned less than an earlier main with the same net
    bool fellBack; // a better main failed its second run
    bool backupWins; // raceWithBackups with competing mains, won by a backup
}

/// @dev What one run of an entry point left behind: every tracked balance and allowance, and a hash per event
struct SelState {
    uint256[] values;
    bytes32[] logs;
}

contract SelectionHandler is Test {
    uint256 internal constant ROUTE_GAS = 1_000_000;
    uint256 internal constant BURN_STEP = 200_000;
    uint256 internal constant FEE_DENOMINATOR = 1_000_000;
    address public constant RECIPIENT = address(0xA11CE);
    address public constant REFUND = address(0xFEED);
    bytes internal constant META = "selection";

    RelayRouterBase public immutable router;
    RelayApprovalProxy public immutable proxy;
    TestERC20 public immutable tokenA;
    TestERC20 public immutable tokenB;
    SelSpender public immutable shared;
    SelRouteProvider[SEL_SLOTS] public providers;

    uint256 public races;
    mapping(string => uint256) public violations;
    mapping(string => string) public firstViolation;
    mapping(string => uint256) public reach;

    constructor(RelayRouterBase router_) {
        router = router_;
        proxy = new RelayApprovalProxy(address(this), address(router_), PERMIT2);
        tokenA = new TestERC20();
        tokenB = new TestERC20();
        shared = new SelSpender();
        for (uint256 i; i < SEL_SLOTS; ++i) {
            providers[i] = new SelRouteProvider();
        }
        tokenA.approve(address(proxy), type(uint256).max);
    }

    receive() external payable {}

    /// @dev The one fuzzed entry point. Runs race, raceWithBackups(n), raceSingle, raceWithBackups(1) and
    /// raceWithBackups(mainCount) on the same routes from the same state, and keeps the last. The handler's storage
    /// rolls back with each snapshot, so every check is recorded after the last run
    function race(SelInput calldata p) external {
        ++races;
        SelPlan memory plan = _plan(p);
        _prepare(plan);
        uint256 n = plan.scripts.length;
        uint256[5] memory entries = [SEL_RACE, SEL_BACKUPS, SEL_SINGLE, SEL_BACKUPS, SEL_BACKUPS];
        uint256[5] memory mains = [n, n, 1, 1, plan.mainCount];
        SelOutcome[5] memory got;
        SelState[4] memory left;
        vm.recordLogs();
        for (uint256 k; k < 5; ++k) {
            bool keep = k + 1 == 5;
            uint256 snapshot = keep ? 0 : vm.snapshot();
            vm.getRecordedLogs();
            got[k] = _execute(plan, entries[k], mains[k]);
            if (keep) continue;
            left[k] = _state();
            vm.revertToAndDelete(snapshot);
        }
        _checkS1(plan, entries[0], mains[0], got[0]);
        _checkS1(plan, entries[2], mains[2], got[2]);
        _checkS1(plan, entries[4], mains[4], got[4]);
        _checkS2(plan, "race and raceWithBackups(n)", got[0], got[1], left[0], left[1]);
        _checkS2(plan, "raceSingle and raceWithBackups(1)", got[2], got[3], left[2], left[3]);
        _countS2(plan, got[0], got[2]);
    }

    /// @dev Self-call so that one try/catch covers everything the router can revert
    function submit(SelPlan calldata plan, uint256 entry, uint256 mainCount) external returns (Result[] memory) {
        require(msg.sender == address(this), "handler only");
        uint256 n = plan.scripts.length;
        bool nativeIn = plan.tokenIn == address(0);
        address holder = plan.flags & SEL_DIRECT_OUTPUT != 0 ? RECIPIENT : address(router);
        Route[] memory routes = new Route[](n);
        for (uint256 i; i < n; ++i) {
            SelScript calldata s = plan.scripts[i];
            SelOrder memory order = SelOrder({
                fail: s.fail,
                tokenIn: plan.tokenIn,
                spender: s.spender,
                spend: s.spend,
                tokenOut: plan.tokenOut,
                out: s.out,
                watch: plan.scripts[s.watch].spender,
                cut: s.cut,
                burnGas: s.burn * BURN_STEP,
                to: holder
            });
            routes[i] = packRoute(
                address(providers[i]),
                s.spender,
                nativeIn ? s.spend : 0,
                ROUTE_GAS,
                s.feePpm,
                abi.encodeCall(SelRouteProvider.run, (order))
            );
        }
        uint256 value = nativeIn ? plan.amountIn : 0;
        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = Call3Value(address(router), false, value, _command(plan, routes, entry, mainCount));
        address[] memory tokens = new address[](nativeIn ? 0 : 1);
        uint256[] memory amounts = new uint256[](tokens.length);
        if (!nativeIn) {
            tokens[0] = plan.tokenIn;
            amounts[0] = plan.amountIn;
        }
        return proxy.transferAndMulticall{value: value}(tokens, amounts, calls, REFUND, address(0), META);
    }

    function _command(SelPlan calldata plan, Route[] memory routes, uint256 entry, uint256 mainCount)
        internal
        pure
        returns (bytes memory)
    {
        if (entry == SEL_RACE) {
            return abi.encodeCall(
                IRouteRace.race,
                (plan.tokenIn, plan.amountIn, plan.tokenOut, plan.minOut, RECIPIENT, plan.flags, routes)
            );
        }
        if (entry == SEL_SINGLE) {
            return abi.encodeCall(
                IRouteRace.raceSingle,
                (plan.tokenIn, plan.amountIn, plan.tokenOut, plan.minOut, RECIPIENT, plan.flags, routes)
            );
        }
        return abi.encodeCall(
            IRouteRace.raceWithBackups,
            (plan.tokenIn, plan.amountIn, plan.tokenOut, plan.minOut, RECIPIENT, plan.flags, routes, mainCount)
        );
    }

    function _execute(SelPlan memory plan, uint256 entry, uint256 mainCount) internal returns (SelOutcome memory o) {
        try this.submit(plan, entry, mainCount) returns (Result[] memory results) {
            o.ok = true;
            (o.winner, o.amountOut) = abi.decode(results[0].returnData, (uint256, uint256));
        } catch (bytes memory err) {
            o.err = err;
        }
    }

    function _plan(SelInput calldata p) internal view returns (SelPlan memory plan) {
        uint256 scale = p.scale % 4;
        uint256 n = 1 + p.routeCount % SEL_SLOTS;
        plan.mainCount = 1 + p.mainCount % n;
        plan.flags = p.flags & 31;
        plan.tokenIn = p.assets % 4 == 2 ? address(0) : address(tokenA);
        plan.tokenOut = p.assets % 4 == 3 ? address(0) : address(tokenB);
        uint256 amountIn = 1 + _amount(p.amountIn, scale);
        plan.amountIn = amountIn;
        plan.scripts = new SelScript[](n);
        uint256 best;
        uint256 worst = type(uint256).max;
        for (uint256 i; i < n; ++i) {
            SelRouteInput calldata r = p.routes[i];
            SelScript memory s = plan.scripts[i];
            uint256 kind = r.kind % 8;
            s.fail = kind == 0;
            s.out = _amount(r.out, scale);
            s.feePpm = _fee(r.fee);
            s.burn = r.burn % 8 < 5 ? 0 : r.burn % 8 - 4;
            s.spender = _spender(r.spender, i, n);
            if (s.spender != address(0) || plan.tokenIn == address(0)) {
                s.spend = kind < 4 ? amountIn : kind < 6 ? r.spend % (amountIn + 1) : 0;
            }
            s.watch = i;
            if (r.fade % 4 == 0 && plan.tokenIn != address(0) && n > 1) {
                s.watch = (i + 1 + (r.fade >> 2) % (n - 1)) % n;
                s.cut = (r.fade >> 4) % 4 == 0 ? s.out + 1 : 1 + r.cut % (s.out == 0 ? 1 : s.out);
            }
            if (s.fail) continue;
            if (s.out > best) best = s.out;
            if (s.out < worst) worst = s.out;
        }
        if (worst > best) worst = best;
        uint256 mode = p.minMode % 5;
        plan.minOut = mode == 0
            ? _amount(p.minOut, scale)
            : mode == 1 ? best : mode == 2 ? best + 1 : mode == 3 ? plan.scripts[p.minOut % n].out : worst;
        if (plan.minOut == 0) plan.minOut = 1;
    }

    function _spender(uint8 choice, uint256 i, uint256 n) internal view returns (address) {
        uint256 kind = choice % 4;
        if (kind == 1) return address(shared);
        if (kind == 2) return address(0);
        if (kind == 3) return address(providers[(i + 1) % n]);
        return address(providers[i]);
    }

    function _amount(uint256 raw, uint256 scale) internal pure returns (uint256) {
        return scale < 2 ? raw % 8 : scale == 2 ? raw % 1000 : raw;
    }

    function _fee(uint8 raw) internal pure returns (uint256) {
        return [uint24(0), 0, 1, 1_000, 100_000, 500_000, 900_000, 999_999][raw % 8];
    }

    /// @dev Every race starts with no tokenIn allowance from the router, so that a fading route sees only the
    /// approvals of this race. The user gets the input, the providers the native they are scripted to deliver
    function _prepare(SelPlan memory plan) internal {
        for (uint256 i; i < SEL_SLOTS; ++i) {
            _clearAllowance(address(providers[i]));
        }
        _clearAllowance(address(shared));
        if (plan.tokenIn == address(0)) vm.deal(address(this), address(this).balance + plan.amountIn);
        else tokenA.mint(address(this), plan.amountIn);
        if (plan.tokenOut == address(0)) {
            for (uint256 i; i < plan.scripts.length; ++i) {
                vm.deal(address(providers[i]), address(providers[i]).balance + plan.scripts[i].out);
            }
        }
    }

    function _clearAllowance(address spender) internal {
        if (tokenA.allowance(address(router), spender) == 0) return;
        vm.prank(address(router));
        tokenA.approve(spender, 0);
    }

    // ------------------------------------------------------------------------------------------------ S1

    /// @dev S1: the race fills exactly when the scripts say a route can win, with one of the routes they allow,
    /// and with that route's output in its committing run
    function _checkS1(SelPlan memory plan, uint256 entry, uint256 mainCount, SelOutcome memory got) internal {
        SelExpect memory x = _expect(plan, entry, mainCount, false);
        string memory what;
        if (!got.ok) {
            if (x.fills) {
                what = string.concat("reverted ", vm.toString(got.err), ", though ", _routes(x.allowed), " can win");
            }
        } else if (!x.fills) {
            what = string.concat("filled by route ", vm.toString(got.winner), ", though no route can win");
        } else if (got.winner >= SEL_SLOTS || x.allowed >> got.winner & 1 == 0) {
            what = string.concat("filled by route ", vm.toString(got.winner), ", expected ", _routes(x.allowed));
        } else if (got.amountOut != x.delivers[got.winner]) {
            what = string.concat(
                "route ",
                vm.toString(got.winner),
                " returned amountOut ",
                vm.toString(got.amountOut),
                ", expected ",
                vm.toString(x.delivers[got.winner])
            );
        }
        if (bytes(what).length != 0) {
            _violate("S1", string.concat(_entryName(entry, mainCount), ": ", what, ". ", _describe(plan)));
            return;
        }
        if (!got.ok || !_one(x.allowed)) return;
        uint256 mains = _mains(plan, entry, mainCount);
        if (x.laterBeats) _reached("S1 later main beats an earlier acceptable one");
        if (x.lastTie) _reached("S1 last main wins a tie on net");
        if (x.gasTie) _reached("S1 trial gas decides a tie on net");
        if (x.fellBack) _reached("S1 leader fails its second run, next best wins");
        if (x.backupWins) _reached("S1 backup wins, no main qualified");
        if (entry == SEL_SINGLE && got.winner != 0) _reached("S1 raceSingle winner is not route 0");
        if (mains > 1 && got.winner < mains && _backupQualifies(plan, mains)) {
            _reached("S1 backup passed over, a main qualified");
        }
        SelExpect memory raw = _expect(plan, entry, mainCount, true);
        if (raw.fills && _one(raw.allowed) && raw.allowed != x.allowed) _reached("S1 fee changes the winner");
    }

    /// @dev The routes that compete: all of race, the first `mainCount` of raceWithBackups unless it is one, none
    /// of raceSingle
    function _mains(SelPlan memory plan, uint256 entry, uint256 mainCount) internal pure returns (uint256) {
        if (entry == SEL_RACE) return plan.scripts.length;
        return entry == SEL_BACKUPS && mainCount != 1 ? mainCount : 0;
    }

    /// @dev The winner the scripts call for, worked out from the route outputs, fees and gas steps alone. With
    /// `rawRank` the mains are ranked by raw output, to tell the races where the fee decides
    function _expect(SelPlan memory plan, uint256 entry, uint256 mainCount, bool rawRank)
        internal
        pure
        returns (SelExpect memory x)
    {
        uint256 n = plan.scripts.length;
        uint256 mains = _mains(plan, entry, mainCount);
        uint256 minOut = plan.minOut;
        uint256[SEL_SLOTS] memory trial;
        uint256[SEL_SLOTS] memory net;
        uint256 granted; // the routes whose spender the router has approved
        uint256 eligible; // mains that reached the minimum in their trial, other than one that committed
        uint256 leadNet;
        for (uint256 i; i < mains; ++i) {
            granted |= 1 << i;
            (bool ok, uint256 out) = _run(plan, i, granted);
            if (!ok || out < minOut) continue;
            trial[i] = out;
            net[i] = rawRank ? out : out * (FEE_DENOMINATOR - plan.scripts[i].feePpm) / FEE_DENOMINATOR;
            // The last main wins in its trial when its net is no lower than the best earlier one
            if (i + 1 == mains && (eligible == 0 || net[i] >= leadNet)) {
                x.laterBeats = eligible != 0;
                x.lastTie = eligible != 0 && net[i] == leadNet;
                return _win(x, i, out);
            }
            if (eligible == 0 || net[i] > leadNet) leadNet = net[i];
            eligible |= 1 << i;
        }
        // Every main is approved now. The best runs again and commits if it delivers no less than in its trial
        uint256 passing;
        uint256[SEL_SLOTS] memory second;
        for (uint256 i; i < mains; ++i) {
            if (eligible >> i & 1 == 0) continue;
            (bool ok, uint256 out) = _run(plan, i, granted);
            if (ok && out >= trial[i]) {
                passing |= 1 << i;
                second[i] = out;
            }
        }
        for (uint256 c; c < mains; ++c) {
            if (passing >> c & 1 == 0) continue;
            bool beaten;
            bool outranked;
            bool byGas;
            bool afterEligible;
            for (uint256 d; d < mains; ++d) {
                if (d == c || eligible >> d & 1 == 0) continue;
                if (d < c) afterEligible = true;
                uint256 burnD = plan.scripts[d].burn;
                uint256 burnC = plan.scripts[c].burn;
                // Better: a higher net, or the same net from a trial that burned at least one step less
                if (net[d] > net[c] || (net[d] == net[c] && burnD < burnC)) {
                    if (passing >> d & 1 != 0) beaten = true;
                    else outranked = true;
                } else if (d < c && net[d] == net[c] && burnD > burnC) {
                    byGas = true;
                }
            }
            if (beaten) continue;
            x.fills = true;
            x.allowed |= 1 << c;
            x.delivers[c] = second[c];
            x.laterBeats = x.laterBeats || afterEligible;
            x.fellBack = x.fellBack || outranked;
            x.gasTie = x.gasTie || byGas;
        }
        if (x.fills) return x;
        // The routes after the mains, or all routes when none compete, in order: the first to reach the minimum
        for (uint256 j = mains; j < n; ++j) {
            granted |= 1 << j;
            (bool ok, uint256 out) = _run(plan, j, granted);
            if (ok && out >= minOut) {
                x.backupWins = mains != 0;
                return _win(x, j, out);
            }
        }
    }

    function _win(SelExpect memory x, uint256 i, uint256 out) internal pure returns (SelExpect memory) {
        x.fills = true;
        x.allowed = 1 << i;
        x.delivers[i] = out;
        return x;
    }

    /// @dev Whether a route after the mains would reach the minimum, had no main won
    function _backupQualifies(SelPlan memory plan, uint256 mains) internal pure returns (bool) {
        uint256 granted = (1 << mains) - 1;
        for (uint256 j = mains; j < plan.scripts.length; ++j) {
            granted |= 1 << j;
            (bool ok, uint256 out) = _run(plan, j, granted);
            if (ok && out >= plan.minOut) return true;
        }
        return false;
    }

    /// @dev One run of route `i` once the router has approved the spenders of the routes in `granted`
    function _run(SelPlan memory plan, uint256 i, uint256 granted) internal pure returns (bool ok, uint256 out) {
        SelScript memory s = plan.scripts[i];
        if (s.fail) return (false, 0);
        if (s.cut != 0 && _approved(plan, plan.scripts[s.watch].spender, granted)) {
            return s.cut > s.out ? (false, 0) : (true, s.out - s.cut);
        }
        return (true, s.out);
    }

    function _approved(SelPlan memory plan, address spender, uint256 granted) internal pure returns (bool) {
        if (spender == address(0) || plan.tokenIn == address(0)) return false;
        for (uint256 j; j < plan.scripts.length; ++j) {
            if (granted >> j & 1 != 0 && plan.scripts[j].spender == spender) return true;
        }
        return false;
    }

    function _one(uint256 mask) internal pure returns (bool) {
        return mask != 0 && mask & (mask - 1) == 0;
    }

    // ------------------------------------------------------------------------------------------------ S2

    /// @dev S2: two entry points that should be one race seen two ways give the same result or the same revert
    /// data, leave every tracked balance and allowance the same, and emit the same events
    function _checkS2(
        SelPlan memory plan,
        string memory pair,
        SelOutcome memory a,
        SelOutcome memory b,
        SelState memory sa,
        SelState memory sb
    ) internal {
        string memory what;
        if (a.ok != b.ok) {
            what = a.ok
                ? string.concat("the first filled, the second reverted ", vm.toString(b.err))
                : string.concat("the first reverted ", vm.toString(a.err), ", the second filled");
        } else if (a.ok && (a.winner != b.winner || a.amountOut != b.amountOut)) {
            what = string.concat(
                "route ",
                vm.toString(a.winner),
                " with ",
                vm.toString(a.amountOut),
                " against route ",
                vm.toString(b.winner),
                " with ",
                vm.toString(b.amountOut)
            );
        } else if (!a.ok && keccak256(a.err) != keccak256(b.err)) {
            what = string.concat("reverted ", vm.toString(a.err), " against ", vm.toString(b.err));
        } else {
            for (uint256 i; i < sa.values.length && bytes(what).length == 0; ++i) {
                if (sa.values[i] != sb.values[i]) {
                    what = string.concat(
                        _valueName(i), " is ", vm.toString(sa.values[i]), " against ", vm.toString(sb.values[i])
                    );
                }
            }
            if (bytes(what).length == 0 && sa.logs.length != sb.logs.length) {
                what = string.concat(vm.toString(sa.logs.length), " events against ", vm.toString(sb.logs.length));
            }
            for (uint256 i; i < sa.logs.length && bytes(what).length == 0; ++i) {
                if (sa.logs[i] != sb.logs[i]) what = string.concat("event ", vm.toString(i), " differs");
            }
        }
        if (bytes(what).length != 0) _violate("S2", string.concat(pair, ": ", what, ". ", _describe(plan)));
    }

    /// @dev The races where the allowances left by the two forms would differ, if one of them cleared fewer
    function _countS2(SelPlan memory plan, SelOutcome memory raced, SelOutcome memory single) internal {
        if (!raced.ok) _reached("S2 race reverts, compared");
        if (!single.ok) _reached("S2 raceSingle reverts, compared");
        if (raced.ok && plan.flags & 1 != 0) _reached("S2 race fills under flag 1, events compared");
        if (plan.tokenIn == address(0) || plan.flags & 2 != 0) return;
        uint256 n = plan.scripts.length;
        if (raced.ok && raced.winner + 1 < n) {
            for (uint256 j = raced.winner + 1; j < n; ++j) {
                if (!_declared(plan, plan.scripts[j].spender, raced.winner + 1)) {
                    _reached("S2 race leaves a later spender to clear");
                    break;
                }
            }
        }
        if (single.ok && single.winner != 0) {
            address winner = plan.scripts[single.winner].spender;
            for (uint256 j; j < single.winner; ++j) {
                address spender = plan.scripts[j].spender;
                if (spender != address(0) && spender != winner) {
                    _reached("S2 raceSingle leaves an earlier spender to clear");
                    break;
                }
            }
        }
    }

    /// @dev Whether `spender` is non-zero and declared by none of the first `count` routes
    function _declared(SelPlan memory plan, address spender, uint256 count) internal pure returns (bool) {
        if (spender == address(0)) return true;
        for (uint256 k; k < count; ++k) {
            if (plan.scripts[k].spender == spender) return true;
        }
        return false;
    }

    /// @dev Every tracked holder's balance of tokenA, tokenB and native, then the router's tokenA allowance to
    /// every route target and the shared spender, then one hash per event recorded since the run began
    function _state() internal returns (SelState memory st) {
        address[] memory holders = _holders();
        st.values = new uint256[](holders.length * 3 + SEL_SLOTS + 1);
        for (uint256 h; h < holders.length; ++h) {
            st.values[h * 3] = tokenA.balanceOf(holders[h]);
            st.values[h * 3 + 1] = tokenB.balanceOf(holders[h]);
            st.values[h * 3 + 2] = holders[h].balance;
        }
        for (uint256 i; i <= SEL_SLOTS; ++i) {
            address spender = i < SEL_SLOTS ? address(providers[i]) : address(shared);
            st.values[holders.length * 3 + i] = tokenA.allowance(address(router), spender);
        }
        Vm.Log[] memory logs = vm.getRecordedLogs();
        st.logs = new bytes32[](logs.length);
        for (uint256 i; i < logs.length; ++i) {
            st.logs[i] = keccak256(abi.encode(logs[i].emitter, logs[i].topics, logs[i].data));
        }
    }

    function _holders() internal view returns (address[] memory holders) {
        holders = new address[](5 + SEL_SLOTS + 1);
        holders[0] = address(this);
        holders[1] = address(router);
        holders[2] = RECIPIENT;
        holders[3] = REFUND;
        holders[4] = address(proxy);
        for (uint256 i; i < SEL_SLOTS; ++i) {
            holders[5 + i] = address(providers[i]);
        }
        holders[5 + SEL_SLOTS] = address(shared);
    }

    function _valueName(uint256 i) internal pure returns (string memory) {
        string[10] memory names = [
            "user",
            "router",
            "recipient",
            "refund",
            "proxy",
            "provider0",
            "provider1",
            "provider2",
            "provider3",
            "shared"
        ];
        uint256 balances = names.length * 3;
        if (i >= balances) {
            return string.concat(
                "router's tokenA allowance to ", i - balances < SEL_SLOTS ? names[5 + i - balances] : "shared"
            );
        }
        string[3] memory assets = ["tokenA", "tokenB", "native"];
        return string.concat(names[i / 3], "'s ", assets[i % 3]);
    }

    // ------------------------------------------------------------------------------------------------ reports

    function _routes(uint256 mask) internal pure returns (string memory list) {
        list = "route";
        bool first = true;
        for (uint256 i; i < SEL_SLOTS; ++i) {
            if (mask >> i & 1 == 0) continue;
            list = string.concat(list, first ? " " : " or ", vm.toString(i));
            first = false;
        }
    }

    function _entryName(uint256 entry, uint256 mainCount) internal pure returns (string memory) {
        if (entry == SEL_RACE) return "race";
        if (entry == SEL_SINGLE) return "raceSingle";
        return string.concat("raceWithBackups(", vm.toString(mainCount), ")");
    }

    function _describe(SelPlan memory plan) internal view returns (string memory d) {
        d = string.concat(
            plan.tokenIn == address(0) ? "native" : "tokenA",
            " to ",
            plan.tokenOut == address(0) ? "native" : "tokenB",
            ", amountIn ",
            vm.toString(plan.amountIn),
            ", min ",
            vm.toString(plan.minOut),
            ", flags ",
            vm.toString(plan.flags)
        );
        for (uint256 i; i < plan.scripts.length; ++i) {
            SelScript memory s = plan.scripts[i];
            d = string.concat(
                d,
                "; [",
                vm.toString(i),
                "] ",
                s.fail ? "reverts" : string.concat("out ", vm.toString(s.out)),
                " fee ",
                vm.toString(s.feePpm),
                " burn ",
                vm.toString(s.burn),
                " spender ",
                _label(s.spender)
            );
            if (s.cut != 0) {
                d = string.concat(d, " cut ", vm.toString(s.cut), " once ", vm.toString(s.watch), " is approved");
            }
        }
    }

    function _label(address spender) internal view returns (string memory) {
        if (spender == address(0)) return "none";
        if (spender == address(shared)) return "shared";
        for (uint256 i; i < SEL_SLOTS; ++i) {
            if (spender == address(providers[i])) return string.concat("target ", vm.toString(i));
        }
        return vm.toString(spender);
    }

    function _reached(string memory key) internal {
        ++reach[key];
    }

    function _violate(string memory id, string memory what) internal {
        if (violations[id]++ == 0) {
            firstViolation[id] = string.concat(id, " in race #", vm.toString(races), ": ", what);
        }
    }
}

contract RelayRouterSelectionTest is Test {
    SelectionHandler handler;

    function _deployRouter() internal virtual returns (RelayRouterBase) {
        return new RelayRouter();
    }

    function setUp() public {
        handler = new SelectionHandler(_deployRouter());
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = SelectionHandler.race.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_S1_bestRouteWins() public view {
        _clean("S1");
    }

    function invariant_S2_entryPointsAgree() public view {
        _clean("S2");
    }

    /// @dev Fixed inputs. Fails unless every situation that gives the invariants their meaning occurred
    function test_reach() public {
        // A 50% fee: route 1 nets 100 against route 0's 60, though route 0 delivers more
        SelInput memory p = _base(2);
        p.routes[0] = _route(120, 5);
        p.routes[1] = _route(100, 0);
        handler.race(p);

        // The last main nets 100 from 200 at a 50% fee, as much as route 0, and wins the tie
        p.routes[0] = _route(100, 0);
        p.routes[1] = _route(200, 5);
        handler.race(p);

        // Routes 0 and 1 net 100 each; route 0's trial burns one step more, so route 1 leads and wins
        p = _base(3);
        p.routes[0] = _route(100, 0);
        p.routes[0].burn = 5;
        p.routes[1] = _route(100, 0);
        p.routes[2] = _route(50, 0);
        handler.race(p);

        // Route 0 leads with 120 but delivers 50 less once route 1's spender is approved, so route 1 wins
        p.routes[0] = _route(120, 0);
        p.routes[0].fade = 16;
        p.routes[0].cut = 49;
        p.routes[1] = _route(100, 0);
        p.routes[2] = _route(10, 0);
        handler.race(p);

        // raceWithBackups(2): neither main reaches 90, the backup does. raceSingle takes route 2 as well
        p = _base(3);
        p.mainCount = 1;
        p.routes[0] = _route(10, 0);
        p.routes[1] = _route(20, 0);
        p.routes[2] = _route(100, 0);
        handler.race(p);

        // raceWithBackups(2): route 0 reaches 90 and wins, though the backup delivers more
        p.routes[0] = _route(100, 0);
        p.routes[1] = _route(50, 0);
        p.routes[2] = _route(200, 0);
        handler.race(p);

        // Under flag 1, race and raceWithBackups(3) fill with route 0 and leave routes 1 and 2 to clear; with a
        // minimum above every output, all four forms revert
        p = _base(3);
        p.flags = 1;
        p.routes[0] = _route(100, 0);
        p.routes[1] = _route(50, 0);
        p.routes[2] = _route(10, 0);
        handler.race(p);
        p.minOut = 101;
        handler.race(p);

        _clean("S1");
        _clean("S2");
        _reached("S2 race leaves a later spender to clear");
        _reached("S2 raceSingle leaves an earlier spender to clear");
        _reached("S2 race reverts, compared");
        _reached("S2 raceSingle reverts, compared");
        _reached("S2 race fills under flag 1, events compared");
        _reached("S1 fee changes the winner");
        _reached("S1 later main beats an earlier acceptable one");
        _reached("S1 last main wins a tie on net");
        _reached("S1 trial gas decides a tie on net");
        _reached("S1 leader fails its second run, next best wins");
        _reached("S1 backup wins, no main qualified");
        _reached("S1 backup passed over, a main qualified");
        _reached("S1 raceSingle winner is not route 0");
    }

    function _base(uint8 n) internal pure returns (SelInput memory p) {
        p.routeCount = n - 1;
        p.mainCount = n - 1; // all routes are mains
        p.scale = 3;
        p.amountIn = 1000;
        p.minOut = 90;
    }

    function _route(uint64 out, uint8 fee) internal pure returns (SelRouteInput memory r) {
        r.kind = 1;
        r.out = out;
        r.fee = fee;
        r.fade = 1;
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

contract RelayRouterNonTstoreSelectionTest is RelayRouterSelectionTest {
    function _deployRouter() internal override returns (RelayRouterBase) {
        return new RelayRouter_NonTstore();
    }
}
