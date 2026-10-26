// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FloppyMarket} from "../src/FloppyMarket.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";

/// Local fork of BNB Chain mainnet (read state only; nothing is broadcast).
/// Run: forge test --match-contract Fork --fork-url https://bsc-dataseed.bnbchain.org
contract FloppyMarketForkTest is Test {
    address constant FLOPPY = 0x8F1E4787f131990d793Af253d118aed7Fe1B29AF;

    function test_fork_real_collection_sale() public {
        if (block.chainid != 56) return; // skipped when not forking
        IERC721 nft = IERC721(FLOPPY);
        address feeRecipient = makeAddr("feeRecipient");
        FloppyMarket market = new FloppyMarket(FLOPPY, address(this), feeRecipient, 500);

        uint256 tokenId = 1;
        address seller = nft.ownerOf(tokenId);
        (address royaltyReceiver,) = IERC2981(FLOPPY).royaltyInfo(tokenId, 1 ether);
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 1 ether);

        vm.startPrank(seller);
        nft.setApprovalForAll(address(market), true);
        market.list(tokenId, 1 ether, uint64(block.timestamp + 1 days));
        vm.stopPrank();

        uint256 s0 = seller.balance;
        uint256 r0 = royaltyReceiver.balance;
        vm.prank(buyer);
        market.buy{value: 1 ether}(tokenId);

        assertEq(nft.ownerOf(tokenId), buyer);
        assertEq(feeRecipient.balance, 0.05 ether);
        if (royaltyReceiver == seller) {
            assertEq(seller.balance - s0, 0.95 ether);
        } else {
            assertEq(royaltyReceiver.balance - r0, 0.05 ether);
            assertEq(seller.balance - s0 + market.pendingWithdrawals(seller), 0.9 ether);
        }
    }
}
