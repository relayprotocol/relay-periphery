// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";

import {Call3Value} from "../src/common/Multicall3.sol";
import {RelayRouter} from "../src/RelayRouter.sol";
import {TestERC20} from "./mocks/TestERC20.sol";

/// @title  RelayRouter Residual-Funds Invariant Tests
/// @notice Documents and enforces the design invariant declared in
///         RelayRouter.sol: the router holds no residual ETH or ERC20
///         balances after a well-formed multicall, and the permissionless
///         `cleanup*` surface is intentional.
///
///         These tests are the operational counterpart to vigil PRECON-012
///         and to the contract-level threat-model NatSpec on
///         RelayRouter.sol. They exist so that automated audit tooling
///         can verify the design intent rather than merely read it.
contract RelayRouterResidualFundsTest is Test {
    RelayRouter router;
    TestERC20 token;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        router = new RelayRouter();
        token = new TestERC20();
        vm.deal(alice, 10 ether);
        vm.deal(bob, 0);
    }

    // ─────────────────────────────────────────────────────────────────
    // Invariant: no residual balance after a well-formed multicall
    // ─────────────────────────────────────────────────────────────────

    /// @notice An empty multicall with msg.value > 0 leaves zero ETH on
    ///         the router because cleanupNative is auto-invoked at the
    ///         end of multicall.
    function test_invariant_noEthAfterEmptyMulticallWithValue() public {
        Call3Value[] memory calls = new Call3Value[](0);

        vm.prank(alice);
        router.multicall{value: 1 ether}(calls, alice, address(0), "");

        assertEq(address(router).balance, 0, "router holds ETH after multicall");
    }

    /// @notice The auto-cleanup refunds to refundTo, not to msg.sender,
    ///         when the two differ.
    function test_invariant_ethRefundedToRefundTo() public {
        Call3Value[] memory calls = new Call3Value[](0);

        vm.prank(alice);
        router.multicall{value: 1 ether}(calls, bob, address(0), "");

        assertEq(address(router).balance, 0, "router holds ETH after multicall");
        assertEq(bob.balance, 1 ether, "refundTo did not receive ETH");
    }

    /// @notice ERC20 dust on the router is fully swept when the multicall
    ///         includes a cleanupErc20s call. There is no auto-cleanup for
    ///         ERC20s — every consumer of the router is expected to add a
    ///         cleanupErc20s call to the multicall.
    function test_invariant_noErc20AfterCleanupCall() public {
        // Stage tokens on the router (simulates a swap proceed).
        token.mint(address(router), 100 ether);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        address[] memory recipients = new address[](1);
        recipients[0] = alice;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0; // 0 = sweep full balance

        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = Call3Value({
            target: address(router),
            allowFailure: false,
            value: 0,
            callData: abi.encodeCall(
                router.cleanupErc20s,
                (tokens, recipients, amounts, "")
            )
        });

        router.multicall(calls, address(this), address(0), "");

        assertEq(token.balanceOf(address(router)), 0, "router holds ERC20 after cleanup");
        assertEq(token.balanceOf(alice), 100 ether, "recipient did not receive ERC20");
    }

    // ─────────────────────────────────────────────────────────────────
    // Design intent: cleanup* are intentionally permissionless
    // ─────────────────────────────────────────────────────────────────
    //
    // These tests exist to make the design intent inspectable. They are
    // intentionally "positive" assertions that the permissionless sweep
    // surface works as documented — not findings.

    /// @notice cleanupNative is intentionally permissionless. Any address
    ///         can sweep stranded ETH on the router. Safe under the
    ///         deployed threat model because the router holds no ETH at
    ///         rest under normal operation.
    function test_designIntent_anyoneCanSweepStrandedEth() public {
        // Strand 1 ETH on the router (simulates a direct send / dust).
        vm.deal(address(router), 1 ether);

        // An unrelated address sweeps it to itself.
        vm.prank(bob);
        router.cleanupNative(0, bob, "");

        assertEq(address(router).balance, 0);
        assertEq(bob.balance, 1 ether);
    }

    /// @notice cleanupErc20s is intentionally permissionless. Same
    ///         rationale as the native variant.
    function test_designIntent_anyoneCanSweepStrandedErc20() public {
        token.mint(address(router), 50 ether);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        address[] memory recipients = new address[](1);
        recipients[0] = bob;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0;

        vm.prank(bob);
        router.cleanupErc20s(tokens, recipients, amounts, "");

        assertEq(token.balanceOf(address(router)), 0);
        assertEq(token.balanceOf(bob), 50 ether);
    }
}
