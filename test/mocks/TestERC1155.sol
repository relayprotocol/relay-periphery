// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

// Used for minting test ERC1155s in our tests
contract TestERC1155 is ERC1155("uri") {
    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }

    function mintBatch(address to, uint256[] calldata ids, uint256[] calldata amounts) external {
        _mintBatch(to, ids, amounts, "");
    }
}
