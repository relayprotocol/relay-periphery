// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RelayRouter} from "../src/RelayRouter.sol";
import {RouteRaceEngine} from "../src/RouteRaceEngine.sol";
import {IRelayRouter} from "../src/interfaces/IRelayRouter.sol";
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

/// @notice Base fork: a real Uniswap V3 swap on the router, then `sweepWithMinimum` into Relay's depository.
contract SweepWithMinimumForkTest is Test {
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address constant DEPOSITORY = 0x4cD00E387622C35bDDB9b4c962C136462338BC31;

    bytes32 constant ERC20_DEPOSIT = keccak256("RelayErc20Deposit(address,address,uint256,bytes32)");
    bytes32 constant NATIVE_DEPOSIT = keccak256("RelayNativeDeposit(address,uint256,bytes32)");

    RelayRouter router;
    address user = makeAddr("limit-order-user");
    address solver = makeAddr("limit-order-solver");
    bytes32 orderId = keccak256("limit-order");

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("base"));
        router = new RelayRouter();
        deal(WETH, address(router), 1 ether);
    }

    function test_swapOutputIsDepositedUnderTheOrderIdOnlyAtOrAboveTheMinimum() public {
        uint256 depositoryBefore = IERC20(USDC).balanceOf(DEPOSITORY);
        uint256 snapshot = vm.snapshot();

        uint256 out = _fillErc20(0);
        assertGt(out, 0);
        assertEq(IERC20(USDC).balanceOf(DEPOSITORY), depositoryBefore + out);
        assertEq(IERC20(USDC).balanceOf(address(router)), 0);
        assertEq(IERC20(WETH).balanceOf(address(router)), 0);
        assertEq(IERC20(USDC).allowance(address(router), DEPOSITORY), 0);

        vm.revertTo(snapshot);
        assertEq(_fillErc20(out), out);

        vm.revertTo(snapshot);
        vm.expectRevert(abi.encodeWithSelector(RouteRaceEngine.InsufficientOutput.selector, out, out + 1));
        vm.prank(solver);
        router.multicall(_erc20Calls(out + 1), solver, address(0), "");
        assertEq(IERC20(WETH).balanceOf(address(router)), 1 ether);
        assertEq(IERC20(USDC).balanceOf(DEPOSITORY), depositoryBefore);
    }

    function test_nativeOutputIsDepositedUnderTheOrderIdOnlyAtOrAboveTheMinimum() public {
        Call3Value[] memory calls = new Call3Value[](2);
        calls[0] = Call3Value(WETH, false, 0, abi.encodeCall(IWETH.withdraw, (1 ether)));
        calls[1] = Call3Value(
            address(router),
            false,
            0,
            abi.encodeCall(
                IRelayRouter.sweepNativeWithMinimum,
                (1 ether, DEPOSITORY, abi.encodeWithSignature("depositNative(address,bytes32)", user, orderId))
            )
        );
        uint256 depositoryBefore = DEPOSITORY.balance;
        uint256 snapshot = vm.snapshot();

        vm.recordLogs();
        vm.prank(solver);
        router.multicall(calls, solver, address(0), "");
        (address from, uint256 amount, bytes32 id) = abi.decode(_onlyLog(NATIVE_DEPOSIT), (address, uint256, bytes32));
        assertEq(from, user);
        assertEq(amount, 1 ether);
        assertEq(id, orderId);
        assertEq(DEPOSITORY.balance, depositoryBefore + 1 ether);
        assertEq(address(router).balance, 0);

        vm.revertTo(snapshot);
        calls[1].callData = abi.encodeCall(
            IRelayRouter.sweepNativeWithMinimum,
            (1 ether + 1, DEPOSITORY, abi.encodeWithSignature("depositNative(address,bytes32)", user, orderId))
        );
        vm.expectRevert(abi.encodeWithSelector(RouteRaceEngine.InsufficientOutput.selector, 1 ether, 1 ether + 1));
        vm.prank(solver);
        router.multicall(calls, solver, address(0), "");
        assertEq(IERC20(WETH).balanceOf(address(router)), 1 ether);
    }

    function test_withoutDataTheFullOutputGoesToTheRecipient() public {
        Call3Value[] memory calls = _erc20Calls(0);
        calls[2].callData = abi.encodeCall(IRelayRouter.sweepWithMinimum, (USDC, 1, user, ""));

        vm.prank(solver);
        router.multicall(calls, solver, address(0), "");
        assertGt(IERC20(USDC).balanceOf(user), 0);
        assertEq(IERC20(USDC).balanceOf(address(router)), 0);
    }

    function _fillErc20(uint256 minAmount) internal returns (uint256 amount) {
        vm.recordLogs();
        vm.prank(solver);
        router.multicall(_erc20Calls(minAmount), solver, address(0), "");
        address from;
        address token;
        bytes32 id;
        (from, token, amount, id) = abi.decode(_onlyLog(ERC20_DEPOSIT), (address, address, uint256, bytes32));
        assertEq(from, user);
        assertEq(token, USDC);
        assertEq(id, orderId);
    }

    function _erc20Calls(uint256 minAmount) internal view returns (Call3Value[] memory calls) {
        calls = new Call3Value[](3);
        calls[0] = Call3Value(WETH, false, 0, abi.encodeCall(IERC20.approve, (SWAP_ROUTER, 1 ether)));
        calls[1] = Call3Value(
            SWAP_ROUTER,
            false,
            0,
            abi.encodeCall(
                ISwapRouter02.exactInputSingle,
                (ISwapRouter02.ExactInputSingleParams(WETH, USDC, 500, address(router), 1 ether, 0, 0))
            )
        );
        calls[2] = Call3Value(
            address(router),
            false,
            0,
            abi.encodeCall(
                IRelayRouter.sweepWithMinimum,
                (
                    USDC,
                    minAmount,
                    DEPOSITORY,
                    abi.encodeWithSignature("depositErc20(address,address,bytes32)", user, USDC, orderId)
                )
            )
        );
    }

    function _onlyLog(bytes32 topic) internal returns (bytes memory data) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == DEPOSITORY && logs[i].topics[0] == topic) {
                data = logs[i].data;
                ++found;
            }
        }
        assertEq(found, 1);
    }
}
