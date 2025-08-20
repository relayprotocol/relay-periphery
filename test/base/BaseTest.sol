// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {ISignatureTransfer} from "permit2-relay/src/interfaces/ISignatureTransfer.sol";
import {Permit2} from "permit2-relay/src/Permit2.sol";

import {IUniswapV2Factory} from "../interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "../interfaces/IUniswapV2Router02.sol";

import {TestERC20} from "../mocks/TestERC20.sol";
import {TestERC20Permit} from "../mocks/TestERC20Permit.sol";

// Helpers structs

struct RelayerWitness {
    address relayer;
}

contract BaseTest is Test {
    // Accounts
    Account alice;
    Account bob;
    Account cal;

    // Tokens
    TestERC20 erc20_1;
    TestERC20 erc20_2;
    TestERC20 erc20_3;
    TestERC20Permit erc20_permit;

    // Constants
    address constant RELAY_SOLVER = 0xf70da97812CB96acDF810712Aa562db8dfA3dbEF;
    address constant UNISWAP_V2 = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address constant ROUTER_V2 = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    Permit2 constant PERMIT2 = Permit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    // For Permit2
    bytes32 public PERMIT2_DOMAIN_SEPARATOR;
    bytes32 public constant _PERMIT2_TOKEN_PERMISSIONS_TYPEHASH =
        keccak256("TokenPermissions(address token,uint256 amount)");
    string public constant _PERMIT2_WITNESS_TRANSFER_TYPEHASH_STUB =
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,";
    string public constant _PERMIT2_BATCH_WITNESS_TRANSFER_TYPEHASH_STUB =
        "PermitBatchWitnessTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline,";

    function setUp() public virtual {
        // Fund accounts
        alice = makeAccountAndDeal("alice", 10 ether);
        bob = makeAccountAndDeal("bob", 10 ether);
        cal = makeAccountAndDeal("cal", 10 ether);

        // Deploy tokens
        erc20_1 = new TestERC20();
        erc20_2 = new TestERC20();
        erc20_3 = new TestERC20();
        erc20_permit = new TestERC20Permit();

        // Mint tokens
        erc20_1.mint(address(this), 100 ether);
        erc20_2.mint(address(this), 100 ether);
        erc20_3.mint(address(this), 100 ether);
        erc20_permit.mint(address(this), 100 ether);

        // Get the permit2 domain-separator
        PERMIT2_DOMAIN_SEPARATOR = PERMIT2.DOMAIN_SEPARATOR();
    }

    // Utility methods

    function makeAccountAndDeal(
        string memory name,
        uint256 amount
    ) internal returns (Account memory) {
        (address addr, uint256 pk) = makeAddrAndKey(name);

        vm.deal(addr, amount);

        return Account({addr: addr, key: pk});
    }

    // Sign a permit2
    function getPermit2TransferSignature(
        ISignatureTransfer.PermitBatchTransferFrom memory permit,
        address spender,
        uint256 privateKey,
        bytes32 typeHash,
        bytes32 domainSeparator
    ) internal pure returns (bytes memory signature) {
        bytes32[] memory tokenPermissions = new bytes32[](
            permit.permitted.length
        );
        for (uint256 i = 0; i < permit.permitted.length; ++i) {
            tokenPermissions[i] = keccak256(
                bytes.concat(
                    _PERMIT2_TOKEN_PERMISSIONS_TYPEHASH,
                    abi.encode(permit.permitted[i])
                )
            );
        }

        bytes32 hashToSign = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                keccak256(
                    abi.encode(
                        typeHash,
                        keccak256(abi.encodePacked(tokenPermissions)),
                        spender,
                        permit.nonce,
                        permit.deadline
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, hashToSign);
        return bytes.concat(r, s, bytes1(v));
    }

    // Sign a witness permit2
    function getPermit2WitnessTransferSignature(
        ISignatureTransfer.PermitTransferFrom memory permit,
        address spender,
        uint256 privateKey,
        bytes32 typeHash,
        bytes32 witness,
        bytes32 domainSeparator
    ) internal pure returns (bytes memory signature) {
        bytes32 tokenPermissions = keccak256(
            abi.encode(_PERMIT2_TOKEN_PERMISSIONS_TYPEHASH, permit.permitted)
        );

        bytes32 hashToSign = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                keccak256(
                    abi.encode(
                        typeHash,
                        tokenPermissions,
                        spender,
                        permit.nonce,
                        permit.deadline,
                        witness
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, hashToSign);
        return bytes.concat(r, s, bytes1(v));
    }

    // Sign a batch witness permit2
    function getPermit2BatchWitnessSignature(
        ISignatureTransfer.PermitBatchTransferFrom memory permit,
        address spender,
        uint256 privateKey,
        bytes32 typeHash,
        bytes32 witness,
        bytes32 domainSeparator
    ) internal pure returns (bytes memory signature) {
        bytes32[] memory tokenPermissions = new bytes32[](
            permit.permitted.length
        );
        for (uint256 i = 0; i < permit.permitted.length; ++i) {
            tokenPermissions[i] = keccak256(
                abi.encode(_PERMIT2_TOKEN_PERMISSIONS_TYPEHASH, permit.permitted[i])
            );
        }

        bytes32 hashToSign = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                keccak256(
                    abi.encode(
                        typeHash,
                        keccak256(abi.encodePacked(tokenPermissions)),
                        spender,
                        permit.nonce,
                        permit.deadline,
                        witness
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, hashToSign);
        return bytes.concat(r, s, bytes1(v));
    }
}
