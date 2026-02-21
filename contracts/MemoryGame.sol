// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * MemoryGame Contract
 * - ERC-1155: token IDs 1-6 represent the 6 shape pairs
 * - Players submit two card indices (0-11); contract verifies match
 * - Matching a pair mints an NFT to the caller
 * - fake $MEMORY reward tokens (ID 0) given at end of game
 * - Supports 2-player turn enforcement
 */
contract MemoryGame is ERC1155, Ownable {

    // ── Token IDs ──────────────────────────────────────────────────────────────
    uint256 public constant MEMORY_TOKEN   = 0;
    uint256 public constant SHAPE_CIRCLE   = 1;
    uint256 public constant SHAPE_SQUARE   = 2;
    uint256 public constant SHAPE_TRIANGLE = 3;
    uint256 public constant SHAPE_STAR     = 4;
    uint256 public constant SHAPE_HEART    = 5;
    uint256 public constant SHAPE_DIAMOND  = 6;

    uint256 public constant REWARD_PER_PAIR = 10 * 1e18;

    // ── Game State ─────────────────────────────────────────────────────────────
    // Renamed from "Game" to "GameData" to avoid collision with contract name
    struct GameData {
        address player1;
        address player2;
        address currentPlayer;
        uint8[12] board;       // shape ID (1-6) at each position
        bool[12]  revealed;    // permanently matched positions
        uint8  pairs1;
        uint8  pairs2;
        bool   active;
        bool   singlePlayer;
    }

    uint256 public nextGameId = 1;
    mapping(uint256 => GameData) public games;

    // ── Events ─────────────────────────────────────────────────────────────────
    event GameCreated(uint256 indexed gameId, address indexed player1, bool singlePlayer);
    event PlayerJoined(uint256 indexed gameId, address indexed player2);
    event CardFlipped(uint256 indexed gameId, address indexed player, uint8 cardIndex, uint8 shape);
    event PairMatched(uint256 indexed gameId, address indexed player, uint8 shape);
    event PairMismatched(uint256 indexed gameId, address indexed player, uint8 index1, uint8 index2);
    event GameOver(uint256 indexed gameId, address indexed winner, uint8 totalPairs);

    // ── Constructor ────────────────────────────────────────────────────────────
    constructor()
        ERC1155("https://memorygame.example/{id}.json")
        Ownable(msg.sender)
    {
        _mint(msg.sender, MEMORY_TOKEN, 100000 * 1e18, "");
    }

    // ── Game Creation ──────────────────────────────────────────────────────────

    function createGame(uint256 shuffleSeed, bool singlePlayer)
        external
        returns (uint256 gameId)
    {
        gameId = nextGameId++;
        GameData storage gd = games[gameId];
        gd.player1       = msg.sender;
        gd.currentPlayer = msg.sender;
        gd.singlePlayer  = singlePlayer;
        gd.active        = true;

        _shuffleBoard(gameId, shuffleSeed);

        if (singlePlayer) {
            gd.player2 = msg.sender;
        }

        emit GameCreated(gameId, msg.sender, singlePlayer);
    }

    function joinGame(uint256 gameId) external {
        GameData storage gd = games[gameId];
        require(gd.active,                "Game not active");
        require(gd.player2 == address(0), "Game full");
        require(gd.player1 != msg.sender, "Already in game");
        gd.player2 = msg.sender;
        emit PlayerJoined(gameId, msg.sender);
    }

    // ── Core Gameplay ──────────────────────────────────────────────────────────

    function submitPair(uint256 gameId, uint8 idx1, uint8 idx2)
        external
        returns (bool isMatch, uint8 shape)
    {
        GameData storage gd = games[gameId];
        require(gd.active,                                    "Game not active");
        require(gd.player2 != address(0) || gd.singlePlayer, "Waiting for player2");
        require(msg.sender == gd.currentPlayer,               "Not your turn");
        require(idx1 < 12 && idx2 < 12,                      "Index out of range");
        require(idx1 != idx2,                                 "Same index");
        require(!gd.revealed[idx1] && !gd.revealed[idx2],    "Card already matched");

        uint8 shape1 = gd.board[idx1];
        uint8 shape2 = gd.board[idx2];

        emit CardFlipped(gameId, msg.sender, idx1, shape1);
        emit CardFlipped(gameId, msg.sender, idx2, shape2);

        if (shape1 == shape2) {
            gd.revealed[idx1] = true;
            gd.revealed[idx2] = true;

            if (msg.sender == gd.player1) gd.pairs1++;
            else gd.pairs2++;

            _mint(msg.sender, shape1, 1, "");
            _mint(msg.sender, MEMORY_TOKEN, REWARD_PER_PAIR, "");

            isMatch = true;
            shape   = shape1;
            emit PairMatched(gameId, msg.sender, shape1);

            if (_allRevealed(gameId)) {
                _endGame(gameId);
            }
        } else {
            isMatch = false;
            shape   = 0;
            emit PairMismatched(gameId, msg.sender, idx1, idx2);
            if (!gd.singlePlayer) {
                gd.currentPlayer = (msg.sender == gd.player1) ? gd.player2 : gd.player1;
            }
        }
    }

    // ── View Helpers ───────────────────────────────────────────────────────────

    /**
     * Returns the full shuffled board for a game.
     * Only the game creator (player1) can read this — prevents cheating by
     * opponents peeking at the board before flipping.
     * In single-player mode anyone can call it (player1 == player2).
     */
    function getBoard(uint256 gameId)
        external
        view
        returns (uint8[12] memory)
    {
        GameData storage gd = games[gameId];
        require(msg.sender == gd.player1 || msg.sender == gd.player2, "Not your game");
        return gd.board;
    }

    function getRevealedMask(uint256 gameId)
        external
        view
        returns (bool[12] memory)
    {
        return games[gameId].revealed;
    }

    function getGameInfo(uint256 gameId)
        external
        view
        returns (
            address player1,
            address player2,
            address currentPlayer,
            uint8 pairs1,
            uint8 pairs2,
            bool active
        )
    {
        GameData storage gd = games[gameId];
        return (
            gd.player1,
            gd.player2,
            gd.currentPlayer,
            gd.pairs1,
            gd.pairs2,
            gd.active
        );
    }

    // ── Internal ───────────────────────────────────────────────────────────────

    // Uses gameId (not storage ref) to avoid "Identifier not unique" compiler error
    function _shuffleBoard(uint256 gameId, uint256 seed) internal {
        uint8[12] memory cards;
        for (uint8 i = 0; i < 6; i++) {
            cards[i * 2]     = i + 1;
            cards[i * 2 + 1] = i + 1;
        }
        for (uint8 i = 11; i > 0; i--) {
            uint8 j = uint8(
                uint256(keccak256(abi.encodePacked(seed, i))) % (uint256(i) + 1)
            );
            (cards[i], cards[j]) = (cards[j], cards[i]);
        }
        games[gameId].board = cards;
    }

    function _allRevealed(uint256 gameId) internal view returns (bool) {
        bool[12] storage rev = games[gameId].revealed;
        for (uint8 i = 0; i < 12; i++) {
            if (!rev[i]) return false;
        }
        return true;
    }

    function _endGame(uint256 gameId) internal {
        GameData storage gd = games[gameId];
        gd.active = false;

        address winner;
        uint8   winPairs;
        if (gd.pairs1 >= gd.pairs2) {
            winner   = gd.player1;
            winPairs = gd.pairs1;
        } else {
            winner   = gd.player2;
            winPairs = gd.pairs2;
        }

        if (balanceOf(owner(), MEMORY_TOKEN) >= 50 * 1e18) {
            safeTransferFrom(owner(), winner, MEMORY_TOKEN, 50 * 1e18, "");
        }

        emit GameOver(gameId, winner, winPairs);
    }

    // Owner can top up the reward pool
    function mintRewardPool(uint256 amount) external onlyOwner {
        _mint(msg.sender, MEMORY_TOKEN, amount, "");
    }
}
