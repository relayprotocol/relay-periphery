// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Call3Value} from "../src/common/Multicall3.sol";
import {RelayApprovalProxy} from "../src/RelayApprovalProxy.sol";
import {RelayRouter} from "../src/RelayRouter.sol";
import {TestERC20} from "./mocks/TestERC20.sol";

/// @title  RelayApprovalProxy residue cleanup (DEC-2400)
/// @notice Every proxy entrypoint returns what the multicall leaves of the
///         tokens it moved, plus the router's native balance, to `refundTo`.
///         The router's cleanup functions are permissionless, so anything the
///         proxy left behind was claimable by the next caller. Before DEC-2400
///         the raw `transferAndMulticall` skipped this sweep.
contract ApprovalProxyResidueCleanupTest is Test {
    bytes32 constant FUNDS_MOVEMENT_TOPIC =
        keccak256("FundsMovement(address,address,address,uint256,bytes)");

    RelayRouter router;
    RelayApprovalProxy proxy;
    TestERC20 token;
    TestERC20 otherToken;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address refundTo = makeAddr("refundTo");

    function setUp() public {
        router = new RelayRouter();
        proxy = new RelayApprovalProxy(
            address(this),
            address(router),
            makeAddr("permit2")
        );
        token = new TestERC20();
        otherToken = new TestERC20();

        token.mint(alice, 1 ether);
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        token.approve(address(proxy), type(uint256).max);
    }

    // ─────────────────────────────────────────────────────────────────
    // transferAndMulticall
    // ─────────────────────────────────────────────────────────────────

    /// @notice Whatever the multicall does not spend of the transferred
    ///         tokens goes back to refundTo, tagged with the call's metadata.
    function test_transferAndMulticall_sweepsUnspentTokensToRefundTo()
        public
    {
        bytes memory metadata = "dec-2400";
        Call3Value[] memory calls = _transfer(token, bob, 0.4 ether);

        vm.recordLogs();
        vm.prank(alice);
        proxy.transferAndMulticall(
            _one(address(token)),
            _one(1 ether),
            calls,
            refundTo,
            address(0),
            metadata
        );

        assertEq(token.balanceOf(bob), 0.4 ether);
        assertEq(token.balanceOf(refundTo), 0.6 ether, "residue not refunded");
        assertEq(token.balanceOf(address(router)), 0, "residue left on router");
        _assertSweepLogged(address(token), 0.6 ether, metadata);
    }

    /// @notice Native value the multicall does not spend goes back to
    ///         refundTo as well, through the router's own sweep at the end
    ///         of `multicall`; the proxy adds nothing for native.
    function test_transferAndMulticall_sweepsNativeToRefundTo() public {
        Call3Value[] memory calls = new Call3Value[](0);

        vm.prank(alice);
        proxy.transferAndMulticall{value: 1 ether}(
            _one(address(token)),
            _one(0),
            calls,
            refundTo,
            address(0),
            ""
        );

        assertEq(refundTo.balance, 1 ether, "native not refunded");
        assertEq(address(router).balance, 0, "native left on router");
    }

    /// @notice A multicall that consumes everything leaves nothing to sweep
    ///         and the sweep stays silent: no transfer, no FundsMovement.
    function test_transferAndMulticall_noSweepWhenFullyConsumed() public {
        Call3Value[] memory calls = _transfer(token, bob, 1 ether);

        vm.recordLogs();
        vm.prank(alice);
        proxy.transferAndMulticall(
            _one(address(token)),
            _one(1 ether),
            calls,
            refundTo,
            address(0),
            ""
        );

        assertEq(token.balanceOf(bob), 1 ether);
        assertEq(token.balanceOf(refundTo), 0);
        assertEq(
            _sweepLogCount(address(token)),
            0,
            "sweep emitted with nothing to sweep"
        );
    }

    /// @notice Only the tokens the proxy transferred are swept. Other ERC20s
    ///         the multicall leaves on the router (swap output, say) are the
    ///         caller's to clean up with an explicit `cleanupErc20s` call, as
    ///         the NatSpec says.
    function test_transferAndMulticall_sweepsOnlyTransferredTokens() public {
        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = Call3Value({
            target: address(otherToken),
            allowFailure: false,
            value: 0,
            callData: abi.encodeCall(
                TestERC20.mint,
                (address(router), 1 ether)
            )
        });

        vm.prank(alice);
        proxy.transferAndMulticall(
            _one(address(token)),
            _one(1 ether),
            calls,
            refundTo,
            address(0),
            ""
        );

        assertEq(token.balanceOf(refundTo), 1 ether, "listed token not swept");
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(
            otherToken.balanceOf(address(router)),
            1 ether,
            "unlisted token unexpectedly swept"
        );
    }

    // ─────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────

    function _transfer(
        TestERC20 erc20,
        address to,
        uint256 amount
    ) internal pure returns (Call3Value[] memory calls) {
        calls = new Call3Value[](1);
        calls[0] = Call3Value({
            target: address(erc20),
            allowFailure: false,
            value: 0,
            callData: abi.encodeCall(IERC20.transfer, (to, amount))
        });
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _one(uint256 v) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = v;
    }

    /// @dev The router's sweep is the FundsMovement it emits with itself as
    ///      `from`. Exactly one must exist for `currency`, carrying the
    ///      amount and the metadata the proxy was called with.
    function _assertSweepLogged(
        address currency,
        uint256 amount,
        bytes memory metadata
    ) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter != address(router) ||
                logs[i].topics[0] != FUNDS_MOVEMENT_TOPIC
            ) continue;
            (
                address from,
                address to,
                address loggedCurrency,
                uint256 loggedAmount,
                bytes memory loggedMetadata
            ) = abi.decode(
                    logs[i].data,
                    (address, address, address, uint256, bytes)
                );
            if (from != address(router) || loggedCurrency != currency) {
                continue;
            }
            assertEq(to, refundTo, "sweep recipient");
            assertEq(loggedAmount, amount, "sweep amount");
            assertEq(loggedMetadata, metadata, "sweep metadata");
            found++;
        }
        assertEq(found, 1, "expected exactly one sweep FundsMovement");
    }

    function _sweepLogCount(address currency) internal returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter != address(router) ||
                logs[i].topics[0] != FUNDS_MOVEMENT_TOPIC
            ) continue;
            (address from, , address loggedCurrency, , ) = abi.decode(
                logs[i].data,
                (address, address, address, uint256, bytes)
            );
            if (from == address(router) && loggedCurrency == currency) n++;
        }
    }
}
