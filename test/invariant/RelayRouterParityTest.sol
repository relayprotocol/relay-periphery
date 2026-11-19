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
import {TestERC20} from "../mocks/TestERC20.sol";
import {TestERC721} from "../mocks/TestERC721.sol";
import {TestERC1155} from "../mocks/TestERC1155.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

/// @dev Permit2's address on every chain. The approval proxy refuses a zero one.
address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

// S3 parity: the same sequence of top-level calls gives, call by call, the same success flag, the same return or
// revert data, the same events, and the same balances, allowances and NFT owners on RelayRouter (transient
// storage) and on RelayRouter_NonTstore (storage).
//
// The handler holds two worlds built the same way: a router, its proxy, two tokens, two NFT contracts, route
// targets, callers, a batch contract, an account and an NFT-taking contract. World 0 has the transient router,
// world 1 the storage router. Each handler call is one step: it draws one plan, or in a third of the steps two or
// three plans, from its seed, builds each plan's top-level call in each world from that world's addresses, makes
// the calls in each world, and compares the two results. Addresses in return data, revert data and events are
// compared by role: every address of world 0 is replaced by its twin of world 1.
//
// Transactions. forge resolves `isolate = true` here, so every call the handler makes is its own transaction, and
// calls made inside one such call share transient storage (checked on 2026-11-16 with probes). A step of one plan
// has its caller make the call: one transaction. A step of several plans has the batch contract make them all inside
// one call of its own: one transaction of several router calls, in which the transient router can keep state from
// one call to the next too. Between steps only what the storage router keeps in its two slots carries over.
//
// Gas. Every step gets the whole handler budget, about 1e9, and every route a gas limit of at most 1e6, so a route
// always gets its full limit and no outcome depends on how much gas the top-level call had. Trial gas is in: it
// breaks ties on net between mains, and a quarter of the races make such a tie, with routes that burn different
// amounts. Inside a race the only router state either variant reads is the context word, already warm, so a run
// of a route costs the same on both. The race events carry the gas of each run, so S3 compares it.

uint256 constant ROUTES = 4;
uint256 constant CALLERS = 3;
uint256 constant MAX_COMMANDS = 3;
uint256 constant WORLDS = 2;

// Race flags
uint256 constant DIRECT_OUTPUT = 4;

// Plan.kind: the top-level call of a step. FUND is not a call to the router: it mints and deals in both worlds.
uint8 constant FUND = 0;
uint8 constant MULTICALL = 1; // a caller calls router.multicall without an nftRecipient
uint8 constant MULTICALL_NFT = 2; // the same with an nftRecipient
uint8 constant VIA_PROXY = 3; // a caller calls proxy.transferAndMulticall
uint8 constant CLEANUP_ERC20S = 4;
uint8 constant CLEANUP_ERC20S_VIA_CALL = 5;
uint8 constant CLEANUP_NATIVE = 6;
uint8 constant CLEANUP_NATIVE_VIA_CALL = 7;
uint8 constant NFT721_TO_ROUTER = 8; // a caller mints an ERC-721 to the router, which reaches its hook
uint8 constant NFT1155_TO_ROUTER = 9;
uint8 constant NFT1155_BATCH_TO_ROUTER = 10;
uint8 constant KINDS = 11;

// CmdPlan.kind: a command of a multicall
uint8 constant C_RACE_SINGLE = 0;
uint8 constant C_RACE = 1;
uint8 constant C_RACE_WITH_BACKUPS = 2;
uint8 constant C_NESTED = 3; // router.multicall with one inner command, called by the router itself
uint8 constant C_ERC20_SEND = 4; // token.transfer of what the router holds
uint8 constant C_NFT721_MINT = 5; // a mint to the router, which its hook passes on to the nftRecipient
uint8 constant C_NFT1155_MINT = 6;
uint8 constant C_NFT1155_BATCH = 7;
uint8 constant C_NATIVE_SEND = 8;
uint8 constant C_FAILING = 9; // a call that reverts
uint8 constant C_CALL_ROUTE = 10; // router.callRoute as a command, which the router refuses
uint8 constant COMMANDS = 11;

// Address roles, resolved per world by `_addr`
uint8 constant R_ZERO = 0;
uint8 constant R_ACCOUNT = 1; // an address without code
uint8 constant R_HOLDER = 2; // a contract that takes NFTs and nothing else
uint8 constant R_ROUTER = 3;
uint8 constant R_PROXY = 4;
uint8 constant R_CALLER = 5; // the caller of the step
uint8 constant R_ROUTE0 = 6; // and the next ROUTES - 1

// Token roles, resolved per world by `_token`
uint8 constant T_NATIVE = 0;
uint8 constant T_A = 1;
uint8 constant T_B = 2;

bytes constant META = "parity";
string constant ALONE = ", alone in its transaction";

uint256 constant NONE = type(uint256).max;

/// @dev A route target, and a contract the cleanups call
contract ParityRoute {
    error RouteFailed();

    uint256 public sink;

    receive() external payable {}

    /// @dev Burns `burn` rounds of hashing, then takes `spend` of the caller's tokenIn and delivers `out` of tokenOut
    /// (native when tokenOut is 0) to `to`, or reverts
    function run(address tokenIn, uint256 spend, address tokenOut, uint256 out, address to, uint256 burn, bool fail)
        external
        payable
    {
        uint256 x = burn;
        for (uint256 i; i < burn; ++i) {
            x = uint256(keccak256(abi.encode(x)));
        }
        if (x == 1) sink = x;
        if (fail) revert RouteFailed();
        if (tokenIn != address(0) && spend != 0) TestERC20(tokenIn).transferFrom(msg.sender, address(this), spend);
        if (tokenOut != address(0)) {
            TestERC20(tokenOut).mint(to, out);
        } else if (out != 0) {
            (bool paid,) = to.call{value: out}("");
            if (!paid) revert RouteFailed();
        }
    }

    /// @dev What cleanupErc20sViaCall calls once it has approved this contract: takes what it approved
    function take(address token) external {
        TestERC20(token).transferFrom(msg.sender, address(this), TestERC20(token).allowance(msg.sender, address(this)));
    }

    function refuse() external payable {
        revert RouteFailed();
    }
}

/// @dev An nftRecipient and a recipient that is a contract: takes every ERC-721 and ERC-1155, and no native
contract NftHolder is ERC721Holder, ERC1155Holder {}

/// @dev A caller: makes a top-level call for the handler, so that the call is the caller's and not the handler's
contract ParityCaller {
    receive() external payable {}

    function forward(address to, bytes calldata data) external payable returns (bool ok, bytes memory ret) {
        (ok, ret) = to.call{value: msg.value}(data);
    }
}

struct Forward {
    ParityCaller from;
    address to;
    uint256 value;
    bytes data;
}

/// @dev Makes several top-level calls inside one call of its own, so that they are one transaction
contract ParityBatch {
    function run(Forward[] calldata calls) external payable returns (bool[] memory oks, bytes[] memory rets) {
        oks = new bool[](calls.length);
        rets = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            (oks[i], rets[i]) = calls[i].from.forward{value: calls[i].value}(calls[i].to, calls[i].data);
        }
    }
}

struct World {
    RelayRouterBase router;
    RelayApprovalProxy proxy;
    TestERC20 tokenA;
    TestERC20 tokenB;
    TestERC721 nft721;
    TestERC1155 nft1155;
    NftHolder holder;
    address account;
    ParityBatch batch;
    ParityRoute[ROUTES] routes;
    ParityCaller[CALLERS] callers;
}

struct RoutePlan {
    uint8 slot; // which route target
    uint8 spender; // 0 the target, 1 none, 2 the next route target, 3 the account
    uint256 out;
    uint8 spend; // 0 all of amountIn, 1 half, 2 nothing
    uint256 burn;
    uint256 gasLimit;
    uint256 fee;
    uint8 value; // 0 none, 1 amountIn, 2 one wei
    bool fail;
}

struct RacePlan {
    uint8 tokenIn; // a token role
    uint8 tokenOut;
    uint256 amountIn;
    uint256 value; // the command's value
    uint256 minOut;
    uint256 flags;
    uint8 recipient; // an address role
    uint256 n;
    uint256 mainCount;
    RoutePlan[ROUTES] routes;
}

struct CmdPlan {
    uint8 kind;
    uint8 innerKind; // C_NESTED: the kind of the one inner command
    bool allowFailure;
    uint8 token;
    uint256 amount;
    uint256 id;
    uint8 to; // an address role
    uint8 nftTo; // C_NESTED: the inner multicall's nftRecipient, an address role
    RacePlan race;
}

struct Plan {
    uint256 seed;
    uint8 kind;
    uint8 caller;
    uint8 nftTo; // an address role
    uint8 refundTo; // an address role
    uint256 msgValue;
    uint256 cmdCount;
    CmdPlan[MAX_COMMANDS] cmds;
    // FUND, VIA_PROXY, the cleanups and the NFT kinds
    uint8 shape;
    uint8 token0;
    uint8 token1;
    uint256 amount0;
    uint256 amount1;
    uint8 to0;
    uint8 to1;
    uint256 id;
}

struct Outcome {
    bool ok;
    bytes ret;
    Vm.Log[] logs;
    uint256 fundsBefore;
    uint256 fundsAfter;
}

struct Rng {
    uint256 s;
}

contract ParityHandler is Test {
    World[WORLDS] internal w;
    // Role pairs: twins[i] of world 1 is the twin of originals[i] of world 0
    address[] internal originals;
    address[] internal twins;
    uint256 internal bloom;
    uint256[] internal minted721;
    uint256 internal nextId = 1000;
    bool internal inTransaction;

    uint256 public steps;
    mapping(string => uint256) public reach;
    mapping(string => uint256) public violations;
    mapping(string => string) public firstViolation;

    constructor() {
        vm.deal(address(this), 1e30);
        _build(0, new RelayRouter());
        _build(1, new RelayRouter_NonTstore());
        _pair(address(w[0].router), address(w[1].router));
        _pair(address(w[0].proxy), address(w[1].proxy));
        _pair(address(w[0].tokenA), address(w[1].tokenA));
        _pair(address(w[0].tokenB), address(w[1].tokenB));
        _pair(address(w[0].nft721), address(w[1].nft721));
        _pair(address(w[0].nft1155), address(w[1].nft1155));
        _pair(address(w[0].holder), address(w[1].holder));
        _pair(w[0].account, w[1].account);
        _pair(address(w[0].batch), address(w[1].batch));
        for (uint256 i; i < ROUTES; ++i) {
            _pair(address(w[0].routes[i]), address(w[1].routes[i]));
        }
        for (uint256 i; i < CALLERS; ++i) {
            _pair(address(w[0].callers[i]), address(w[1].callers[i]));
        }
    }

    function _build(uint256 wi, RelayRouterBase router) internal {
        World storage x = w[wi];
        string memory tag = vm.toString(wi);
        x.router = router;
        x.proxy = new RelayApprovalProxy(address(this), address(router), PERMIT2);
        x.tokenA = new TestERC20();
        x.tokenB = new TestERC20();
        x.nft721 = new TestERC721();
        x.nft1155 = new TestERC1155();
        x.holder = new NftHolder();
        x.account = makeAddr(string.concat("account", tag));
        x.batch = new ParityBatch();
        for (uint256 i; i < ROUTES; ++i) {
            x.routes[i] = new ParityRoute();
            vm.deal(address(x.routes[i]), 1e24);
        }
        for (uint256 i; i < CALLERS; ++i) {
            ParityCaller caller = new ParityCaller();
            x.callers[i] = caller;
            vm.deal(address(caller), 1e24);
            vm.startPrank(address(caller));
            x.tokenA.approve(address(x.proxy), type(uint256).max);
            x.tokenB.approve(address(x.proxy), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _pair(address original, address twin) internal {
        require(original != twin, "a role has one address in both worlds");
        originals.push(original);
        twins.push(twin);
        bloom |= 1 << uint8(uint160(original));
    }

    // ------------------------------------------------------------------------------------------------ the step

    /// @dev One step: a plan alone, which is one transaction, or in a third of the steps up to three plans that are
    /// not FUND, made inside one call of the batch contract, which makes them one transaction
    function step(uint256 seed) external {
        ++steps;
        Rng memory g = Rng(seed);
        uint256 n = _r(g, 3) == 0 ? 2 + _r(g, 2) : 1;
        Plan[] memory plans = new Plan[](n);
        uint256 m;
        for (uint256 i; i < n; ++i) {
            Plan memory p = _plan(uint256(keccak256(abi.encode(seed, i))));
            if (n == 1 || p.kind != FUND) plans[m++] = p;
        }
        assembly ("memory-safe") {
            mstore(plans, m)
        }
        if (m == 0) return;
        if (n == 1) return _run(plans[0]);
        inTransaction = true;
        _runTransaction(plans);
        inTransaction = false;
    }

    function _run(Plan memory p) internal {
        if (p.kind == FUND) {
            for (uint256 wi; wi < WORLDS; ++wi) {
                _fund(wi, p);
            }
            _compareState(p, ALONE);
            return;
        }
        Outcome[WORLDS] memory o;
        for (uint256 wi; wi < WORLDS; ++wi) {
            Forward memory f = _call(wi, p);
            o[wi].fundsBefore = _routerFunds(wi);
            vm.recordLogs();
            (o[wi].ok, o[wi].ret) = f.from.forward{value: f.value}(f.to, f.data);
            o[wi].logs = vm.getRecordedLogs();
            o[wi].fundsAfter = _routerFunds(wi);
        }
        _record721(p);
        _compareResult(p, o, ALONE);
        _compareEvents(p, o, ALONE);
        _compareState(p, ALONE);
        for (uint256 wi; wi < WORLDS; ++wi) {
            _reach(p, o[wi], wi, false);
        }
    }

    function _runTransaction(Plan[] memory plans) internal {
        uint256 n = plans.length;
        Outcome[WORLDS][] memory o = new Outcome[WORLDS][](n);
        Vm.Log[][WORLDS] memory logs;
        for (uint256 wi; wi < WORLDS; ++wi) {
            Forward[] memory calls = new Forward[](n);
            uint256 value;
            for (uint256 i; i < n; ++i) {
                calls[i] = _call(wi, plans[i]);
                value += calls[i].value;
            }
            vm.recordLogs();
            (bool[] memory oks, bytes[] memory rets) = w[wi].batch.run{value: value}(calls);
            logs[wi] = vm.getRecordedLogs();
            for (uint256 i; i < n; ++i) {
                (o[i][wi].ok, o[i][wi].ret) = (oks[i], rets[i]);
            }
        }
        string memory where = string.concat(", in one transaction of ", vm.toString(n), " calls");
        for (uint256 i; i < n; ++i) {
            _record721(plans[i]);
            _compareResult(plans[i], o[i], string.concat(", call ", vm.toString(i), where));
            for (uint256 wi; wi < WORLDS; ++wi) {
                _reach(plans[i], o[i][wi], wi, i > 0);
            }
        }
        Outcome[WORLDS] memory all;
        (all[0].logs, all[1].logs) = (logs[0], logs[1]);
        _compareEvents(plans[n - 1], all, where);
        _compareState(plans[n - 1], where);
    }

    function _fund(uint256 wi, Plan memory p) internal {
        World storage x = w[wi];
        x.tokenA.mint(address(x.router), p.amount0);
        x.tokenB.mint(address(x.router), p.amount1);
        x.tokenA.mint(address(x.callers[p.caller]), p.amount0 * 3);
        x.tokenB.mint(address(x.callers[p.caller]), p.amount1 * 3);
        if (p.shape == 0) vm.deal(address(x.router), address(x.router).balance + 200);
    }

    /// @dev The top-level call of `p` in world `wi`: who makes it, to whom, with what value and calldata
    function _call(uint256 wi, Plan memory p) internal view returns (Forward memory f) {
        World storage x = w[wi];
        f.from = x.callers[p.caller];
        address to = address(x.router);
        uint256 value;
        bytes memory data;
        uint8 kind = p.kind;
        if (kind == MULTICALL || kind == MULTICALL_NFT || kind == VIA_PROXY) {
            value = p.msgValue;
            Call3Value[] memory calls = new Call3Value[](p.cmdCount);
            for (uint256 i; i < p.cmdCount; ++i) {
                calls[i] = _command(wi, p, p.cmds[i], p.cmds[i].kind);
            }
            address refundTo = _addr(wi, p, p.refundTo);
            address nftTo = _addr(wi, p, p.nftTo);
            if (kind != VIA_PROXY) {
                data = abi.encodeCall(RelayRouterBase.multicall, (calls, refundTo, nftTo, META));
            } else {
                to = address(x.proxy);
                uint256 n = p.shape % 3;
                address[] memory tokens = new address[](n);
                uint256[] memory amounts = new uint256[](n == 2 && p.shape >= 6 ? 1 : n);
                if (n > 0) (tokens[0], amounts[0]) = (_token(wi, p.token0), p.amount0);
                if (n > 1) tokens[1] = _token(wi, p.token1);
                if (amounts.length > 1) amounts[1] = p.amount1;
                data = abi.encodeCall(
                    RelayApprovalProxy.transferAndMulticall, (tokens, amounts, calls, refundTo, nftTo, META)
                );
            }
        } else if (kind == CLEANUP_ERC20S || kind == CLEANUP_ERC20S_VIA_CALL) {
            uint256 n = p.shape % 2 + 1;
            address[] memory tokens = new address[](n);
            address[] memory tos = new address[](n);
            uint256[] memory amounts = new uint256[](p.shape == 2 ? n + 1 : n);
            bytes[] memory datas = new bytes[](n);
            for (uint256 i; i < n; ++i) {
                tokens[i] = _token(wi, i == 0 ? p.token0 : p.token1);
                amounts[i] = i == 0 ? p.amount0 : p.amount1;
                tos[i] = _addr(wi, p, i == 0 ? p.to0 : p.to1);
                datas[i] = p.shape == 3
                    ? abi.encodeCall(ParityRoute.refuse, ())
                    : p.shape == 4 ? bytes("") : abi.encodeCall(ParityRoute.take, (tokens[i]));
            }
            data = kind == CLEANUP_ERC20S
                ? abi.encodeCall(RelayRouterBase.cleanupErc20s, (tokens, tos, amounts, META))
                : abi.encodeCall(RelayRouterBase.cleanupErc20sViaCall, (tokens, tos, datas, amounts));
        } else if (kind == CLEANUP_NATIVE) {
            data = abi.encodeCall(RelayRouterBase.cleanupNative, (p.amount0, _addr(wi, p, p.to0), META));
        } else if (kind == CLEANUP_NATIVE_VIA_CALL) {
            bytes memory inner = p.shape == 3 ? abi.encodeCall(ParityRoute.refuse, ()) : bytes("");
            data = abi.encodeCall(RelayRouterBase.cleanupNativeViaCall, (p.amount0, _addr(wi, p, p.to0), inner));
        } else if (kind == NFT721_TO_ROUTER) {
            to = address(x.nft721);
            data = abi.encodeWithSignature("safeMint(address,uint256)", address(x.router), p.id);
        } else if (kind == NFT1155_TO_ROUTER) {
            to = address(x.nft1155);
            data = abi.encodeCall(TestERC1155.mint, (address(x.router), p.id % 3, 1));
        } else {
            to = address(x.nft1155);
            data = abi.encodeCall(TestERC1155.mintBatch, (address(x.router), _ids(), _ones()));
        }
        (f.to, f.value, f.data) = (to, value, data);
    }

    function _command(uint256 wi, Plan memory p, CmdPlan memory c, uint8 kind)
        internal
        view
        returns (Call3Value memory call)
    {
        World storage x = w[wi];
        call.allowFailure = c.allowFailure;
        call.target = address(x.router);
        if (kind <= C_RACE_WITH_BACKUPS) {
            call.value = c.race.value;
            call.callData = _raceCall(wi, p, c.race, kind);
        } else if (kind == C_NESTED) {
            Call3Value[] memory inner = new Call3Value[](1);
            inner[0] = _command(wi, p, c, c.innerKind);
            call.callData = abi.encodeCall(RelayRouterBase.multicall, (inner, address(0), _addr(wi, p, c.nftTo), META));
        } else if (kind == C_ERC20_SEND) {
            call.target = _token(wi, c.token);
            call.callData = abi.encodeWithSignature("transfer(address,uint256)", _addr(wi, p, c.to), c.amount);
        } else if (kind == C_NFT721_MINT) {
            call.target = address(x.nft721);
            call.callData = abi.encodeWithSignature("safeMint(address,uint256)", address(x.router), c.id);
        } else if (kind == C_NFT1155_MINT) {
            call.target = address(x.nft1155);
            call.callData = abi.encodeCall(TestERC1155.mint, (address(x.router), c.id % 3, 1));
        } else if (kind == C_NFT1155_BATCH) {
            call.target = address(x.nft1155);
            call.callData = abi.encodeCall(TestERC1155.mintBatch, (address(x.router), _ids(), _ones()));
        } else if (kind == C_NATIVE_SEND) {
            call.target = _addr(wi, p, c.to);
            call.value = c.amount;
        } else if (kind == C_FAILING) {
            call.target = address(x.routes[c.id % ROUTES]);
            call.callData = abi.encodeCall(ParityRoute.refuse, ());
        } else {
            call.callData = abi.encodeWithSelector(RouteRaceEngine.callRoute.selector);
        }
    }

    function _raceCall(uint256 wi, Plan memory p, RacePlan memory r, uint8 kind) internal view returns (bytes memory) {
        address tokenIn = _token(wi, r.tokenIn);
        address tokenOut = _token(wi, r.tokenOut);
        address recipient = _addr(wi, p, r.recipient);
        address holder = r.flags & DIRECT_OUTPUT != 0 ? recipient : address(w[wi].router);
        Route[] memory routes = new Route[](r.n);
        for (uint256 i; i < r.n; ++i) {
            RoutePlan memory q = r.routes[i];
            address target = address(w[wi].routes[q.slot]);
            address spender = q.spender == 0
                ? target
                : q.spender == 1
                    ? address(0)
                    : q.spender == 2 ? address(w[wi].routes[(q.slot + 1) % ROUTES]) : w[wi].account;
            uint256 spend = q.spend == 0 ? r.amountIn : q.spend == 1 ? r.amountIn / 2 : 0;
            routes[i] = packRoute(
                target,
                spender,
                q.value == 0 ? 0 : q.value == 1 ? r.amountIn : 1,
                q.gasLimit,
                q.fee,
                abi.encodeCall(ParityRoute.run, (tokenIn, spend, tokenOut, q.out, holder, q.burn, q.fail))
            );
        }
        if (kind == C_RACE_SINGLE) {
            return abi.encodeCall(
                IRouteRace.raceSingle, (tokenIn, r.amountIn, tokenOut, r.minOut, recipient, r.flags, routes)
            );
        }
        if (kind == C_RACE) {
            return
                abi.encodeCall(IRouteRace.race, (tokenIn, r.amountIn, tokenOut, r.minOut, recipient, r.flags, routes));
        }
        return abi.encodeCall(
            IRouteRace.raceWithBackups,
            (tokenIn, r.amountIn, tokenOut, r.minOut, recipient, r.flags, routes, r.mainCount)
        );
    }

    function _addr(uint256 wi, Plan memory p, uint8 role) internal view returns (address) {
        World storage x = w[wi];
        if (role == R_ZERO) return address(0);
        if (role == R_ACCOUNT) return x.account;
        if (role == R_HOLDER) return address(x.holder);
        if (role == R_ROUTER) return address(x.router);
        if (role == R_PROXY) return address(x.proxy);
        if (role == R_CALLER) return address(x.callers[p.caller]);
        return address(x.routes[role - R_ROUTE0]);
    }

    function _token(uint256 wi, uint8 role) internal view returns (address) {
        if (role == T_A) return address(w[wi].tokenA);
        if (role == T_B) return address(w[wi].tokenB);
        return address(0);
    }

    function _ids() internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        (ids[0], ids[1]) = (1, 2);
    }

    function _ones() internal pure returns (uint256[] memory ones) {
        ones = new uint256[](2);
        (ones[0], ones[1]) = (1, 1);
    }

    function _record721(Plan memory p) internal {
        if (p.kind == NFT721_TO_ROUTER) minted721.push(p.id);
        for (uint256 i; i < p.cmdCount; ++i) {
            CmdPlan memory c = p.cmds[i];
            if (c.kind == C_NFT721_MINT || (c.kind == C_NESTED && c.innerKind == C_NFT721_MINT)) minted721.push(c.id);
        }
    }

    /// @dev What the router holds of native, tokenA and tokenB, summed: tells whether a call moved what it held
    function _routerFunds(uint256 wi) internal view returns (uint256) {
        World storage x = w[wi];
        address router = address(x.router);
        return router.balance + x.tokenA.balanceOf(router) + x.tokenB.balanceOf(router);
    }

    // ------------------------------------------------------------------------------------------------ the plan

    function _r(Rng memory g, uint256 n) internal pure returns (uint256) {
        g.s = uint256(keccak256(abi.encode(g.s)));
        return g.s % n;
    }

    function _plan(uint256 seed) internal returns (Plan memory p) {
        Rng memory g = Rng(seed);
        p.seed = seed;
        uint256 k = _r(g, 20);
        p.kind = k < 3
            ? FUND
            : k < 8
                ? MULTICALL
                : k < 10
                    ? MULTICALL_NFT
                    : k < 13 ? VIA_PROXY : uint8(CLEANUP_ERC20S + (k - 13) % (KINDS - CLEANUP_ERC20S));
        p.caller = uint8(_r(g, CALLERS));
        p.shape = uint8(_r(g, 8));
        p.token0 = uint8(1 + _r(g, 2));
        p.token1 = uint8(1 + _r(g, 2));
        p.id = nextId++;
        World storage x = w[0];
        address router = address(x.router);
        if (p.kind == FUND) {
            p.amount0 = [0, 100, 1000, 5000][_r(g, 4)];
            p.amount1 = [0, 100, 1000, 5000][_r(g, 4)];
            p.shape %= 2;
        } else if (p.kind == CLEANUP_ERC20S || p.kind == CLEANUP_ERC20S_VIA_CALL) {
            p.shape %= 5;
            p.amount0 = _cleanupAmount(g, _balance(0, p.token0, router));
            p.amount1 = _cleanupAmount(g, _balance(0, p.token1, router));
            p.to0 = _cleanupTo(g, p.kind);
            p.to1 = _cleanupTo(g, p.kind);
        } else if (p.kind == CLEANUP_NATIVE || p.kind == CLEANUP_NATIVE_VIA_CALL) {
            p.shape %= 4;
            p.amount0 = _cleanupAmount(g, router.balance);
            uint256 t = _r(g, 4);
            p.to0 = p.kind == CLEANUP_NATIVE
                ? [R_ZERO, R_ACCOUNT, R_HOLDER, R_ROUTE0][t]
                : [R_ROUTE0, uint8(R_ROUTE0 + 1), R_HOLDER, R_ACCOUNT][t];
        } else if (p.kind == MULTICALL || p.kind == MULTICALL_NFT || p.kind == VIA_PROXY) {
            _planMulticall(g, p);
        }
    }

    function _cleanupAmount(Rng memory g, uint256 balance) internal pure returns (uint256) {
        uint256 k = _r(g, 5);
        return k < 2 ? 0 : k == 2 ? balance / 2 : k == 3 ? 7 : 1e30;
    }

    function _cleanupTo(Rng memory g, uint8 kind) internal pure returns (uint8) {
        if (kind == CLEANUP_ERC20S_VIA_CALL) return uint8(R_ROUTE0 + _r(g, 2));
        return [R_ACCOUNT, R_HOLDER, R_CALLER, R_ROUTE0][_r(g, 4)];
    }

    function _balance(uint256 wi, uint8 token, address who) internal view returns (uint256) {
        if (token == T_NATIVE) return who.balance;
        return TestERC20(_token(wi, token)).balanceOf(who);
    }

    function _planMulticall(Rng memory g, Plan memory p) internal {
        address router = address(w[0].router);
        address caller = address(w[0].callers[p.caller]);
        if (p.kind == MULTICALL_NFT) {
            p.nftTo = [
                R_ACCOUNT, R_HOLDER, R_ACCOUNT, R_HOLDER, R_ACCOUNT, R_HOLDER, R_ACCOUNT, R_HOLDER, R_ROUTER
            ][_r(g, 9)];
        } else if (p.kind == VIA_PROXY) {
            p.nftTo = [R_ZERO, R_ACCOUNT, R_HOLDER][_r(g, 3)];
        }
        uint256 rf = _r(g, 6);
        p.refundTo = rf < 3 ? R_ZERO : rf == 3 ? R_ACCOUNT : rf == 4 ? R_CALLER : R_ROUTER;
        if (p.kind == VIA_PROXY && p.refundTo == R_ZERO && _r(g, 4) != 0) p.refundTo = R_ACCOUNT;
        p.msgValue = [0, 0, 50, 300][_r(g, 4)];
        // The proxy moves amount0 of token0 and amount1 of token1 from the caller to the router
        uint256[3] memory extra;
        if (p.kind == VIA_PROXY) {
            p.amount0 = _r(g, 5) == 0 ? 1e30 : _balance(0, p.token0, caller) / (1 + _r(g, 3));
            p.amount1 = _balance(0, p.token1, caller) / (1 + _r(g, 3));
            uint256 n = p.shape % 3;
            if (n > 0) extra[p.token0] += p.amount0;
            if (n > 1) extra[p.token1] += p.amount1;
        }
        uint256[3] memory have =
            [router.balance + p.msgValue, _balance(0, T_A, router) + extra[1], _balance(0, T_B, router) + extra[2]];
        uint256 count = _r(g, 20);
        p.cmdCount = count == 0 ? 0 : count < 12 ? 1 : count < 17 ? 2 : 3;
        for (uint256 i; i < p.cmdCount; ++i) {
            CmdPlan memory c = p.cmds[i];
            c.kind = [0, 1, 2, 0, 1, 2, 0, 1, 2, 3, 3, 4, 4, 5, 6, 7, 8, 8, 9, 10][_r(g, 20)];
            // An nftRecipient is set for the NFT mints to go to in half of these multicalls
            if (p.nftTo != R_ZERO && p.nftTo != R_ROUTER && _r(g, 2) == 0) {
                c.kind = uint8(C_NFT721_MINT + _r(g, 3));
            }
            c.innerKind = uint8(C_ERC20_SEND + _r(g, COMMANDS - C_ERC20_SEND));
            if (c.kind == C_NESTED && _r(g, 4) == 0) c.innerKind = uint8(_r(g, 3));
            c.allowFailure = _r(g, c.kind <= C_RACE_WITH_BACKUPS ? 16 : 2) == 0;
            c.token = uint8(1 + _r(g, 2));
            c.to = [R_ACCOUNT, R_HOLDER, R_CALLER, R_ROUTE0][_r(g, 4)];
            c.nftTo = [R_ZERO, R_ACCOUNT, R_HOLDER][_r(g, 3)];
            c.id = nextId++;
            uint256 a = _r(g, 4);
            c.amount = c.kind == C_NATIVE_SEND ? [1, 30, 200, 1e30][a] : a == 3 ? 1e30 : have[c.token] / (1 + a);
            _planRace(g, c.race, have);
        }
    }

    function _planRace(Rng memory g, RacePlan memory r, uint256[3] memory have) internal pure {
        uint256 io = _r(g, 20);
        (r.tokenIn, r.tokenOut) = io < 8
            ? (T_A, T_B)
            : io < 12
                ? (T_B, T_A)
                : io < 15 ? (T_NATIVE, T_B) : io < 17 ? (T_A, T_NATIVE) : io < 19 ? (T_B, T_NATIVE) : (T_A, T_A);
        uint256 a = _r(g, 6);
        uint256 balance = have[r.tokenIn];
        r.amountIn = a < 2 ? balance : a == 2 ? balance / 2 : a == 3 ? balance / 3 : a == 4 ? 0 : balance + 1;
        if (r.tokenIn == T_NATIVE) {
            r.value = _r(g, 6) == 0 ? r.amountIn / 2 : r.amountIn;
        } else if (_r(g, 6) == 0) {
            r.value = 1;
        }
        r.flags = _r(g, 32);
        uint256 rc = _r(g, 24);
        r.recipient = rc < 15 ? R_ACCOUNT : rc < 19 ? R_HOLDER : rc < 23 ? R_ROUTER : R_ZERO;
        r.n = 1 + _r(g, ROUTES);
        r.mainCount = _r(g, 16) == 0 ? [0, r.n + 1][_r(g, 2)] : 1 + _r(g, r.n);
        // Outputs from a short list, so that mains often tie on output; a fee of 0 or 1000 ppm on top
        uint256[5] memory outs = [uint256(0), 40, 100, 100, 160];
        for (uint256 i; i < r.n; ++i) {
            RoutePlan memory q = r.routes[i];
            q.slot = uint8(_r(g, ROUTES));
            q.spender = uint8([0, 0, 0, 1, 2, 3][_r(g, 6)]);
            q.out = outs[_r(g, 5)];
            q.spend = uint8(_r(g, 3));
            q.burn = [0, 0, 20, 60][_r(g, 4)];
            uint256 gl = _r(g, 40);
            q.gasLimit = gl == 0 ? 0 : gl < 6 ? 40_000 : 1_000_000;
            uint256 f = _r(g, 40);
            q.fee = f < 28 ? 0 : f < 39 ? 1000 : 1_000_000;
            uint256 v = _r(g, 10);
            q.value = v < 7 ? 0 : v < 9 ? 1 : 2;
            if (r.tokenIn == T_NATIVE && v == 0) q.value = 1;
            q.fail = _r(g, 6) == 0;
        }
        // In a quarter of the races the second route copies the first except for its burn, so that if both lead,
        // their trial gas decides between them
        if (r.n > 1 && _r(g, 4) == 0) {
            (RoutePlan memory r0, RoutePlan memory r1) = (r.routes[0], r.routes[1]);
            (r1.out, r1.fee, r1.gasLimit, r1.spender, r1.spend, r1.value) =
            (r0.out, r0.fee, r0.gasLimit, r0.spender, r0.spend, r0.value);
            (r0.fail, r1.fail) = (false, false);
            r1.burn = r0.burn == 60 ? 0 : 60;
            if (r.mainCount == 1) r.mainCount = 2;
        }
        r.minOut = [0, 1, 40, 99, 100, 101, 150, 160][_r(g, 8)];
        if (r.minOut == 0 && _r(g, 2) == 0) r.minOut = 1;
    }

    // ------------------------------------------------------------------------------------------------ comparing

    function _compareResult(Plan memory p, Outcome[WORLDS] memory o, string memory where) internal {
        if (o[0].ok != o[1].ok) {
            _violate(
                "result",
                p,
                string.concat(
                    where,
                    ": ",
                    o[0].ok ? "succeeded" : "reverted",
                    " on the transient router and ",
                    o[1].ok ? "succeeded" : "reverted",
                    " on the storage router; data ",
                    _short(o[0].ret),
                    " and ",
                    _short(o[1].ret)
                )
            );
            return;
        }
        bytes memory mapped = _norm(o[0].ret);
        if (keccak256(mapped) != keccak256(o[1].ret)) {
            _violate(
                "result",
                p,
                string.concat(
                    where,
                    ": ",
                    o[0].ok ? "both succeeded" : "both reverted",
                    ", with ",
                    _short(mapped),
                    " (by role) and ",
                    _short(o[1].ret)
                )
            );
        }
    }

    /// @dev SolverCallExecuted carries keccak256 of a command's calldata. The calldata holds each world's own
    /// addresses, so the two hashes differ and cannot be mapped by role: that word is zeroed on both sides. The
    /// event's target and value are still compared, and SolverCallExecutedHashTest checks the hash itself
    function _maskSolverHash(bytes32 topic0, bytes memory data) internal pure returns (bytes memory out) {
        out = bytes.concat(data);
        if (topic0 == keccak256("SolverCallExecuted(address,bytes32,uint256)") && out.length >= 64) {
            for (uint256 j = 32; j < 64; ++j) {
                out[j] = 0;
            }
        }
    }

    function _compareEvents(Plan memory p, Outcome[WORLDS] memory o, string memory where) internal {
        Vm.Log[] memory a = o[0].logs;
        Vm.Log[] memory b = o[1].logs;
        if (a.length != b.length) {
            _violate(
                "events",
                p,
                string.concat(
                    where, ": ", vm.toString(a.length), " events and ", vm.toString(b.length), _firstTopics(a, b)
                )
            );
            return;
        }
        for (uint256 i; i < a.length; ++i) {
            bytes32 topic0 = a[i].topics.length > 0 ? a[i].topics[0] : bytes32(0);
            bool same = _twin(a[i].emitter) == b[i].emitter && a[i].topics.length == b[i].topics.length
                && keccak256(_maskSolverHash(topic0, _norm(a[i].data))) == keccak256(_maskSolverHash(topic0, b[i].data));
            for (uint256 t; same && t < a[i].topics.length; ++t) {
                same = bytes32(_norm(abi.encodePacked(a[i].topics[t]))) == b[i].topics[t];
            }
            if (!same) {
                _violate(
                    "events",
                    p,
                    string.concat(
                        where,
                        ": event ",
                        vm.toString(i),
                        " of ",
                        vm.toString(a.length),
                        " differs: topic ",
                        vm.toString(a[i].topics.length > 0 ? a[i].topics[0] : bytes32(0)),
                        ", data ",
                        _short(_norm(a[i].data)),
                        " (by role) and ",
                        _short(b[i].data)
                    )
                );
                return;
            }
        }
    }

    function _firstTopics(Vm.Log[] memory a, Vm.Log[] memory b) internal pure returns (string memory s) {
        uint256 n = a.length < b.length ? a.length : b.length;
        for (uint256 i; i < n; ++i) {
            bytes32 ta = a[i].topics.length > 0 ? a[i].topics[0] : bytes32(0);
            bytes32 tb = b[i].topics.length > 0 ? b[i].topics[0] : bytes32(0);
            if (ta != tb) return string.concat("; first different event at ", vm.toString(i));
        }
        return string.concat("; the first ", vm.toString(n), " start alike");
    }

    /// @dev Every balance, allowance and NFT owner that a call can change, with owners by role. Per holder: native,
    /// tokenA, tokenB, ERC-721 count, ERC-1155 ids 0 to 2 packed. Then the allowances of both tokens from the
    /// router and from each caller, the only accounts that approve anything, to every holder. Then the owner of
    /// every ERC-721 id a step tried to mint.
    function _state(uint256 wi) internal view returns (uint256[] memory v) {
        World storage x = w[wi];
        address[] memory who = _holders(wi);
        uint256 n = who.length;
        v = new uint256[](n * BALANCES + APPROVERS.length * n * 2 + minted721.length);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            address h = who[i];
            v[k++] = h.balance;
            v[k++] = x.tokenA.balanceOf(h);
            v[k++] = x.tokenB.balanceOf(h);
            v[k++] = x.nft721.balanceOf(h);
            v[k++] = x.nft1155.balanceOf(h, 0) + (x.nft1155.balanceOf(h, 1) << 64) + (x.nft1155.balanceOf(h, 2) << 128);
        }
        for (uint256 a; a < APPROVERS.length; ++a) {
            address owner = who[APPROVERS[a]];
            for (uint256 j; j < n; ++j) {
                v[k++] = x.tokenA.allowance(owner, who[j]);
                v[k++] = x.tokenB.allowance(owner, who[j]);
            }
        }
        for (uint256 i; i < minted721.length; ++i) {
            try x.nft721.ownerOf(minted721[i]) returns (address owner) {
                v[k++] = uint160(wi == 0 ? _twin(owner) : owner);
            } catch {
                v[k++] = NONE;
            }
        }
    }

    uint256 internal constant BALANCES = 5;
    uint256[4] internal APPROVERS = [0, 5 + ROUTES, 6 + ROUTES, 7 + ROUTES];

    function _holders(uint256 wi) internal view returns (address[] memory who) {
        World storage x = w[wi];
        who = new address[](5 + ROUTES + CALLERS);
        (who[0], who[1], who[2], who[3], who[4]) =
        (address(x.router), address(x.proxy), address(x.holder), x.account, address(x.batch));
        for (uint256 i; i < ROUTES; ++i) {
            who[5 + i] = address(x.routes[i]);
        }
        for (uint256 i; i < CALLERS; ++i) {
            who[5 + ROUTES + i] = address(x.callers[i]);
        }
    }

    function _compareState(Plan memory p, string memory where) internal {
        uint256[] memory a = _state(0);
        uint256[] memory b = _state(1);
        for (uint256 i; i < a.length; ++i) {
            if (a[i] != b[i]) {
                _violate(
                    "balances",
                    p,
                    string.concat(
                        where,
                        ": ",
                        _stateName(i),
                        " is ",
                        vm.toString(a[i]),
                        " on the transient side, ",
                        vm.toString(b[i])
                    )
                );
                return;
            }
        }
    }

    function _stateName(uint256 i) internal view returns (string memory) {
        string[12] memory names = [
            "router",
            "proxy",
            "holder",
            "account",
            "batch",
            "route 0",
            "route 1",
            "route 2",
            "route 3",
            "caller 0",
            "caller 1",
            "caller 2"
        ];
        uint256 n = names.length;
        if (i < n * BALANCES) {
            return string.concat(
                names[i / BALANCES], " ", ["native", "tokenA", "tokenB", "ERC-721 count", "ERC-1155"][i % BALANCES]
            );
        }
        i -= n * BALANCES;
        if (i < APPROVERS.length * n * 2) {
            return string.concat(
                "allowance from ",
                names[APPROVERS[i / (2 * n)]],
                " to ",
                names[(i % (2 * n)) / 2],
                i % 2 == 0 ? " of tokenA" : " of tokenB"
            );
        }
        return string.concat("owner of ERC-721 ", vm.toString(minted721[i - APPROVERS.length * n * 2]));
    }

    /// @dev `b` with every address of world 0 replaced by its twin of world 1
    function _norm(bytes memory b) internal view returns (bytes memory out) {
        out = bytes.concat(b);
        address[] memory from = originals;
        address[] memory to = twins;
        uint256 filter = bloom;
        uint256 n = out.length;
        for (uint256 i; i + 20 <= n;) {
            uint256 word;
            assembly ("memory-safe") {
                word := mload(add(add(out, 0x20), i))
            }
            address candidate = address(uint160(word >> 96));
            uint256 j = filter & (1 << uint8(uint160(candidate))) == 0 ? NONE : _find(from, candidate);
            if (j == NONE) {
                ++i;
                continue;
            }
            word = (uint256(uint160(to[j])) << 96) | (word & type(uint96).max);
            assembly ("memory-safe") {
                mstore(add(add(out, 0x20), i), word)
            }
            i += 20;
        }
    }

    function _find(address[] memory list, address a) internal pure returns (uint256) {
        for (uint256 j; j < list.length; ++j) {
            if (list[j] == a) return j;
        }
        return NONE;
    }

    function _twin(address a) internal view returns (address) {
        uint256 j = _find(originals, a);
        return j == NONE ? a : twins[j];
    }

    function _short(bytes memory b) internal pure returns (string memory) {
        if (b.length <= 100) return vm.toString(b);
        bytes memory head = new bytes(100);
        for (uint256 i; i < 100; ++i) {
            head[i] = b[i];
        }
        return string.concat(vm.toString(head), "...(", vm.toString(b.length), " bytes)");
    }

    function _violate(string memory id, Plan memory p, string memory what) internal {
        ++violations[string.concat(id, inTransaction ? " in one transaction" : " alone in a transaction")];
        if (violations[id]++ == 0) {
            firstViolation[id] = string.concat(
                id,
                " at step ",
                vm.toString(steps),
                " (plan seed ",
                vm.toString(p.seed),
                ", ",
                kindName(p.kind),
                ")",
                what
            );
        }
    }

    // ------------------------------------------------------------------------------------------------ reach

    function kindName(uint8 kind) public pure returns (string memory) {
        return [
            "fund",
            "multicall",
            "multicall with nftRecipient",
            "multicall via proxy",
            "cleanupErc20s",
            "cleanupErc20sViaCall",
            "cleanupNative",
            "cleanupNativeViaCall",
            "ERC-721 to the router",
            "ERC-1155 to the router",
            "ERC-1155 batch to the router"
        ][kind];
    }

    function commandName(uint8 kind) public pure returns (string memory) {
        return [
            "raceSingle",
            "race",
            "raceWithBackups",
            "nested multicall",
            "ERC-20 send",
            "ERC-721 mint to the router",
            "ERC-1155 mint to the router",
            "ERC-1155 batch mint to the router",
            "native send",
            "failing call",
            "callRoute"
        ][kind];
    }

    function variantName(uint256 wi) public pure returns (string memory) {
        return wi == 0 ? "transient" : "storage";
    }

    function _reach(Plan memory p, Outcome memory o, uint256 wi, bool later) internal {
        string memory v = variantName(wi);
        string memory outcome = o.ok ? "succeeded" : "reverted";
        ++reach[string.concat(kindName(p.kind), ", ", v, ", ", outcome)];
        if (later) ++reach[string.concat("a later call in one transaction, ", v, ", ", outcome)];
        for (uint256 i; i < p.cmdCount; ++i) {
            CmdPlan memory c = p.cmds[i];
            ++reach[string.concat("command ", commandName(c.kind), ", ", v, ", in a call that ", outcome)];
            if (c.kind == C_NESTED) {
                string memory inner = c.innerKind <= C_RACE_WITH_BACKUPS
                    ? "race command"
                    : c.innerKind >= C_NFT721_MINT && c.innerKind <= C_NFT1155_BATCH
                        ? "NFT mint"
                        : commandName(c.innerKind);
                ++reach[string.concat("nested ", inner, ", ", v, ", in a call that ", outcome)];
            }
            if (!o.ok || c.kind > C_RACE_WITH_BACKUPS) continue;
            if (p.kind != VIA_PROXY && c.race.tokenIn != T_NATIVE && c.race.amountIn != 0) {
                ++reach[string.concat("carry: a race spent input that an earlier call left, ", v)];
            }
            if (c.kind != C_RACE_SINGLE && _tie(c.race)) {
                ++reach[string.concat("a race with a tie on net between two mains, ", v)];
            }
        }
        if (o.ok && p.kind >= CLEANUP_ERC20S && p.kind <= CLEANUP_NATIVE_VIA_CALL && o.fundsAfter < o.fundsBefore) {
            ++reach[string.concat("carry: a cleanup moved funds that an earlier call left, ", v)];
        }
    }

    function _isMulticall(uint8 kind) internal pure returns (bool) {
        return kind == MULTICALL || kind == MULTICALL_NFT || kind == VIA_PROXY;
    }

    /// @dev Whether two mains that run, at or above the minimum, have the same output and fee and burn different
    /// amounts, so that their trial gas decides between them if they lead
    function _tie(RacePlan memory r) internal pure returns (bool) {
        uint256 mains = r.mainCount == 0 || r.mainCount > r.n ? 0 : r.mainCount;
        for (uint256 i; i < mains; ++i) {
            RoutePlan memory a = r.routes[i];
            if (a.fail || a.out < r.minOut || a.gasLimit != 1_000_000) continue;
            for (uint256 j = i + 1; j < mains; ++j) {
                RoutePlan memory b = r.routes[j];
                if (!b.fail && b.out == a.out && b.fee == a.fee && b.gasLimit == a.gasLimit && b.burn != a.burn) {
                    return true;
                }
            }
        }
        return false;
    }
}

contract RelayRouterParityTest is Test {
    ParityHandler internal handler;

    function setUp() public {
        handler = new ParityHandler();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ParityHandler.step.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_S3_sameResult() public view {
        _assertClean("result");
    }

    function invariant_S3_sameEvents() public view {
        _assertClean("events");
    }

    function invariant_S3_sameBalances() public view {
        _assertClean("balances");
    }

    function _assertClean(string memory id) internal view {
        assertEq(handler.violations(id), 0, handler.firstViolation(id));
    }

    function test_reach() public {
        for (uint256 seed; seed < REACH_STEPS; ++seed) {
            handler.step(seed);
        }
        _assertClean("result");
        _assertClean("events");
        _assertClean("balances");
        for (uint256 wi; wi < 2; ++wi) {
            string memory v = handler.variantName(wi);
            for (uint8 kind = MULTICALL; kind < KINDS; ++kind) {
                string memory name = string.concat(handler.kindName(kind), ", ", v, ", ");
                // Outside a multicall the router has no nftRecipient, so its hooks always revert
                if (kind < NFT721_TO_ROUTER) _reached(string.concat(name, "succeeded"));
                _reached(string.concat(name, "reverted"));
            }
            for (uint8 kind; kind < COMMANDS; ++kind) {
                string memory name = string.concat("command ", handler.commandName(kind), ", ", v, ", in a call that ");
                // The router refuses a callRoute command whether it may fail or not
                if (kind != C_CALL_ROUTE) _reached(string.concat(name, "succeeded"));
                _reached(string.concat(name, "reverted"));
            }
            // A race command inside a nested multicall always reverts the multicall
            _reached(string.concat("nested race command, ", v, ", in a call that reverted"));
            _reached(string.concat("nested NFT mint, ", v, ", in a call that succeeded"));
            _reached(string.concat("carry: a race spent input that an earlier call left, ", v));
            _reached(string.concat("carry: a cleanup moved funds that an earlier call left, ", v));
            _reached(string.concat("a race with a tie on net between two mains, ", v));
            _reached(string.concat("a later call in one transaction, ", v, ", succeeded"));
            _reached(string.concat("a later call in one transaction, ", v, ", reverted"));
        }
    }

    uint256 internal constant REACH_STEPS = 220;

    function _reached(string memory key) internal {
        uint256 count = handler.reach(key);
        emit log_named_uint(key, count);
        assertGt(count, 0, string.concat("not reached: ", key));
    }
}
