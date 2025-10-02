// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Call3Value, Result} from "../../common/Multicall3.sol";

interface IRelayRouterV3 {
    function multicall(
        Call3Value[] calldata calls,
        address refundTo,
        address nftRecipient,
        bytes calldata metadata
    ) external payable returns (Result[] memory returnData);
}
