// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {EIP712} from "solady/src/utils/EIP712.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {IAllowanceHolder} from "0x-settler/src/allowanceholder/IAllowanceHolder.sol";
import {Permit2} from "permit2-relay/src/Permit2.sol";
import {ISignatureTransfer} from "permit2-relay/src/interfaces/ISignatureTransfer.sol";
import {ApprovalProxy} from "../src/v2/ApprovalProxy.sol";
import {RelayRouter} from "../src/v2/RelayRouter.sol";
import {Call3Value, Permit} from "../src/v2/utils/RelayStructs.sol";
import {NoOpERC20} from "./mocks/NoOpERC20.sol";
import {TestERC20Permit} from "./mocks/TestERC20Permit.sol";
import {TestERC721} from "./mocks/TestERC721.sol";
import {TestERC721_ERC20PaymentToken} from "./mocks/TestERC721_ERC20PaymentToken.sol";
import {BaseRelayTest} from "./base/BaseRelayTest.sol";
import {IUniswapV2Router01} from "./interfaces/IUniswapV2Router02.sol";
import {Attacker} from "./mocks/Attacker.sol";

import {ERC20Router} from "../src/v1/ERC20RouterV1.sol";

struct RelayerWitness {
    address relayer;
}

contract RelayRouterTest is Test, BaseRelayTest, EIP712 {
    using SafeERC20 for IERC20;

    error Unauthorized();
    error InvalidSender();
    error InvalidSigner();
    error InvalidTarget(address target);
    error ERC20InsufficientAllowance(
        address spender,
        uint256 allowance,
        uint256 needed
    );
    error ERC20InsufficientBalance(
        address sender,
        uint256 balance,
        uint256 needed
    );

    event FundsReceived();
    event FundsReceivedWithData(bytes data);
    event RouterUpdated(address newRouter);
    event TestStructHash(bytes32 structHash);
    Permit2 permit2 = Permit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IAllowanceHolder allowanceHolder =
        IAllowanceHolder(payable(0x0000000000001fF3684f28c67538d4D072C22734));
    RelayRouter router;
    ApprovalProxy approvalProxy;
    TestERC20Permit erc20Permit;

    bytes32 public DOMAIN_SEPARATOR;
    bytes32 public constant _CALL3VALUE_TYPEHASH =
        keccak256(
            "Call3Value(address target,bool allowFailure,uint256 value,bytes callData)"
        );
    bytes32 public constant _EIP_712_RELAYER_WITNESS_TYPE_HASH =
        keccak256(
            "RelayerWitness(address relayer,address refundTo,address nftRecipient,Call3Value[] call3Values)Call3Value(address target,bool allowFailure,uint256 value,bytes callData)"
        );
    bytes32 public constant _FULL_RELAYER_WITNESS_TYPEHASH =
        keccak256(
            "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,RelayerWitness witness)RelayerWitness(address relayer,address refundTo,address nftRecipient,Call3Value[] call3Values)Call3Value(address target,bool allowFailure,uint256 value,bytes callData)TokenPermissions(address token,uint256 amount)"
        );
    bytes32 public constant _FULL_RELAYER_WITNESS_BATCH_TYPEHASH =
        keccak256(
            "PermitBatchWitnessTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline,RelayerWitness witness)RelayerWitness(address relayer,address refundTo,address nftRecipient,Call3Value[] call3Values)Call3Value(address target,bool allowFailure,uint256 value,bytes callData)TokenPermissions(address token,uint256 amount)"
        );
    bytes32 public constant _PERMIT_BATCH_TRANSFER_FROM_TYPEHASH =
        keccak256(
            "PermitBatchTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
        );
    bytes32 private constant _2612_PERMIT_TYPEHASH =
        keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
    string public constant _RELAYER_WITNESS_TYPE_STRING =
        "RelayerWitness witness)RelayerWitness(address relayer,address refundTo,address nftRecipient,Call3Value[] call3Values)Call3Value(address target,bool allowFailure,uint256 value,bytes callData)TokenPermissions(address token,uint256 amount)";

    ISignatureTransfer.PermitBatchTransferFrom emptyPermit =
        ISignatureTransfer.PermitBatchTransferFrom({
            permitted: new ISignatureTransfer.TokenPermissions[](0),
            nonce: 1,
            deadline: 0
        });

    function setUp() public override {
        super.setUp();

        router = new RelayRouter();
        approvalProxy = new ApprovalProxy(
            address(this),
            address(router),
            PERMIT2
        );

        erc20Permit = new TestERC20Permit("Test20Permit", "TST20");
        // Alice approves permit2 on the ERC20
        erc20_1.mint(alice.addr, 1 ether);
        erc20_2.mint(alice.addr, 1 ether);
        erc20_3.mint(alice.addr, 1 ether);
        erc20Permit.mint(alice.addr, 1 ether);

        vm.startPrank(alice.addr);
        erc20_1.approve(address(permit2), type(uint256).max);
        erc20_2.approve(address(permit2), type(uint256).max);
        erc20_3.approve(address(permit2), type(uint256).max);
        erc20Permit.approve(address(permit2), type(uint256).max);
        vm.stopPrank();

        DOMAIN_SEPARATOR = permit2.DOMAIN_SEPARATOR();
    }

    function testCorrectWitnessTypehashes() public pure {
        assertEq(
            keccak256(
                abi.encodePacked(
                    _PERMIT_WITNESS_TRANSFER_TYPEHASH_STUB,
                    _RELAYER_WITNESS_TYPE_STRING
                )
            ),
            _FULL_RELAYER_WITNESS_TYPEHASH
        );
        assertEq(
            keccak256(
                abi.encodePacked(
                    _PERMIT_BATCH_WITNESS_TRANSFER_TYPEHASH_STUB,
                    _RELAYER_WITNESS_TYPE_STRING
                )
            ),
            _FULL_RELAYER_WITNESS_BATCH_TYPEHASH
        );
    }

    function testApprovalProxy__Permit2TransferAndMulticall() public {
        // Create the permit
        ISignatureTransfer.TokenPermissions[]
            memory permitted = new ISignatureTransfer.TokenPermissions[](3);
        permitted[0] = ISignatureTransfer.TokenPermissions({
            token: address(erc20_1),
            amount: 0.1 ether
        });
        permitted[1] = ISignatureTransfer.TokenPermissions({
            token: address(erc20_2),
            amount: 0.2 ether
        });
        permitted[2] = ISignatureTransfer.TokenPermissions({
            token: address(erc20_3),
            amount: 0.3 ether
        });

        ISignatureTransfer.PermitBatchTransferFrom
            memory permit = ISignatureTransfer.PermitBatchTransferFrom({
                permitted: permitted,
                nonce: 1,
                deadline: block.timestamp + 100
            });

        // Create calldata to transfer tokens from the router to Bob
        bytes memory calldata1 = abi.encodeWithSelector(
            erc20_1.transfer.selector,
            bob.addr,
            0.03 ether
        );

        bytes memory calldata2 = abi.encodeWithSelector(
            erc20_2.transfer.selector,
            bob.addr,
            0.15 ether
        );

        bytes memory calldata3 = abi.encodeWithSelector(
            erc20_3.transfer.selector,
            bob.addr,
            0.2 ether
        );

        bytes memory calldata4 = abi.encodeWithSelector(
            erc20_1.approve.selector,
            alice.addr,
            1 ether
        );

        Call3Value[] memory calls = new Call3Value[](4);
        calls[0] = Call3Value({
            target: address(erc20_1),
            allowFailure: false,
            value: 0,
            callData: calldata1
        });
        calls[1] = Call3Value({
            target: address(erc20_2),
            allowFailure: false,
            value: 0,
            callData: calldata2
        });
        calls[2] = Call3Value({
            target: address(erc20_3),
            allowFailure: false,
            value: 0,
            callData: calldata3
        });
        calls[3] = Call3Value({
            target: address(erc20_1),
            allowFailure: false,
            value: 0,
            callData: calldata4
        });

        // Get the witness
        bytes32[] memory call3ValuesHashes = new bytes32[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            call3ValuesHashes[i] = keccak256(
                abi.encode(
                    _CALL3VALUE_TYPEHASH,
                    calls[i].target,
                    calls[i].allowFailure,
                    calls[i].value,
                    keccak256(calls[i].callData)
                )
            );
        }

        bytes32 witness = keccak256(
            abi.encode(
                _EIP_712_RELAYER_WITNESS_TYPE_HASH,
                relayer.addr,
                alice.addr,
                address(0),
                keccak256(abi.encodePacked(call3ValuesHashes))
            )
        );

        // Get the permit signature
        bytes memory permitSig = getPermitBatchWitnessSignature(
            permit,
            address(approvalProxy),
            alice.key,
            _FULL_RELAYER_WITNESS_BATCH_TYPEHASH,
            witness,
            DOMAIN_SEPARATOR
        );

        // Call the router as the relayer
        vm.prank(relayer.addr);
        approvalProxy.permit2TransferAndMulticall(
            alice.addr,
            permit,
            calls,
            alice.addr,
            address(0),
            permitSig
        );

        assertEq(erc20_1.balanceOf(bob.addr), 0.03 ether);
        assertEq(erc20_2.balanceOf(bob.addr), 0.15 ether);
        assertEq(erc20_3.balanceOf(bob.addr), 0.2 ether);

        assertEq(erc20_1.balanceOf(address(router)), 0.07 ether);
        assertEq(erc20_2.balanceOf(address(router)), 0.05 ether);
        assertEq(erc20_3.balanceOf(address(router)), 0.1 ether);

        assertEq(erc20_1.balanceOf(alice.addr), 0.9 ether);
        assertEq(erc20_2.balanceOf(alice.addr), 0.8 ether);
        assertEq(erc20_3.balanceOf(alice.addr), 0.7 ether);
    }

    function testMulticall__SwapWETHForUSDC() public {
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        bytes memory data = abi.encodeWithSelector(
            IUniswapV2Router01.swapExactETHForTokens.selector,
            0,
            path,
            alice.addr,
            block.timestamp
        );

        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = Call3Value({
            target: ROUTER_V2,
            allowFailure: false,
            value: 1 ether,
            callData: data
        });

        uint256 aliceBalanceBefore = alice.addr.balance;
        uint256 aliceUSDCBalanceBefore = IERC20(USDC).balanceOf(alice.addr);

        vm.prank(alice.addr);
        router.multicall{value: 1 ether}(calls, address(0), address(0));

        uint256 aliceBalanceAfter = alice.addr.balance;
        uint256 aliceUSDCBalanceAfter = IERC20(USDC).balanceOf(alice.addr);

        assertEq(aliceBalanceBefore - aliceBalanceAfter, 1 ether);
        assertGt(aliceUSDCBalanceAfter, aliceUSDCBalanceBefore);
    }

    function testMulticall__TwoSwaps() public {
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        bytes memory calldata1 = abi.encodeWithSelector(
            IUniswapV2Router01.swapExactETHForTokens.selector,
            0,
            path,
            alice.addr,
            block.timestamp
        );
        bytes memory calldata2 = abi.encodeWithSelector(
            IUniswapV2Router01.swapExactETHForTokens.selector,
            0,
            path,
            alice.addr,
            block.timestamp
        );

        Call3Value[] memory calls = new Call3Value[](2);
        calls[0] = Call3Value({
            target: ROUTER_V2,
            allowFailure: false,
            value: 1 ether,
            callData: calldata1
        });
        calls[1] = Call3Value({
            target: ROUTER_V2,
            allowFailure: false,
            value: 1 ether,
            callData: calldata2
        });

        uint256 aliceBalanceBefore = alice.addr.balance;
        uint256 aliceUSDCBalanceBefore = IERC20(USDC).balanceOf(alice.addr);

        vm.prank(alice.addr);
        router.multicall{value: 2 ether}(calls, address(0), address(0));

        uint256 aliceBalanceAfter = alice.addr.balance;
        uint256 aliceUSDCBalanceAfter = IERC20(USDC).balanceOf(alice.addr);

        assertEq(aliceBalanceBefore - aliceBalanceAfter, 2 ether);
        assertGt(aliceUSDCBalanceAfter, aliceUSDCBalanceBefore);
    }

    function testMulticall__SwapAndCallWithCleanup() public {
        // Deploy NFT that costs 20 USDC to mint
        TestERC721_ERC20PaymentToken nft = new TestERC721_ERC20PaymentToken(
            USDC
        );

        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        bytes memory calldata1 = abi.encodeWithSelector(
            IUniswapV2Router01.swapExactETHForTokens.selector,
            0,
            path,
            address(router),
            block.timestamp
        );
        bytes memory calldata2 = abi.encodeWithSelector(
            IERC20.approve.selector,
            address(nft),
            type(uint256).max
        );
        bytes memory calldata3 = abi.encodeWithSelector(
            nft.mint.selector,
            alice.addr,
            10
        );

        Call3Value[] memory calls = new Call3Value[](3);
        calls[0] = Call3Value({
            target: ROUTER_V2,
            allowFailure: false,
            value: 1 ether,
            callData: calldata1
        });
        calls[1] = Call3Value({
            target: USDC,
            allowFailure: false,
            value: 0,
            callData: calldata2
        });
        calls[2] = Call3Value({
            target: address(nft),
            allowFailure: false,
            value: 0,
            callData: calldata3
        });

        uint256 aliceBalanceBefore = alice.addr.balance;
        uint256 routerUSDCBalanceBefore = IERC20(USDC).balanceOf(
            address(router)
        );

        vm.prank(alice.addr);
        router.multicall{value: 1 ether}(calls, address(0), address(0));

        uint256 aliceBalanceAfterMulticall = alice.addr.balance;
        uint256 routerUSDCBalanceAfterMulticall = IERC20(USDC).balanceOf(
            address(router)
        );

        assertEq(aliceBalanceBefore - aliceBalanceAfterMulticall, 1 ether);
        assertGt(routerUSDCBalanceAfterMulticall, routerUSDCBalanceBefore);
        assertEq(nft.ownerOf(10), alice.addr);

        address[] memory tokens = new address[](1);
        tokens[0] = USDC;

        address[] memory recipients = new address[](1);
        recipients[0] = alice.addr;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0;
        router.cleanupErc20s(tokens, recipients, amounts);

        uint256 aliceUSDCBalanceAfterCleanup = IERC20(USDC).balanceOf(
            alice.addr
        );
        uint256 routerUSDCBalanceAfterCleanup = IERC20(USDC).balanceOf(
            address(this)
        );
        assertEq(aliceUSDCBalanceAfterCleanup, routerUSDCBalanceAfterMulticall);
        assertEq(routerUSDCBalanceAfterCleanup, 0);
    }

    function testApprovalProxyMulticall__transferFrom() public {
        // Approve the approval proxy to spend erc20_1
        vm.prank(alice.addr);
        erc20_1.approve(address(approvalProxy), 1 ether);

        address[] memory tokens = new address[](1);
        tokens[0] = address(erc20_1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        bytes memory calldata1 = abi.encodeWithSelector(
            IERC20.transferFrom.selector,
            alice.addr,
            bob.addr,
            1 ether
        );

        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = Call3Value({
            target: address(erc20_1),
            allowFailure: false,
            value: 0,
            callData: calldata1
        });

        vm.prank(alice.addr);
        vm.expectRevert("Multicall3: call failed");
        approvalProxy.transferAndMulticall(
            tokens,
            amounts,
            calls,
            alice.addr,
            address(0)
        );

        assertEq(erc20_1.balanceOf(address(router)), 0);

        calls[0] = Call3Value({
            target: address(erc20_1),
            allowFailure: false,
            value: 0,
            callData: abi.encodeWithSelector(
                IERC20.transfer.selector,
                bob.addr,
                1 ether
            )
        });

        vm.prank(alice.addr);
        approvalProxy.transferAndMulticall(
            tokens,
            amounts,
            calls,
            alice.addr,
            address(0)
        );

        assertEq(erc20_1.balanceOf(bob.addr), 1 ether);
    }

    function testApprovalProxyMulticall__swapExactTokensForTokens() public {
        // Deal alice some USDC
        deal(USDC, alice.addr, 1000 * 10 ** 6);

        // Approve the approval proxy to spend USDC
        vm.prank(alice.addr);
        IERC20(USDC).approve(address(approvalProxy), 1 ether);

        // Create the path from usdc to dai
        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = DAI;

        address[] memory tokens = new address[](1);
        tokens[0] = USDC;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000 * 10 ** 6;

        // RelayRouter approves UniV2Router to spend USDC
        bytes memory calldata1 = abi.encodeWithSelector(
            IERC20.approve.selector,
            ROUTER_V2,
            1000 * 10 ** 6
        );
        // RelayRouter swaps USDC for DAI and alice receives output
        bytes memory calldata2 = abi.encodeWithSelector(
            IUniswapV2Router01.swapExactTokensForTokens.selector,
            1000 * 10 ** 6,
            990 * 10 ** 18,
            path,
            alice.addr,
            block.timestamp
        );

        Call3Value[] memory calls = new Call3Value[](2);
        calls[0] = Call3Value({
            target: USDC,
            allowFailure: false,
            value: 0,
            callData: calldata1
        });
        calls[1] = Call3Value({
            target: ROUTER_V2,
            allowFailure: false,
            value: 0,
            callData: calldata2
        });

        vm.prank(alice.addr);
        approvalProxy.transferAndMulticall(
            tokens,
            amounts,
            calls,
            alice.addr,
            address(0)
        );

        assertEq(IERC20(USDC).balanceOf(alice.addr), 0);
        assertEq(IERC20(USDC).balanceOf(address(router)), 0);
        assertGt(IERC20(DAI).balanceOf(alice.addr), 990 * 10 ** 18);
    }

    function testApprovalProxyMulticall__RevertNoOpERC20() public {
        NoOpERC20 noOpERC20 = new NoOpERC20();
        vm.startPrank(alice.addr);
        noOpERC20.mint(alice.addr, 1 ether);
        noOpERC20.approve(address(approvalProxy), 1 ether);

        address[] memory tokens = new address[](1);
        tokens[0] = address(noOpERC20);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        bytes memory calldata1 = abi.encodeWithSelector(
            IERC20.transfer.selector,
            bob.addr,
            1 ether
        );

        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = Call3Value({
            target: address(noOpERC20),
            allowFailure: false,
            value: 0,
            callData: calldata1
        });

        vm.expectRevert("Multicall3: call failed");
        approvalProxy.transferAndMulticall(
            tokens,
            amounts,
            calls,
            alice.addr,
            address(0)
        );
    }

    function testApprovalProxy__SetRouter() public {
        vm.expectRevert(Unauthorized.selector);
        vm.prank(alice.addr);
        approvalProxy.setRouter(alice.addr);

        vm.expectEmit();
        emit RouterUpdated(bob.addr);
        approvalProxy.setRouter(bob.addr);
    }

    function testApprovalProxy__RevertApprovalExploit() public {
        // Alice approves the approval proxy to spend erc20_1
        vm.prank(alice.addr);
        erc20_1.approve(address(approvalProxy), 1 ether);

        // Bob listens to this tx and tries to transfer Alice's tokens
        // via the approval
        NoOpERC20 noOpERC20 = new NoOpERC20();
        vm.prank(bob.addr);
        noOpERC20.approve(address(approvalProxy), 1 ether);

        address[] memory tokens = new address[](1);
        tokens[0] = address(noOpERC20);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        bytes memory calldata1 = abi.encodeWithSelector(
            IERC20.transferFrom.selector,
            alice.addr,
            bob.addr,
            1 ether
        );

        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = Call3Value({
            target: address(erc20_1),
            allowFailure: false,
            value: 0,
            callData: calldata1
        });

        vm.prank(bob.addr);
        vm.expectRevert("Multicall3: call failed");
        approvalProxy.transferAndMulticall(
            tokens,
            amounts,
            calls,
            bob.addr,
            address(0)
        );
    }

    function testApprovalProxy__PermitTransferAndMulticall() public {
        // Sign the permit
        bytes32 structHash = keccak256(
            abi.encode(
                _2612_PERMIT_TYPEHASH,
                alice.addr,
                address(approvalProxy),
                1 ether,
                0,
                block.timestamp + 100
            )
        );

        emit TestStructHash(structHash);

        bytes32 eip712PermitHash = _hashTypedData(
            erc20Permit.DOMAIN_SEPARATOR(),
            structHash
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alice.key, eip712PermitHash);

        Permit[] memory permits = new Permit[](1);
        permits[0] = Permit({
            token: address(erc20Permit),
            owner: alice.addr,
            value: 1 ether,
            nonce: 0,
            deadline: block.timestamp + 100,
            v: v,
            r: r,
            s: s
        });

        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = Call3Value({
            target: address(erc20Permit),
            allowFailure: false,
            value: 0,
            callData: abi.encodeWithSelector(
                IERC20.transfer.selector,
                bob.addr,
                1 ether
            )
        });

        vm.prank(alice.addr);
        approvalProxy.permitTransferAndMulticall(
            permits,
            calls,
            alice.addr,
            address(0)
        );

        assertEq(erc20Permit.balanceOf(alice.addr), 0);
        assertEq(erc20Permit.balanceOf(bob.addr), 1 ether);
    }

    function testApprovalProxy__PermitTransferAndMulticall__Frontrun() public {
        // Sign the permit
        bytes32 structHash = keccak256(
            abi.encode(
                _2612_PERMIT_TYPEHASH,
                alice.addr,
                address(approvalProxy),
                1 ether,
                0,
                block.timestamp + 100
            )
        );

        bytes32 eip712PermitHash = _hashTypedData(
            erc20Permit.DOMAIN_SEPARATOR(),
            structHash
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alice.key, eip712PermitHash);

        Permit[] memory permits = new Permit[](1);
        permits[0] = Permit({
            token: address(erc20Permit),
            owner: alice.addr,
            value: 1 ether,
            nonce: 0,
            deadline: block.timestamp + 100,
            v: v,
            r: r,
            s: s
        });

        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = Call3Value({
            target: address(erc20Permit),
            allowFailure: false,
            value: 0,
            callData: abi.encodeWithSelector(
                IERC20.transfer.selector,
                bob.addr,
                1 ether
            )
        });

        // Cal frontruns alice's permit
        vm.prank(cal.addr);
        erc20Permit.permit(
            alice.addr,
            address(approvalProxy),
            1 ether,
            block.timestamp + 100,
            v,
            r,
            s
        );

        vm.prank(alice.addr);
        approvalProxy.permitTransferAndMulticall(
            permits,
            calls,
            alice.addr,
            address(0)
        );
        assertEq(erc20Permit.balanceOf(alice.addr), 0);
        assertEq(erc20Permit.balanceOf(bob.addr), 1 ether);
    }

    function testApprovalProxy__PermitTransferAndMulticall__RevertUnauthorized()
        public
    {
        // Sign the permit
        bytes32 structHash = keccak256(
            abi.encode(
                _2612_PERMIT_TYPEHASH,
                alice.addr,
                address(approvalProxy),
                1 ether,
                0,
                block.timestamp + 100
            )
        );

        bytes32 eip712PermitHash = _hashTypedData(
            erc20Permit.DOMAIN_SEPARATOR(),
            structHash
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alice.key, eip712PermitHash);

        Permit[] memory permits = new Permit[](1);
        permits[0] = Permit({
            token: address(erc20Permit),
            owner: alice.addr,
            value: 1 ether,
            nonce: 0,
            deadline: block.timestamp + 100,
            v: v,
            r: r,
            s: s
        });

        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = Call3Value({
            target: address(erc20Permit),
            allowFailure: false,
            value: 0,
            callData: abi.encodeWithSelector(
                IERC20.transfer.selector,
                bob.addr,
                1 ether
            )
        });

        vm.prank(bob.addr);
        vm.expectRevert(Unauthorized.selector);
        approvalProxy.permitTransferAndMulticall(
            permits,
            calls,
            bob.addr,
            address(0)
        );
    }

    function testApprovalProxy__Permit2TransferAndMulticall__MaliciousSolverChangingRefundToAndNftRecipient()
        public
    {
        // Deploy NFT that costs 20 USDC to mint
        TestERC721_ERC20PaymentToken nft = new TestERC721_ERC20PaymentToken(
            USDC
        );

        // Create the permit
        ISignatureTransfer.TokenPermissions[]
            memory permitted = new ISignatureTransfer.TokenPermissions[](1);
        permitted[0] = ISignatureTransfer.TokenPermissions({
            token: address(erc20_1),
            amount: 0.1 ether
        });

        ISignatureTransfer.PermitBatchTransferFrom
            memory permit = ISignatureTransfer.PermitBatchTransferFrom({
                permitted: permitted,
                nonce: 1,
                deadline: block.timestamp + 100
            });

        address[] memory path = new address[](2);
        path[0] = address(erc20_1);
        path[1] = USDC;

        bytes memory calldata1 = abi.encodeWithSelector(
            IUniswapV2Router01.swapExactETHForTokens.selector,
            0,
            path,
            alice.addr,
            block.timestamp
        );
        bytes memory calldata2 = abi.encodeWithSelector(
            IERC20.approve.selector,
            address(nft),
            type(uint256).max
        );
        bytes memory calldata3 = abi.encodeWithSelector(
            nft.mint.selector,
            alice.addr,
            10
        );

        Call3Value[] memory calls = new Call3Value[](3);
        calls[0] = Call3Value({
            target: ROUTER_V2,
            allowFailure: false,
            value: 0,
            callData: calldata1
        });
        calls[1] = Call3Value({
            target: USDC,
            allowFailure: false,
            value: 0,
            callData: calldata2
        });
        calls[2] = Call3Value({
            target: address(nft),
            allowFailure: false,
            value: 0,
            callData: calldata3
        });

        // Get the witness
        bytes32[] memory call3ValuesHashes = new bytes32[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            call3ValuesHashes[i] = keccak256(
                abi.encode(
                    _CALL3VALUE_TYPEHASH,
                    calls[i].target,
                    calls[i].allowFailure,
                    calls[i].value,
                    keccak256(calls[i].callData)
                )
            );
        }

        bytes32 witness = keccak256(
            abi.encode(
                _EIP_712_RELAYER_WITNESS_TYPE_HASH,
                relayer.addr,
                alice.addr,
                alice.addr,
                keccak256(abi.encodePacked(call3ValuesHashes))
            )
        );

        // Get the permit signature
        bytes memory permitSig = getPermitBatchWitnessSignature(
            permit,
            address(approvalProxy),
            alice.key,
            _FULL_RELAYER_WITNESS_BATCH_TYPEHASH,
            witness,
            DOMAIN_SEPARATOR
        );

        // Call the router as the relayer
        // Relayer tries to replace the refundTo and nftRecipient with their address
        vm.expectRevert(InvalidSigner.selector);
        vm.prank(relayer.addr);
        approvalProxy.permit2TransferAndMulticall(
            alice.addr,
            permit,
            calls,
            relayer.addr,
            relayer.addr,
            permitSig
        );
    }

    function testUSDTCleanupWithSafeERC20() public {
        // Deal router some USDT
        deal(USDT, address(router), 1000 * 10 ** 6);

        address[] memory tokens = new address[](1);
        tokens[0] = USDT;

        address[] memory recipients = new address[](1);
        recipients[0] = relaySolver;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0;

        bytes memory calldata1 = abi.encodeWithSelector(
            router.cleanupErc20s.selector,
            tokens,
            recipients,
            amounts
        );

        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = Call3Value({
            target: address(router),
            allowFailure: false,
            value: 0,
            callData: calldata1
        });

        uint256 solverBalanceBefore = IERC20(USDT).balanceOf(relaySolver);

        vm.prank(relaySolver);
        router.multicall(calls, address(0), address(0));

        assertEq(
            IERC20(USDT).balanceOf(relaySolver) - solverBalanceBefore,
            1000 * 10 ** 6
        );
    }

    function testNativeCleanupViaCall() public {
        // Deal router some native tokens
        vm.deal(address(router), 1 ether);

        bytes memory calldata1 = abi.encodeWithSelector(
            router.cleanupNativeViaCall.selector,
            0,
            bob.addr,
            bytes("0x1234567890")
        );

        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = Call3Value({
            target: address(router),
            allowFailure: false,
            value: 0,
            callData: calldata1
        });

        uint256 bobBalanceBefore = address(bob.addr).balance;

        vm.prank(relaySolver);
        router.multicall(calls, address(0), address(0));

        assertEq(address(bob.addr).balance - bobBalanceBefore, 1 ether);
    }

    function testERC721__SafeMintCorrectRecipient() public {
        TestERC721 erc721 = new TestERC721();

        bytes memory calldata1 = abi.encodeWithSignature(
            "safeMint(address,uint256)",
            address(router),
            1
        );

        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = Call3Value({
            target: address(erc721),
            allowFailure: false,
            value: 0,
            callData: calldata1
        });

        vm.prank(alice.addr);
        router.multicall(calls, address(0), alice.addr);

        assertEq(erc721.ownerOf(1), alice.addr);
    }

    function testERC721__MintMsgSender() public {
        TestERC721 erc721 = new TestERC721();

        bytes memory calldata1 = abi.encodeWithSignature("mint(uint256)", 1);
        bytes memory calldata2 = abi.encodeWithSignature(
            "safeTransferFrom(address,address,uint256)",
            address(router),
            alice.addr,
            1
        );

        Call3Value[] memory calls = new Call3Value[](2);
        calls[0] = Call3Value({
            target: address(erc721),
            allowFailure: false,
            value: 0,
            callData: calldata1
        });
        calls[1] = Call3Value({
            target: address(erc721),
            allowFailure: false,
            value: 0,
            callData: calldata2
        });

        vm.prank(alice.addr);
        router.multicall(calls, address(0), alice.addr);

        assertEq(erc721.ownerOf(1), alice.addr);
    }

    function testERC721__SafeMintMsgSender() public {
        TestERC721 erc721 = new TestERC721();

        address[] memory targets = new address[](1);
        targets[0] = address(erc721);

        bytes memory calldata1 = abi.encodeWithSignature(
            "safeMint(uint256)",
            1
        );

        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = Call3Value({
            target: address(erc721),
            allowFailure: false,
            value: 0,
            callData: calldata1
        });

        router.multicall(calls, address(0), alice.addr);

        assertEq(erc721.ownerOf(1), alice.addr);
    }

    function defaultERC20PermitTransfer(
        address token,
        uint256 amount,
        uint256 nonce
    )
        internal
        view
        returns (ISignatureTransfer.PermitTransferFrom memory result)
    {
        result.permitted.token = token;
        result.permitted.amount = amount;
        result.nonce = nonce;
        result.deadline = block.timestamp + 100;
    }

    function _hashTypedData(
        bytes32 domainSeparator,
        bytes32 structHash
    ) internal pure returns (bytes32 digest) {
        digest = domainSeparator;
        /// @solidity memory-safe-assembly
        assembly {
            // Compute the digest.
            mstore(0x00, 0x1901000000000000) // Store "\x19\x01".
            mstore(0x1a, digest) // Store the domain separator.
            mstore(0x3a, structHash) // Store the struct hash.
            digest := keccak256(0x18, 0x42)
            // Restore the part of the free memory slot that was overwritten.
            mstore(0x3a, 0)
        }
    }

    // not used
    function _domainNameAndVersion()
        internal
        pure
        override
        returns (string memory name, string memory version)
    {
        name = "aaaaaaaaa";
        version = "1";
    }
}
