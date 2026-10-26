// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @title FloppyMarket
/// @notice Non-custodial, single-collection NFT marketplace for Floppy Agents on BNB Chain.
///         - Listings stay in the seller's wallet (seller approves this contract).
///         - Offers and collection bids escrow native BNB in this contract.
///         - Every sale pays: marketplace fee -> feeRecipient, ERC-2981 royalty (capped at 10%) -> royalty receiver,
///           remainder -> seller. A failed push payment is credited to pendingWithdrawals (pull payment).
///         - The owner can only change the fee (hard-capped at 5%), the fee recipient, and pause trading.
///           The owner has no function to move escrowed BNB, pending withdrawals, or NFTs.
contract FloppyMarket is Ownable2Step, Pausable, ReentrancyGuard {
    // ---------------------------------------------------------------- constants
    uint256 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Immutable upper bound on the marketplace fee (5%).
    uint256 public constant MAX_FEE_BPS = 500;
    /// @notice Royalty is read from ERC-2981 and capped at 10% of the sale price.
    uint256 public constant MAX_ROYALTY_BPS = 1_000;
    /// @notice Gas forwarded on push payments to seller / royalty receiver / fee recipient.
    ///         Enough for EOAs and common smart wallets; anything that needs more (or reverts) falls back to pull.
    uint256 public constant PUSH_GAS_LIMIT = 50_000;

    /// @notice The only collection this market trades.
    IERC721 public immutable collection;

    // ---------------------------------------------------------------- types
    struct Listing {
        address seller;
        uint64 expiry; // unix seconds, listing valid while block.timestamp <= expiry
        uint256 price; // wei
    }

    struct Bid {
        uint256 amount; // escrowed wei
        uint64 expiry; // acceptable while block.timestamp <= expiry
    }

    enum SaleKind {
        Listing,
        Offer,
        CollectionBid
    }

    // ---------------------------------------------------------------- storage
    uint256 public feeBps;
    address public feeRecipient;

    mapping(uint256 tokenId => Listing) private _listings;
    mapping(uint256 tokenId => mapping(address bidder => Bid)) private _offers;
    mapping(address bidder => Bid) private _collectionBids;
    mapping(address account => uint256) public pendingWithdrawals;

    /// @notice Total BNB currently escrowed for offers + collection bids + pending withdrawals (accounting aid).
    uint256 public totalEscrowed;

    // ---------------------------------------------------------------- events
    event Listed(uint256 indexed tokenId, address indexed seller, uint256 price, uint64 expiry);
    event ListingCancelled(uint256 indexed tokenId, address indexed seller, address indexed cancelledBy);
    event Sale(
        SaleKind indexed kind,
        uint256 indexed tokenId,
        address indexed seller,
        address buyer,
        uint256 price,
        uint256 fee,
        address royaltyReceiver,
        uint256 royalty,
        uint256 sellerProceeds
    );
    event OfferMade(uint256 indexed tokenId, address indexed bidder, uint256 amount, uint64 expiry);
    event OfferWithdrawn(uint256 indexed tokenId, address indexed bidder, uint256 amount);
    event OfferAccepted(uint256 indexed tokenId, address indexed bidder, address indexed seller, uint256 amount);
    event CollectionBidMade(address indexed bidder, uint256 amount, uint64 expiry);
    event CollectionBidWithdrawn(address indexed bidder, uint256 amount);
    event CollectionBidAccepted(address indexed bidder, uint256 indexed tokenId, address indexed seller, uint256 amount);
    event PaymentDeferred(address indexed to, uint256 amount);
    event Withdrawal(address indexed account, uint256 amount);
    event FeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    // ---------------------------------------------------------------- errors
    error ZeroAddress();
    error FeeTooHigh();
    error InvalidPrice();
    error InvalidExpiry();
    error NotTokenOwner();
    error MarketNotApproved();
    error NotListed();
    error ListingExpired();
    error StaleListing();
    error WrongPayment();
    error CannotBuyOwnToken();
    error NotAuthorized();
    error NoOffer();
    error OfferExpired();
    error BelowMinAmount();
    error CannotBidOnOwnToken();
    error NothingToWithdraw();

    // ---------------------------------------------------------------- constructor
    constructor(address collection_, address initialOwner, address feeRecipient_, uint256 feeBps_)
        Ownable(initialOwner)
    {
        if (collection_ == address(0) || feeRecipient_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        collection = IERC721(collection_);
        feeRecipient = feeRecipient_;
        feeBps = feeBps_;
        emit FeeRecipientUpdated(address(0), feeRecipient_);
        emit FeeUpdated(0, feeBps_);
    }

    // ================================================================= listings

    /// @notice List `tokenId` at `price` wei until `expiry`. NFT stays in the seller's wallet.
    ///         Requires setApprovalForAll(market, true) (or approve(market, tokenId)). Re-listing overwrites.
    function list(uint256 tokenId, uint256 price, uint64 expiry) external whenNotPaused {
        if (price == 0) revert InvalidPrice();
        if (expiry <= block.timestamp) revert InvalidExpiry();
        if (collection.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (!_isMarketApproved(msg.sender, tokenId)) revert MarketNotApproved();

        _listings[tokenId] = Listing({seller: msg.sender, expiry: expiry, price: price});
        emit Listed(tokenId, msg.sender, price, expiry);
    }

    /// @notice Cancel a listing. Callable by the listing's seller or the token's current owner
    ///         (so a new owner can clear a stale listing). Allowed while paused.
    function cancelListing(uint256 tokenId) external {
        Listing memory l = _listings[tokenId];
        if (l.seller == address(0)) revert NotListed();
        if (msg.sender != l.seller && msg.sender != _ownerOfOrZero(tokenId)) revert NotAuthorized();
        delete _listings[tokenId];
        emit ListingCancelled(tokenId, l.seller, msg.sender);
    }

    /// @notice Buy a listed token, paying exactly the listing price in BNB.
    function buy(uint256 tokenId) external payable nonReentrant whenNotPaused {
        Listing memory l = _listings[tokenId];
        if (l.seller == address(0)) revert NotListed();
        if (block.timestamp > l.expiry) revert ListingExpired();
        if (collection.ownerOf(tokenId) != l.seller) revert StaleListing();
        if (msg.sender == l.seller) revert CannotBuyOwnToken();
        if (msg.value != l.price) revert WrongPayment();

        // effects
        delete _listings[tokenId];

        // interactions
        collection.safeTransferFrom(l.seller, msg.sender, tokenId);
        _settle(SaleKind.Listing, tokenId, l.seller, msg.sender, l.price);
    }

    // ================================================================= token offers

    /// @notice Offer `msg.value` BNB for `tokenId` until `expiry`. Replaces (and refunds) any previous
    ///         offer by the caller on the same token.
    function makeOffer(uint256 tokenId, uint64 expiry) external payable nonReentrant whenNotPaused {
        if (msg.value == 0) revert InvalidPrice();
        if (expiry <= block.timestamp) revert InvalidExpiry();
        if (collection.ownerOf(tokenId) == msg.sender) revert CannotBidOnOwnToken(); // also reverts if token doesn't exist

        uint256 previous = _offers[tokenId][msg.sender].amount;
        _offers[tokenId][msg.sender] = Bid({amount: msg.value, expiry: expiry});
        totalEscrowed = totalEscrowed + msg.value - previous;
        emit OfferMade(tokenId, msg.sender, msg.value, expiry);

        if (previous != 0) {
            emit OfferWithdrawn(tokenId, msg.sender, previous);
            _pushOrDefer(msg.sender, previous);
        }
    }

    /// @notice Withdraw your escrowed offer on `tokenId`. Always allowed, including while paused.
    function withdrawOffer(uint256 tokenId) external nonReentrant {
        uint256 amount = _offers[tokenId][msg.sender].amount;
        if (amount == 0) revert NoOffer();
        delete _offers[tokenId][msg.sender];
        totalEscrowed -= amount;
        emit OfferWithdrawn(tokenId, msg.sender, amount);
        Address.sendValue(payable(msg.sender), amount);
    }

    /// @notice Current owner of `tokenId` accepts `bidder`'s offer.
    /// @param minAmount Front-running guard: reverts if the offer is now below this amount
    ///        (a bidder could otherwise replace a high offer with a low one right before acceptance).
    function acceptOffer(uint256 tokenId, address bidder, uint256 minAmount)
        external
        nonReentrant
        whenNotPaused
    {
        if (collection.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (bidder == msg.sender) revert CannotBidOnOwnToken();
        Bid memory o = _offers[tokenId][bidder];
        if (o.amount == 0) revert NoOffer();
        if (block.timestamp > o.expiry) revert OfferExpired();
        if (o.amount < minAmount) revert BelowMinAmount();
        if (!_isMarketApproved(msg.sender, tokenId)) revert MarketNotApproved();

        // effects
        delete _offers[tokenId][bidder];
        totalEscrowed -= o.amount;
        _clearListing(tokenId);
        emit OfferAccepted(tokenId, bidder, msg.sender, o.amount);

        // interactions
        collection.safeTransferFrom(msg.sender, bidder, tokenId);
        _settle(SaleKind.Offer, tokenId, msg.sender, bidder, o.amount);
    }

    // ================================================================= collection bids

    /// @notice Bid `msg.value` BNB for any Floppy Agent until `expiry`. One bid per bidder; a new bid
    ///         replaces (and refunds) the previous one.
    function makeCollectionBid(uint64 expiry) external payable nonReentrant whenNotPaused {
        if (msg.value == 0) revert InvalidPrice();
        if (expiry <= block.timestamp) revert InvalidExpiry();

        uint256 previous = _collectionBids[msg.sender].amount;
        _collectionBids[msg.sender] = Bid({amount: msg.value, expiry: expiry});
        totalEscrowed = totalEscrowed + msg.value - previous;
        emit CollectionBidMade(msg.sender, msg.value, expiry);

        if (previous != 0) {
            emit CollectionBidWithdrawn(msg.sender, previous);
            _pushOrDefer(msg.sender, previous);
        }
    }

    /// @notice Withdraw your escrowed collection bid. Always allowed, including while paused.
    function withdrawCollectionBid() external nonReentrant {
        uint256 amount = _collectionBids[msg.sender].amount;
        if (amount == 0) revert NoOffer();
        delete _collectionBids[msg.sender];
        totalEscrowed -= amount;
        emit CollectionBidWithdrawn(msg.sender, amount);
        Address.sendValue(payable(msg.sender), amount);
    }

    /// @notice Any holder sells `tokenId` into `bidder`'s collection bid.
    /// @param minAmount Front-running guard, see acceptOffer.
    function acceptCollectionBid(address bidder, uint256 tokenId, uint256 minAmount)
        external
        nonReentrant
        whenNotPaused
    {
        if (collection.ownerOf(tokenId) != msg.sender) revert NotTokenOwner();
        if (bidder == msg.sender) revert CannotBidOnOwnToken();
        Bid memory b = _collectionBids[bidder];
        if (b.amount == 0) revert NoOffer();
        if (block.timestamp > b.expiry) revert OfferExpired();
        if (b.amount < minAmount) revert BelowMinAmount();
        if (!_isMarketApproved(msg.sender, tokenId)) revert MarketNotApproved();

        // effects
        delete _collectionBids[bidder];
        totalEscrowed -= b.amount;
        _clearListing(tokenId);
        emit CollectionBidAccepted(bidder, tokenId, msg.sender, b.amount);

        // interactions
        collection.safeTransferFrom(msg.sender, bidder, tokenId);
        _settle(SaleKind.CollectionBid, tokenId, msg.sender, bidder, b.amount);
    }

    // ================================================================= pull payments

    /// @notice Withdraw BNB credited after a failed push payment. Always allowed, including while paused.
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        pendingWithdrawals[msg.sender] = 0;
        totalEscrowed -= amount;
        emit Withdrawal(msg.sender, amount);
        Address.sendValue(payable(msg.sender), amount);
    }

    // ================================================================= admin

    function setFee(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        emit FeeUpdated(feeBps, newFeeBps);
        feeBps = newFeeBps;
    }

    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        emit FeeRecipientUpdated(feeRecipient, newRecipient);
        feeRecipient = newRecipient;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ================================================================= views

    function getListing(uint256 tokenId) external view returns (Listing memory) {
        return _listings[tokenId];
    }

    /// @notice True if the listing exists, is unexpired, the seller still owns the token and the market is approved.
    function isListingValid(uint256 tokenId) external view returns (bool) {
        Listing memory l = _listings[tokenId];
        if (l.seller == address(0) || block.timestamp > l.expiry) return false;
        if (_ownerOfOrZero(tokenId) != l.seller) return false;
        return _isMarketApproved(l.seller, tokenId);
    }

    function getOffer(uint256 tokenId, address bidder) external view returns (Bid memory) {
        return _offers[tokenId][bidder];
    }

    function getCollectionBid(address bidder) external view returns (Bid memory) {
        return _collectionBids[bidder];
    }

    /// @notice Breakdown of a sale at `price` for `tokenId` under current settings.
    function quoteSale(uint256 tokenId, uint256 price)
        public
        view
        returns (uint256 fee, address royaltyReceiver, uint256 royalty, uint256 sellerProceeds)
    {
        fee = (price * feeBps) / BPS_DENOMINATOR;
        (royaltyReceiver, royalty) = _royalty(tokenId, price);
        sellerProceeds = price - fee - royalty;
    }

    // ================================================================= internal

    function _settle(SaleKind kind, uint256 tokenId, address seller, address buyer, uint256 price) private {
        (uint256 fee, address royaltyReceiver, uint256 royalty, uint256 proceeds) = quoteSale(tokenId, price);
        emit Sale(kind, tokenId, seller, buyer, price, fee, royaltyReceiver, royalty, proceeds);
        if (fee != 0) _pushOrDefer(feeRecipient, fee);
        if (royalty != 0) _pushOrDefer(royaltyReceiver, royalty);
        if (proceeds != 0) _pushOrDefer(seller, proceeds);
    }

    function _royalty(uint256 tokenId, uint256 price) private view returns (address receiver, uint256 amount) {
        try IERC2981(address(collection)).royaltyInfo(tokenId, price) returns (address r, uint256 a) {
            if (r == address(0) || a == 0) return (address(0), 0);
            uint256 cap = (price * MAX_ROYALTY_BPS) / BPS_DENOMINATOR;
            return (r, a > cap ? cap : a);
        } catch {
            return (address(0), 0);
        }
    }

    /// @dev Push BNB with a gas cap; on failure credit pendingWithdrawals so a reverting / gas-hungry
    ///      recipient can never block a sale. Assembly call copies no return data (no return-bomb).
    ///      Safe w.r.t. re-entrancy: every external entry point that reaches here is nonReentrant.
    function _pushOrDefer(address to, uint256 amount) private {
        bool ok;
        uint256 gasLimit = PUSH_GAS_LIMIT;
        // slither-disable-next-line reentrancy-eth,reentrancy-benign,arbitrary-send-eth
        assembly ("memory-safe") {
            ok := call(gasLimit, to, amount, 0, 0, 0, 0)
        }
        if (!ok) {
            pendingWithdrawals[to] += amount;
            totalEscrowed += amount;
            emit PaymentDeferred(to, amount);
        }
    }

    function _clearListing(uint256 tokenId) private {
        Listing memory l = _listings[tokenId];
        if (l.seller != address(0)) {
            delete _listings[tokenId];
            emit ListingCancelled(tokenId, l.seller, address(this));
        }
    }

    function _isMarketApproved(address owner_, uint256 tokenId) private view returns (bool) {
        return collection.isApprovedForAll(owner_, address(this)) || collection.getApproved(tokenId) == address(this);
    }

    function _ownerOfOrZero(uint256 tokenId) private view returns (address) {
        try collection.ownerOf(tokenId) returns (address o) {
            return o;
        } catch {
            return address(0);
        }
    }
}
