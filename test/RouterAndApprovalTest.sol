// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAllowanceHolder} from "0x-settler/src/allowanceholder/IAllowanceHolder.sol";
import {ISignatureTransfer} from "permit2-relay/src/interfaces/ISignatureTransfer.sol";
import {EIP712} from "solady/src/utils/EIP712.sol";
import {Vm} from "forge-std/Vm.sol";

import {Call3Value} from "../src/common/Multicall3.sol";
import {Permit2612, Permit3009} from "../src/common/Permits.sol";
import {RelayApprovalProxy} from "../src/RelayApprovalProxy.sol";
import {RelayRouter} from "../src/RelayRouter.sol";

import {BaseTest} from "./base/BaseTest.sol";
import {IUniswapV2Router01} from "./interfaces/IUniswapV2Router02.sol";
import {NoOpERC20} from "./mocks/NoOpERC20.sol";
import {TestERC3009} from "./mocks/TestERC3009.sol";
import {TestERC3009Fee} from "./mocks/TestERC3009Fee.sol";
import {TestERC20Permit} from "./mocks/TestERC20Permit.sol";
import {TestERC721} from "./mocks/TestERC721.sol";
import {TestERC721_ERC20PaymentToken} from "./mocks/TestERC721_ERC20PaymentToken.sol";

// Tests

contract RouterAndApprovalTest is BaseTest, EIP712 {
    using SafeERC20 for IERC20;

    // Errors
    error Unauthorized();
    error InvalidSender();
    error InvalidSigner();
    error InvalidTarget(address target);

    // Events
    event RouterUpdated(address newRouter);
    event FundsMovement(
        address from,
        address to,
        address currency,
        uint256 amount,
        bytes metadata
    );

    // Constants
    IAllowanceHolder constant ALLOWANCE_HOLDER =
        IAllowanceHolder(payable(0x0000000000001fF3684f28c67538d4D072C22734));

    // Fields to be set
    RelayRouter router;
    RelayApprovalProxy approvalProxy;

    // Various type-hashes / type-strings
    bytes32 public constant _CALL3VALUE_TYPEHASH =
        keccak256(
            "Call3Value(address target,bool allowFailure,uint256 value,bytes callData)"
        );
    bytes32 public constant _RELAYER_WITNESS_TYPEHASH =
        keccak256(
            "RelayerWitness(address relayer,uint256 msgValue,address refundTo,address nftRecipient,bytes metadata,Call3Value[] call3Values)Call3Value(address target,bool allowFailure,uint256 value,bytes callData)"
        );
    bytes32 public constant _FUNDING_AUTHORIZATION_TYPEHASH =
        keccak256(
            "FundingAuthorization(address token,address from,uint256 value,uint256 validAfter,uint256 validBefore)"
        );
    bytes32 public constant _MULTICALL_AUTHORIZATION_TYPEHASH =
        keccak256(
            "MulticallAuthorization(address from,address relayer,uint256 msgValue,address refundTo,address nftRecipient,bytes metadata,uint256 fundingIndex,Call3Value[] calls,FundingAuthorization[] funding)Call3Value(address target,bool allowFailure,uint256 value,bytes callData)FundingAuthorization(address token,address from,uint256 value,uint256 validAfter,uint256 validBefore)"
        );
    bytes32 public constant _PERMIT2_FULL_RELAYER_WITNESS_TYPEHASH =
        keccak256(
            "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,RelayerWitness witness)Call3Value(address target,bool allowFailure,uint256 value,bytes callData)RelayerWitness(address relayer,uint256 msgValue,address refundTo,address nftRecipient,bytes metadata,Call3Value[] call3Values)TokenPermissions(address token,uint256 amount)"
        );
    bytes32 public constant _PERMIT2_BATCH_TRANSFER_FROM_TYPEHASH =
        keccak256(
            "PermitBatchTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
        );
    bytes32 public constant _PERMIT2_FULL_RELAYER_WITNESS_BATCH_TYPEHASH =
        keccak256(
            "PermitBatchWitnessTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline,RelayerWitness witness)Call3Value(address target,bool allowFailure,uint256 value,bytes callData)RelayerWitness(address relayer,uint256 msgValue,address refundTo,address nftRecipient,bytes metadata,Call3Value[] call3Values)TokenPermissions(address token,uint256 amount)"
        );
    bytes32 private constant _PERMIT2612_TYPEHASH =
        keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
    bytes32 private constant _PERMIT3009_TYPEHASH =
        keccak256(
            "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
        );
    string public constant _PERMIT2_RELAYER_WITNESS_TYPE_STRING =
        "RelayerWitness witness)Call3Value(address target,bool allowFailure,uint256 value,bytes callData)RelayerWitness(address relayer,uint256 msgValue,address refundTo,address nftRecipient,bytes metadata,Call3Value[] call3Values)TokenPermissions(address token,uint256 amount)";

    // Setup
    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("ethereum"));

        super.setUp();

        // Deploy router and approval-proxy contracts
        router = new RelayRouter();
        approvalProxy = new RelayApprovalProxy(
            address(this),
            address(router),
            address(PERMIT2)
        );

        // Mint tokens to alice
        erc20_1.mint(alice.addr, 1 ether);
        erc20_2.mint(alice.addr, 1 ether);
        erc20_3.mint(alice.addr, 1 ether);
        erc20_permit.mint(alice.addr, 1 ether);

        // Have alice approve permit2
        vm.startPrank(alice.addr);
        erc20_1.approve(address(PERMIT2), type(uint256).max);
        erc20_2.approve(address(PERMIT2), type(uint256).max);
        erc20_3.approve(address(PERMIT2), type(uint256).max);
        erc20_permit.approve(address(PERMIT2), type(uint256).max);
        vm.stopPrank();
    }

    // Tests

    function testCorrectWitnessTypehashes() public pure {
        assertEq(
            keccak256(
                abi.encodePacked(
                    _PERMIT2_WITNESS_TRANSFER_TYPEHASH_STUB,
                    _PERMIT2_RELAYER_WITNESS_TYPE_STRING
                )
            ),
            _PERMIT2_FULL_RELAYER_WITNESS_TYPEHASH
        );
        assertEq(
            keccak256(
                abi.encodePacked(
                    _PERMIT2_BATCH_WITNESS_TRANSFER_TYPEHASH_STUB,
                    _PERMIT2_RELAYER_WITNESS_TYPE_STRING
                )
            ),
            _PERMIT2_FULL_RELAYER_WITNESS_BATCH_TYPEHASH
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

        // Create calldata to transfer tokens from the router to bob

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

        Call3Value[] memory calls = new Call3Value[](3);
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

        // Generate a permit from alice

        bytes32 witness = keccak256(
            abi.encode(
                _RELAYER_WITNESS_TYPEHASH,
                bob.addr,
                0,
                alice.addr,
                alice.addr,
                bytes(""),
                _getCallsHash(calls)
            )
        );
        bytes memory permitSignature = getPermit2BatchWitnessSignature(
            permit,
            address(approvalProxy),
            alice.key,
            _PERMIT2_FULL_RELAYER_WITNESS_BATCH_TYPEHASH,
            witness,
            PERMIT2_DOMAIN_SEPARATOR
        );

        // Only the "relayer" (in this case bob) can use the permit via the approval-proxy
        vm.prank(cal.addr);
        vm.expectRevert(InvalidSigner.selector);
        approvalProxy.permit2TransferAndMulticall(
            alice.addr,
            permit,
            calls,
            alice.addr,
            alice.addr,
            bytes(""),
            permitSignature
        );

        // Call the router
        vm.prank(bob.addr);
        approvalProxy.permit2TransferAndMulticall(
            alice.addr,
            permit,
            calls,
            alice.addr,
            alice.addr,
            bytes(""),
            permitSignature
        );

        // Funds transferred as part of the calls are in bob's wallet
        assertEq(erc20_1.balanceOf(bob.addr), 0.03 ether);
        assertEq(erc20_2.balanceOf(bob.addr), 0.15 ether);
        assertEq(erc20_3.balanceOf(bob.addr), 0.2 ether);

        // Any unspent funds are returned to the refund recipient
        assertEq(erc20_1.balanceOf(address(router)), 0);
        assertEq(erc20_2.balanceOf(address(router)), 0);
        assertEq(erc20_3.balanceOf(address(router)), 0);
        assertEq(erc20_1.balanceOf(alice.addr), 0.97 ether);
        assertEq(erc20_2.balanceOf(alice.addr), 0.85 ether);
        assertEq(erc20_3.balanceOf(alice.addr), 0.8 ether);
    }

    function testRouter__Multicall__SwapWETHForUSDC() public {
        // Encode swap calldata

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

        // Encode router calls

        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = Call3Value({
            target: ROUTER_V2,
            allowFailure: false,
            value: 1 ether,
            callData: data
        });

        uint256 aliceEthBalanceBefore = alice.addr.balance;
        uint256 aliceUsdcBalanceBefore = IERC20(USDC).balanceOf(alice.addr);

        vm.prank(alice.addr);
        router.multicall{value: 1 ether}(
            calls,
            address(0),
            address(0),
            bytes("")
        );

        uint256 aliceEthBalanceAfter = alice.addr.balance;
        uint256 aliceUsdcBalanceAfter = IERC20(USDC).balanceOf(alice.addr);

        assertEq(aliceEthBalanceBefore - aliceEthBalanceAfter, 1 ether);
        assertGt(aliceUsdcBalanceAfter, aliceUsdcBalanceBefore);
    }

    function testRouter__Multicall__TwoSwaps() public {
        // Encode swap calldata

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

        // Encode router calls

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

        uint256 aliceEthBalanceBefore = alice.addr.balance;
        uint256 aliceUsdcBalanceBefore = IERC20(USDC).balanceOf(alice.addr);

        vm.prank(alice.addr);
        router.multicall{value: 2 ether}(
            calls,
            address(0),
            address(0),
            bytes("")
        );

        uint256 aliceEthBalanceAfter = alice.addr.balance;
        uint256 aliceUsdcBalanceAfter = IERC20(USDC).balanceOf(alice.addr);

        assertEq(aliceEthBalanceBefore - aliceEthBalanceAfter, 2 ether);
        assertGt(aliceUsdcBalanceAfter, aliceUsdcBalanceBefore);
    }

    function testRouter__Multicall__SwapAndCallWithCleanup() public {
        // Deploy NFT that costs 20 USDC to mint

        TestERC721_ERC20PaymentToken nft = new TestERC721_ERC20PaymentToken(
            USDC
        );

        // Encode swap calldata

        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        // Swap ETH to USDC
        bytes memory calldata1 = abi.encodeWithSelector(
            IUniswapV2Router01.swapExactETHForTokens.selector,
            0,
            path,
            address(router),
            block.timestamp
        );
        // Approve USDC to the NFT contract
        bytes memory calldata2 = abi.encodeWithSelector(
            IERC20.approve.selector,
            address(nft),
            type(uint256).max
        );
        // Mint on the NFT contract
        bytes memory calldata3 = abi.encodeWithSelector(
            nft.mint.selector,
            alice.addr,
            10
        );

        // Encode router calls

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

        uint256 aliceEthBalanceBefore = alice.addr.balance;
        uint256 routerUsdcBalanceBefore = IERC20(USDC).balanceOf(
            address(router)
        );

        vm.prank(alice.addr);
        router.multicall{value: 1 ether}(
            calls,
            address(0),
            address(0),
            bytes("")
        );

        uint256 aliceEthBalanceAfterMulticall = alice.addr.balance;
        uint256 routerUsdcBalanceAfterMulticall = IERC20(USDC).balanceOf(
            address(router)
        );

        assertEq(
            aliceEthBalanceBefore - aliceEthBalanceAfterMulticall,
            1 ether
        );
        assertGt(routerUsdcBalanceAfterMulticall, routerUsdcBalanceBefore);
        assertEq(nft.ownerOf(10), alice.addr);

        // Cleanup on the router

        address[] memory tokens = new address[](1);
        tokens[0] = USDC;
        address[] memory recipients = new address[](1);
        recipients[0] = alice.addr;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0;
        router.cleanupErc20s(tokens, recipients, amounts, bytes(""));

        uint256 aliceUsdcBalanceAfterCleanup = IERC20(USDC).balanceOf(
            alice.addr
        );
        uint256 routerUsdcBalanceAfterCleanup = IERC20(USDC).balanceOf(
            address(this)
        );
        assertEq(aliceUsdcBalanceAfterCleanup, routerUsdcBalanceAfterMulticall);
        assertEq(routerUsdcBalanceAfterCleanup, 0);
    }

    function testApprovalProxy__TransferAndMulticall__TransferFrom() public {
        // Approve the approval proxy to spend erc20_1

        vm.prank(alice.addr);
        erc20_1.approve(address(approvalProxy), 1 ether);

        // Encode transfer calldata

        bytes memory calldata1 = abi.encodeWithSelector(
            IERC20.transferFrom.selector,
            alice.addr,
            bob.addr,
            1 ether
        );

        // Encode router calls

        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = Call3Value({
            target: address(erc20_1),
            allowFailure: false,
            value: 0,
            callData: calldata1
        });

        address[] memory tokens = new address[](1);
        tokens[0] = address(erc20_1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        // The below call will fail because it's a "transferFrom(alice, bob)" which
        // requires alice to give an approval to the router (which is the sender)

        vm.prank(alice.addr);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                address(router),
                0,
                1 ether
            )
        );
        approvalProxy.transferAndMulticall(
            tokens,
            amounts,
            calls,
            alice.addr,
            alice.addr,
            bytes("")
        );

        // Encode router calls

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

        // This time the call should work because we're using "transfer(bob)" which doesn't require any approval

        vm.prank(alice.addr);
        approvalProxy.transferAndMulticall(
            tokens,
            amounts,
            calls,
            alice.addr,
            alice.addr,
            bytes("")
        );

        assertEq(erc20_1.balanceOf(bob.addr), 1 ether);
    }

    function testApprovalProxy__TransferAndMulticall__SwapExactTokensForTokens()
        public
    {
        // Deal alice some USDC

        deal(USDC, alice.addr, 1000 * 10 ** 6);

        // Approve the approval proxy to spend USDC

        vm.prank(alice.addr);
        IERC20(USDC).approve(address(approvalProxy), 1 ether);

        // Encode the swap calldata

        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = DAI;

        // Approve the uniswap router to spend USDC
        bytes memory calldata1 = abi.encodeWithSelector(
            IERC20.approve.selector,
            ROUTER_V2,
            1000 * 10 ** 6
        );
        // Swap USDC for DAI
        bytes memory calldata2 = abi.encodeWithSelector(
            IUniswapV2Router01.swapExactTokensForTokens.selector,
            1000 * 10 ** 6,
            990 * 10 ** 18,
            path,
            alice.addr,
            block.timestamp
        );

        // Encode the router calls

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

        address[] memory tokens = new address[](1);
        tokens[0] = USDC;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000 * 10 ** 6;

        vm.prank(alice.addr);
        approvalProxy.transferAndMulticall(
            tokens,
            amounts,
            calls,
            alice.addr,
            alice.addr,
            bytes("")
        );

        assertEq(IERC20(USDC).balanceOf(alice.addr), 0);
        assertEq(IERC20(USDC).balanceOf(address(router)), 0);
        assertGt(IERC20(DAI).balanceOf(alice.addr), 990 * 10 ** 18);
    }

    function testApprovalProxy__TransferAndMulticall__RevertNoOpErc20() public {
        // Deploy a no-op token (which doesn't actually anything on transfers)

        NoOpERC20 noOpErc20 = new NoOpERC20();

        // Mint and approve the approval-proxy

        vm.startPrank(alice.addr);
        noOpErc20.mint(alice.addr, 1 ether);
        noOpErc20.approve(address(approvalProxy), 1 ether);

        // Encode the calldata

        bytes memory calldata1 = abi.encodeWithSelector(
            IERC20.transfer.selector,
            bob.addr,
            1 ether
        );

        // Encode the router calls

        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = Call3Value({
            target: address(noOpErc20),
            allowFailure: false,
            value: 0,
            callData: calldata1
        });

        address[] memory tokens = new address[](1);
        tokens[0] = address(noOpErc20);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        // The below call should fail given that the no-op token is not going to process any transfers

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector,
                address(router),
                0,
                1 ether
            )
        );
        approvalProxy.transferAndMulticall(
            tokens,
            amounts,
            calls,
            alice.addr,
            alice.addr,
            bytes("")
        );
    }

    function testApprovalProxy__PermitTransferAndMulticall_Eip2612() public {
        // Generate permit

        bytes32 structHash = keccak256(
            abi.encode(
                _PERMIT2612_TYPEHASH,
                alice.addr,
                address(approvalProxy),
                1 ether,
                0,
                block.timestamp + 100
            )
        );
        bytes32 eip712PermitHash = _hashTypedData(
            erc20_permit.DOMAIN_SEPARATOR(),
            structHash
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alice.key, eip712PermitHash);

        Permit2612[] memory permits = new Permit2612[](1);
        permits[0] = Permit2612({
            token: address(erc20_permit),
            owner: alice.addr,
            value: 1 ether,
            deadline: block.timestamp + 100,
            v: v,
            r: r,
            s: s
        });

        // Encode router calls

        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = Call3Value({
            target: address(erc20_permit),
            allowFailure: false,
            value: 0,
            callData: abi.encodeWithSelector(
                IERC20.transfer.selector,
                bob.addr,
                0.4 ether
            )
        });

        // Only the permit owner is allowed to use their permit
        vm.prank(bob.addr);
        vm.expectRevert(Unauthorized.selector);
        approvalProxy.permitTransferAndMulticall(
            permits,
            calls,
            alice.addr,
            alice.addr,
            bytes("")
        );

        vm.prank(alice.addr);
        approvalProxy.permitTransferAndMulticall(
            permits,
            calls,
            alice.addr,
            alice.addr,
            bytes("")
        );

        assertEq(erc20_permit.balanceOf(alice.addr), 0.6 ether);
        assertEq(erc20_permit.balanceOf(bob.addr), 0.4 ether);
        assertEq(erc20_permit.balanceOf(address(router)), 0);
    }

    function testApprovalProxy__PermitTransferAndMulticall__FrontrunEip2612()
        public
    {
        // Generate permit

        bytes32 structHash = keccak256(
            abi.encode(
                _PERMIT2612_TYPEHASH,
                alice.addr,
                address(approvalProxy),
                1 ether,
                0,
                block.timestamp + 100
            )
        );
        bytes32 eip712PermitHash = _hashTypedData(
            erc20_permit.DOMAIN_SEPARATOR(),
            structHash
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alice.key, eip712PermitHash);

        Permit2612[] memory permits = new Permit2612[](1);
        permits[0] = Permit2612({
            token: address(erc20_permit),
            owner: alice.addr,
            value: 1 ether,
            deadline: block.timestamp + 100,
            v: v,
            r: r,
            s: s
        });

        // Encode router calls

        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = Call3Value({
            target: address(erc20_permit),
            allowFailure: false,
            value: 0,
            callData: abi.encodeWithSelector(
                IERC20.transfer.selector,
                bob.addr,
                1 ether
            )
        });

        // Frontrun the permit
        vm.prank(cal.addr);
        erc20_permit.permit(
            alice.addr,
            address(approvalProxy),
            1 ether,
            block.timestamp + 100,
            v,
            r,
            s
        );

        // Frontran permits are successfully skipped

        vm.prank(alice.addr);
        approvalProxy.permitTransferAndMulticall(
            permits,
            calls,
            alice.addr,
            alice.addr,
            bytes("")
        );

        assertEq(erc20_permit.balanceOf(alice.addr), 0);
        assertEq(erc20_permit.balanceOf(bob.addr), 1 ether);
    }

    function testApprovalProxy__Permit2TransferAndMulticall__MaliciousSenderChangingRefundToAndNftRecipient()
        public
    {
        // Deploy NFT that costs 20 USDC to mint

        TestERC721_ERC20PaymentToken nft = new TestERC721_ERC20PaymentToken(
            USDC
        );

        // Generate permit

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

        // Encode swap calldata

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

        // Encode router calls

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

        // Get permit signature

        bytes32 witness = keccak256(
            abi.encode(
                _RELAYER_WITNESS_TYPEHASH,
                bob.addr,
                0,
                alice.addr,
                alice.addr,
                bytes(""),
                _getCallsHash(calls)
            )
        );
        bytes memory permitSignature = getPermit2BatchWitnessSignature(
            permit,
            address(approvalProxy),
            alice.key,
            _PERMIT2_FULL_RELAYER_WITNESS_BATCH_TYPEHASH,
            witness,
            PERMIT2_DOMAIN_SEPARATOR
        );

        // Replace some fields and expect the router call to fail
        vm.expectRevert(InvalidSigner.selector);
        vm.prank(bob.addr);
        approvalProxy.permit2TransferAndMulticall(
            alice.addr,
            permit,
            calls,
            bob.addr,
            bob.addr,
            bytes(""),
            permitSignature
        );
    }

    function testRouter_USDTCleanupWithSafeERC20() public {
        // Deal router some USDT

        deal(USDT, address(router), 1000 * 10 ** 6);

        // Encode cleanup calldata

        address[] memory tokens = new address[](1);
        tokens[0] = USDT;
        address[] memory recipients = new address[](1);
        recipients[0] = bob.addr;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0;

        bytes memory calldata1 = abi.encodeWithSelector(
            router.cleanupErc20s.selector,
            tokens,
            recipients,
            amounts,
            bytes32(0)
        );

        // Encode router calls

        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = Call3Value({
            target: address(router),
            allowFailure: false,
            value: 0,
            callData: calldata1
        });

        uint256 bobUsdtBalanceBefore = IERC20(USDT).balanceOf(bob.addr);

        vm.prank(bob.addr);
        router.multicall(calls, address(0), address(0), bytes(""));

        assertEq(
            IERC20(USDT).balanceOf(bob.addr) - bobUsdtBalanceBefore,
            1000 * 10 ** 6
        );
    }

    function testRouter_NativeCleanupViaCall() public {
        // Deal router some native tokens
        vm.deal(address(router), 1 ether);

        bytes memory calldata1 = abi.encodeWithSelector(
            router.cleanupNativeViaCall.selector,
            0,
            bob.addr,
            bytes("0x1234567890"),
            bytes("")
        );

        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = Call3Value({
            target: address(router),
            allowFailure: false,
            value: 0,
            callData: calldata1
        });

        uint256 bobBalanceBefore = address(bob.addr).balance;

        vm.prank(alice.addr);
        router.multicall(calls, address(0), address(0), bytes(""));

        assertEq(address(bob.addr).balance - bobBalanceBefore, 1 ether);
    }

    function testRouter__OnERC721Received__SafeMintCorrectRecipient() public {
        // Deploy NFT

        TestERC721 erc721 = new TestERC721();

        // Encode mint calldata

        // "safeMint" is not going to call "onERC721Received"
        bytes memory calldata1 = abi.encodeWithSignature(
            "safeMint(address,uint256)",
            address(router),
            1
        );

        // Encode router calls

        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = Call3Value({
            target: address(erc721),
            allowFailure: false,
            value: 0,
            callData: calldata1
        });

        vm.prank(alice.addr);
        router.multicall(calls, alice.addr, alice.addr, bytes(""));

        // The router should have automatically forward the minted token to the sender
        assertEq(erc721.ownerOf(1), alice.addr);
    }

    function testRouter__OnERC721Received__MintMsgSender() public {
        // Deploy NFT

        TestERC721 erc721 = new TestERC721();

        // Encode mint and transfer calldata

        // "mint" is not going to call "onERC721Received"
        bytes memory calldata1 = abi.encodeWithSignature("mint(uint256)", 1);
        bytes memory calldata2 = abi.encodeWithSignature(
            "safeTransferFrom(address,address,uint256)",
            address(router),
            alice.addr,
            1
        );

        // Encode router calls

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
        router.multicall(calls, alice.addr, alice.addr, bytes(""));

        assertEq(erc721.ownerOf(1), alice.addr);
    }

    function testApprovalProxy__Permit3009TransferAndMulticall() public {
        uint256 amount = 1000 * 10 ** 6;
        TestERC3009 aliceToken = new TestERC3009();
        TestERC3009 bobToken = new TestERC3009();
        aliceToken.mint(alice.addr, amount);
        bobToken.mint(bob.addr, amount);

        // Encode router calls

        Call3Value[] memory calls = new Call3Value[](2);
        calls[0] = Call3Value({
            target: address(aliceToken),
            allowFailure: false,
            value: 0,
            callData: abi.encodeWithSelector(
                IERC20.transfer.selector,
                bob.addr,
                amount / 2
            )
        });
        calls[1] = Call3Value({
            target: address(bobToken),
            allowFailure: false,
            value: 0,
            callData: abi.encodeWithSelector(
                IERC20.transfer.selector,
                cal.addr,
                amount / 2
            )
        });

        uint256 validBefore = block.timestamp + 100;
        Permit3009[] memory permits = new Permit3009[](2);
        permits[0] = Permit3009({
            from: alice.addr,
            value: amount,
            validAfter: 0,
            validBefore: validBefore,
            v: 0,
            r: bytes32(0),
            s: bytes32(0)
        });
        permits[1] = Permit3009({
            from: bob.addr,
            value: amount,
            validAfter: 0,
            validBefore: validBefore,
            v: 0,
            r: bytes32(0),
            s: bytes32(0)
        });
        address[] memory tokens = new address[](2);
        tokens[0] = address(aliceToken);
        tokens[1] = address(bobToken);
        bytes32 fundingHash = _getFundingHash(permits, tokens);

        bytes32 aliceAuthorizationDigest = _getMulticallAuthorizationDigest(
            alice.addr,
            alice.addr,
            0,
            alice.addr,
            alice.addr,
            bytes(""),
            calls,
            fundingHash,
            0
        );
        bytes32 bobAuthorizationDigest = _getMulticallAuthorizationDigest(
            bob.addr,
            alice.addr,
            0,
            alice.addr,
            alice.addr,
            bytes(""),
            calls,
            fundingHash,
            1
        );
        (uint8 aliceAuthorizationV, bytes32 aliceAuthorizationR, bytes32 aliceAuthorizationS) =
            vm.sign(alice.key, aliceAuthorizationDigest);
        (uint8 bobAuthorizationV, bytes32 bobAuthorizationR, bytes32 bobAuthorizationS) =
            vm.sign(bob.key, bobAuthorizationDigest);
        bytes[] memory multicallSignatures = new bytes[](2);
        multicallSignatures[0] = bytes.concat(
            aliceAuthorizationR,
            aliceAuthorizationS,
            bytes1(aliceAuthorizationV)
        );
        multicallSignatures[1] = bytes.concat(
            bobAuthorizationR,
            bobAuthorizationS,
            bytes1(bobAuthorizationV)
        );

        // Generate ERC3009 authorizations whose nonces are the corresponding
        // signed multicall authorization digests.

        bytes32 aliceStructHash = keccak256(
            abi.encode(
                _PERMIT3009_TYPEHASH,
                alice.addr,
                address(approvalProxy),
                amount,
                0,
                validBefore,
                aliceAuthorizationDigest
            )
        );
        bytes32 alicePermitHash = _hashTypedData(
            aliceToken.DOMAIN_SEPARATOR(),
            aliceStructHash
        );
        (permits[0].v, permits[0].r, permits[0].s) =
            vm.sign(alice.key, alicePermitHash);

        bytes32 bobStructHash = keccak256(
            abi.encode(
                _PERMIT3009_TYPEHASH,
                bob.addr,
                address(approvalProxy),
                amount,
                0,
                validBefore,
                bobAuthorizationDigest
            )
        );
        bytes32 bobPermitHash = _hashTypedData(
            bobToken.DOMAIN_SEPARATOR(),
            bobStructHash
        );
        (permits[1].v, permits[1].r, permits[1].s) =
            vm.sign(bob.key, bobPermitHash);

        bytes[] memory mismatchedMulticallSignatures = new bytes[](1);
        vm.expectRevert(RelayApprovalProxy.ArrayLengthsMismatch.selector);
        approvalProxy.permit3009TransferAndMulticall(
            permits,
            tokens,
            calls,
            alice.addr,
            alice.addr,
            bytes(""),
            mismatchedMulticallSignatures
        );

        // Every signature commits to the complete ordered funding batch, so
        // an aligned subset cannot be submitted independently.
        Permit3009[] memory subsetPermits = new Permit3009[](1);
        subsetPermits[0] = permits[0];
        address[] memory subsetTokens = new address[](1);
        subsetTokens[0] = tokens[0];
        bytes[] memory subsetSignatures = new bytes[](1);
        subsetSignatures[0] = multicallSignatures[0];
        vm.prank(alice.addr);
        vm.expectRevert(
            RelayApprovalProxy.InvalidMulticallSignature.selector
        );
        approvalProxy.permit3009TransferAndMulticall(
            subsetPermits,
            subsetTokens,
            calls,
            alice.addr,
            alice.addr,
            bytes(""),
            subsetSignatures
        );
        assertFalse(
            aliceToken.authorizationState(
                alice.addr,
                aliceAuthorizationDigest
            )
        );
        assertFalse(
            bobToken.authorizationState(bob.addr, bobAuthorizationDigest)
        );

        Permit3009[] memory emptyPermits = new Permit3009[](0);
        address[] memory emptyTokens = new address[](0);
        bytes[] memory emptyMulticallSignatures = new bytes[](0);
        vm.expectRevert(RelayApprovalProxy.PermitsCannotBeEmpty.selector);
        approvalProxy.permit3009TransferAndMulticall(
            emptyPermits,
            emptyTokens,
            calls,
            alice.addr,
            alice.addr,
            bytes(""),
            emptyMulticallSignatures
        );

        // Any changes in the signed execution parameters should result in a
        // failure before the ERC3009 authorization is consumed.

        vm.prank(bob.addr);
        vm.expectRevert(
            RelayApprovalProxy.InvalidMulticallSignature.selector
        );
        approvalProxy.permit3009TransferAndMulticall(
            permits,
            tokens,
            calls,
            alice.addr,
            alice.addr,
            bytes(""),
            multicallSignatures
        );

        bytes memory signedCallData = calls[0].callData;
        calls[0].callData = abi.encodeWithSelector(
            IERC20.transfer.selector,
            cal.addr,
            amount
        );
        vm.prank(alice.addr);
        vm.expectRevert(
            RelayApprovalProxy.InvalidMulticallSignature.selector
        );
        approvalProxy.permit3009TransferAndMulticall(
            permits,
            tokens,
            calls,
            alice.addr,
            alice.addr,
            bytes(""),
            multicallSignatures
        );
        calls[0].callData = signedCallData;

        // The ERC3009 authorization cannot be used without the explicit
        // multicall authorization signature.

        bytes[] memory missingMulticallSignatures = new bytes[](2);
        vm.prank(alice.addr);
        vm.expectRevert(
            RelayApprovalProxy.InvalidMulticallSignature.selector
        );
        approvalProxy.permit3009TransferAndMulticall(
            permits,
            tokens,
            calls,
            alice.addr,
            alice.addr,
            bytes(""),
            missingMulticallSignatures
        );

        // Each signature must correspond to the permit at the same index.
        bytes memory aliceMulticallSignature = multicallSignatures[0];
        multicallSignatures[0] = multicallSignatures[1];
        multicallSignatures[1] = aliceMulticallSignature;
        vm.prank(alice.addr);
        vm.expectRevert(
            RelayApprovalProxy.InvalidMulticallSignature.selector
        );
        approvalProxy.permit3009TransferAndMulticall(
            permits,
            tokens,
            calls,
            alice.addr,
            alice.addr,
            bytes(""),
            multicallSignatures
        );
        multicallSignatures[1] = multicallSignatures[0];
        multicallSignatures[0] = aliceMulticallSignature;

        vm.prank(alice.addr);
        approvalProxy.permit3009TransferAndMulticall(
            permits,
            tokens,
            calls,
            alice.addr,
            alice.addr,
            bytes(""),
            multicallSignatures
        );

        assertEq(aliceToken.balanceOf(alice.addr), amount / 2);
        assertEq(aliceToken.balanceOf(bob.addr), amount / 2);
        assertEq(bobToken.balanceOf(bob.addr), 0);
        assertEq(bobToken.balanceOf(alice.addr), amount / 2);
        assertEq(bobToken.balanceOf(cal.addr), amount / 2);
        assertEq(aliceToken.balanceOf(address(router)), 0);
        assertEq(bobToken.balanceOf(address(router)), 0);
    }

    function testApprovalProxy__Permit3009DuplicateOwnerTokenAndEmptyMulticallCleanup()
        public
    {
        uint256 amount = 1000 * 10 ** 6;
        TestERC3009 token = new TestERC3009();
        token.mint(alice.addr, amount);
        Call3Value[] memory emptyCalls = new Call3Value[](0);

        uint256 validBefore = block.timestamp + 100;
        Permit3009[] memory permits = new Permit3009[](2);
        permits[0] = Permit3009({
            from: alice.addr,
            value: amount / 2,
            validAfter: 0,
            validBefore: validBefore,
            v: 0,
            r: bytes32(0),
            s: bytes32(0)
        });
        permits[1] = Permit3009({
            from: alice.addr,
            value: amount / 2,
            validAfter: 0,
            validBefore: validBefore,
            v: 0,
            r: bytes32(0),
            s: bytes32(0)
        });
        address[] memory tokens = new address[](2);
        tokens[0] = address(token);
        tokens[1] = address(token);
        bytes32 fundingHash = _getFundingHash(permits, tokens);

        bytes32 firstAuthorizationDigest = _getMulticallAuthorizationDigest(
            alice.addr,
            bob.addr,
            // This flow is submitted with `{value: 1 ether}`, which the
            // authorization now commits to.
            1 ether,
            alice.addr,
            alice.addr,
            bytes(""),
            emptyCalls,
            fundingHash,
            0
        );
        bytes32 secondAuthorizationDigest = _getMulticallAuthorizationDigest(
            alice.addr,
            bob.addr,
            // This flow is submitted with `{value: 1 ether}`, which the
            // authorization now commits to.
            1 ether,
            alice.addr,
            alice.addr,
            bytes(""),
            emptyCalls,
            fundingHash,
            1
        );
        (uint8 firstV, bytes32 firstR, bytes32 firstS) =
            vm.sign(alice.key, firstAuthorizationDigest);
        (uint8 secondV, bytes32 secondR, bytes32 secondS) =
            vm.sign(alice.key, secondAuthorizationDigest);
        bytes[] memory multicallSignatures = new bytes[](2);
        multicallSignatures[0] = bytes.concat(
            firstR,
            firstS,
            bytes1(firstV)
        );
        multicallSignatures[1] = bytes.concat(
            secondR,
            secondS,
            bytes1(secondV)
        );

        bytes32 firstStructHash = keccak256(
            abi.encode(
                _PERMIT3009_TYPEHASH,
                alice.addr,
                address(approvalProxy),
                amount / 2,
                0,
                validBefore,
                firstAuthorizationDigest
            )
        );
        bytes32 firstPermitHash = _hashTypedData(
            token.DOMAIN_SEPARATOR(),
            firstStructHash
        );
        (permits[0].v, permits[0].r, permits[0].s) =
            vm.sign(alice.key, firstPermitHash);

        bytes32 secondStructHash = keccak256(
            abi.encode(
                _PERMIT3009_TYPEHASH,
                alice.addr,
                address(approvalProxy),
                amount / 2,
                0,
                validBefore,
                secondAuthorizationDigest
            )
        );
        bytes32 secondPermitHash = _hashTypedData(
            token.DOMAIN_SEPARATOR(),
            secondStructHash
        );
        (permits[1].v, permits[1].r, permits[1].s) =
            vm.sign(alice.key, secondPermitHash);

        vm.prank(bob.addr);
        approvalProxy.permit3009TransferAndMulticall{value: 1 ether}(
            permits,
            tokens,
            emptyCalls,
            alice.addr,
            alice.addr,
            bytes(""),
            multicallSignatures
        );

        assertEq(token.balanceOf(alice.addr), amount);
        assertEq(token.balanceOf(address(router)), 0);
        assertTrue(
            token.authorizationState(alice.addr, firstAuthorizationDigest)
        );
        assertTrue(
            token.authorizationState(alice.addr, secondAuthorizationDigest)
        );
        assertEq(address(router).balance, 0);
        assertEq(address(approvalProxy).balance, 0);

        // A subsequent attacker-controlled multicall cannot spend the funds.
        Call3Value[] memory attackerCalls = new Call3Value[](1);
        attackerCalls[0] = Call3Value({
            target: address(token),
            allowFailure: true,
            value: 0,
            callData: abi.encodeWithSelector(
                IERC20.transfer.selector,
                bob.addr,
                amount
            )
        });
        vm.prank(bob.addr);
        router.multicall(
            attackerCalls,
            bob.addr,
            bob.addr,
            bytes("")
        );

        assertEq(token.balanceOf(bob.addr), 0);
        assertEq(token.balanceOf(address(router)), 0);
    }

    // ─────────────────────────────────────────────────────────────────
    // VIG-RP-114: msg.value is part of the signed authorization
    // ─────────────────────────────────────────────────────────────────

    function testApprovalProxy__Permit3009__MsgValueIsBound() public {
        uint256 amount = 1000 * 10 ** 6;
        TestERC3009 aliceToken = new TestERC3009();
        aliceToken.mint(alice.addr, amount);

        Call3Value[] memory calls = new Call3Value[](0);
        uint256 validBefore = block.timestamp + 100;

        Permit3009[] memory permits = new Permit3009[](1);
        permits[0] = Permit3009({
            from: alice.addr,
            value: amount,
            validAfter: 0,
            validBefore: validBefore,
            v: 0,
            r: bytes32(0),
            s: bytes32(0)
        });
        address[] memory tokens = new address[](1);
        tokens[0] = address(aliceToken);

        // Sign for a zero-value submission.
        bytes32 digest = _getMulticallAuthorizationDigest(
            alice.addr,
            bob.addr,
            0,
            alice.addr,
            alice.addr,
            bytes(""),
            calls,
            _getFundingHash(permits, tokens),
            0
        );
        bytes[] memory multicallSignatures = new bytes[](1);
        {
            (uint8 av, bytes32 ar, bytes32 as_) = vm.sign(alice.key, digest);
            multicallSignatures[0] = bytes.concat(ar, as_, bytes1(av));
        }
        (permits[0].v, permits[0].r, permits[0].s) = vm.sign(
            alice.key,
            _hashTypedData(
                aliceToken.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        _PERMIT3009_TYPEHASH,
                        alice.addr,
                        address(approvalProxy),
                        amount,
                        0,
                        validBefore,
                        digest
                    )
                )
            )
        );

        // Submitting the same bundle with native value attached no longer
        // matches the authorization.
        vm.deal(bob.addr, 1 ether);
        vm.prank(bob.addr);
        vm.expectRevert(
            RelayApprovalProxy.InvalidMulticallSignature.selector
        );
        approvalProxy.permit3009TransferAndMulticall{value: 1 wei}(
            permits,
            tokens,
            calls,
            alice.addr,
            alice.addr,
            bytes(""),
            multicallSignatures
        );

        // The authorized zero-value submission still works.
        vm.prank(bob.addr);
        approvalProxy.permit3009TransferAndMulticall(
            permits,
            tokens,
            calls,
            alice.addr,
            alice.addr,
            bytes(""),
            multicallSignatures
        );

        assertEq(aliceToken.balanceOf(alice.addr), amount, "not refunded");
        assertEq(aliceToken.balanceOf(address(router)), 0);
    }

    // ─────────────────────────────────────────────────────────────────
    // VIG-RP-101: fee-on-transfer ERC3009 tokens
    // ─────────────────────────────────────────────────────────────────

    function testApprovalProxy__Permit3009__FeeOnTransferForwardsReceived()
        public
    {
        uint256 amount = 1000 * 10 ** 6;
        TestERC3009Fee feeToken = new TestERC3009Fee();
        feeToken.mint(alice.addr, amount);

        Call3Value[] memory calls = new Call3Value[](0);
        uint256 validBefore = block.timestamp + 100;

        Permit3009[] memory permits = new Permit3009[](1);
        permits[0] = Permit3009({
            from: alice.addr,
            value: amount,
            validAfter: 0,
            validBefore: validBefore,
            v: 0,
            r: bytes32(0),
            s: bytes32(0)
        });
        address[] memory tokens = new address[](1);
        tokens[0] = address(feeToken);

        bytes32 digest = _getMulticallAuthorizationDigest(
            alice.addr,
            bob.addr,
            0,
            alice.addr,
            alice.addr,
            bytes(""),
            calls,
            _getFundingHash(permits, tokens),
            0
        );
        bytes[] memory multicallSignatures = new bytes[](1);
        {
            (uint8 av, bytes32 ar, bytes32 as_) = vm.sign(alice.key, digest);
            multicallSignatures[0] = bytes.concat(ar, as_, bytes1(av));
        }
        (permits[0].v, permits[0].r, permits[0].s) = vm.sign(
            alice.key,
            _hashTypedData(
                feeToken.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        _PERMIT3009_TYPEHASH,
                        alice.addr,
                        address(approvalProxy),
                        amount,
                        0,
                        validBefore,
                        digest
                    )
                )
            )
        );

        // The token taxes every transfer, so the proxy receives `amount`
        // minus one fee and the router receives that minus a second fee. The
        // event must report the second figure — what actually reached the
        // router — not the proxy's receipt and not the authorized `amount`.
        uint256 received = amount - (amount * feeToken.FEE_BPS()) / 10_000;
        uint256 delivered = received -
            (received * feeToken.FEE_BPS()) /
            10_000;

        vm.expectEmit(true, true, true, true, address(approvalProxy));
        emit FundsMovement(
            alice.addr,
            address(router),
            address(feeToken),
            delivered,
            bytes("")
        );

        vm.prank(bob.addr);
        approvalProxy.permit3009TransferAndMulticall(
            permits,
            tokens,
            calls,
            alice.addr,
            alice.addr,
            bytes(""),
            multicallSignatures
        );

        assertEq(feeToken.balanceOf(address(approvalProxy)), 0, "proxy holds");
        assertEq(feeToken.balanceOf(address(router)), 0, "router holds");

        // The empty multicall sweeps the router's balance back to alice,
        // taxed a third time on the way. Alice ending with exactly
        // `delivered` minus that sweep fee pins that the router really did
        // hold `delivered`, not the proxy's receipt.
        assertEq(
            feeToken.balanceOf(alice.addr),
            delivered - (delivered * feeToken.FEE_BPS()) / 10_000,
            "router receipt overstated"
        );
    }

    // ─────────────────────────────────────────────────────────────────
    // VIG-RP-106 / 091: no FundsMovement for a zero-amount transfer
    // ─────────────────────────────────────────────────────────────────

    function testApprovalProxy__TransferAndMulticall__NoPhantomFundsMovement()
        public
    {
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        tokens[0] = address(erc20_1);
        amounts[0] = 0;

        Call3Value[] memory calls = new Call3Value[](0);

        vm.prank(alice.addr);
        vm.recordLogs();
        approvalProxy.transferAndMulticall(
            tokens,
            amounts,
            calls,
            alice.addr,
            alice.addr,
            bytes("")
        );

        bytes32 topic = keccak256(
            "FundsMovement(address,address,address,uint256,bytes)"
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != topic, "phantom FundsMovement");
        }
    }

    // ─────────────────────────────────────────────────────────────────
    // The authorization type string must not drift from the contract
    // ─────────────────────────────────────────────────────────────────

    function testCorrectMulticallAuthorizationTypehash() public view {
        assertEq(
            approvalProxy._MULTICALL_AUTHORIZATION_TYPEHASH(),
            _MULTICALL_AUTHORIZATION_TYPEHASH
        );
        assertEq(
            approvalProxy._FUNDING_AUTHORIZATION_TYPEHASH(),
            _FUNDING_AUTHORIZATION_TYPEHASH
        );
        assertEq(
            approvalProxy._RELAYER_WITNESS_TYPEHASH(),
            _RELAYER_WITNESS_TYPEHASH
        );
        assertEq(
            approvalProxy._RELAYER_WITNESS_TYPE_STRING(),
            _PERMIT2_RELAYER_WITNESS_TYPE_STRING
        );
    }

    // Utility methods

    function _getCallsHash(
        Call3Value[] memory calls
    ) internal pure returns (bytes32) {
        bytes32[] memory callHashes = new bytes32[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            // Encode the call and hash it
            callHashes[i] = keccak256(
                abi.encode(
                    _CALL3VALUE_TYPEHASH,
                    calls[i].target,
                    calls[i].allowFailure,
                    calls[i].value,
                    keccak256(calls[i].callData)
                )
            );
        }

        return keccak256(abi.encodePacked(callHashes));
    }

    function _getFundingHash(
        Permit3009[] memory permits,
        address[] memory tokens
    ) internal pure returns (bytes32) {
        bytes32[] memory fundingHashes = new bytes32[](permits.length);
        for (uint256 i = 0; i < permits.length; i++) {
            fundingHashes[i] = keccak256(
                abi.encode(
                    _FUNDING_AUTHORIZATION_TYPEHASH,
                    tokens[i],
                    permits[i].from,
                    permits[i].value,
                    permits[i].validAfter,
                    permits[i].validBefore
                )
            );
        }

        return keccak256(abi.encodePacked(fundingHashes));
    }

    function _getMulticallAuthorizationDigest(
        address user,
        address relayer,
        uint256 msgValue,
        address refundTo,
        address nftRecipient,
        bytes memory metadata,
        Call3Value[] memory calls,
        bytes32 fundingHash,
        uint256 fundingIndex
    ) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                _DOMAIN_TYPEHASH,
                keccak256(bytes("RelayApprovalProxy")),
                keccak256(bytes("3.1")),
                block.chainid,
                address(approvalProxy)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                _MULTICALL_AUTHORIZATION_TYPEHASH,
                user,
                relayer,
                msgValue,
                refundTo,
                nftRecipient,
                keccak256(metadata),
                fundingIndex,
                _getCallsHash(calls),
                fundingHash
            )
        );

        return _hashTypedData(domainSeparator, structHash);
    }

    function _getRelayerWitnessHash(
        address relayer,
        uint256 msgValue,
        address refundTo,
        address nftRecipient,
        bytes memory metadata,
        Call3Value[] memory calls
    ) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    _RELAYER_WITNESS_TYPEHASH,
                    relayer,
                    msgValue,
                    refundTo,
                    nftRecipient,
                    keccak256(metadata),
                    _getCallsHash(calls)
                )
            );
    }

    function _hashTypedData(
        bytes32 domainSeparator,
        bytes32 structHash
    ) internal pure returns (bytes32 digest) {
        digest = domainSeparator;
        /// @solidity memory-safe-assembly
        assembly {
            // Compute the digest
            mstore(0x00, 0x1901000000000000) // Store "\x19\x01"
            mstore(0x1a, digest) // Store the domain separator
            mstore(0x3a, structHash) // Store the struct hash
            digest := keccak256(0x18, 0x42)
            // Restore the part of the free memory slot that was overwritten
            mstore(0x3a, 0)
        }
    }

    // Not actually used but still required to be defined

    function _domainNameAndVersion()
        internal
        pure
        override
        returns (string memory name, string memory version)
    {
        name = "UNUSED";
        version = "UNUSED";
    }
}
