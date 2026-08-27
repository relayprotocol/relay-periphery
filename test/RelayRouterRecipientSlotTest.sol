// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";

import {Call3Value} from "../src/common/Multicall3.sol";
import {RelayRouter} from "../src/RelayRouter.sol";
import {RelayRouter_NonTstore} from "../src/RelayRouter_NonTstore.sol";
import {TestERC721} from "./mocks/TestERC721.sol";

/// @notice The subset of the router surface these tests drive, shared by both
///         storage variants.
interface IRecipientRouter {
    function multicall(
        Call3Value[] calldata calls,
        address refundTo,
        address nftRecipient,
        bytes calldata metadata
    ) external payable;
}

/// @title  NFT recipient slot regression tests (VIG-RP-003 / 004 / 025)
/// @notice The reentrancy guard admits nested same-sender calls, so a call
///         inside `calls` can re-enter `multicall`. Before the fix, the nested
///         frame ran `_clearRecipient()` unconditionally and zeroed the
///         enclosing frame's NFT recipient while it was still executing. Any
///         later NFT callback then read a zero recipient and reverted with
///         `NoRecipientSet`. With `allowFailure: true` that revert was
///         swallowed: the mint or transfer never happened, the multicall
///         reported success, and the user got nothing.
///
///         Note this is narrower than VIG-RP-003 claims. The finding says the
///         NFT is "minted to the router" and stranded; it is not. The receiver
///         hook reverts inside `_safeMint`, which unwinds the mint atomically,
///         so no token is created and nothing is left on the router. The
///         damage is a silently swallowed mint, not a stranded asset.
///
///         #62 fixed the reentrancy guard slot but not the recipient slot, and
///         made the nested path cleanly reachable in the process.
contract RelayRouterRecipientSlotTest is Test {
    error RecipientAlreadySet(address current, address requested);

    TestERC721 nft;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        nft = new TestERC721();
    }

    // ─────────────────────────────────────────────────────────────────
    // Baseline
    // ─────────────────────────────────────────────────────────────────

    function test_baseline_recipientReceivesNft_tstore() public {
        _baseline(address(new RelayRouter()));
    }

    function test_baseline_recipientReceivesNft_nonTstore() public {
        _baseline(address(new RelayRouter_NonTstore()));
    }

    // ─────────────────────────────────────────────────────────────────
    // The regression: a nested frame must not clear the recipient
    // ─────────────────────────────────────────────────────────────────

    /// @notice A nested multicall that sets no recipient of its own must leave
    ///         the enclosing frame's recipient intact.
    function test_nestedCallKeepsRecipient_tstore() public {
        _nestedKeepsRecipient(address(new RelayRouter()));
    }

    function test_nestedCallKeepsRecipient_nonTstore() public {
        _nestedKeepsRecipient(address(new RelayRouter_NonTstore()));
    }

    /// @notice Same nesting with `allowFailure: true` on the mint. Before the
    ///         fix the callback reverted, the revert was swallowed, and the
    ///         mint never happened while the multicall reported success.
    function test_nestedCallKeepsRecipient_allowFailure_tstore() public {
        _nestedKeepsRecipientAllowFailure(address(new RelayRouter()));
    }

    function test_nestedCallKeepsRecipient_allowFailure_nonTstore() public {
        _nestedKeepsRecipientAllowFailure(
            address(new RelayRouter_NonTstore())
        );
    }

    // ─────────────────────────────────────────────────────────────────
    // Conflicting and matching nested recipients
    // ─────────────────────────────────────────────────────────────────

    /// @notice A nested frame asking for a different recipient is a genuine
    ///         conflict and must revert rather than silently reroute.
    function test_nestedConflictingRecipientReverts_tstore() public {
        _nestedConflictReverts(address(new RelayRouter()));
    }

    function test_nestedConflictingRecipientReverts_nonTstore() public {
        _nestedConflictReverts(address(new RelayRouter_NonTstore()));
    }

    /// @notice A nested frame asking for the same recipient is a no-op.
    function test_nestedMatchingRecipientAllowed_tstore() public {
        _nestedMatchingAllowed(address(new RelayRouter()));
    }

    function test_nestedMatchingRecipientAllowed_nonTstore() public {
        _nestedMatchingAllowed(address(new RelayRouter_NonTstore()));
    }

    /// @notice The recipient does not leak past the outer frame.
    function test_recipientClearedAfterOuterCall_tstore() public {
        _recipientCleared(address(new RelayRouter()));
    }

    function test_recipientClearedAfterOuterCall_nonTstore() public {
        _recipientCleared(address(new RelayRouter_NonTstore()));
    }

    // ─────────────────────────────────────────────────────────────────
    // Helpers
    // ─────────────────────────────────────────────────────────────────

    function _mintCall(
        uint256 tokenId,
        bool allowFailure
    ) internal view returns (Call3Value memory) {
        return
            Call3Value({
                target: address(nft),
                allowFailure: allowFailure,
                value: 0,
                callData: abi.encodeWithSignature("safeMint(uint256)", tokenId)
            });
    }

    function _nestedCall(
        address router,
        address nestedRecipient
    ) internal view returns (Call3Value memory) {
        Call3Value[] memory none = new Call3Value[](0);
        return
            Call3Value({
                target: router,
                allowFailure: false,
                value: 0,
                callData: abi.encodeCall(
                    IRecipientRouter.multicall,
                    (none, alice, nestedRecipient, "")
                )
            });
    }

    function _baseline(address router) internal {
        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = _mintCall(1, false);

        vm.prank(alice);
        IRecipientRouter(router).multicall(calls, alice, alice, "");

        assertEq(nft.ownerOf(1), alice);
    }

    function _nestedKeepsRecipient(address router) internal {
        Call3Value[] memory calls = new Call3Value[](2);
        calls[0] = _nestedCall(router, address(0));
        calls[1] = _mintCall(1, false);

        vm.prank(alice);
        IRecipientRouter(router).multicall(calls, alice, alice, "");

        assertEq(nft.ownerOf(1), alice, "recipient lost after nested call");
        assertEq(nft.balanceOf(router), 0, "NFT left on the router");
    }

    function _nestedKeepsRecipientAllowFailure(address router) internal {
        Call3Value[] memory calls = new Call3Value[](2);
        calls[0] = _nestedCall(router, address(0));
        calls[1] = _mintCall(1, true);

        vm.prank(alice);
        IRecipientRouter(router).multicall(calls, alice, alice, "");

        assertEq(nft.ownerOf(1), alice, "mint silently swallowed");
        assertEq(nft.balanceOf(router), 0, "NFT left on the router");
    }

    function _nestedConflictReverts(address router) internal {
        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = _nestedCall(router, bob);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(RecipientAlreadySet.selector, alice, bob)
        );
        IRecipientRouter(router).multicall(calls, alice, alice, "");
    }

    function _nestedMatchingAllowed(address router) internal {
        Call3Value[] memory calls = new Call3Value[](2);
        calls[0] = _nestedCall(router, alice);
        calls[1] = _mintCall(1, false);

        vm.prank(alice);
        IRecipientRouter(router).multicall(calls, alice, alice, "");

        assertEq(nft.ownerOf(1), alice);
    }

    function _recipientCleared(address router) internal {
        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = _mintCall(1, false);

        vm.prank(alice);
        IRecipientRouter(router).multicall(calls, alice, alice, "");

        // With no recipient set, the callback has nowhere to forward to.
        vm.prank(alice);
        vm.expectRevert();
        nft.safeMint(router, 2);
    }
}
