// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {IERC1820Registry} from "@openzeppelin/contracts/interfaces/IERC1820Registry.sol";

import {Call3Value} from "../src/common/Multicall3.sol";
import {RelayApprovalProxy} from "../src/RelayApprovalProxy.sol";
import {RelayRouter} from "../src/RelayRouter.sol";
import {RelayRouter_NonTstore} from "../src/RelayRouter_NonTstore.sol";
import {HookRegistryCode} from "./mocks/HookRegistryCode.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {TestERC777} from "./mocks/TestERC777.sol";

/// @title  The router refuses hook registry targets (DEC-2050)
/// @notice Every router call runs with the router as msg.sender, so a call to
///         an ERC777 hook registry would let anyone set the router's transfer
///         hooks or hand its entries to a new manager for good. Every call
///         site with a caller chosen target and calldata must refuse both
///         registries, whatever `allowFailure` says. The real registry code
///         is etched at the real addresses, so without the check each call
///         that sends no value would succeed. `cleanupNativeViaCall` always
///         sends value, which both registries reject, so its test only pins
///         the check.
contract RouterHookRegistryTest is Test {
    error InvalidTarget(address target);

    address alice = address(0xA11CE);

    function setUp() public {
        vm.etch(HookRegistryCode.ERC1820, HookRegistryCode.ERC1820_RUNTIME);
        vm.etch(HookRegistryCode.ERC820, HookRegistryCode.ERC820_RUNTIME);
    }

    function test_multicallRejected_tstore() public {
        _multicallRejected(address(new RelayRouter()), HookRegistryCode.ERC1820, false);
    }

    function test_multicallRejected_nonTstore() public {
        _multicallRejected(address(new RelayRouter_NonTstore()), HookRegistryCode.ERC1820, false);
    }

    /// @notice `allowFailure` must not turn the rejection into a skipped call
    function test_rejectedDespiteAllowFailure_tstore() public {
        _multicallRejected(address(new RelayRouter()), HookRegistryCode.ERC1820, true);
    }

    function test_rejectedDespiteAllowFailure_nonTstore() public {
        _multicallRejected(address(new RelayRouter_NonTstore()), HookRegistryCode.ERC1820, true);
    }

    /// @notice Some early ERC777 tokens still read hooks from ERC820
    function test_legacyRegistryRejected_tstore() public {
        _multicallRejected(address(new RelayRouter()), HookRegistryCode.ERC820, false);
    }

    function test_legacyRegistryRejected_nonTstore() public {
        _multicallRejected(address(new RelayRouter_NonTstore()), HookRegistryCode.ERC820, false);
    }

    function test_cleanupErc20sViaCallRejected_tstore() public {
        _cleanupErc20sViaCallRejected(address(new RelayRouter()));
    }

    function test_cleanupErc20sViaCallRejected_nonTstore() public {
        _cleanupErc20sViaCallRejected(address(new RelayRouter_NonTstore()));
    }

    function test_cleanupNativeViaCallRejected_tstore() public {
        _cleanupNativeViaCallRejected(address(new RelayRouter()));
    }

    function test_cleanupNativeViaCallRejected_nonTstore() public {
        _cleanupNativeViaCallRejected(address(new RelayRouter_NonTstore()));
    }

    /// @notice ERC777 tokens still move through the router, with no router hook
    function test_erc777DepositReachesRecipient_tstore() public {
        _erc777DepositReachesRecipient(address(new RelayRouter()));
    }

    function test_erc777DepositReachesRecipient_nonTstore() public {
        _erc777DepositReachesRecipient(address(new RelayRouter_NonTstore()));
    }

    function _oneCall(address target, bool allowFailure, bytes memory callData)
        internal
        pure
        returns (Call3Value[] memory calls)
    {
        calls = new Call3Value[](1);
        calls[0] = Call3Value({target: target, allowFailure: allowFailure, value: 0, callData: callData});
    }

    function _setManager(address router) internal view returns (bytes memory) {
        return abi.encodeCall(IERC1820Registry.setManager, (router, alice));
    }

    function _expectRejected(address registry) internal {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(InvalidTarget.selector, registry));
    }

    function _multicallRejected(address router, address registry, bool allowFailure) internal {
        Call3Value[] memory calls = _oneCall(registry, allowFailure, _setManager(router));
        _expectRejected(registry);
        RelayRouter(payable(router)).multicall(calls, alice, address(0), "");
    }

    function _cleanupErc20sViaCallRejected(address router) internal {
        address[] memory tokens = new address[](1);
        address[] memory tos = new address[](1);
        bytes[] memory datas = new bytes[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = address(new TestERC20());
        tos[0] = HookRegistryCode.ERC1820;
        datas[0] = _setManager(router);
        // Any non zero amount makes the call, whatever the balance
        amounts[0] = 1;

        _expectRejected(HookRegistryCode.ERC1820);
        RelayRouter(payable(router)).cleanupErc20sViaCall(tokens, tos, datas, amounts);
    }

    function _cleanupNativeViaCallRejected(address router) internal {
        vm.deal(router, 1);
        bytes memory data = _setManager(router);

        _expectRejected(HookRegistryCode.ERC1820);
        RelayRouter(payable(router)).cleanupNativeViaCall(1, HookRegistryCode.ERC1820, data);
    }

    function _erc777DepositReachesRecipient(address router) internal {
        RelayApprovalProxy proxy = new RelayApprovalProxy(address(this), router, makeAddr("permit2"));
        TestERC777 token = new TestERC777();
        address recipient = makeAddr("recipient");

        token.mint(alice, 1 ether);
        vm.prank(alice);
        token.approve(address(proxy), 1 ether);

        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        address[] memory recipients = new address[](1);
        recipients[0] = recipient;
        // Amount 0 sweeps the router's whole balance
        uint256[] memory sweep = new uint256[](1);
        Call3Value[] memory calls =
            _oneCall(router, false, abi.encodeCall(RelayRouter.cleanupErc20s, (tokens, recipients, sweep, "")));

        vm.prank(alice);
        proxy.transferAndMulticall(tokens, amounts, calls, alice, address(0), "");

        assertEq(token.balanceOf(recipient), 1 ether);
        assertEq(token.balanceOf(router), 0);
    }
}
