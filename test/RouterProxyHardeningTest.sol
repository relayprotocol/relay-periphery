// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RelayApprovalProxy} from "../src/RelayApprovalProxy.sol";
import {RelayRouter} from "../src/RelayRouter.sol";
import {RelayRouter_NonTstore} from "../src/RelayRouter_NonTstore.sol";
import {TestERC20} from "./mocks/TestERC20.sol";

/// @notice The permissionless cleanup surface under test, shared by both
///         router variants.
interface IRouterCleanup {
    function cleanupErc20sViaCall(
        address[] calldata tokens,
        address[] calldata tos,
        bytes[] calldata datas,
        uint256[] calldata amounts
    ) external;

    function cleanupNativeViaCall(
        uint256 amount,
        address to,
        bytes calldata data
    ) external;
}

/// @notice Stands in for a downstream protocol consuming the approval granted
///         by `cleanupErc20sViaCall`. Pulls a configurable amount so the
///         partial-consumption path can be exercised.
contract Erc20Consumer {
    address public immutable TOKEN;
    uint256 public pullAmount;
    address public pullRecipient;

    constructor(address token) {
        TOKEN = token;
        pullRecipient = address(this);
    }

    function setPullAmount(uint256 amount) external {
        pullAmount = amount;
    }

    function setPullRecipient(address recipient) external {
        pullRecipient = recipient;
    }

    function pull() external {
        IERC20(TOKEN).transferFrom(msg.sender, pullRecipient, pullAmount);
    }
}

/// @notice Stands in for a downstream protocol consuming native tokens.
contract NativeConsumer {
    function deposit() external payable {}
}

/// @notice An owner whose `receive` hook costs well over the 100k gas stipend
///         that `_send` used to impose, standing in for a multisig or smart
///         contract wallet.
contract GasHungryOwner {
    uint256[] private filler;

    receive() external payable {
        for (uint256 i; i < 20; i++) {
            filler.push(i);
        }
    }

    function withdrawFrom(RelayApprovalProxy proxy, address token) external {
        proxy.withdraw(token);
    }
}

/// @title  Router and approval-proxy hardening tests
/// @notice Covers three vigil findings addressed ahead of the V3 redeployment:
///
///           - VIG-RP-026: `cleanupErc20sViaCall` and `cleanupNativeViaCall`
///             moved funds out of the router without emitting `FundsMovement`,
///             making the movement invisible to monitoring keyed on that event.
///           - VIG-RP-113: `_send` capped the owner-only `withdraw` at 100k
///             gas, stranding the native balance for a contract owner whose
///             receive hook costs more than the stipend.
///           - VIG-RP-104: the proxy constructor accepted zero addresses for
///             immutables and for the owner of its only rescue function.
///           - VIG-RP-092: withdraw() was the only fund-movement path in the
///             proxy that emitted no FundsMovement.
///           - VIG-RP-105: receive() accepted native tokens silently, so with
///             092 the whole ETH lifecycle through the proxy was invisible.
contract RouterProxyHardeningTest is Test {
    event FundsMovement(
        address from,
        address to,
        address currency,
        uint256 amount,
        bytes metadata
    );

    TestERC20 token;
    address permit2 = address(0xBEEF);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        token = new TestERC20();
    }

    // ─────────────────────────────────────────────────────────────────
    // VIG-RP-026: ViaCall cleanups emit FundsMovement
    // ─────────────────────────────────────────────────────────────────

    function test_erc20ViaCall_emitsFundsMovement_tstore() public {
        _erc20ViaCallEmits(address(new RelayRouter()));
    }

    function test_erc20ViaCall_emitsFundsMovement_nonTstore() public {
        _erc20ViaCallEmits(address(new RelayRouter_NonTstore()));
    }

    /// @dev The emitted amount is what the target actually consumed, not what
    ///      was approved. A target pulling less than the approval must not
    ///      report the larger figure.
    function test_erc20ViaCall_emitsConsumedNotApproved_tstore() public {
        _erc20ViaCallEmitsConsumed(address(new RelayRouter()));
    }

    function test_erc20ViaCall_emitsConsumedNotApproved_nonTstore() public {
        _erc20ViaCallEmitsConsumed(address(new RelayRouter_NonTstore()));
    }

    /// @dev A target that pulls nothing moves no funds, so it must not emit.
    ///      Approval events from `safeApproveWithRetry` are expected and are
    ///      filtered out here.
    function test_erc20ViaCall_noEventWhenNothingConsumed_tstore() public {
        _erc20ViaCallEmitsNothing(address(new RelayRouter()));
    }

    function test_erc20ViaCall_noEventWhenNothingConsumed_nonTstore() public {
        _erc20ViaCallEmitsNothing(address(new RelayRouter_NonTstore()));
    }

    function _erc20ViaCallEmitsNothing(address router) internal {
        Erc20Consumer consumer = new Erc20Consumer(address(token));
        token.mint(router, 100 ether);
        consumer.setPullAmount(0);

        vm.recordLogs();
        _cleanupErc20(router, address(consumer), 100 ether);

        bytes32 topic = keccak256(
            "FundsMovement(address,address,address,uint256,bytes)"
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != topic,
                "emitted a phantom movement"
            );
        }

        assertEq(token.balanceOf(router), 100 ether, "balance moved");
    }

    /// @dev The event's `to` is the approved call target by definition: when
    ///      the target delivers the tokens to a third party, the event still
    ///      reports the target, since the router cannot observe the final
    ///      recipient. Pins the semantics documented on `FundsMovement` so
    ///      the field is not later mistaken for a token recipient.
    function test_erc20ViaCall_toIsSpenderNotFinalRecipient_tstore() public {
        _erc20ViaCallReportsSpender(address(new RelayRouter()));
    }

    function test_erc20ViaCall_toIsSpenderNotFinalRecipient_nonTstore()
        public
    {
        _erc20ViaCallReportsSpender(address(new RelayRouter_NonTstore()));
    }

    function test_nativeViaCall_emitsFundsMovement_tstore() public {
        _nativeViaCallEmits(address(new RelayRouter()));
    }

    function test_nativeViaCall_emitsFundsMovement_nonTstore() public {
        _nativeViaCallEmits(address(new RelayRouter_NonTstore()));
    }

    function _erc20ViaCallEmits(address router) internal {
        Erc20Consumer consumer = new Erc20Consumer(address(token));
        token.mint(router, 100 ether);
        consumer.setPullAmount(100 ether);

        vm.expectEmit(true, true, true, true, router);
        emit FundsMovement(
            router,
            address(consumer),
            address(token),
            100 ether,
            ""
        );
        // amount 0 means "full balance"
        _cleanupErc20(router, address(consumer), 0);

        assertEq(token.balanceOf(address(consumer)), 100 ether);
        assertEq(token.balanceOf(router), 0);
    }

    function _erc20ViaCallEmitsConsumed(address router) internal {
        Erc20Consumer consumer = new Erc20Consumer(address(token));
        token.mint(router, 100 ether);
        consumer.setPullAmount(40 ether);

        vm.expectEmit(true, true, true, true, router);
        emit FundsMovement(
            router,
            address(consumer),
            address(token),
            40 ether,
            ""
        );
        _cleanupErc20(router, address(consumer), 100 ether);

        assertEq(token.balanceOf(router), 60 ether, "residual not left behind");
    }

    function _erc20ViaCallReportsSpender(address router) internal {
        Erc20Consumer consumer = new Erc20Consumer(address(token));
        address thirdParty = address(0x781D);
        token.mint(router, 100 ether);
        consumer.setPullAmount(100 ether);
        consumer.setPullRecipient(thirdParty);

        vm.expectEmit(true, true, true, true, router);
        emit FundsMovement(
            router,
            address(consumer),
            address(token),
            100 ether,
            ""
        );
        _cleanupErc20(router, address(consumer), 0);

        assertEq(token.balanceOf(thirdParty), 100 ether, "third party unpaid");
        assertEq(token.balanceOf(address(consumer)), 0);
        assertEq(token.balanceOf(router), 0);
    }

    function _nativeViaCallEmits(address router) internal {
        NativeConsumer consumer = new NativeConsumer();
        vm.deal(router, 5 ether);

        vm.expectEmit(true, true, true, true, router);
        emit FundsMovement(
            router,
            address(consumer),
            address(0),
            5 ether,
            ""
        );
        vm.prank(alice);
        IRouterCleanup(router).cleanupNativeViaCall(
            0,
            address(consumer),
            abi.encodeCall(NativeConsumer.deposit, ())
        );

        assertEq(address(consumer).balance, 5 ether);
        assertEq(router.balance, 0);
    }

    function _cleanupErc20(
        address router,
        address consumer,
        uint256 amount
    ) internal {
        address[] memory tokens = new address[](1);
        address[] memory tos = new address[](1);
        bytes[] memory datas = new bytes[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = address(token);
        tos[0] = consumer;
        datas[0] = abi.encodeCall(Erc20Consumer.pull, ());
        amounts[0] = amount;

        vm.prank(alice);
        IRouterCleanup(router).cleanupErc20sViaCall(
            tokens,
            tos,
            datas,
            amounts
        );
    }

    // ─────────────────────────────────────────────────────────────────
    // VIG-RP-113: withdraw forwards all gas
    // ─────────────────────────────────────────────────────────────────

    /// @notice A contract owner whose receive hook costs more than 100k gas can
    ///         still withdraw the native balance. Under the previous fixed
    ///         stipend this reverted with NativeTransferFailed.
    function test_withdrawNative_toGasHungryOwner() public {
        RelayRouter router = new RelayRouter();
        GasHungryOwner owner = new GasHungryOwner();
        RelayApprovalProxy proxy = new RelayApprovalProxy(
            address(owner),
            address(router),
            permit2
        );

        vm.deal(address(proxy), 3 ether);
        owner.withdrawFrom(proxy, address(0));

        assertEq(address(owner).balance, 3 ether, "owner did not receive ETH");
        assertEq(address(proxy).balance, 0, "proxy still holds ETH");
    }

    /// @notice The gas-hungry receive hook really does exceed the old stipend,
    ///         so the test above is not vacuous.
    function test_gasHungryOwnerExceedsOldStipend() public {
        GasHungryOwner owner = new GasHungryOwner();
        uint256 before = gasleft();
        (bool ok, ) = address(owner).call{value: 0}("");
        uint256 used = before - gasleft();

        assertTrue(ok);
        assertGt(used, 100000, "receive hook is cheaper than the old cap");
    }

    function test_withdrawErc20_stillWorks() public {
        RelayRouter router = new RelayRouter();
        RelayApprovalProxy proxy = new RelayApprovalProxy(
            alice,
            address(router),
            permit2
        );

        token.mint(address(proxy), 7 ether);
        vm.prank(alice);
        proxy.withdraw(address(token));

        assertEq(token.balanceOf(alice), 7 ether);
    }

    // ─────────────────────────────────────────────────────────────────
    // VIG-RP-092 / 105: the proxy's own ETH lifecycle is observable
    // ─────────────────────────────────────────────────────────────────

    function test_receive_emitsFundsMovement() public {
        RelayApprovalProxy proxy = _proxy(alice);

        vm.deal(bob, 1 ether);
        vm.expectEmit(true, true, true, true, address(proxy));
        emit FundsMovement(bob, address(proxy), address(0), 1 ether, "");

        vm.prank(bob);
        (bool ok, ) = address(proxy).call{value: 1 ether}("");
        assertTrue(ok);
    }

    function test_withdrawNative_emitsFundsMovement() public {
        RelayApprovalProxy proxy = _proxy(alice);
        vm.deal(address(proxy), 2 ether);

        vm.expectEmit(true, true, true, true, address(proxy));
        emit FundsMovement(address(proxy), alice, address(0), 2 ether, "");

        vm.prank(alice);
        proxy.withdraw(address(0));
    }

    function test_withdrawErc20_emitsFundsMovement() public {
        RelayApprovalProxy proxy = _proxy(alice);
        token.mint(address(proxy), 5 ether);

        vm.expectEmit(true, true, true, true, address(proxy));
        emit FundsMovement(address(proxy), alice, address(token), 5 ether, "");

        vm.prank(alice);
        proxy.withdraw(address(token));
    }

    /// @notice Nothing to move, nothing to report.
    function test_withdraw_noEventWhenEmpty() public {
        RelayApprovalProxy proxy = _proxy(alice);

        vm.recordLogs();
        vm.prank(alice);
        proxy.withdraw(address(token));

        bytes32 topic = keccak256(
            "FundsMovement(address,address,address,uint256,bytes)"
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != topic, "phantom movement");
        }
    }

    function _proxy(address owner) internal returns (RelayApprovalProxy) {
        return
            new RelayApprovalProxy(
                owner,
                address(new RelayRouter()),
                permit2
            );
    }

    // ─────────────────────────────────────────────────────────────────
    // VIG-RP-104: constructor rejects zero addresses
    // ─────────────────────────────────────────────────────────────────

    function test_constructorRejectsZeroOwner() public {
        address router = address(new RelayRouter());
        vm.expectRevert(
            RelayApprovalProxy.ConstructorArgCannotBeZeroAddress.selector
        );
        new RelayApprovalProxy(address(0), router, permit2);
    }

    function test_constructorRejectsZeroRouter() public {
        vm.expectRevert(
            RelayApprovalProxy.ConstructorArgCannotBeZeroAddress.selector
        );
        new RelayApprovalProxy(alice, address(0), permit2);
    }

    function test_constructorRejectsZeroPermit2() public {
        address router = address(new RelayRouter());
        vm.expectRevert(
            RelayApprovalProxy.ConstructorArgCannotBeZeroAddress.selector
        );
        new RelayApprovalProxy(alice, router, address(0));
    }

    function test_constructorAcceptsNonZeroArgs() public {
        address router = address(new RelayRouter());
        RelayApprovalProxy proxy = new RelayApprovalProxy(
            alice,
            router,
            permit2
        );
        assertEq(proxy.owner(), alice);
    }
}
