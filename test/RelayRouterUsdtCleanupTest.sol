// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RelayRouter} from "../src/RelayRouter.sol";
import {RelayRouter_NonTstore} from "../src/RelayRouter_NonTstore.sol";

/// @notice Minimal interface for the permissionless cleanup surface under test.
interface IRouterCleanup {
    function cleanupErc20sViaCall(
        address[] calldata tokens,
        address[] calldata tos,
        bytes[] calldata datas,
        uint256[] calldata amounts
    ) external;
}

/// @notice Mainnet USDT (TetherToken) interface. Note that `approve`,
///         `transfer` and `transferFrom` do NOT return a bool, and `approve`
///         reverts when setting a non-zero allowance over an existing non-zero
///         allowance.
interface IUSDT {
    function approve(address spender, uint256 value) external;
    function transferFrom(address from, address to, uint256 value) external;
    function balanceOf(address account) external view returns (uint256);
    function allowance(
        address owner,
        address spender
    ) external view returns (uint256);
}

/// @notice A stand-in for the cleanup call target. It pulls a configurable
///         amount of USDT from its caller (the router) via `transferFrom`,
///         exactly as a real downstream protocol would consume the approval
///         granted by `cleanupErc20sViaCall`.
contract UsdtConsumer {
    address public immutable USDT_TOKEN;
    uint256 public pullAmount;

    constructor(address _usdt) {
        USDT_TOKEN = _usdt;
    }

    function setPullAmount(uint256 amount) external {
        pullAmount = amount;
    }

    /// @dev Pulls `pullAmount` USDT from `msg.sender` (the router). Uses the
    ///      no-return USDT interface so the consumer itself does not revert on
    ///      the empty returndata.
    function pull() external {
        IUSDT(USDT_TOKEN).transferFrom(msg.sender, address(this), pullAmount);
    }
}

/// @title  RelayRouter USDT cleanupErc20sViaCall regression tests (DEC-1106)
/// @notice Mainnet-fork tests that pin the fix replacing the typed
///         `IERC20(token).approve(to, amount)` in `cleanupErc20sViaCall` with
///         solady's `safeApproveWithRetry`.
///
///         Two real USDT quirks are exercised:
///           1. `approve` returns no bool, so a typed approve reverts while
///              ABI-decoding empty returndata. This was the original
///              EXECUTION_REVERTED that blocked gasless aUSDT -> mUSD.
///           2. `approve` reverts when overwriting a non-zero allowance with a
///              new non-zero value. This bricks the next cleanup whenever a
///              target consumes less than the approved amount and leaves a
///              non-zero residual allowance.
contract RelayRouterUsdtCleanupTest is Test {
    // Mainnet USDT.
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("ethereum"));
    }

    // ─────────────────────────────────────────────────────────────────
    // Quirk #1: USDT.approve returns no bool — the original revert.
    // ─────────────────────────────────────────────────────────────────

    /// @notice Documents the root cause: a typed approve against real USDT
    ///         reverts while decoding a bool from empty returndata. This is the
    ///         behaviour the fix removes from the router.
    function test_rootCause_typedApproveOnUsdtReverts() public {
        // The typed IERC20 interface expects a bool return; USDT returns none,
        // so the call reverts without data.
        vm.expectRevert();
        IERC20(USDT).approve(address(0xBEEF), 1e6);
    }

    /// @notice The fix: cleanupErc20sViaCall approves and consumes real USDT
    ///         without reverting (full-balance consumption path).
    function test_cleanupViaCall_usdt_approveDoesNotRevert_tstore() public {
        _approveDoesNotRevert(address(new RelayRouter()));
    }

    function test_cleanupViaCall_usdt_approveDoesNotRevert_nonTstore() public {
        _approveDoesNotRevert(address(new RelayRouter_NonTstore()));
    }

    function _approveDoesNotRevert(address router) internal {
        uint256 amount = 100e6;

        // Stage USDT on the router, as the unwrapped asset would be after a swap.
        deal(USDT, router, amount);

        UsdtConsumer consumer = new UsdtConsumer(USDT);
        consumer.setPullAmount(amount);

        (
            address[] memory tokens,
            address[] memory tos,
            bytes[] memory datas,
            uint256[] memory amounts
        ) = _singleCall(address(consumer), amount);

        // With the typed approve this reverted with EXECUTION_REVERTED.
        IRouterCleanup(router).cleanupErc20sViaCall(tokens, tos, datas, amounts);

        assertEq(IUSDT(USDT).balanceOf(router), 0, "router retains USDT");
        assertEq(
            IUSDT(USDT).balanceOf(address(consumer)),
            amount,
            "consumer did not receive USDT"
        );
    }

    // ─────────────────────────────────────────────────────────────────
    // Quirk #2: residual non-zero allowance must be reset before re-approve.
    // ─────────────────────────────────────────────────────────────────

    /// @notice When a target consumes less than the approved amount, a non-zero
    ///         residual allowance remains. A subsequent cleanup must not revert
    ///         re-approving over that residual — safeApproveWithRetry resets to
    ///         zero first.
    function test_cleanupViaCall_usdt_residualAllowancePath_tstore() public {
        _residualAllowancePath(address(new RelayRouter()));
    }

    function test_cleanupViaCall_usdt_residualAllowancePath_nonTstore() public {
        _residualAllowancePath(address(new RelayRouter_NonTstore()));
    }

    function _residualAllowancePath(address router) internal {
        deal(USDT, router, 100e6);

        UsdtConsumer consumer = new UsdtConsumer(USDT);

        // First cleanup: approve 100, but the target only pulls 60, leaving a
        // non-zero residual allowance of 40 on (router -> consumer).
        consumer.setPullAmount(60e6);
        {
            (
                address[] memory tokens,
                address[] memory tos,
                bytes[] memory datas,
                uint256[] memory amounts
            ) = _singleCall(address(consumer), 100e6);
            IRouterCleanup(router).cleanupErc20sViaCall(
                tokens,
                tos,
                datas,
                amounts
            );
        }

        assertEq(
            IUSDT(USDT).allowance(router, address(consumer)),
            40e6,
            "expected non-zero residual allowance"
        );
        assertEq(IUSDT(USDT).balanceOf(router), 40e6, "unexpected router balance");

        // Second cleanup: re-approving 40 over the residual 40 would revert with
        // a plain USDT approve (non-zero over non-zero). safeApproveWithRetry
        // resets to zero first, so this succeeds and the remaining 40 is pulled.
        consumer.setPullAmount(40e6);
        {
            (
                address[] memory tokens,
                address[] memory tos,
                bytes[] memory datas,
                uint256[] memory amounts
            ) = _singleCall(address(consumer), 40e6);
            IRouterCleanup(router).cleanupErc20sViaCall(
                tokens,
                tos,
                datas,
                amounts
            );
        }

        assertEq(IUSDT(USDT).balanceOf(router), 0, "router retains USDT");
        assertEq(
            IUSDT(USDT).balanceOf(address(consumer)),
            100e6,
            "consumer did not receive full USDT"
        );
    }

    // ─────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────

    function _singleCall(
        address consumer,
        uint256 amount
    )
        internal
        pure
        returns (
            address[] memory tokens,
            address[] memory tos,
            bytes[] memory datas,
            uint256[] memory amounts
        )
    {
        tokens = new address[](1);
        tokens[0] = USDT;
        tos = new address[](1);
        tos[0] = consumer;
        datas = new bytes[](1);
        datas[0] = abi.encodeWithSignature("pull()");
        amounts = new uint256[](1);
        amounts[0] = amount;
    }
}
