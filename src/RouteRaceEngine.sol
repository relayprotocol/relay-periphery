// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {Route, RouteLib} from "./interfaces/IRouteRace.sol";

abstract contract RouteRaceEngine {
    using SafeTransferLib for address;

    error NoRoutes();
    error InvalidMainCount(uint256 mainCount, uint256 routeCount);
    error AllRoutesFailed();
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);
    error WinnerUnderperformed(uint256 amountOut, uint256 trialAmountOut);
    error MinAmountOutRequired();
    error RouteGasLimitRequired();
    error InvalidRouteTarget(address target);
    error InvalidRouteFee(uint256 index, uint256 feePpm);
    error ExcessiveRouteValue();
    error RouteApprovalFailed();
    error ValueOnNativeOutput();
    error InvalidMsgValue();
    error IdenticalTokens();
    error RecipientCannotBeZeroAddress();
    error InvalidRecipient(address recipient);
    error OnlySelf();
    error TrialResult(uint256 amountOut);
    error AllowanceNotCleared();
    error BalanceReadFailed();
    error InsufficientInput(uint256 balance, uint256 amountIn);
    error InputOverspent(uint256 spent, uint256 amountIn);
    error OutputBalanceDecreased();

    event RouteTrialSucceeded(
        uint256 index, address indexed target, uint256 amountOut, uint256 feePpm, uint256 gasUsed
    );
    event RouteTrialFailed(uint256 index, address indexed target, bytes revertData, uint256 gasUsed);
    event RouteRaceWon(
        uint256 indexed index,
        address indexed target,
        uint256 amountOut,
        uint256 trialedCount,
        uint256 mainCount,
        uint256 feePpm,
        uint256 gasUsed
    );
    event RouteExecutionFailed(uint256 indexed index, address indexed target, bytes revertData, uint256 gasUsed);

    address internal constant ERC1820_REGISTRY = 0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24;
    address internal constant ERC820_REGISTRY = 0x820b586C8C28125366C998641B09DCbE7d4cBF06;
    uint256 internal constant FEE_DENOMINATOR = 1_000_000;
    uint256 internal constant TOKEN_CALL_GAS = 100_000;
    uint256 internal constant TOKEN_READ_GAS = 30_000;
    uint256 internal constant EMIT_EVENTS = 1;
    uint256 internal constant KEEP_ALLOWANCES = 2;
    uint256 internal constant DIRECT_OUTPUT = 4;
    uint256 internal constant NO_INPUT_REFUND = 8;
    uint256 internal constant LOG_FUNDS_MOVEMENT = 16;
    uint256 private constant MAX_REVERT_DATA_BYTES = 512;
    uint256 private constant NO_WINNER = type(uint256).max;
    uint256 private constant NEVER_COMMIT = type(uint256).max;
    uint256 private constant REVERTED = 0;
    uint256 private constant MEASURED = 1;
    uint256 private constant COMMITTED = 2;

    struct Race {
        address tokenIn;
        uint256 amountIn;
        address tokenOut;
        uint256 minAmountOut;
        address holder;
        uint256 outBefore;
        uint256 inBefore;
        uint256 maxRouteValue;
        uint256 flags;
        address approved;
        uint256 winnerGas;
    }

    struct Lead {
        uint256 index;
        uint256 output;
        uint256 net;
        uint256 gasUsed;
    }

    function _requireRaceActive() internal view virtual;
    function _logDelivery(address recipient, address tokenOut, uint256 amountOut) internal virtual;

    function _isHookRegistry(address target) internal pure returns (bool) {
        return target == ERC1820_REGISTRY || target == ERC820_REGISTRY;
    }

    function _raceSingle(bytes calldata args, uint256 value, address refundTo)
        internal
        returns (uint256 winnerIndex, uint256 amountOut)
    {
        (Race memory r, address recipient, Route[] calldata routes) = _open(args, value);
        (winnerIndex, amountOut) = _firstAcceptable(r, routes, 0, 0, false);
        unchecked {
            _settle(r, routes, recipient, refundTo, winnerIndex, amountOut, winnerIndex + 1, 1);
        }
    }

    function _race(bytes calldata args, uint256 value, address refundTo)
        internal
        returns (uint256 winnerIndex, uint256 amountOut)
    {
        (Race memory r, address recipient, Route[] calldata routes) = _open(args, value);
        uint256 mainCount = routes.length;
        bool won;
        uint256 bestOutput;
        bool anyOutput;
        (won, winnerIndex, amountOut, bestOutput, anyOutput) = _compete(r, routes, mainCount);
        if (!won) _revertWithoutWinner(anyOutput, bestOutput, r.minAmountOut);
        _settle(r, routes, recipient, refundTo, winnerIndex, amountOut, mainCount, mainCount);
    }

    function _raceWithBackups(bytes calldata args, uint256 value, address refundTo)
        internal
        returns (uint256 winnerIndex, uint256 amountOut)
    {
        (Race memory r, address recipient, Route[] calldata routes) = _open(args, value);
        uint256 mainCount;
        assembly ("memory-safe") {
            mainCount := calldataload(add(args.offset, 0xe0))
        }
        if (mainCount == 0 || mainCount > routes.length) revert InvalidMainCount(mainCount, routes.length);
        uint256 trialedCount = mainCount;
        bool won;
        uint256 bestOutput;
        bool anyOutput;
        if (mainCount != 1) (won, winnerIndex, amountOut, bestOutput, anyOutput) = _compete(r, routes, mainCount);
        if (!won) {
            (winnerIndex, amountOut) =
                _firstAcceptable(r, routes, mainCount == 1 ? 0 : mainCount, bestOutput, anyOutput);
            unchecked {
                trialedCount = winnerIndex + 1;
            }
        }
        _settle(r, routes, recipient, refundTo, winnerIndex, amountOut, trialedCount, mainCount);
    }

    function _open(bytes calldata args, uint256 value)
        private
        view
        returns (Race memory r, address recipient, Route[] calldata routes)
    {
        address tokenIn;
        uint256 amountIn;
        address tokenOut;
        uint256 minAmountOut;
        uint256 flags;
        assembly ("memory-safe") {
            let base := args.offset
            tokenIn := shr(96, shl(96, calldataload(base)))
            amountIn := calldataload(add(base, 0x20))
            tokenOut := shr(96, shl(96, calldataload(add(base, 0x40))))
            minAmountOut := calldataload(add(base, 0x60))
            recipient := shr(96, shl(96, calldataload(add(base, 0x80))))
            flags := calldataload(add(base, 0xa0))
            let routesAt := add(base, calldataload(add(base, 0xc0)))
            routes.length := calldataload(routesAt)
            routes.offset := add(routesAt, 0x20)
        }
        if (routes.length == 0) revert NoRoutes();
        if (recipient == address(0)) revert RecipientCannotBeZeroAddress();
        if (minAmountOut == 0) revert MinAmountOutRequired();
        if (tokenIn == tokenOut) revert IdenticalTokens();
        r.tokenIn = tokenIn;
        r.amountIn = amountIn;
        r.tokenOut = tokenOut;
        r.minAmountOut = minAmountOut;
        r.flags = flags;
        if (tokenIn == address(0)) {
            if (value < amountIn) revert InvalidMsgValue();
            r.maxRouteValue = amountIn;
        } else {
            uint256 balance = _balanceOf(tokenIn, address(this));
            if (balance < amountIn) revert InsufficientInput(balance, amountIn);
            unchecked {
                r.inBefore = balance - amountIn;
            }
            r.maxRouteValue = value;
        }
        address holder = flags & DIRECT_OUTPUT == 0 ? address(this) : recipient;
        r.holder = holder;
        r.outBefore = tokenOut == address(0) ? holder.balance : _balanceOf(tokenOut, holder);
    }

    function _settle(
        Race memory r,
        Route[] calldata routes,
        address recipient,
        address refundTo,
        uint256 winnerIndex,
        uint256 amountOut,
        uint256 trialedCount,
        uint256 mainCount
    ) private {
        address tokenIn = r.tokenIn;
        uint256 flags = r.flags;
        if (tokenIn != address(0) && flags & KEEP_ALLOWANCES == 0) {
            _revokeGrants(tokenIn, routes, trialedCount, winnerIndex);
        }
        if (recipient != r.holder) {
            address tokenOut = r.tokenOut;
            if (tokenOut == address(0)) recipient.safeTransferETH(amountOut);
            else tokenOut.safeTransfer(recipient, amountOut);
        }
        if (flags & EMIT_EVENTS != 0) {
            emit RouteRaceWon(
                winnerIndex,
                _targetAt(routes, winnerIndex),
                amountOut,
                trialedCount,
                mainCount,
                RouteLib.feePpmOf(_routeAt(routes, winnerIndex).packed),
                r.winnerGas
            );
        }
        if (flags & LOG_FUNDS_MOVEMENT != 0 && recipient != address(this)) {
            _logDelivery(recipient, r.tokenOut, amountOut);
        }
        if (tokenIn != address(0)) {
            uint256 balance = _balanceOf(tokenIn, address(this));
            uint256 inBefore = r.inBefore;
            if (balance < inBefore) {
                unchecked {
                    revert InputOverspent(r.amountIn + (inBefore - balance), r.amountIn);
                }
            }
            if (balance != inBefore && flags & NO_INPUT_REFUND == 0 && refundTo != address(this)) {
                unchecked {
                    tokenIn.safeTransfer(refundTo, balance - inBefore);
                }
            }
        }
    }

    function _firstAcceptable(Race memory r, Route[] calldata routes, uint256 from, uint256 bestOutput, bool anyOutput)
        private
        returns (uint256, uint256)
    {
        uint256 minAmountOut = r.minAmountOut;
        bool emitEvents = r.flags & EMIT_EVENTS != 0;
        uint256 routeCount = routes.length;
        for (uint256 i = from; i < routeCount;) {
            (uint256 status, uint256 output, uint256 gasUsed) = _attempt(r, routes, i, minAmountOut, false);
            if (status == COMMITTED) {
                r.winnerGas = gasUsed;
                return (i, output);
            }
            if (emitEvents) _emitTrial(routes, i, status, output, gasUsed);
            if (status == MEASURED) {
                anyOutput = true;
                if (output > bestOutput) bestOutput = output;
            }
            unchecked {
                ++i;
            }
        }
        _revertWithoutWinner(anyOutput, bestOutput, minAmountOut);
    }

    function _revertWithoutWinner(bool anyOutput, uint256 bestOutput, uint256 minAmountOut) private pure {
        if (!anyOutput) revert AllRoutesFailed();
        revert InsufficientOutput(bestOutput, minAmountOut);
    }

    function _compete(Race memory r, Route[] calldata routes, uint256 mainCount)
        private
        returns (bool won, uint256 winnerIndex, uint256 amountOut, uint256 bestOutput, bool anyOutput)
    {
        uint256 minAmountOut = r.minAmountOut;
        bool emitEvents = r.flags & EMIT_EVENTS != 0;
        Lead memory lead;
        lead.index = NO_WINNER;
        uint256[] memory book;
        for (uint256 i; i < mainCount;) {
            uint256 feePpm = RouteLib.feePpmOf(_routeAt(routes, i).packed);
            uint256 threshold = NEVER_COMMIT;
            unchecked {
                if (i + 1 == mainCount) {
                    threshold = minAmountOut;
                    if (lead.output >= minAmountOut) {
                        uint256 rawToMatch = _rawFor(lead.net, feePpm);
                        if (rawToMatch > threshold) threshold = rawToMatch;
                    }
                }
            }
            (uint256 status, uint256 output, uint256 gasUsed) = _attempt(r, routes, i, threshold, false);
            if (status == COMMITTED) {
                r.winnerGas = gasUsed;
                return (true, i, output, 0, false);
            }
            if (emitEvents) _emitTrial(routes, i, status, output, gasUsed);
            if (status == MEASURED) {
                if (book.length == 0) book = new uint256[](mainCount << 1);
                book[i] = output;
                book[mainCount + i] = gasUsed;
                _challenge(lead, i, output, _netOf(output, feePpm), gasUsed, minAmountOut);
            }
            unchecked {
                ++i;
            }
        }
        while (lead.index != NO_WINNER && lead.output >= minAmountOut) {
            uint256 index = lead.index;
            (uint256 status, uint256 output, uint256 gasUsed) = _attempt(r, routes, index, lead.output, true);
            if (status == COMMITTED) {
                r.winnerGas = gasUsed;
                return (true, index, output, 0, false);
            }
            if (emitEvents) {
                emit RouteExecutionFailed(
                    index,
                    _targetAt(routes, index),
                    status == MEASURED
                        ? abi.encodeWithSelector(WinnerUnderperformed.selector, output, lead.output)
                        : _failureData(status),
                    gasUsed
                );
            }
            book[index] = 0;
            lead.index = NO_WINNER;
            lead.output = 0;
            lead.net = 0;
            lead.gasUsed = 0;
            for (uint256 i; i < mainCount;) {
                uint256 candidate = book[i];
                if (candidate != 0) {
                    _challenge(
                        lead,
                        i,
                        candidate,
                        _netOf(candidate, RouteLib.feePpmOf(_routeAt(routes, i).packed)),
                        book[mainCount + i],
                        minAmountOut
                    );
                }
                unchecked {
                    ++i;
                }
            }
        }
        return (false, 0, 0, lead.output, lead.index != NO_WINNER);
    }

    function _challenge(
        Lead memory lead,
        uint256 index,
        uint256 output,
        uint256 net,
        uint256 gasUsed,
        uint256 minAmountOut
    ) private pure {
        if (lead.index != NO_WINNER) {
            bool eligible = output >= minAmountOut;
            bool leaderEligible = lead.output >= minAmountOut;
            if (eligible != leaderEligible) {
                if (!eligible) return;
            } else if (eligible) {
                if (net < lead.net || (net == lead.net && gasUsed >= lead.gasUsed)) return;
            } else if (output < lead.output || (output == lead.output && gasUsed >= lead.gasUsed)) {
                return;
            }
        }
        lead.index = index;
        lead.output = output;
        lead.net = net;
        lead.gasUsed = gasUsed;
    }

    function _netOf(uint256 output, uint256 feePpm) private pure returns (uint256) {
        if (feePpm == 0) return output;
        unchecked {
            uint256 keptPpm = FEE_DENOMINATOR - feePpm;
            return (output / FEE_DENOMINATOR) * keptPpm + (output % FEE_DENOMINATOR) * keptPpm / FEE_DENOMINATOR;
        }
    }

    function _rawFor(uint256 net, uint256 feePpm) private pure returns (uint256 raw) {
        if (feePpm == 0) return net;
        if (net > type(uint256).max / FEE_DENOMINATOR) return type(uint256).max;
        assembly ("memory-safe") {
            let keptPpm := sub(FEE_DENOMINATOR, feePpm)
            let scaled := mul(net, FEE_DENOMINATOR)
            raw := add(div(scaled, keptPpm), iszero(iszero(mod(scaled, keptPpm))))
        }
    }

    function _emitTrial(Route[] calldata routes, uint256 index, uint256 status, uint256 output, uint256 gasUsed)
        private
    {
        uint256 packed = _routeAt(routes, index).packed;
        address target = RouteLib.targetOf(packed);
        if (status == MEASURED) emit RouteTrialSucceeded(index, target, output, RouteLib.feePpmOf(packed), gasUsed);
        else emit RouteTrialFailed(index, target, _failureData(status), gasUsed);
    }

    function _failureData(uint256 status) private pure returns (bytes memory) {
        if (status == REVERTED) return _boundedRevertData();
        return abi.encodeWithSelector(bytes4(uint32(status)));
    }

    function _routeAt(Route[] calldata routes, uint256 index) private pure returns (Route calldata route) {
        assembly ("memory-safe") {
            route := add(routes.offset, calldataload(add(routes.offset, shl(5, index))))
        }
    }

    function _targetAt(Route[] calldata routes, uint256 index) private pure returns (address) {
        return RouteLib.targetOf(_routeAt(routes, index).packed);
    }

    function _spenderAt(Route[] calldata routes, uint256 index) private pure returns (address spender) {
        Route calldata route = _routeAt(routes, index);
        uint256 packed = route.packed;
        spender = packed >> 255 != 0 ? RouteLib.targetOf(packed) : route.spender;
    }

    function _attempt(Race memory r, Route[] calldata routes, uint256 index, uint256 threshold, bool granted)
        private
        returns (uint256 status, uint256 output, uint256 gasUsed)
    {
        Route calldata route = _routeAt(routes, index);
        uint256 packed = route.packed;
        address target = RouteLib.targetOf(packed);
        uint256 value = route.value;
        uint256 gasLimit = RouteLib.gasLimitOf(packed);
        if (gasLimit == 0) revert RouteGasLimitRequired();
        if (target == address(this)) revert InvalidRouteTarget(target);
        if (_isHookRegistry(target)) revert InvalidRouteTarget(target);
        if (RouteLib.feePpmOf(packed) >= FEE_DENOMINATOR) revert InvalidRouteFee(index, RouteLib.feePpmOf(packed));

        address tokenIn = r.tokenIn;
        if (tokenIn != address(0)) {
            address spender = packed >> 255 != 0 ? target : route.spender;
            if (spender != address(0) && spender != r.approved) {
                if (!granted && !_grant(r, tokenIn, spender, routes, index)) {
                    return (uint32(RouteApprovalFailed.selector), 0, 0);
                }
                r.approved = spender;
            }
        }

        address tokenOut = r.tokenOut;
        if (value > r.maxRouteValue) return (uint32(ExcessiveRouteValue.selector), 0, 0);
        if (value != 0 && tokenOut == address(0)) return (uint32(ValueOnNativeOutput.selector), 0, 0);

        uint256 outBefore = r.outBefore;
        address holder = r.holder;
        bytes4 sel = RouteRaceEngine.callRoute.selector;
        bytes4 trialResult = TrialResult.selector;
        assembly ("memory-safe") {
            let cdAt := add(route, calldataload(add(route, 0x60)))
            let cdLen := calldataload(cdAt)
            let buf := mload(0x40)
            mstore(buf, sel)
            mstore(add(buf, 0x04), threshold)
            mstore(add(buf, 0x24), tokenOut)
            mstore(add(buf, 0x44), outBefore)
            mstore(add(buf, 0x64), holder)
            mstore(add(buf, 0x84), target)
            mstore(add(buf, 0xa4), value)
            mstore(add(buf, 0xc4), gasLimit)
            calldatacopy(add(buf, 0xe4), add(cdAt, 0x20), cdLen)
            gasUsed := gas()
            switch call(gasUsed, address(), 0, buf, add(0xe4, cdLen), 0x00, 0x24)
            case 0 {
                if and(eq(returndatasize(), 0x24), eq(shr(224, mload(0x00)), shr(224, trialResult))) {
                    status := MEASURED
                    output := mload(0x04)
                }
            }
            default {
                status := COMMITTED
                output := mload(0x00)
            }
            gasUsed := sub(gasUsed, gas())
        }
    }

    function callRoute() external returns (uint256 output) {
        if (msg.sender != address(this)) revert OnlySelf();
        _requireRaceActive();
        uint256 threshold;
        address tokenOut;
        uint256 outBefore;
        address holder;
        bytes4 trialResult = TrialResult.selector;
        assembly ("memory-safe") {
            threshold := calldataload(0x04)
            tokenOut := calldataload(0x24)
            outBefore := calldataload(0x44)
            holder := calldataload(0x64)
            let ptr := mload(0x40)
            let cdLen := sub(calldatasize(), 0xe4)
            calldatacopy(ptr, 0xe4, cdLen)
            if iszero(call(calldataload(0xc4), calldataload(0x84), calldataload(0xa4), ptr, cdLen, 0, 0)) {
                let retSize := returndatasize()
                if gt(retSize, MAX_REVERT_DATA_BYTES) { retSize := MAX_REVERT_DATA_BYTES }
                returndatacopy(ptr, 0, retSize)
                if and(eq(retSize, 0x24), eq(shr(224, mload(ptr)), shr(224, trialResult))) { retSize := 0x04 }
                revert(ptr, retSize)
            }
        }
        uint256 outAfter = tokenOut == address(0) ? holder.balance : _balanceOf(tokenOut, holder);
        if (outAfter < outBefore) revert OutputBalanceDecreased();
        unchecked {
            output = outAfter - outBefore;
        }
        if (output < threshold) revert TrialResult(output);
    }

    function _grant(Race memory r, address tokenIn, address spender, Route[] calldata routes, uint256 index)
        private
        returns (bool)
    {
        uint256 amountIn = r.amountIn;
        if (r.flags & KEEP_ALLOWANCES != 0) {
            return _allowanceCovers(tokenIn, spender, amountIn) || _tryApprove(tokenIn, spender, type(uint256).max);
        }
        for (uint256 i; i < index;) {
            if (_spenderAt(routes, i) == spender) return true;
            unchecked {
                ++i;
            }
        }
        if (_tryApprove(tokenIn, spender, amountIn)) return true;
        _clearAllowance(tokenIn, spender);
        return false;
    }

    function _revokeGrants(address tokenIn, Route[] calldata routes, uint256 trialedCount, uint256 winnerIndex)
        private
    {
        address winner = _spenderAt(routes, winnerIndex);
        if (winner != address(0)) _clearAllowance(tokenIn, winner);
        if (trialedCount == 1) return;
        for (uint256 i; i < trialedCount;) {
            address spender = _spenderAt(routes, i);
            bool skip = spender == address(0) || spender == winner;
            for (uint256 k; !skip && k < i;) {
                skip = _spenderAt(routes, k) == spender;
                unchecked {
                    ++k;
                }
            }
            if (!skip && !_approve(tokenIn, spender, 0) && _allowanceCovers(tokenIn, spender, 1)) {
                revert AllowanceNotCleared();
            }
            unchecked {
                ++i;
            }
        }
    }

    function _balanceOf(address token, address holder) private view returns (uint256 amount) {
        bool ok;
        assembly ("memory-safe") {
            mstore(0x14, holder)
            mstore(0x00, 0x70a08231000000000000000000000000)
            ok := staticcall(TOKEN_READ_GAS, token, 0x10, 0x24, 0x00, 0x20)
            ok := and(ok, gt(returndatasize(), 0x1f))
            amount := mload(0x00)
        }
        if (!ok) revert BalanceReadFailed();
    }

    function _allowanceCovers(address token, address spender, uint256 amount) private view returns (bool covers) {
        assembly ("memory-safe") {
            mstore(0x14, address())
            mstore(0x34, spender)
            mstore(0x00, 0xdd62ed3e000000000000000000000000)
            covers := staticcall(TOKEN_READ_GAS, token, 0x10, 0x44, 0x00, 0x20)
            covers := and(covers, and(gt(returndatasize(), 0x1f), iszero(lt(mload(0x00), amount))))
            mstore(0x34, 0)
        }
    }

    function _allowanceIsZero(address token, address spender) private view returns (bool zero) {
        assembly ("memory-safe") {
            mstore(0x14, address())
            mstore(0x34, spender)
            mstore(0x00, 0xdd62ed3e000000000000000000000000)
            zero := staticcall(TOKEN_READ_GAS, token, 0x10, 0x44, 0x00, 0x20)
            zero := and(zero, and(gt(returndatasize(), 0x1f), iszero(mload(0x00))))
            mstore(0x34, 0)
        }
    }

    function _clearAllowance(address token, address spender) private {
        if (_allowanceIsZero(token, spender)) return;
        _tryApprove(token, spender, 0);
        if (!_allowanceIsZero(token, spender)) revert AllowanceNotCleared();
    }

    function _tryApprove(address token, address spender, uint256 amount) private returns (bool) {
        if (_approve(token, spender, amount)) return true;
        _approve(token, spender, 0);
        return _approve(token, spender, amount);
    }

    function _approve(address token, address spender, uint256 amount) private returns (bool ok) {
        assembly ("memory-safe") {
            mstore(0x14, spender)
            mstore(0x34, amount)
            mstore(0x00, 0x095ea7b3000000000000000000000000)
            ok := call(TOKEN_CALL_GAS, token, 0, 0x10, 0x44, 0x00, 0x20)
            ok := and(ok, or(iszero(returndatasize()), and(gt(returndatasize(), 0x1f), eq(mload(0x00), 1))))
            mstore(0x34, 0)
        }
    }

    function _boundedRevertData() private pure returns (bytes memory revertData) {
        assembly ("memory-safe") {
            let size := returndatasize()
            if gt(size, MAX_REVERT_DATA_BYTES) { size := MAX_REVERT_DATA_BYTES }
            revertData := mload(0x40)
            mstore(revertData, size)
            returndatacopy(add(revertData, 0x20), 0, size)
            mstore(0x40, and(add(add(revertData, 0x3f), size), not(0x1f)))
        }
    }
}
