// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISignatureTransfer} from "permit2-relay/src/interfaces/ISignatureTransfer.sol";
import {SignatureVerification} from "permit2-relay/src/libraries/SignatureVerification.sol";
import {InvalidNonce} from "permit2-relay/src/PermitErrors.sol";

import {RelayRouter} from "../src/RelayRouter.sol";
import {RelayApprovalProxy} from "../src/RelayApprovalProxy.sol";
import {RelayApprovalProxyBase} from "../src/RelayApprovalProxyBase.sol";
import {RouteRaceEngine} from "../src/RouteRaceEngine.sol";
import {Call3Value} from "../src/common/Multicall3.sol";

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IWETH {
    function withdraw(uint256 amount) external;
}

interface IOnlyOwnerMulticaller {
    function aggregate(address[] calldata targets, bytes[] calldata data, uint256[] calldata values, address refundTo)
        external
        payable
        returns (bytes[] memory);
}

/// @notice Base fork, end to end: Relay's deployed OnlyOwnerMulticaller submits a limit order that the user signed
///         through Permit2, the router swaps on Uniswap V3, and the signed tail deposits into Relay's depository.
contract LimitOrderTailForkTest is Test {
    ISignatureTransfer constant PERMIT2 = ISignatureTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant DEPOSITORY = 0x4cD00E387622C35bDDB9b4c962C136462338BC31;
    address constant MULTICALLER = 0xfC4Ef5dfF5a5e2C0d381aE073AD7ebb20ac60BE2;
    address constant MULTICALLER_OWNER = 0xf70da97812CB96acDF810712Aa562db8dfA3dbEF;

    // Written out here, not read from the proxy, so that the test checks the proxy's type strings.
    bytes32 constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    bytes32 constant PERMIT_TYPEHASH = keccak256(
        "PermitBatchWitnessTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline,TailWitness witness)SweepWithMinimum(address token,uint256 minAmount,address recipient,bytes32 orderId)TailWitness(address relayer,address refundTo,SweepWithMinimum tail)TokenPermissions(address token,uint256 amount)"
    );
    bytes32 constant TAIL_WITNESS_TYPEHASH = keccak256(
        "TailWitness(address relayer,address refundTo,SweepWithMinimum tail)SweepWithMinimum(address token,uint256 minAmount,address recipient,bytes32 orderId)"
    );
    bytes32 constant SWEEP_WITH_MINIMUM_TYPEHASH =
        keccak256("SweepWithMinimum(address token,uint256 minAmount,address recipient,bytes32 orderId)");

    bytes32 constant ERC20_DEPOSIT = keccak256("RelayErc20Deposit(address,address,uint256,bytes32)");
    bytes32 constant NATIVE_DEPOSIT = keccak256("RelayNativeDeposit(address,uint256,bytes32)");

    uint256 constant NONCE = 48213907716532;
    bytes32 constant ORDER_ID = keccak256("limit-order");

    RelayRouter router;
    RelayApprovalProxy proxy;
    address user;
    uint256 userKey;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("base"));
        router = new RelayRouter();
        proxy = new RelayApprovalProxy(address(this), address(router), address(PERMIT2));
        (user, userKey) = makeAddrAndKey("limit-order-tail-user");
        assertEq(user.code.length, 0);
        deal(WETH, user, 1 ether);
        deal(USDC, user, 100e6);
        vm.startPrank(user);
        IERC20(WETH).approve(address(PERMIT2), type(uint256).max);
        IERC20(USDC).approve(address(PERMIT2), type(uint256).max);
        vm.stopPrank();
    }

    function test_sellDepositsAtLeastTheSignedMinimumUnderTheOrderId() public {
        uint256 snapshot = vm.snapshot();
        uint256 out = _fill(_permit(WETH, 1 ether), _sell(1), _swapCalls(1 ether));
        assertGt(out, 0);

        vm.revertTo(snapshot);
        RelayApprovalProxyBase.SweepWithMinimum memory tail = _sell(out);
        uint256 depositoryBefore = IERC20(USDC).balanceOf(DEPOSITORY);
        assertEq(_fill(_permit(WETH, 1 ether), tail, _swapCalls(1 ether)), out);
        assertEq(IERC20(USDC).balanceOf(DEPOSITORY), depositoryBefore + out);
        assertEq(IERC20(WETH).balanceOf(user), 0);
        assertEq(IERC20(WETH).balanceOf(address(router)), 0);
        assertEq(IERC20(USDC).balanceOf(address(router)), 0);
        assertEq(IERC20(USDC).allowance(address(router), DEPOSITORY), 0);
        assertTrue(_nonceUsed());

        // The same signature cannot fill twice.
        deal(WETH, user, 1 ether);
        bytes memory signature = _sign(_permit(WETH, 1 ether), tail);
        vm.expectRevert(InvalidNonce.selector);
        _submit(_permit(WETH, 1 ether), tail, _swapCalls(1 ether), signature);
    }

    function test_belowTheSignedMinimumNothingMovesAndTheNonceStaysUnused() public {
        uint256 snapshot = vm.snapshot();
        uint256 out = _fill(_permit(WETH, 1 ether), _sell(1), _swapCalls(1 ether));
        vm.revertTo(snapshot);

        RelayApprovalProxyBase.SweepWithMinimum memory tail = _sell(out + 1);
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _permit(WETH, 1 ether);
        bytes memory signature = _sign(permit, tail);
        vm.expectRevert(abi.encodeWithSelector(RouteRaceEngine.InsufficientOutput.selector, out, out + 1));
        _submit(permit, tail, _swapCalls(1 ether), signature);
        assertEq(IERC20(WETH).balanceOf(user), 1 ether);
        assertFalse(_nonceUsed());
    }

    function test_aSolverCallThatTakesOutputRevertsTheFill() public {
        uint256 snapshot = vm.snapshot();
        uint256 out = _fill(_permit(WETH, 1 ether), _sell(1), _swapCalls(1 ether));
        vm.revertTo(snapshot);

        Call3Value[] memory calls = new Call3Value[](3);
        Call3Value[] memory swap = _swapCalls(1 ether);
        calls[0] = swap[0];
        calls[1] = swap[1];
        calls[2] = Call3Value(USDC, false, 0, abi.encodeCall(IERC20.transfer, (makeAddr("thief"), 1)));
        RelayApprovalProxyBase.SweepWithMinimum memory tail = _sell(out);
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _permit(WETH, 1 ether);
        bytes memory signature = _sign(permit, tail);
        vm.expectRevert(abi.encodeWithSelector(RouteRaceEngine.InsufficientOutput.selector, out - 1, out));
        _submit(permit, tail, calls, signature);
        assertEq(IERC20(WETH).balanceOf(user), 1 ether);
    }

    function test_onlyTheSignedRelayerCanUseTheSignature() public {
        RelayApprovalProxyBase.SweepWithMinimum memory tail = _sell(1);
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _permit(WETH, 1 ether);
        bytes memory signature = _sign(permit, tail);

        vm.prank(MULTICALLER_OWNER);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        proxy.permit2TransferAndMulticallWithTail(user, permit, _swapCalls(1 ether), tail, user, "", signature);

        // A tail signature is not a RelayerWitness signature either.
        vm.prank(MULTICALLER);
        vm.expectRevert(SignatureVerification.InvalidSigner.selector);
        proxy.permit2TransferAndMulticall(user, permit, _swapCalls(1 ether), user, address(0), "", signature);
        assertEq(IERC20(WETH).balanceOf(user), 1 ether);
    }

    function test_unsoldInputReturnsToRefundTo() public {
        RelayApprovalProxyBase.SweepWithMinimum memory tail = _sell(1);
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _permit(WETH, 1 ether);
        _submit(permit, tail, _swapCalls(0.6 ether), _sign(permit, tail));
        assertEq(IERC20(WETH).balanceOf(user), 0.4 ether);
        assertEq(IERC20(WETH).balanceOf(address(router)), 0);
    }

    function test_buyDepositsTheFullSignedAmount() public {
        RelayApprovalProxyBase.SweepWithMinimum memory tail =
            RelayApprovalProxyBase.SweepWithMinimum(USDC, 100e6, DEPOSITORY, ORDER_ID);
        assertEq(_fill(_permit(USDC, 100e6), tail, new Call3Value[](0)), 100e6);
        assertEq(IERC20(USDC).balanceOf(user), 0);
    }

    function test_nativeTailDepositsWithDepositNative() public {
        RelayApprovalProxyBase.SweepWithMinimum memory tail =
            RelayApprovalProxyBase.SweepWithMinimum(address(0), 1 ether, DEPOSITORY, ORDER_ID);
        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = Call3Value(WETH, false, 0, abi.encodeCall(IWETH.withdraw, (1 ether)));
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _permit(WETH, 1 ether);
        uint256 depositoryBefore = DEPOSITORY.balance;

        vm.recordLogs();
        _submit(permit, tail, calls, _sign(permit, tail));
        (address from, uint256 amount, bytes32 id) = abi.decode(_onlyDeposit(NATIVE_DEPOSIT), (address, uint256, bytes32));
        assertEq(from, user);
        assertEq(amount, 1 ether);
        assertEq(id, ORDER_ID);
        assertEq(DEPOSITORY.balance, depositoryBefore + 1 ether);
        assertEq(address(router).balance, 0);
    }

    function test_sameChainOrderPaysTheRecipientWithoutADeposit() public {
        address recipient = makeAddr("same-chain-recipient");
        RelayApprovalProxyBase.SweepWithMinimum memory tail =
            RelayApprovalProxyBase.SweepWithMinimum(USDC, 1, recipient, bytes32(0));
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _permit(WETH, 1 ether);

        vm.recordLogs();
        _submit(permit, tail, _swapCalls(1 ether), _sign(permit, tail));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].emitter != DEPOSITORY);
        }
        assertGt(IERC20(USDC).balanceOf(recipient), 0);
        assertEq(IERC20(USDC).balanceOf(address(router)), 0);
    }

    function test_invalidTailFieldsRevertBeforeAnyTransfer() public {
        RelayApprovalProxyBase.SweepWithMinimum[4] memory tails = [
            RelayApprovalProxyBase.SweepWithMinimum(USDC, 0, DEPOSITORY, ORDER_ID),
            RelayApprovalProxyBase.SweepWithMinimum(USDC, 1, address(0), ORDER_ID),
            RelayApprovalProxyBase.SweepWithMinimum(USDC, 1, address(proxy), ORDER_ID),
            RelayApprovalProxyBase.SweepWithMinimum(USDC, 1, address(router), ORDER_ID)
        ];
        ISignatureTransfer.PermitBatchTransferFrom memory permit = _permit(WETH, 1 ether);
        for (uint256 i; i < tails.length; ++i) {
            bytes memory signature = _sign(permit, tails[i]);
            vm.prank(MULTICALLER);
            vm.expectRevert(RelayApprovalProxyBase.InvalidTail.selector);
            proxy.permit2TransferAndMulticallWithTail(user, permit, new Call3Value[](0), tails[i], user, "", signature);
        }
        vm.prank(MULTICALLER);
        vm.expectRevert(RelayApprovalProxyBase.InvalidTail.selector);
        proxy.permit2TransferAndMulticallWithTail(user, permit, new Call3Value[](0), _sell(1), address(0), "", "");
        assertEq(IERC20(WETH).balanceOf(user), 1 ether);
    }

    function _sell(uint256 minAmount) internal pure returns (RelayApprovalProxyBase.SweepWithMinimum memory) {
        return RelayApprovalProxyBase.SweepWithMinimum(USDC, minAmount, DEPOSITORY, ORDER_ID);
    }

    function _permit(address token, uint256 amount)
        internal
        view
        returns (ISignatureTransfer.PermitBatchTransferFrom memory permit)
    {
        permit.permitted = new ISignatureTransfer.TokenPermissions[](1);
        permit.permitted[0] = ISignatureTransfer.TokenPermissions(token, amount);
        permit.nonce = NONCE;
        permit.deadline = block.timestamp + 7 days;
    }

    function _swapCalls(uint256 amountIn) internal view returns (Call3Value[] memory calls) {
        calls = new Call3Value[](2);
        calls[0] = Call3Value(WETH, false, 0, abi.encodeCall(IERC20.approve, (SWAP_ROUTER, amountIn)));
        calls[1] = Call3Value(
            SWAP_ROUTER,
            false,
            0,
            abi.encodeCall(
                ISwapRouter02.exactInputSingle,
                (ISwapRouter02.ExactInputSingleParams(WETH, USDC, 500, address(router), amountIn, 0, 0))
            )
        );
    }

    function _sign(
        ISignatureTransfer.PermitBatchTransferFrom memory permit,
        RelayApprovalProxyBase.SweepWithMinimum memory tail
    ) internal view returns (bytes memory) {
        bytes32[] memory permissions = new bytes32[](permit.permitted.length);
        for (uint256 i; i < permit.permitted.length; ++i) {
            permissions[i] = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, permit.permitted[i]));
        }
        bytes32 witness = keccak256(
            abi.encode(
                TAIL_WITNESS_TYPEHASH,
                MULTICALLER,
                user,
                keccak256(abi.encode(SWEEP_WITH_MINIMUM_TYPEHASH, tail.token, tail.minAmount, tail.recipient, tail.orderId))
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                PERMIT2.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        PERMIT_TYPEHASH,
                        keccak256(abi.encodePacked(permissions)),
                        address(proxy),
                        permit.nonce,
                        permit.deadline,
                        witness
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userKey, digest);
        return bytes.concat(r, s, bytes1(v));
    }

    function _submit(
        ISignatureTransfer.PermitBatchTransferFrom memory permit,
        RelayApprovalProxyBase.SweepWithMinimum memory tail,
        Call3Value[] memory calls,
        bytes memory signature
    ) internal {
        address[] memory targets = new address[](1);
        targets[0] = address(proxy);
        bytes[] memory data = new bytes[](1);
        data[0] = abi.encodeCall(
            RelayApprovalProxyBase.permit2TransferAndMulticallWithTail, (user, permit, calls, tail, user, "", signature)
        );
        vm.prank(MULTICALLER_OWNER);
        IOnlyOwnerMulticaller(MULTICALLER).aggregate(targets, data, new uint256[](1), address(1));
    }

    function _fill(
        ISignatureTransfer.PermitBatchTransferFrom memory permit,
        RelayApprovalProxyBase.SweepWithMinimum memory tail,
        Call3Value[] memory calls
    ) internal returns (uint256 amount) {
        vm.recordLogs();
        _submit(permit, tail, calls, _sign(permit, tail));
        address from;
        address token;
        bytes32 id;
        (from, token, amount, id) = abi.decode(_onlyDeposit(ERC20_DEPOSIT), (address, address, uint256, bytes32));
        assertEq(from, user);
        assertEq(token, tail.token);
        assertEq(id, tail.orderId);
    }

    function _onlyDeposit(bytes32 topic) internal returns (bytes memory data) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == DEPOSITORY) {
                assertEq(logs[i].topics[0], topic);
                data = logs[i].data;
                ++found;
            }
        }
        assertEq(found, 1);
    }

    function _nonceUsed() internal view returns (bool) {
        return PERMIT2.nonceBitmap(user, NONCE >> 8) & (1 << (NONCE & 0xff)) != 0;
    }
}
