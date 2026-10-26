// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title Floppy Agents
/// @notice 3,333 fully on-chain pixel floppy disks for .ai Agent ID holders on BNB Chain.
///         Free mint: call mint() with value 0, 1 per wallet. No approvals, no payments, no transfers of your assets.
///         Creator: 5% royalty (ERC-2981) and a one-time reserve of up to 33 tokens.
contract FloppyAgents is ERC721, ERC2981, Ownable {
    using Strings for uint256;

    uint256 public constant MAX_SUPPLY = 3333;
    uint256 public constant CREATOR_RESERVE = 33;
    IERC721 public constant AGENT_ID = IERC721(0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F);

    uint256 public totalSupply;
    uint256 public creatorMinted;
    mapping(address => bool) public hasMinted;
    mapping(uint256 => uint256) private _seed;

    error NotAgentIdHolder();
    error AlreadyMinted();
    error SoldOut();
    error NotFree();
    error ReserveExceeded();

    constructor(address initialOwner, address royaltyReceiver, address giftA, address giftB)
        ERC721("Floppy Agents", "FLOPPY")
        Ownable(initialOwner)
    {
        _setDefaultRoyalty(royaltyReceiver, 500); // 5%
        creatorMinted = 2;
        _mintTo(giftA);
        _mintTo(giftB);
    }

    /// @notice Free mint, 1 per wallet, only for holders of a .ai Agent ID.
    function mint() external payable returns (uint256 tokenId) {
        if (msg.value != 0) revert NotFree();
        if (AGENT_ID.balanceOf(msg.sender) == 0) revert NotAgentIdHolder();
        if (hasMinted[msg.sender]) revert AlreadyMinted();
        hasMinted[msg.sender] = true;
        tokenId = _mintTo(msg.sender);
    }

    function _mintTo(address to) internal returns (uint256 tokenId) {
        if (totalSupply >= MAX_SUPPLY) revert SoldOut();
        tokenId = ++totalSupply;
        _seed[tokenId] = uint256(keccak256(abi.encodePacked(block.prevrandao, blockhash(block.number - 1), to, tokenId)));
        _mint(to, tokenId);
    }

    /// @notice Creator reserve, max 33 tokens in total (including the 2 minted at deploy).
    function creatorMint(address to, uint256 qty) external onlyOwner {
        if (creatorMinted + qty > CREATOR_RESERVE) revert ReserveExceeded();
        creatorMinted += qty;
        for (uint256 i; i < qty; ++i) _mintTo(to);
    }

    /// @notice Owner can change the royalty receiver; rate is capped at 5%.
    function setRoyalty(address receiver, uint96 bps) external onlyOwner {
        require(bps <= 500, "max 5%");
        _setDefaultRoyalty(receiver, bps);
    }

    function supportsInterface(bytes4 id) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(id);
    }

    // ---------------- traits ----------------
    // Rarity: Common 50%, Uncommon 25%, Rare 15%, Epic 8%, Legendary 2%
    function _tier(uint256 s) internal pure returns (uint256) {
        uint256 r = s % 1000;
        if (r < 20) return 4;
        if (r < 100) return 3;
        if (r < 250) return 2;
        if (r < 500) return 1;
        return 0;
    }

    function _traits(uint256 s) internal pure returns (uint256[6] memory t) {
        t[0] = _tier(s);                                  // rarity
        t[1] = t[0] * 3 + ((s >> 16) % 3);                // disk color, 3 per tier
        t[2] = (s >> 32) % (3 + t[0]);                    // label art, more unlocked per tier
        if (t[0] == 4) t[2] = 6 + ((s >> 32) % 2);        // legendary: Agent Eyes or BNB
        t[3] = t[0] >= 3 ? 2 + (t[0] - 3) : (s >> 48) % 2; // shutter: Silver/Black, Gold (epic), Holo (legendary)
        t[4] = (s >> 64) % 6;                             // background
        t[5] = t[0] >= 2 ? 2 : (s >> 80) % 2;             // capacity: 720KB / 1.44MB / 2.88MB (rare+)
    }

    function _tierName(uint256 i) internal pure returns (string memory) {
        return ["Common", "Uncommon", "Rare", "Epic", "Legendary"][i];
    }
    function _colorName(uint256 i) internal pure returns (string memory) {
        return ["Classic Black", "Office Gray", "Retro Beige",
                "Ocean Blue", "Forest Green", "Cherry Red",
                "Clear Teal", "Clear Purple", "Sunset Orange",
                "Neon Pink", "Neon Green", "Ice Chrome",
                "Gold", "Diamond", "Obsidian Gold"][i];
    }
    function _color(uint256 i) internal pure returns (string memory) {
        return ["#2b2b33", "#8d939c", "#d8c9a3",
                "#2f5fb3", "#2f7a46", "#c23a3a",
                "#2bb3a8", "#7d4fd1", "#ff8a3d",
                "#ff3ea5", "#39d96a", "#b9d3e6",
                "#f3ba2f", "#8fe6ff", "#1c160c"][i];
    }
    function _colorDark(uint256 i) internal pure returns (string memory) {
        return ["#17171c", "#5f646b", "#a8987a",
                "#1d3e7a", "#1d5230", "#862626",
                "#1a7a73", "#523391", "#c45f1f",
                "#b8276f", "#22a04a", "#7f9db3",
                "#b8861b", "#4fb8d6", "#0a0804"][i];
    }
    function _labelName(uint256 i) internal pure returns (string memory) {
        return ["Blank", "Notes", "Barcode", "Smiley", "Heart", "Skull", "Agent Eyes", "BNB"][i];
    }
    function _shutterName(uint256 i) internal pure returns (string memory) {
        return ["Silver", "Black", "Gold", "Holo"][i];
    }
    function _bgName(uint256 i) internal pure returns (string memory) {
        return ["Sky", "Mint", "Peach", "Lilac", "Night", "Paper"][i];
    }
    function _bg(uint256 i) internal pure returns (string memory) {
        return ["#bfe3ff", "#c9f2d9", "#ffd9c2", "#e1d4ff", "#141428", "#f4efe2"][i];
    }
    function _capName(uint256 i) internal pure returns (string memory) {
        return ["720KB", "1.44MB", "2.88MB"][i];
    }
    function _capColor(uint256 i) internal pure returns (string memory) {
        return ["#4d8bff", "#ff5b5b", "#f3ba2f"][i];
    }

    // ---------------- art (24x24 pixel grid) ----------------
    function _r(uint256 x, uint256 y, uint256 w, uint256 h, string memory c) internal pure returns (string memory) {
        string memory a = string.concat('<rect x="', x.toString(), '" y="', y.toString(), '" width="');
        return string.concat(a, w.toString(), '" height="', h.toString(), '" fill="', c, '"/>');
    }

    function _body(uint256 ci) internal pure returns (string memory) {
        string memory c = _color(ci);
        string memory d = _colorDark(ci);
        return string.concat(
            _r(4, 4, 17, 17, "#00000040"),          // shadow
            _r(3, 3, 17, 17, d),                    // outline
            _r(4, 3, 15, 16, c),                    // body
            _r(19, 4, 1, 15, c),
            _r(4, 18, 1, 1, "#000000"),              // write-protect hole
            _r(18, 18, 1, 1, d)
        );
    }

    function _shutter(uint256 s) internal pure returns (string memory) {
        string memory m = ["#c9ced6", "#3a3a40", "#f3ba2f", "#9fe8ff"][s];
        string memory h = ["#eef1f5", "#5a5a62", "#fff27a", "#ff9ff3"][s];
        return string.concat(
            _r(7, 3, 9, 6, m),
            _r(7, 3, 9, 1, h),
            _r(12, 4, 2, 4, "#1a1a1a"),
            s == 3 ? _r(8, 5, 2, 1, "#ffffff") : ""
        );
    }

    function _label(uint256 kind, uint256 cap) internal pure returns (string memory o) {
        // paper label x5..18, y11..19
        o = string.concat(_r(5, 11, 14, 8, "#fbf8ef"), _r(5, 11, 14, 1, _capColor(cap)));
        if (kind == 1) {        // Notes
            o = string.concat(o, _r(7, 13, 9, 1, "#2f5fb3"), _r(7, 15, 7, 1, "#2f5fb3"), _r(7, 17, 5, 1, "#2f5fb3"));
        } else if (kind == 2) { // Barcode
            o = string.concat(o, string.concat(_r(7, 13, 1, 4, "#111111"), _r(9, 13, 2, 4, "#111111"), _r(12, 13, 1, 4, "#111111"), _r(14, 13, 1, 4, "#111111")), string.concat(_r(16, 13, 1, 4, "#111111")));
        } else if (kind == 3) { // Smiley
            o = string.concat(o, string.concat(_r(9, 13, 1, 2, "#111111"), _r(14, 13, 1, 2, "#111111"), _r(9, 16, 1, 1, "#111111"), _r(10, 17, 4, 1, "#111111")), string.concat(_r(14, 16, 1, 1, "#111111")));
        } else if (kind == 4) { // Heart
            o = string.concat(o, string.concat(_r(9, 13, 2, 1, "#ff3e6c"), _r(13, 13, 2, 1, "#ff3e6c"), _r(8, 14, 8, 2, "#ff3e6c"), _r(9, 16, 6, 1, "#ff3e6c")), string.concat(_r(11, 17, 2, 1, "#ff3e6c")));
        } else if (kind == 5) { // Skull
            o = string.concat(o, string.concat(_r(9, 13, 6, 3, "#222222"), _r(10, 14, 1, 1, "#fbf8ef"), _r(13, 14, 1, 1, "#fbf8ef"), _r(10, 16, 4, 1, "#222222")), string.concat(_r(10, 17, 1, 1, "#222222"), _r(12, 17, 1, 1, "#222222")));
        } else if (kind == 6) { // Agent Eyes
            o = string.concat(o, string.concat(_r(6, 12, 12, 7, "#120022"), _r(8, 14, 3, 2, "#ff3ea5"), _r(13, 14, 3, 2, "#ff3ea5"), _r(9, 14, 1, 1, "#ffffff")), string.concat(_r(14, 14, 1, 1, "#ffffff"), _r(10, 17, 4, 1, "#ff3ea5")));
        } else if (kind == 7) { // BNB
            o = string.concat(o, string.concat(_r(6, 12, 12, 7, "#1a1a1a"), _r(11, 13, 2, 1, "#f3ba2f"), _r(10, 14, 4, 1, "#f3ba2f"), _r(9, 15, 2, 1, "#f3ba2f")), string.concat(_r(13, 15, 2, 1, "#f3ba2f"), _r(10, 16, 4, 1, "#f3ba2f"), _r(11, 17, 2, 1, "#f3ba2f"), _r(7, 15, 1, 1, "#f3ba2f")), string.concat(_r(16, 15, 1, 1, "#f3ba2f")));
        }
    }

    function _sparkle(uint256 tier) internal pure returns (string memory) {
        if (tier == 4) return string.concat(_r(1, 2, 1, 1, "#fff27a"), _r(22, 1, 1, 1, "#fff27a"), _r(1, 20, 1, 1, "#fff27a"), _r(22, 21, 1, 1, "#fff27a"), _r(21, 11, 1, 1, "#ffffff"));
        if (tier == 3) return string.concat(_r(1, 3, 1, 1, "#ffffff"), _r(22, 20, 1, 1, "#ffffff"));
        return "";
    }

    function _svg(uint256[6] memory t) internal pure returns (string memory) {
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" shape-rendering="crispEdges" width="480" height="480">',
            _r(0, 0, 24, 24, _bg(t[4])),
            _sparkle(t[0]),
            _body(t[1]),
            _r(19, 3, 1, 1, _bg(t[4])),
            _shutter(t[3]),
            _label(t[2], t[5]),
            "</svg>"
        );
    }

    function _attr(string memory k, string memory v) internal pure returns (string memory) {
        return string.concat('{"trait_type":"', k, '","value":"', v, '"}');
    }

    function _attrs(uint256[6] memory t) internal pure returns (string memory) {
        return string.concat(
            "[", _attr("Rarity", _tierName(t[0])), ",", _attr("Disk", _colorName(t[1])), ",", _attr("Label", _labelName(t[2])), ",",
            _attr("Shutter", _shutterName(t[3])), ",", _attr("Background", _bgName(t[4])), ",", _attr("Capacity", _capName(t[5])), "]"
        );
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        uint256[6] memory t = _traits(_seed[tokenId]);
        string memory json = string.concat(
            '{"name":"Floppy Agents #', tokenId.toString(),
            '","description":"3,333 fully on-chain pixel floppy disks for .ai Agent ID holders on BNB Chain. Free mint, 1 per agent wallet.","attributes":',
            _attrs(t),
            ',"image":"data:image/svg+xml;base64,', Base64.encode(bytes(_svg(t))), '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function rarityOf(uint256 tokenId) external view returns (string memory) {
        _requireOwned(tokenId);
        return _tierName(_tier(_seed[tokenId]));
    }
}
