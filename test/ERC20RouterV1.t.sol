// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Multicaller} from "multicaller/src/Multicaller.sol";
import {Permit2} from "permit2-relay/src/Permit2.sol";
import {ISignatureTransfer} from "permit2-relay/src/interfaces/ISignatureTransfer.sol";
import {IPermit2} from "permit2-relay/src/interfaces/IPermit2.sol";
import {PermitSignature} from "permit2-relay/test/utils/PermitSignature.sol";
import {ApprovalProxy} from "../src/v1/ApprovalProxyV1.sol";
import {ERC20Router} from "../src/v1/ERC20RouterV1.sol";
import {NoOpERC20} from "./mocks/NoOpERC20.sol";
import {TestERC721} from "./mocks/TestERC721.sol";
import {TestERC721_ERC20PaymentToken} from "./mocks/TestERC721_ERC20PaymentToken.sol";
import {BaseRelayTest} from "./base/BaseRelayTest.sol";
import {IUniswapV2Router01} from "./interfaces/IUniswapV2Router02.sol";
import {CleanupReenterer} from "./mocks/CleanupReenterer.sol";
import {CleanupReentererDelegatecall} from "./mocks/CleanupReentererDelegatecall.sol";
import {Multicaller} from "multicaller/src/Multicaller.sol";
struct RelayerWitness {
    address relayer;
}

contract ERC20RouterV1Test is Test, BaseRelayTest {
    using SafeERC20 for IERC20;

    error Unauthorized();
    error InvalidSender();
    error InvalidMsgSender(address expected, address actual);
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

    Permit2 permit2 = Permit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    Multicaller multicaller =
        Multicaller(payable(0x0000000000002Bdbf1Bf3279983603Ec279CC6dF));
    ERC20Router router;
    ApprovalProxy approvalProxy;

    bytes32 public DOMAIN_SEPARATOR;
    bytes32 public constant _EIP_712_RELAYER_WITNESS_TYPE_HASH =
        keccak256("RelayerWitness(address relayer)");
    bytes32 public constant _FULL_RELAYER_WITNESS_TYPEHASH =
        keccak256(
            "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,RelayerWitness witness)RelayerWitness(address relayer)TokenPermissions(address token,uint256 amount)"
        );
    bytes32 public constant _FULL_RELAYER_WITNESS_BATCH_TYPEHASH =
        keccak256(
            "PermitBatchWitnessTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline,RelayerWitness witness)RelayerWitness(address relayer)TokenPermissions(address token,uint256 amount)"
        );
    string public constant _PERMIT_TRANSFER_TYPEHASH_STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";
    string public constant _RELAYER_WITNESS_TYPE_STRING =
        "RelayerWitness witness)RelayerWitness(address relayer)TokenPermissions(address token,uint256 amount)";

    ISignatureTransfer.PermitBatchTransferFrom emptyPermit =
        ISignatureTransfer.PermitBatchTransferFrom({
            permitted: new ISignatureTransfer.TokenPermissions[](0),
            nonce: 1,
            deadline: 0
        });

    function setUp() public override {
        super.setUp();

        router = new ERC20Router(address(permit2));

        approvalProxy = new ApprovalProxy(address(this), address(router));

        // Alice approves permit2 on the ERC20
        erc20_1.mint(alice.addr, 1 ether);
        erc20_2.mint(alice.addr, 1 ether);
        erc20_3.mint(alice.addr, 1 ether);

        vm.startPrank(alice.addr);
        erc20_1.approve(address(permit2), type(uint256).max);
        erc20_2.approve(address(permit2), type(uint256).max);
        erc20_3.approve(address(permit2), type(uint256).max);
        vm.stopPrank();

        DOMAIN_SEPARATOR = permit2.DOMAIN_SEPARATOR();
    }

    function testReceive() public {
        uint256 value = 1 ether;

        vm.prank(alice.addr);
        (bool success, ) = address(router).call{value: value}("");
        assert(success);

        assertEq(address(router).balance, 1 ether);
    }

    function testCorrectWitnessTypehashes() public {
        assertEq(
            keccak256(
                abi.encodePacked(
                    _PERMIT_TRANSFER_TYPEHASH_STUB,
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

    function testPermitMulticall() public {
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

        // Get the witness
        bytes32 witness = keccak256(
            abi.encode(_EIP_712_RELAYER_WITNESS_TYPE_HASH, relayer.addr)
        );

        // Get the permit signature
        bytes memory permitSig = getPermitBatchWitnessSignature(
            permit,
            alice.key,
            _FULL_RELAYER_WITNESS_BATCH_TYPEHASH,
            witness,
            DOMAIN_SEPARATOR
        );

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

        address[] memory targets = new address[](4);
        targets[0] = address(erc20_1);
        targets[1] = address(erc20_2);
        targets[2] = address(erc20_3);
        targets[3] = address(erc20_1);

        bytes[] memory datas = new bytes[](4);
        datas[0] = calldata1;
        datas[1] = calldata2;
        datas[2] = calldata3;
        datas[3] = calldata4;

        uint256[] memory values = new uint256[](4);
        values[0] = 0;
        values[1] = 0;
        values[2] = 0;
        values[3] = 0;

        // Call the router as the relayer
        vm.prank(relayer.addr);
        router.permitMulticall(
            alice.addr,
            permit,
            targets,
            datas,
            values,
            alice.addr,
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

    function testMulticall() public {
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeWithSelector(
            IUniswapV2Router01.swapExactETHForTokens.selector,
            0,
            path,
            alice.addr,
            block.timestamp
        );

        address[] memory targets = new address[](1);
        targets[0] = ROUTER_V2;

        uint256[] memory values = new uint256[](1);
        values[0] = 1 ether;

        uint256 aliceBalanceBefore = alice.addr.balance;
        uint256 aliceUSDCBalanceBefore = IERC20(USDC).balanceOf(alice.addr);

        vm.prank(alice.addr);
        router.delegatecallMulticall{value: 1 ether}(
            targets,
            datas,
            values,
            alice.addr
        );

        vm.prank(bob.addr);
        router.delegatecallMulticall{value: 1 ether}(
            targets,
            datas,
            values,
            address(0)
        );
        uint256 aliceBalanceAfter = alice.addr.balance;
        uint256 aliceUSDCBalanceAfter = IERC20(USDC).balanceOf(alice.addr);

        assertEq(aliceBalanceBefore - aliceBalanceAfter, 1 ether);
        assertGt(aliceUSDCBalanceAfter, aliceUSDCBalanceBefore);
    }

    function testMulticallTwoSwaps() public {
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        bytes[] memory datas = new bytes[](2);
        datas[0] = abi.encodeWithSelector(
            IUniswapV2Router01.swapExactETHForTokens.selector,
            0,
            path,
            alice.addr,
            block.timestamp
        );
        datas[1] = abi.encodeWithSelector(
            IUniswapV2Router01.swapExactETHForTokens.selector,
            0,
            path,
            alice.addr,
            block.timestamp
        );

        address[] memory targets = new address[](2);
        targets[0] = ROUTER_V2;
        targets[1] = ROUTER_V2;

        uint256[] memory values = new uint256[](2);
        values[0] = 1 ether;
        values[1] = 1 ether;

        uint256 aliceBalanceBefore = alice.addr.balance;
        uint256 aliceUSDCBalanceBefore = IERC20(USDC).balanceOf(alice.addr);

        vm.prank(alice.addr);
        router.delegatecallMulticall{value: 2 ether}(
            targets,
            datas,
            values,
            alice.addr
        );

        uint256 aliceBalanceAfter = alice.addr.balance;
        uint256 aliceUSDCBalanceAfter = IERC20(USDC).balanceOf(alice.addr);

        assertEq(aliceBalanceBefore - aliceBalanceAfter, 2 ether);
        assertGt(aliceUSDCBalanceAfter, aliceUSDCBalanceBefore);
    }

    function testSwapAndCallWithCleanup() public {
        // Deploy NFT that costs 20 USDC to mint
        TestERC721_ERC20PaymentToken nft = new TestERC721_ERC20PaymentToken(
            USDC
        );

        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        bytes[] memory datas = new bytes[](4);
        datas[0] = abi.encodeWithSelector(
            IUniswapV2Router01.swapExactETHForTokens.selector,
            0,
            path,
            address(router),
            block.timestamp
        );
        datas[1] = abi.encodeWithSelector(
            IERC20.approve.selector,
            address(nft),
            type(uint256).max
        );
        datas[2] = abi.encodeWithSelector(nft.mint.selector, alice.addr, 10);
        datas[3] = abi.encodeWithSelector(
            router.cleanupERC20.selector,
            USDC,
            alice.addr
        );

        address[] memory targets = new address[](4);
        targets[0] = ROUTER_V2;
        targets[1] = USDC;
        targets[2] = address(nft);
        targets[3] = address(router);

        uint256[] memory values = new uint256[](4);
        values[0] = 1 ether;
        values[1] = 0;
        values[2] = 0;
        values[3] = 0;

        uint256 aliceBalanceBefore = alice.addr.balance;
        uint256 routerUSDCBalanceBefore = IERC20(USDC).balanceOf(
            address(router)
        );
        uint256 aliceUSDCBalanceBefore = IERC20(USDC).balanceOf(alice.addr);

        vm.prank(alice.addr);
        router.delegatecallMulticall{value: 1 ether}(
            targets,
            datas,
            values,
            alice.addr
        );

        uint256 aliceBalanceAfterMulticall = alice.addr.balance;
        uint256 aliceUSDCBalanceAfterMulticall = IERC20(USDC).balanceOf(
            alice.addr
        );
        uint256 routerUSDCBalanceAfterCleanup = IERC20(USDC).balanceOf(
            address(this)
        );

        assertEq(aliceBalanceBefore - aliceBalanceAfterMulticall, 1 ether);
        assertGt(aliceUSDCBalanceAfterMulticall, aliceUSDCBalanceBefore);
        assertEq(nft.ownerOf(10), alice.addr);
        assertEq(routerUSDCBalanceAfterCleanup, 0);
    }

    function testSwapETHForERC20() public {
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeWithSelector(
            IUniswapV2Router01.swapExactETHForTokens.selector,
            0,
            path,
            alice.addr,
            block.timestamp
        );

        address[] memory targets = new address[](1);
        targets[0] = ROUTER_V2;

        uint256[] memory values = new uint256[](1);
        values[0] = 1 ether;

        uint256 aliceBalanceBefore = alice.addr.balance;
        uint256 aliceUSDCBalanceBefore = IERC20(USDC).balanceOf(alice.addr);

        vm.prank(alice.addr);
        router.permitMulticall{value: 1 ether}(
            alice.addr,
            emptyPermit,
            targets,
            datas,
            values,
            alice.addr,
            bytes("")
        );

        uint256 aliceBalanceAfter = alice.addr.balance;
        uint256 aliceUSDCBalanceAfter = IERC20(USDC).balanceOf(alice.addr);

        assertEq(aliceBalanceBefore - aliceBalanceAfter, 1 ether);
        assertGt(aliceUSDCBalanceAfter, aliceUSDCBalanceBefore);
    }

    function testMalicious_ApproveThenMulticall() public {
        // Approve the router to spend erc20_1
        vm.prank(alice.addr);
        erc20_1.approve(address(router), 1 ether);

        address[] memory targets = new address[](1);
        targets[0] = address(erc20_1);
        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeWithSelector(
            IERC20.transferFrom.selector,
            alice.addr,
            bob.addr,
            1 ether
        );
        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        vm.prank(bob.addr);
        router.delegatecallMulticall(targets, datas, values, bob.addr);

        assertEq(erc20_1.balanceOf(bob.addr), 1 ether);
    }

    function testApprovalProxyMulticall__transferFrom() public {
        // Approve the approval helper to spend erc20_1
        vm.prank(alice.addr);
        erc20_1.approve(address(approvalProxy), 1 ether);

        address[] memory tokens = new address[](1);
        tokens[0] = address(erc20_1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        address[] memory targets = new address[](1);
        targets[0] = address(erc20_1);
        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeWithSelector(
            IERC20.transferFrom.selector,
            alice.addr,
            bob.addr,
            1 ether
        );
        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        vm.prank(alice.addr);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20InsufficientAllowance.selector,
                address(router),
                0,
                1 ether
            )
        );
        approvalProxy.transferAndMulticall(
            tokens,
            amounts,
            targets,
            datas,
            values,
            alice.addr
        );

        assertEq(erc20_1.balanceOf(address(router)), 0);

        datas[0] = abi.encodeWithSelector(
            IERC20.transfer.selector,
            bob.addr,
            1 ether
        );

        vm.prank(alice.addr);
        approvalProxy.transferAndMulticall(
            tokens,
            amounts,
            targets,
            datas,
            values,
            alice.addr
        );

        assertEq(erc20_1.balanceOf(bob.addr), 1 ether);
    }

    function testApprovalProxyMulticall__swapExactTokensForTokens() public {
        // Deal alice some USDC
        deal(USDC, alice.addr, 1000 * 10 ** 6);

        // Approve the approval helper to spend USDC
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

        address[] memory targets = new address[](2);
        targets[0] = USDC;
        targets[1] = ROUTER_V2;

        bytes[] memory datas = new bytes[](2);
        // ERC20Router approves UniV2Router to spend USDC
        datas[0] = abi.encodeWithSelector(
            IERC20.approve.selector,
            ROUTER_V2,
            1000 * 10 ** 6
        );
        // ERC20Router swaps USDC for DAI and alice receives output
        datas[1] = abi.encodeWithSelector(
            IUniswapV2Router01.swapExactTokensForTokens.selector,
            1000 * 10 ** 6,
            990 * 10 ** 18,
            path,
            alice.addr,
            block.timestamp
        );

        uint256[] memory values = new uint256[](2);
        values[0] = 0;
        values[1] = 0;

        vm.prank(alice.addr);
        approvalProxy.transferAndMulticall(
            tokens,
            amounts,
            targets,
            datas,
            values,
            alice.addr
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

        address[] memory targets = new address[](1);
        targets[0] = address(noOpERC20);

        bytes[] memory datas = new bytes[](1);
        // ERC20Router approves UniV2Router to spend USDC
        datas[0] = abi.encodeWithSelector(
            IERC20.transfer.selector,
            bob.addr,
            1 ether
        );

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20InsufficientBalance.selector,
                address(router),
                0,
                1 ether
            )
        );
        approvalProxy.transferAndMulticall(
            tokens,
            amounts,
            targets,
            datas,
            values,
            alice.addr
        );
    }

    function testRevertZoraProtocolRewards() public {
        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeWithSignature(
            "withdraw(address,uint256)",
            alice.addr,
            0
        );

        address[] memory targets = new address[](1);
        targets[0] = 0x7777777F279eba3d3Ad8F4E708545291A6fDBA8B;

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidTarget.selector,
                0x7777777F279eba3d3Ad8F4E708545291A6fDBA8B
            )
        );
        vm.prank(alice.addr);
        router.delegatecallMulticall{value: 1 ether}(
            targets,
            datas,
            values,
            alice.addr
        );
    }

    function testApprovalProxySetRouter() public {
        vm.expectRevert(Unauthorized.selector);
        vm.prank(alice.addr);
        approvalProxy.setRouter(alice.addr);

        vm.expectEmit();
        emit RouterUpdated(bob.addr);
        approvalProxy.setRouter(bob.addr);
    }

    function testApprovalProxy__RevertApprovalExploit() public {
        // Alice approves the approval helper to spend erc20_1
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
        address[] memory targets = new address[](1);
        targets[0] = address(erc20_1);
        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeWithSelector(
            IERC20.transferFrom.selector,
            alice.addr,
            bob.addr,
            1 ether
        );
        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        vm.prank(bob.addr);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20InsufficientAllowance.selector,
                address(router),
                0,
                1 ether
            )
        );
        approvalProxy.transferAndMulticall(
            tokens,
            amounts,
            targets,
            datas,
            values,
            alice.addr
        );
    }

    function testUSDTCleanupWithSafeERC20() public {
        // Deal router some USDT
        deal(USDT, address(router), 1000 * 10 ** 6);

        address[] memory targets = new address[](1);
        targets[0] = address(router);

        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeWithSelector(
            router.cleanupERC20.selector,
            USDT,
            relaySolver
        );

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        uint256 relaySolverBalanceBefore = IERC20(USDT).balanceOf(relaySolver);

        vm.prank(relaySolver);
        router.delegatecallMulticall(targets, datas, values, relaySolver);

        assertEq(
            IERC20(USDT).balanceOf(relaySolver) - relaySolverBalanceBefore,
            1000 * 10 ** 6
        );
    }

    function testUSDTTransferAndMulticall() public {
        // Deal solver some USDT
        deal(USDT, relaySolver, 1000 * 10 ** 6);

        address[] memory tokens = new address[](1);
        tokens[0] = USDT;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1000 * 10 ** 6;

        address[] memory targets = new address[](1);
        targets[0] = address(router);

        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeWithSelector(
            router.cleanupERC20.selector,
            USDT,
            relaySolver
        );

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        vm.startPrank(relaySolver);
        IERC20(USDT).safeIncreaseAllowance(
            address(approvalProxy),
            1000 * 10 ** 6
        );

        approvalProxy.transferAndMulticall(
            tokens,
            amounts,
            targets,
            datas,
            values,
            relaySolver
        );

        assertEq(IERC20(USDT).balanceOf(relaySolver), 1000 * 10 ** 6);
    }

    function testERC721__SafeMintCorrectRecipient() public {
        Multicaller multicaller = new Multicaller();
        TestERC721 erc721 = new TestERC721();

        address[] memory targets = new address[](1);
        targets[0] = address(erc721);
        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeWithSignature(
            "safeMint(address,uint256)",
            address(router),
            1
        );

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        bytes[] memory multicallDatas = new bytes[](2);
        multicallDatas[0] = abi.encodeWithSelector(
            ERC20Router.delegatecallMulticall.selector,
            targets,
            datas,
            values,
            alice.addr
        );

        datas[0] = abi.encodeWithSignature("safeMint(address,uint256)", address(router), 2);

        multicallDatas[1] = abi.encodeWithSelector(
            ERC20Router.delegatecallMulticall.selector,
            targets,
            datas,
            values,
            address(0)
        );

        address[] memory multicallTargets = new address[](2);
        multicallTargets[0] = address(router);
        multicallTargets[1] = address(router);

        uint256[] memory multicallValues = new uint256[](2);
        multicallValues[0] = 0;
        multicallValues[1] = 0;

        vm.prank(alice.addr);
        multicaller.aggregate(multicallTargets, multicallDatas, multicallValues, address(0));
        assertEq(erc721.ownerOf(1), alice.addr);
        assertEq(erc721.ownerOf(2), alice.addr);

        datas[0] = abi.encodeWithSignature("safeMint(address,uint256)", address(router), 3);
        vm.prank(alice.addr);
        router.delegatecallMulticall(targets, datas, values, address(0));
    }

    function testERC721__MintMsgSender() public {
        TestERC721 erc721 = new TestERC721();

        address[] memory targets = new address[](2);
        targets[0] = address(erc721);
        targets[1] = address(erc721);

        bytes[] memory datas = new bytes[](2);
        datas[0] = abi.encodeWithSignature("mint(uint256)", 1);
        datas[1] = abi.encodeWithSignature(
            "safeTransferFrom(address,address,uint256)",
            address(router),
            alice.addr,
            1
        );

        uint256[] memory values = new uint256[](2);
        values[0] = 0;

        vm.prank(alice.addr);
        router.delegatecallMulticall(targets, datas, values, alice.addr);

        assertEq(erc721.ownerOf(1), alice.addr);
    }

    function testERC721__SafeMintMsgSender() public {
        TestERC721 erc721 = new TestERC721();

        address[] memory targets = new address[](1);
        targets[0] = address(erc721);

        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeWithSignature("safeMint(uint256)", 1);

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        router.delegatecallMulticall(targets, datas, values, alice.addr);

        assertEq(erc721.ownerOf(1), alice.addr);
    }

    function testDelegateMulticallReentrancy() public {
        // Deal router some USDT
        deal(USDT, address(router), 1000 * 10 ** 6);

        CleanupReenterer cleanupReenterer = new CleanupReenterer(
            address(router),
            USDT,
            bob.addr
        );

        address[] memory targets = new address[](1);
        targets[0] = address(cleanupReenterer);

        bytes[] memory datas = new bytes[](1);
        datas[0] = "";

        uint256[] memory values = new uint256[](1);
        values[0] = 1 ether;

        uint256 relaySolverBalanceBefore = IERC20(USDT).balanceOf(relaySolver);

        vm.prank(relaySolver);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidMsgSender.selector,
                address(relaySolver),
                address(cleanupReenterer)
            )
        );
        router.delegatecallMulticall{value: 1 ether}(
            targets,
            datas,
            values,
            relaySolver
        );

        assertEq(IERC20(USDT).balanceOf(relaySolver), relaySolverBalanceBefore);
    }

    function testDelegateMulticallReentrancy__Delegatecall() public {
        // Deal router some USDC
        deal(USDC, address(router), 1000 * 10 ** 6);

        CleanupReentererDelegatecall cleanupReenterer = new CleanupReentererDelegatecall(
                address(router),
                USDC,
                bob.addr
            );

        address[] memory targets = new address[](1);
        targets[0] = address(cleanupReenterer);

        bytes[] memory datas = new bytes[](1);
        datas[0] = "";

        uint256[] memory values = new uint256[](1);
        values[0] = 0;

        uint256 relaySolverBalanceBefore = IERC20(USDC).balanceOf(relaySolver);

        vm.prank(relaySolver);
        // This call will succeed but no tokens will be transferred
        // because address(this) in cleanupERC20 will be the reenterer
        router.delegatecallMulticall{value: 1 ether}(
            targets,
            datas,
            values,
            relaySolver
        );

        assertEq(IERC20(USDC).balanceOf(relaySolver), relaySolverBalanceBefore);
    }

    function testSwapAndCallWithCleanup2() public {
        // Deploy NFT that costs 20 USDC to mint
        TestERC721_ERC20PaymentToken nft = new TestERC721_ERC20PaymentToken(
            USDC
        );

        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;

        bytes[] memory datas = new bytes[](3);
        datas[0] = abi.encodeWithSelector(
            IUniswapV2Router01.swapExactETHForTokens.selector,
            0,
            path,
            address(router),
            block.timestamp
        );
        datas[1] = abi.encodeWithSelector(
            IERC20.approve.selector,
            address(nft),
            type(uint256).max
        );
        datas[2] = abi.encodeWithSelector(nft.mint.selector, alice.addr, 10);

        address[] memory targets = new address[](3);
        targets[0] = ROUTER_V2;
        targets[1] = USDC;
        targets[2] = address(nft);

        uint256[] memory values = new uint256[](3);
        values[0] = 1 ether;
        values[1] = 0;
        values[2] = 0;

        uint256 aliceBalanceBefore = alice.addr.balance;
        uint256 routerUSDCBalanceBefore = IERC20(USDC).balanceOf(
            address(router)
        );

        vm.prank(alice.addr);
        router.delegatecallMulticall{value: 1 ether}(
            targets,
            datas,
            values,
            alice.addr
        );

        uint256 aliceBalanceAfterMulticall = alice.addr.balance;
        uint256 routerUSDCBalanceAfterMulticall = IERC20(USDC).balanceOf(
            address(router)
        );

        assertEq(aliceBalanceBefore - aliceBalanceAfterMulticall, 1 ether);
        assertGt(routerUSDCBalanceAfterMulticall, routerUSDCBalanceBefore);
        assertEq(nft.ownerOf(10), alice.addr);

        vm.prank(alice.addr);
        router.cleanupERC20(USDC, alice.addr);

        uint256 aliceUSDCBalanceAfterCleanup = IERC20(USDC).balanceOf(
            alice.addr
        );
        uint256 routerUSDCBalanceAfterCleanup = IERC20(USDC).balanceOf(
            address(this)
        );
        assertEq(aliceUSDCBalanceAfterCleanup, routerUSDCBalanceAfterMulticall);
        assertEq(routerUSDCBalanceAfterCleanup, 0);
    }

    function testReentrancyGuardMsgSender() public {
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

        // Get the witness
        bytes32 witness = keccak256(
            abi.encode(_EIP_712_RELAYER_WITNESS_TYPE_HASH, relayer.addr)
        );

        // Get the permit signature
        bytes memory permitSig = getPermitBatchWitnessSignature(
            permit,
            alice.key,
            _FULL_RELAYER_WITNESS_BATCH_TYPEHASH,
            witness,
            DOMAIN_SEPARATOR
        );

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

        address[] memory targets = new address[](4);
        targets[0] = address(erc20_1);
        targets[1] = address(erc20_2);
        targets[2] = address(erc20_3);
        targets[3] = address(erc20_1);

        bytes[] memory datas = new bytes[](4);
        datas[0] = calldata1;
        datas[1] = calldata2;
        datas[2] = calldata3;
        datas[3] = calldata4;

        uint256[] memory values = new uint256[](4);
        values[0] = 0;
        values[1] = 0;
        values[2] = 0;
        values[3] = 0;

        // Call the router as the relayer
        vm.prank(relayer.addr);
        router.permitMulticall(
            alice.addr,
            permit,
            targets,
            datas,
            values,
            alice.addr,
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
        // Approve the approval helper to spend erc20_1
        erc20_1.mint(alice.addr, 0.1 ether);
        vm.prank(alice.addr);
        erc20_1.approve(address(approvalProxy), 1 ether);

        address[] memory tokens = new address[](1);
        tokens[0] = address(erc20_1);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        address[] memory targets2 = new address[](1);
        targets2[0] = address(erc20_1);
        bytes[] memory datas2 = new bytes[](1);
        datas2[0] = abi.encodeWithSelector(
            IERC20.transferFrom.selector,
            alice.addr,
            bob.addr,
            1 ether
        );
        uint256[] memory values2 = new uint256[](1);
        values2[0] = 0;

        vm.prank(alice.addr);
        vm.expectRevert(
            abi.encodeWithSelector(
                ERC20InsufficientAllowance.selector,
                address(router),
                0,
                1 ether
            )
        );
        approvalProxy.transferAndMulticall(
            tokens,
            amounts,
            targets2,
            datas2,
            values2,
            alice.addr
        );

        assertEq(erc20_1.balanceOf(address(router)), 0);

        datas2[0] = abi.encodeWithSelector(
            IERC20.transfer.selector,
            bob.addr,
            1 ether
        );

        vm.prank(alice.addr);
        approvalProxy.transferAndMulticall(
            tokens,
            amounts,
            targets,
            datas,
            values,
            alice.addr
        );

        assertEq(erc20_1.balanceOf(bob.addr), 1 ether);
    }


    function getPermitWitnessTransferSignature(
        ISignatureTransfer.PermitTransferFrom memory permit,
        uint256 privateKey,
        bytes32 typehash,
        bytes32 witness,
        bytes32 domainSeparator
    ) internal view returns (bytes memory sig) {
        bytes32 tokenPermissions = keccak256(
            abi.encode(_TOKEN_PERMISSIONS_TYPEHASH, permit.permitted)
        );

        bytes32 msgHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                keccak256(
                    abi.encode(
                        typehash,
                        tokenPermissions,
                        address(router),
                        permit.nonce,
                        permit.deadline,
                        witness
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        return bytes.concat(r, s, bytes1(v));
    }

    function getPermitBatchWitnessSignature(
        ISignatureTransfer.PermitBatchTransferFrom memory permit,
        uint256 privateKey,
        bytes32 typeHash,
        bytes32 witness,
        bytes32 domainSeparator
    ) internal view returns (bytes memory sig) {
        bytes32[] memory tokenPermissions = new bytes32[](
            permit.permitted.length
        );
        for (uint256 i = 0; i < permit.permitted.length; ++i) {
            tokenPermissions[i] = keccak256(
                abi.encode(_TOKEN_PERMISSIONS_TYPEHASH, permit.permitted[i])
            );
        }

        bytes32 msgHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                keccak256(
                    abi.encode(
                        typeHash,
                        keccak256(abi.encodePacked(tokenPermissions)),
                        address(router),
                        permit.nonce,
                        permit.deadline,
                        witness
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, msgHash);
        return bytes.concat(r, s, bytes1(v));
    }
}
