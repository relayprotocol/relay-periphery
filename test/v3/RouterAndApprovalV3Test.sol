// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {StdUtils} from "forge-std/StdUtils.sol";

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAllowanceHolder} from "0x-settler/src/allowanceholder/IAllowanceHolder.sol";
import {ISignatureTransfer} from "permit2-relay/src/interfaces/ISignatureTransfer.sol";
import {EIP712} from "solady/src/utils/EIP712.sol";

import {RelayApprovalProxyV3} from "../../src/v3/RelayApprovalProxyV3.sol";
import {RelayRouterV3} from "../../src/v3/RelayRouterV3.sol";
import {Call3Value, Permit} from "../../src/v3/utils/RelayStructs.sol";

import {BaseTest} from "../base/BaseTest.sol";
import {IUniswapV2Router01} from "../interfaces/IUniswapV2Router02.sol";
import {NoOpERC20} from "../mocks/NoOpERC20.sol";
import {TestERC20Permit} from "../mocks/TestERC20Permit.sol";
import {TestERC721} from "../mocks/TestERC721.sol";
import {TestERC721_ERC20PaymentToken} from "../mocks/TestERC721_ERC20PaymentToken.sol";

struct RelayerWitness {
    address relayer;
}

contract RouterAndApprovalV3Test is BaseTest, EIP712 {
    using SafeERC20 for IERC20;

    // Errors
    error Unauthorized();
    error InvalidSender();
    error InvalidSigner();
    error InvalidTarget(address target);

    // Events
    event RouterUpdated(address newRouter);

    // Constants
    IAllowanceHolder constant ALLOWANCE_HOLDER =
        IAllowanceHolder(payable(0x0000000000001fF3684f28c67538d4D072C22734));

    // Fields to be set
    RelayRouterV3 router;
    RelayApprovalProxyV3 approvalProxy;

    // Various type-hashes / type-strings
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
            "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,RelayerWitness witness)Call3Value(address target,bool allowFailure,uint256 value,bytes callData)RelayerWitness(address relayer,address refundTo,address nftRecipient,Call3Value[] call3Values)TokenPermissions(address token,uint256 amount)"
        );
    bytes32 public constant _FULL_RELAYER_WITNESS_BATCH_TYPEHASH =
        keccak256(
            "PermitBatchWitnessTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline,RelayerWitness witness)Call3Value(address target,bool allowFailure,uint256 value,bytes callData)RelayerWitness(address relayer,address refundTo,address nftRecipient,Call3Value[] call3Values)TokenPermissions(address token,uint256 amount)"
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
        "RelayerWitness witness)Call3Value(address target,bool allowFailure,uint256 value,bytes callData)RelayerWitness(address relayer,address refundTo,address nftRecipient,Call3Value[] call3Values)TokenPermissions(address token,uint256 amount)";

    // Setup
    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("ethereum"));

        super.setUp();

        // Deploy router and approval-proxy contracts
        router = new RelayRouterV3();
        approvalProxy = new RelayApprovalProxyV3(
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
                bob.addr,
                alice.addr,
                address(0),
                keccak256(abi.encodePacked(call3ValuesHashes))
            )
        );
        bytes memory permitSignature = getPermitBatchWitnessSignature(
            permit,
            address(approvalProxy),
            alice.key,
            _FULL_RELAYER_WITNESS_BATCH_TYPEHASH,
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
            address(0),
            permitSignature
        );

        // Call the router
        vm.prank(bob.addr);
        approvalProxy.permit2TransferAndMulticall(
            alice.addr,
            permit,
            calls,
            alice.addr,
            address(0),
            permitSignature
        );

        // Funds transferred as part of the calls are in bob's wallet
        assertEq(erc20_1.balanceOf(bob.addr), 0.03 ether);
        assertEq(erc20_2.balanceOf(bob.addr), 0.15 ether);
        assertEq(erc20_3.balanceOf(bob.addr), 0.2 ether);

        // Any other funds are left in the router
        assertEq(erc20_1.balanceOf(address(router)), 0.07 ether);
        assertEq(erc20_2.balanceOf(address(router)), 0.05 ether);
        assertEq(erc20_3.balanceOf(address(router)), 0.1 ether);

        // All tokens specified by alice were spent from her wallet
        assertEq(erc20_1.balanceOf(alice.addr), 0.9 ether);
        assertEq(erc20_2.balanceOf(alice.addr), 0.8 ether);
        assertEq(erc20_3.balanceOf(alice.addr), 0.7 ether);
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
        router.multicall{value: 1 ether}(calls, address(0), address(0));

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
        router.multicall{value: 2 ether}(calls, address(0), address(0));

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
        router.multicall{value: 1 ether}(calls, address(0), address(0));

        uint256 aliceEthBalanceAfterMulticall = alice.addr.balance;
        uint256 routerUsdcBalanceAfterMulticall = IERC20(USDC).balanceOf(
            address(router)
        );

        assertEq(aliceEthBalanceBefore - aliceEthBalanceAfterMulticall, 1 ether);
        assertGt(routerUsdcBalanceAfterMulticall, routerUsdcBalanceBefore);
        assertEq(nft.ownerOf(10), alice.addr);

        // Cleanup on the router

        address[] memory tokens = new address[](1);
        tokens[0] = USDC;
        address[] memory recipients = new address[](1);
        recipients[0] = alice.addr;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0;
        router.cleanupErc20s(tokens, recipients, amounts);

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
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(router), 0, 1 ether));
        approvalProxy.transferAndMulticall(
            tokens,
            amounts,
            calls,
            alice.addr,
            address(0)
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
            address(0)
        );

        assertEq(erc20_1.balanceOf(bob.addr), 1 ether);
    }

    function testApprovalProxy__TransferAndMulticall__SwapExactTokensForTokens() public {
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
            address(0)
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

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(router), 0, 1 ether));
        approvalProxy.transferAndMulticall(
            tokens,
            amounts,
            calls,
            alice.addr,
            address(0)
        );
    }

    function testApprovalProxy__SetRouter() public {
        // Only the owner can set a new router
        vm.expectRevert(Unauthorized.selector);

        vm.prank(alice.addr);
        approvalProxy.setRouter(alice.addr);

        // Ensure an event is emitted
        vm.expectEmit();
        emit RouterUpdated(bob.addr);
        approvalProxy.setRouter(bob.addr);
    }

    function testApprovalProxy__PermitTransferAndMulticall_Eip2612() public {
        // Generate permit

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
            erc20_permit.DOMAIN_SEPARATOR(),
            structHash
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alice.key, eip712PermitHash);

        Permit[] memory permits = new Permit[](1);
        permits[0] = Permit({
            token: address(erc20_permit),
            owner: alice.addr,
            value: 1 ether,
            nonce: 0,
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

        // Only the permit owner is allowed to use their permit
        vm.prank(bob.addr);
        vm.expectRevert(Unauthorized.selector);
        approvalProxy.permitTransferAndMulticall(
            permits,
            calls,
            bob.addr,
            address(0)
        );

        vm.prank(alice.addr);
        approvalProxy.permitTransferAndMulticall(
            permits,
            calls,
            alice.addr,
            address(0)
        );

        assertEq(erc20_permit.balanceOf(alice.addr), 0);
        assertEq(erc20_permit.balanceOf(bob.addr), 1 ether);
    }

    function testApprovalProxy__PermitTransferAndMulticall__FrontrunEip2612() public {
        // Generate permit

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
            erc20_permit.DOMAIN_SEPARATOR(),
            structHash
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alice.key, eip712PermitHash);

        Permit[] memory permits = new Permit[](1);
        permits[0] = Permit({
            token: address(erc20_permit),
            owner: alice.addr,
            value: 1 ether,
            nonce: 0,
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
            address(0)
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
                bob.addr,
                alice.addr,
                alice.addr,
                keccak256(abi.encodePacked(call3ValuesHashes))
            )
        );
        bytes memory permitSignature = getPermitBatchWitnessSignature(
            permit,
            address(approvalProxy),
            alice.key,
            _FULL_RELAYER_WITNESS_BATCH_TYPEHASH,
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
            amounts
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
        router.multicall(calls, address(0), address(0));

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

        vm.prank(alice.addr);
        router.multicall(calls, address(0), address(0));

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
        router.multicall(calls, address(0), alice.addr);

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
        router.multicall(calls, address(0), alice.addr);

        assertEq(erc721.ownerOf(1), alice.addr);
    }

    // Utility methods

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
