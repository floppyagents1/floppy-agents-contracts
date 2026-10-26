// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FloppyMarket} from "../src/FloppyMarket.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    MockFloppy,
    MockPlain721,
    RevertingReceiver,
    GasGuzzler,
    ReentrantBuyer,
    ReentrantBidder,
    ReentrantSeller,
    ReturnBomber
} from "./mocks/Mocks.sol";

contract FloppyMarketTest is Test {
    FloppyMarket market;
    MockFloppy nft;

    address owner = makeAddr("owner");
    address feeRecipient = makeAddr("feeRecipient");
    address royaltyReceiver = makeAddr("royaltyReceiver");
    address alice = makeAddr("alice"); // seller
    address bob = makeAddr("bob"); // buyer / bidder
    address carol = makeAddr("carol");

    uint256 constant PRICE = 1 ether;
    uint64 expiry;

    function setUp() public {
        nft = new MockFloppy(royaltyReceiver, 500); // 5% like Floppy Agents
        market = new FloppyMarket(address(nft), owner, feeRecipient, 500);
        expiry = uint64(block.timestamp + 7 days);
        for (uint256 i = 1; i <= 5; i++) nft.mint(alice, i);
        nft.mint(carol, 10);
        vm.prank(alice);
        nft.setApprovalForAll(address(market), true);
        vm.prank(carol);
        nft.setApprovalForAll(address(market), true);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        vm.deal(alice, 100 ether);
    }

    function _list(uint256 id, uint256 price) internal {
        vm.prank(alice);
        market.list(id, price, expiry);
    }

    // ------------------------------------------------------------ constructor / admin

    function test_constructor() public view {
        assertEq(address(market.collection()), address(nft));
        assertEq(market.owner(), owner);
        assertEq(market.feeRecipient(), feeRecipient);
        assertEq(market.feeBps(), 500);
    }

    function test_constructor_reverts() public {
        vm.expectRevert(FloppyMarket.ZeroAddress.selector);
        new FloppyMarket(address(0), owner, feeRecipient, 500);
        vm.expectRevert(FloppyMarket.ZeroAddress.selector);
        new FloppyMarket(address(nft), owner, address(0), 500);
        vm.expectRevert(FloppyMarket.FeeTooHigh.selector);
        new FloppyMarket(address(nft), owner, feeRecipient, 501);
    }

    function test_setFee_cap_and_onlyOwner() public {
        vm.prank(owner);
        market.setFee(250);
        assertEq(market.feeBps(), 250);
        vm.prank(owner);
        vm.expectRevert(FloppyMarket.FeeTooHigh.selector);
        market.setFee(501);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        market.setFee(100);
    }

    function test_setFeeRecipient() public {
        vm.prank(owner);
        market.setFeeRecipient(carol);
        assertEq(market.feeRecipient(), carol);
        vm.prank(owner);
        vm.expectRevert(FloppyMarket.ZeroAddress.selector);
        market.setFeeRecipient(address(0));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        market.setFeeRecipient(bob);
    }

    function test_ownable2step() public {
        vm.prank(owner);
        market.transferOwnership(carol);
        assertEq(market.owner(), owner);
        assertEq(market.pendingOwner(), carol);
        vm.prank(carol);
        market.acceptOwnership();
        assertEq(market.owner(), carol);
    }

    // ------------------------------------------------------------ listing

    function test_list_and_view() public {
        _list(1, PRICE);
        FloppyMarket.Listing memory l = market.getListing(1);
        assertEq(l.seller, alice);
        assertEq(l.price, PRICE);
        assertEq(l.expiry, expiry);
        assertTrue(market.isListingValid(1));
        assertEq(nft.ownerOf(1), alice, "non-custodial");
    }

    function test_list_reverts() public {
        vm.startPrank(alice);
        vm.expectRevert(FloppyMarket.InvalidPrice.selector);
        market.list(1, 0, expiry);
        vm.expectRevert(FloppyMarket.InvalidExpiry.selector);
        market.list(1, PRICE, uint64(block.timestamp));
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(FloppyMarket.NotTokenOwner.selector);
        market.list(1, PRICE, expiry);
        // not approved
        nft.mint(bob, 20);
        vm.prank(bob);
        vm.expectRevert(FloppyMarket.MarketNotApproved.selector);
        market.list(20, PRICE, expiry);
    }

    function test_list_with_single_token_approval() public {
        nft.mint(bob, 21);
        vm.startPrank(bob);
        nft.approve(address(market), 21);
        market.list(21, PRICE, expiry);
        vm.stopPrank();
        vm.prank(carol);
        market.buy{value: PRICE}(21);
        assertEq(nft.ownerOf(21), carol);
    }

    function test_cancelListing() public {
        _list(1, PRICE);
        vm.prank(bob);
        vm.expectRevert(FloppyMarket.NotAuthorized.selector);
        market.cancelListing(1);
        vm.prank(alice);
        market.cancelListing(1);
        assertEq(market.getListing(1).seller, address(0));
        vm.prank(alice);
        vm.expectRevert(FloppyMarket.NotListed.selector);
        market.cancelListing(1);
    }

    function test_newOwner_can_cancel_stale_listing() public {
        _list(1, PRICE);
        vm.prank(alice);
        nft.transferFrom(alice, carol, 1);
        vm.prank(carol);
        market.cancelListing(1);
        assertEq(market.getListing(1).seller, address(0));
    }

    // ------------------------------------------------------------ buy + fee math

    function test_buy_feeMath() public {
        _list(1, PRICE);
        uint256 a0 = alice.balance;
        vm.prank(bob);
        market.buy{value: PRICE}(1);
        assertEq(nft.ownerOf(1), bob);
        assertEq(feeRecipient.balance, 0.05 ether);
        assertEq(royaltyReceiver.balance, 0.05 ether);
        assertEq(alice.balance - a0, 0.9 ether);
        assertEq(address(market).balance, 0);
        assertEq(market.getListing(1).seller, address(0), "listing deleted");
    }

    function testFuzz_feeMath(uint96 price, uint16 feeBps, uint16 royBps) public {
        price = uint96(bound(price, 1, 1e27));
        feeBps = uint16(bound(feeBps, 0, 500));
        royBps = uint16(bound(royBps, 0, 10_000));
        vm.prank(owner);
        market.setFee(feeBps);
        nft.setRoyalty(royaltyReceiver, royBps);

        _list(1, price);
        vm.deal(bob, price);
        uint256 a0 = alice.balance;
        vm.prank(bob);
        market.buy{value: price}(1);

        uint256 fee = (uint256(price) * feeBps) / 10_000;
        uint256 roy = (uint256(price) * royBps) / 10_000;
        uint256 cap = (uint256(price) * 1000) / 10_000;
        if (roy > cap) roy = cap;
        assertEq(feeRecipient.balance, fee);
        assertEq(royaltyReceiver.balance, roy);
        assertEq(alice.balance - a0, uint256(price) - fee - roy);
        assertEq(address(market).balance, 0, "no dust left");
    }

    function test_royalty_capped_at_10pct() public {
        nft.setRoyalty(royaltyReceiver, 5000); // 50%
        (uint256 fee, address r, uint256 roy, uint256 proceeds) = market.quoteSale(1, PRICE);
        assertEq(fee, 0.05 ether);
        assertEq(r, royaltyReceiver);
        assertEq(roy, 0.1 ether);
        assertEq(proceeds, 0.85 ether);
    }

    function test_noERC2981_collection_royalty_zero() public {
        MockPlain721 plain = new MockPlain721();
        FloppyMarket m2 = new FloppyMarket(address(plain), owner, feeRecipient, 500);
        plain.mint(alice, 1);
        vm.startPrank(alice);
        plain.setApprovalForAll(address(m2), true);
        m2.list(1, PRICE, expiry);
        vm.stopPrank();
        uint256 a0 = alice.balance;
        vm.prank(bob);
        m2.buy{value: PRICE}(1);
        assertEq(alice.balance - a0, 0.95 ether);
        assertEq(feeRecipient.balance, 0.05 ether);
    }

    function test_zero_fee() public {
        vm.prank(owner);
        market.setFee(0);
        _list(1, PRICE);
        uint256 a0 = alice.balance;
        vm.prank(bob);
        market.buy{value: PRICE}(1);
        assertEq(feeRecipient.balance, 0);
        assertEq(alice.balance - a0, 0.95 ether);
    }

    function test_buy_reverts() public {
        vm.prank(bob);
        vm.expectRevert(FloppyMarket.NotListed.selector);
        market.buy{value: PRICE}(1);

        _list(1, PRICE);
        vm.prank(bob);
        vm.expectRevert(FloppyMarket.WrongPayment.selector);
        market.buy{value: PRICE - 1}(1);
        vm.prank(bob);
        vm.expectRevert(FloppyMarket.WrongPayment.selector);
        market.buy{value: PRICE + 1}(1);
        vm.prank(alice);
        vm.expectRevert(FloppyMarket.CannotBuyOwnToken.selector);
        market.buy{value: PRICE}(1);
    }

    function test_expiry() public {
        _list(1, PRICE);
        vm.warp(expiry); // still valid at expiry second
        assertTrue(market.isListingValid(1));
        vm.warp(expiry + 1);
        assertFalse(market.isListingValid(1));
        vm.prank(bob);
        vm.expectRevert(FloppyMarket.ListingExpired.selector);
        market.buy{value: PRICE}(1);
    }

    function test_stale_listing_after_transfer() public {
        _list(1, PRICE);
        vm.prank(alice);
        nft.transferFrom(alice, carol, 1);
        assertFalse(market.isListingValid(1));
        vm.prank(bob);
        vm.expectRevert(FloppyMarket.StaleListing.selector);
        market.buy{value: PRICE}(1);
    }

    function test_stale_listing_not_revived_when_token_returns_via_other_path() public {
        // alice lists, sells via offer; the old listing must not be buyable by anyone afterwards
        _list(1, PRICE);
        vm.prank(bob);
        market.makeOffer{value: 0.5 ether}(1, expiry);
        vm.prank(alice);
        market.acceptOffer(1, bob, 0.5 ether);
        assertEq(market.getListing(1).seller, address(0), "listing cleared on offer sale");
    }

    function test_approval_revoked_makes_buy_fail() public {
        _list(1, PRICE);
        vm.prank(alice);
        nft.setApprovalForAll(address(market), false);
        assertFalse(market.isListingValid(1));
        vm.prank(bob);
        vm.expectRevert(); // ERC721InsufficientApproval
        market.buy{value: PRICE}(1);
        assertEq(bob.balance, 100 ether, "buyer refunded by revert");
    }

    // ------------------------------------------------------------ offers

    function test_offer_lifecycle_accept() public {
        vm.prank(bob);
        market.makeOffer{value: 2 ether}(2, expiry);
        assertEq(market.getOffer(2, bob).amount, 2 ether);
        assertEq(address(market).balance, 2 ether);
        assertEq(market.totalEscrowed(), 2 ether);

        uint256 a0 = alice.balance;
        vm.prank(alice);
        market.acceptOffer(2, bob, 2 ether);
        assertEq(nft.ownerOf(2), bob);
        assertEq(alice.balance - a0, 1.8 ether);
        assertEq(feeRecipient.balance, 0.1 ether);
        assertEq(royaltyReceiver.balance, 0.1 ether);
        assertEq(address(market).balance, 0);
        assertEq(market.totalEscrowed(), 0);
        assertEq(market.getOffer(2, bob).amount, 0);
    }

    function test_offer_replace_refunds_previous() public {
        vm.startPrank(bob);
        market.makeOffer{value: 1 ether}(2, expiry);
        market.makeOffer{value: 3 ether}(2, expiry);
        vm.stopPrank();
        assertEq(market.getOffer(2, bob).amount, 3 ether);
        assertEq(bob.balance, 97 ether);
        assertEq(address(market).balance, 3 ether);
        assertEq(market.totalEscrowed(), 3 ether);
    }

    function test_offer_withdraw() public {
        vm.prank(bob);
        market.makeOffer{value: 1 ether}(2, expiry);
        vm.prank(bob);
        market.withdrawOffer(2);
        assertEq(bob.balance, 100 ether);
        vm.prank(bob);
        vm.expectRevert(FloppyMarket.NoOffer.selector);
        market.withdrawOffer(2);
    }

    function test_offer_reverts() public {
        vm.startPrank(bob);
        vm.expectRevert(FloppyMarket.InvalidPrice.selector);
        market.makeOffer{value: 0}(2, expiry);
        vm.expectRevert(FloppyMarket.InvalidExpiry.selector);
        market.makeOffer{value: 1}(2, uint64(block.timestamp));
        vm.expectRevert(); // nonexistent token
        market.makeOffer{value: 1}(999, expiry);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(FloppyMarket.CannotBidOnOwnToken.selector);
        market.makeOffer{value: 1}(2, expiry);
    }

    function test_acceptOffer_reverts() public {
        vm.prank(bob);
        market.makeOffer{value: 1 ether}(2, expiry);
        vm.prank(carol);
        vm.expectRevert(FloppyMarket.NotTokenOwner.selector);
        market.acceptOffer(2, bob, 0);
        vm.prank(alice);
        vm.expectRevert(FloppyMarket.NoOffer.selector);
        market.acceptOffer(2, carol, 0);
        vm.prank(alice);
        vm.expectRevert(FloppyMarket.BelowMinAmount.selector);
        market.acceptOffer(2, bob, 1 ether + 1);
        vm.warp(expiry + 1);
        vm.prank(alice);
        vm.expectRevert(FloppyMarket.OfferExpired.selector);
        market.acceptOffer(2, bob, 0);
        // expired offer can still be withdrawn
        vm.prank(bob);
        market.withdrawOffer(2);
        assertEq(bob.balance, 100 ether);
    }

    function test_offer_frontrun_lowering_blocked_by_minAmount() public {
        vm.prank(bob);
        market.makeOffer{value: 5 ether}(2, expiry);
        // bob front-runs alice's accept by replacing with a tiny offer
        vm.prank(bob);
        market.makeOffer{value: 1 wei}(2, expiry);
        vm.prank(alice);
        vm.expectRevert(FloppyMarket.BelowMinAmount.selector);
        market.acceptOffer(2, bob, 5 ether);
    }

    function test_acceptOffer_by_new_owner_after_transfer() public {
        vm.prank(bob);
        market.makeOffer{value: 1 ether}(2, expiry);
        vm.prank(alice);
        nft.transferFrom(alice, carol, 2);
        vm.prank(alice);
        vm.expectRevert(FloppyMarket.NotTokenOwner.selector);
        market.acceptOffer(2, bob, 0);
        vm.prank(carol);
        market.acceptOffer(2, bob, 1 ether);
        assertEq(nft.ownerOf(2), bob);
    }

    // ------------------------------------------------------------ collection bids

    function test_collectionBid_lifecycle() public {
        vm.prank(bob);
        market.makeCollectionBid{value: 1 ether}(expiry);
        assertEq(market.getCollectionBid(bob).amount, 1 ether);

        uint256 c0 = carol.balance;
        vm.prank(carol);
        market.acceptCollectionBid(bob, 10, 1 ether);
        assertEq(nft.ownerOf(10), bob);
        assertEq(carol.balance - c0, 0.9 ether);
        assertEq(market.getCollectionBid(bob).amount, 0);
        assertEq(address(market).balance, 0);

        // bid consumed: second holder cannot fill it
        vm.prank(alice);
        vm.expectRevert(FloppyMarket.NoOffer.selector);
        market.acceptCollectionBid(bob, 1, 0);
    }

    function test_collectionBid_replace_withdraw_expiry() public {
        vm.startPrank(bob);
        market.makeCollectionBid{value: 1 ether}(expiry);
        market.makeCollectionBid{value: 2 ether}(expiry);
        vm.stopPrank();
        assertEq(bob.balance, 98 ether);
        assertEq(market.totalEscrowed(), 2 ether);

        vm.warp(expiry + 1);
        vm.prank(alice);
        vm.expectRevert(FloppyMarket.OfferExpired.selector);
        market.acceptCollectionBid(bob, 1, 0);

        vm.prank(bob);
        market.withdrawCollectionBid();
        assertEq(bob.balance, 100 ether);
        vm.prank(bob);
        vm.expectRevert(FloppyMarket.NoOffer.selector);
        market.withdrawCollectionBid();
    }

    function test_acceptCollectionBid_reverts() public {
        vm.prank(bob);
        market.makeCollectionBid{value: 1 ether}(expiry);
        vm.prank(carol);
        vm.expectRevert(FloppyMarket.NotTokenOwner.selector);
        market.acceptCollectionBid(bob, 1, 0);
        vm.prank(alice);
        vm.expectRevert(FloppyMarket.BelowMinAmount.selector);
        market.acceptCollectionBid(bob, 1, 2 ether);
        // holder without approval
        nft.mint(makeAddr("dave"), 30);
        vm.prank(makeAddr("dave"));
        vm.expectRevert(FloppyMarket.MarketNotApproved.selector);
        market.acceptCollectionBid(bob, 30, 0);
    }

    function test_collectionBid_accept_clears_listing() public {
        _list(1, 5 ether);
        vm.prank(bob);
        market.makeCollectionBid{value: 1 ether}(expiry);
        vm.prank(alice);
        market.acceptCollectionBid(bob, 1, 1 ether);
        assertEq(market.getListing(1).seller, address(0));
    }

    // ------------------------------------------------------------ pause

    function test_pause_blocks_trading_but_not_withdrawals() public {
        _list(1, PRICE);
        vm.prank(bob);
        market.makeOffer{value: 1 ether}(2, expiry);
        vm.prank(bob);
        market.makeCollectionBid{value: 1 ether}(expiry);

        vm.prank(owner);
        market.pause();

        vm.startPrank(bob);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.buy{value: PRICE}(1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.makeOffer{value: 1 ether}(3, expiry);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.makeCollectionBid{value: 1 ether}(expiry);
        vm.stopPrank();
        vm.startPrank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.list(3, PRICE, expiry);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.acceptOffer(2, bob, 0);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        market.acceptCollectionBid(bob, 2, 0);
        market.cancelListing(1); // allowed
        vm.stopPrank();

        vm.startPrank(bob);
        market.withdrawOffer(2);
        market.withdrawCollectionBid();
        vm.stopPrank();
        assertEq(bob.balance, 100 ether);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        market.unpause();
        vm.prank(owner);
        market.unpause();
    }

    // ------------------------------------------------------------ failed transfers -> pull payments

    function test_seller_rejects_BNB_gets_pending() public {
        RevertingReceiver seller = new RevertingReceiver();
        nft.mint(address(seller), 40);
        seller.approveMarket(nft, address(market));
        seller.list(market, 40, PRICE, expiry);

        vm.prank(bob);
        market.buy{value: PRICE}(40);
        assertEq(nft.ownerOf(40), bob, "sale not blocked");
        assertEq(market.pendingWithdrawals(address(seller)), 0.9 ether);
        assertEq(address(market).balance, 0.9 ether);
        assertEq(market.totalEscrowed(), 0.9 ether);

        // still rejects -> withdraw reverts, funds stay credited
        vm.expectRevert();
        seller.withdraw(market);
        assertEq(market.pendingWithdrawals(address(seller)), 0.9 ether);

        seller.setAccept(true);
        seller.withdraw(market);
        assertEq(address(seller).balance, 0.9 ether);
        assertEq(market.pendingWithdrawals(address(seller)), 0);
        assertEq(address(market).balance, 0);

        vm.expectRevert(FloppyMarket.NothingToWithdraw.selector);
        seller.withdraw(market);
    }

    function test_royalty_receiver_reverts_gets_pending() public {
        RevertingReceiver rr = new RevertingReceiver();
        nft.setRoyalty(address(rr), 500);
        _list(1, PRICE);
        uint256 a0 = alice.balance;
        vm.prank(bob);
        market.buy{value: PRICE}(1);
        assertEq(alice.balance - a0, 0.9 ether);
        assertEq(market.pendingWithdrawals(address(rr)), 0.05 ether);
    }

    function test_gas_guzzling_feeRecipient_cannot_block_sale() public {
        GasGuzzler g = new GasGuzzler();
        vm.prank(owner);
        market.setFeeRecipient(address(g));
        _list(1, PRICE);
        vm.prank(bob);
        market.buy{value: PRICE}(1);
        assertEq(nft.ownerOf(1), bob);
        assertEq(market.pendingWithdrawals(address(g)), 0.05 ether);
    }

    function test_offer_accept_by_contract_seller_rejecting_BNB() public {
        RevertingReceiver seller = new RevertingReceiver();
        nft.mint(address(seller), 41);
        seller.approveMarket(nft, address(market));
        vm.prank(bob);
        market.makeOffer{value: 1 ether}(41, expiry);
        seller.acceptOffer(market, 41, bob);
        assertEq(nft.ownerOf(41), bob);
        assertEq(market.pendingWithdrawals(address(seller)), 0.9 ether);
    }

    function test_return_bomb_royalty_receiver_cannot_block_sale() public {
        ReturnBomber rb = new ReturnBomber();
        nft.setRoyalty(address(rb), 500);
        _list(1, PRICE);
        vm.prank(bob);
        market.buy{value: PRICE, gas: 400_000}(1);
        assertEq(nft.ownerOf(1), bob);
        assertEq(market.pendingWithdrawals(address(rb)), 0.05 ether);
    }

    // ------------------------------------------------------------ reentrancy

    function test_reentrancy_buyer_onERC721Received_blocked() public {
        _list(1, PRICE);
        _list(2, PRICE);
        ReentrantBuyer attacker = new ReentrantBuyer(market);
        vm.deal(address(attacker), 0);
        vm.deal(address(this), PRICE);
        attacker.attackBuy{value: PRICE}(1, 2);
        assertTrue(attacker.reentryBlocked());
        assertEq(
            keccak256(attacker.lastErr()),
            keccak256(abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector))
        );
        assertEq(nft.ownerOf(1), address(attacker));
        assertEq(nft.ownerOf(2), alice);
    }

    function test_reentrancy_double_withdraw_blocked() public {
        ReentrantBidder attacker = new ReentrantBidder(market);
        vm.deal(address(this), 1 ether);
        attacker.offer{value: 1 ether}(2, expiry);
        // other users' escrow in contract that attacker would try to drain
        vm.prank(bob);
        market.makeOffer{value: 5 ether}(2, expiry);

        attacker.withdraw();
        assertTrue(attacker.reentryBlocked());
        assertEq(address(attacker).balance, 1 ether, "withdrew exactly once");
        assertEq(address(market).balance, 5 ether, "bob's escrow intact");
        assertEq(market.getOffer(2, bob).amount, 5 ether);
    }

    function test_reentrancy_seller_receive_falls_back_to_pending() public {
        ReentrantSeller seller = new ReentrantSeller(market);
        nft.mint(address(seller), 50);
        seller.approveAndList(nft, 50, PRICE, expiry);
        vm.prank(bob);
        market.buy{value: PRICE}(50);
        assertEq(nft.ownerOf(50), bob);
        assertEq(market.pendingWithdrawals(address(seller)), 0.9 ether);
        seller.setOpen(true);
        seller.withdraw();
        assertEq(address(seller).balance, 0.9 ether);
        assertEq(address(market).balance, 0);
    }

    // ------------------------------------------------------------ no owner extraction / no stray BNB

    function test_rejects_plain_BNB_transfers() public {
        vm.prank(bob);
        (bool ok,) = address(market).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_escrow_accounting_invariant_simple() public {
        vm.prank(bob);
        market.makeOffer{value: 1 ether}(1, expiry);
        vm.prank(carol);
        market.makeCollectionBid{value: 2 ether}(expiry);
        assertEq(address(market).balance, market.totalEscrowed());
        vm.prank(alice);
        market.acceptCollectionBid(carol, 3, 0);
        assertEq(address(market).balance, market.totalEscrowed());
        vm.prank(alice);
        market.acceptOffer(1, bob, 0);
        assertEq(address(market).balance, market.totalEscrowed());
        assertEq(address(market).balance, 0);
    }

    receive() external payable {}
}
