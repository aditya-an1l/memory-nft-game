// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title  MemoryGame
 * @author Aditya Anil (aditya-an1l)
 * @notice A fully on-chain memory card matching game with ERC-1155 NFT rewards.
 *
 * @dev    Architecture overview
 *         ─────────────────────
 *         Inherits ERC-1155 so this single contract manages ALL token types:
 *           - Token ID 0  →  $MEMORY  (fungible reward token, 18 decimals)
 *           - Token ID 1  →  Circle   NFT (non-fungible shape reward)
 *           - Token ID 2  →  Square   NFT
 *           - Token ID 3  →  Triangle NFT
 *           - Token ID 4  →  Star     NFT
 *           - Token ID 5  →  Heart    NFT
 *           - Token ID 6  →  Diamond  NFT
 *
 *         Inherits Ownable so the deployer controls the reward pool and
 *         metadata URI updates.
 *
 *         Game flow
 *         ─────────
 *         1. Player calls createGame() → contract shuffles a 12-card board
 *            on-chain using a Fisher-Yates shuffle seeded by the caller.
 *         2. In multiplayer, a second player calls joinGame().
 *         3. Players call submitPair() with two card indices. The contract
 *            checks whether the shapes at those positions match.
 *         4. A match mints 1 shape NFT + REWARD_PER_PAIR $MEMORY to the
 *            caller and emits PairMatched.
 *         5. A mismatch emits PairMismatched and (in 2-player) advances
 *            the turn to the other player.
 *         6. When all 6 pairs are revealed, _endGame() fires: the winner
 *            (most pairs) receives a 50 $MEMORY bonus from the owner pool
 *            and a GameOver event is emitted.
 *
 *         Security notes
 *         ──────────────
 *         The shuffle seed is caller-supplied, which means a miner/validator
 *         could theoretically front-run createGame() to pick a favourable
 *         seed. For a Sepolia testnet demo this is acceptable. For production,
 *         replace with Chainlink VRF.
 *
 *         getBoard() is restricted to game participants to prevent opponents
 *         from peeking at the hidden board before flipping.
 */
contract MemoryGame is ERC1155, Ownable {

    // ══════════════════════════════════════════════════════════════════════════
    //  TOKEN ID CONSTANTS
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice ERC-1155 token ID for the fungible $MEMORY reward token (18 decimals).
    uint256 public constant MEMORY_TOKEN   = 0;

    /// @notice ERC-1155 token ID minted when a Circle pair is matched.
    uint256 public constant SHAPE_CIRCLE   = 1;

    /// @notice ERC-1155 token ID minted when a Square pair is matched.
    uint256 public constant SHAPE_SQUARE   = 2;

    /// @notice ERC-1155 token ID minted when a Triangle pair is matched.
    uint256 public constant SHAPE_TRIANGLE = 3;

    /// @notice ERC-1155 token ID minted when a Star pair is matched.
    uint256 public constant SHAPE_STAR     = 4;

    /// @notice ERC-1155 token ID minted when a Heart pair is matched.
    uint256 public constant SHAPE_HEART    = 5;

    /// @notice ERC-1155 token ID minted when a Diamond pair is matched.
    uint256 public constant SHAPE_DIAMOND  = 6;

    /// @notice Amount of $MEMORY awarded per matched pair (in 1e18 units).
    /// @dev    Equals 10 × 10^18, mirroring the standard 18-decimal convention.
    uint256 public constant REWARD_PER_PAIR = 10 * 1e18;

    // ══════════════════════════════════════════════════════════════════════════
    //  DATA STRUCTURES
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Stores all mutable state for a single game session.
     *
     * @dev    Named GameData (not Game) to avoid an identifier collision with
     *         the parent contract name in Solidity 0.8.20.
     *
     * @param player1       Address that created the game; always the first mover.
     * @param player2       Address of the second participant. In single-player
     *                      mode this is set to player1 so turn checks always pass.
     * @param currentPlayer The address whose turn it currently is.
     * @param board         Fixed-size array of 12 shape IDs (values 1–6).
     *                      Position i holds the shape hidden at card index i.
     *                      Populated once by _shuffleBoard() and never mutated.
     * @param revealed      Parallel boolean array; revealed[i] == true means
     *                      card i has been permanently matched and removed from play.
     * @param pairs1        Running count of pairs collected by player1.
     * @param pairs2        Running count of pairs collected by player2.
     * @param active        False once _endGame() has been called.
     * @param singlePlayer  True when both player slots belong to the same address.
     */
    struct GameData {
        address   player1;
        address   player2;
        address   currentPlayer;
        uint8[12] board;
        bool[12]  revealed;
        uint8     pairs1;
        uint8     pairs2;
        bool      active;
        bool      singlePlayer;
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  STORAGE
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice Auto-incrementing counter; the next game created will use this ID.
    /// @dev    Starts at 1 so gameId 0 is never valid — useful as a null sentinel.
    uint256 public nextGameId = 1;

    /// @notice Maps a game ID to its full on-chain state.
    mapping(uint256 => GameData) public games;

    // ══════════════════════════════════════════════════════════════════════════
    //  EVENTS
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Emitted when a new game session is initialised.
     * @param gameId      Unique identifier assigned to this game.
     * @param player1     Address of the creator / first player.
     * @param singlePlayer True if the game is configured for one player only.
     */
    event GameCreated(uint256 indexed gameId, address indexed player1, bool singlePlayer);

    /**
     * @notice Emitted when a second player successfully joins a multiplayer game.
     * @param gameId  The game being joined.
     * @param player2 Address of the joining player.
     */
    event PlayerJoined(uint256 indexed gameId, address indexed player2);

    /**
     * @notice Emitted once per card revealed during a submitPair() call.
     * @dev    Two CardFlipped events fire per turn (one per index). Frontends
     *         can listen here to animate the flip before the result is known.
     * @param gameId    The game in which the card was flipped.
     * @param player    Address of the player who flipped the card.
     * @param cardIndex Position (0–11) of the card that was turned over.
     * @param shape     Shape ID (1–6) hidden at that position.
     */
    event CardFlipped(uint256 indexed gameId, address indexed player, uint8 cardIndex, uint8 shape);

    /**
     * @notice Emitted when two flipped cards share the same shape.
     * @dev    At this point the shape NFT and $MEMORY reward have already been
     *         minted to `player`. Frontends should lock those two card positions.
     * @param gameId The game in which the match occurred.
     * @param player Address of the player who found the match.
     * @param shape  Shape ID (1–6) of the matched pair.
     */
    event PairMatched(uint256 indexed gameId, address indexed player, uint8 shape);

    /**
     * @notice Emitted when two flipped cards have different shapes.
     * @dev    In multiplayer, the turn has already advanced to the other player
     *         by the time this event fires.
     * @param gameId The game in which the mismatch occurred.
     * @param player Address of the player whose turn it was.
     * @param index1 First card index that was flipped.
     * @param index2 Second card index that was flipped.
     */
    event PairMismatched(uint256 indexed gameId, address indexed player, uint8 index1, uint8 index2);

    /**
     * @notice Emitted when all 6 pairs have been found and the game ends.
     * @dev    The winner bonus transfer (if funded) happens before this event.
     * @param gameId     The completed game.
     * @param winner     Address of the player with the most matched pairs.
     *                   In a tie, player1 is declared the winner.
     * @param totalPairs Number of pairs collected by the winner.
     */
    event GameOver(uint256 indexed gameId, address indexed winner, uint8 totalPairs);

    // ══════════════════════════════════════════════════════════════════════════
    //  CONSTRUCTOR
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Deploys the contract and mints the initial $MEMORY reward pool
     *         to the deployer (owner).
     *
     * @dev    The URI follows ERC-1155 metadata convention: `{id}` is replaced
     *         by the token ID (zero-padded to 64 hex chars) by compliant clients.
     *
     *         The initial mint of 100 000 $MEMORY gives the contract owner a
     *         pool from which end-game winner bonuses are drawn via
     *         safeTransferFrom inside _endGame().
     */
    constructor()
        ERC1155("https://memorygame.example/{id}.json")
        Ownable(msg.sender)
    {
        _mint(msg.sender, MEMORY_TOKEN, 100_000 * 1e18, "");
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  EXTERNAL — GAME LIFECYCLE
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Creates a new game and shuffles the 12-card board on-chain.
     *
     * @dev    Shuffle algorithm: Fisher-Yates using keccak256(seed, i) as the
     *         random source. Because the seed is caller-supplied it is NOT
     *         cryptographically unpredictable — use Chainlink VRF for production.
     *
     *         In single-player mode player2 is set to msg.sender immediately so
     *         that the `currentPlayer` guard in submitPair() never blocks solo play.
     *
     * @param shuffleSeed  Arbitrary number used to seed the on-chain shuffle.
     *                     The frontend should pass a large random BigInt so that
     *                     different games produce different board layouts.
     * @param singlePlayer True to create a solo game; false to wait for a second
     *                     player to call joinGame().
     *
     * @return gameId The ID assigned to the newly created game. Store this value
     *                and pass it to all subsequent calls (submitPair, getBoard, etc).
     */
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

        // In single-player mode both slots belong to the same address.
        if (singlePlayer) {
            gd.player2 = msg.sender;
        }

        emit GameCreated(gameId, msg.sender, singlePlayer);
    }

    /**
     * @notice Allows a second player to join an open multiplayer game.
     *
     * @dev    Reverts if:
     *           • The game is not active (already finished).
     *           • player2 has already been assigned (game is full).
     *           • The caller is the same address as player1.
     *
     * @param gameId ID of the game to join, as returned by createGame().
     */
    function joinGame(uint256 gameId) external {
        GameData storage gd = games[gameId];
        require(gd.active,                "Game not active");
        require(gd.player2 == address(0), "Game full");
        require(gd.player1 != msg.sender, "Already in game");

        gd.player2 = msg.sender;
        emit PlayerJoined(gameId, msg.sender);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  EXTERNAL — CORE GAMEPLAY
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Submits two card indices for match evaluation — the primary
     *         gameplay transaction.
     *
     * @dev    On every call:
     *           1. Both indices are validated (in range, distinct, not yet matched).
     *           2. Two CardFlipped events are emitted so frontends can animate.
     *           3a. If the shapes match:
     *                 - Both positions marked revealed.
     *                 - Caller's pair counter increments.
     *                 - 1 shape-specific NFT minted to the caller.
     *                 - REWARD_PER_PAIR $MEMORY minted to the caller.
     *                 - PairMatched emitted.
     *                 - If this was the last pair, _endGame() is called.
     *                 - Turn does NOT advance (matched player goes again).
     *           3b. If the shapes do not match:
     *                 - PairMismatched emitted.
     *                 - In multiplayer, currentPlayer switches to the other player.
     *
     *         Reverts if:
     *           • Game is not active.
     *           • Multiplayer game has no second player yet.
     *           • Caller is not the currentPlayer.
     *           • Either index is outside the 0–11 range.
     *           • Both indices are the same (flipping one card twice).
     *           • Either card has already been permanently matched.
     *
     * @param gameId ID of the game being played.
     * @param idx1   Index (0–11) of the first card to flip.
     * @param idx2   Index (0–11) of the second card to flip.
     *
     * @return isMatch True if both cards share the same shape; false otherwise.
     * @return shape   The shape ID (1–6) of the matched pair, or 0 on mismatch.
     */
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

        // Announce both flips before revealing the outcome.
        emit CardFlipped(gameId, msg.sender, idx1, shape1);
        emit CardFlipped(gameId, msg.sender, idx2, shape2);

        if (shape1 == shape2) {
            // ── Match path ────────────────────────────────────────────────────

            // Permanently lock both card positions.
            gd.revealed[idx1] = true;
            gd.revealed[idx2] = true;

            // Increment the correct player's pair counter.
            if (msg.sender == gd.player1) gd.pairs1++;
            else                          gd.pairs2++;

            // Mint 1 shape-specific NFT to the matched player.
            _mint(msg.sender, shape1, 1, "");

            // Mint fungible $MEMORY reward tokens.
            _mint(msg.sender, MEMORY_TOKEN, REWARD_PER_PAIR, "");

            isMatch = true;
            shape   = shape1;
            emit PairMatched(gameId, msg.sender, shape1);

            // End the game if this was the final pair.
            if (_allRevealed(gameId)) {
                _endGame(gameId);
            }
            // Matched player retains the turn — no currentPlayer switch needed.

        } else {
            // ── Mismatch path ─────────────────────────────────────────────────

            isMatch = false;
            shape   = 0;
            emit PairMismatched(gameId, msg.sender, idx1, idx2);

            // Advance the turn only in multiplayer mode.
            if (!gd.singlePlayer) {
                gd.currentPlayer = (msg.sender == gd.player1)
                    ? gd.player2
                    : gd.player1;
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  EXTERNAL — VIEW / READ-ONLY HELPERS
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Returns the full shuffled card layout for a game.
     *
     * @dev    Access is restricted to the two participants of the game to prevent
     *         a third party from reading the board and cheating in multiplayer.
     *         In single-player, player1 == player2 so only that address can call.
     *
     *         IMPORTANT: The frontend must call this immediately after createGame()
     *         confirms to sync its local board with the on-chain arrangement.
     *         Without this sync the frontend shuffle and the contract shuffle diverge,
     *         causing every submitPair() to evaluate wrong indices and revert.
     *
     * @param gameId ID of the game whose board should be returned.
     *
     * @return A fixed-size array of 12 shape IDs (values 1–6), one per card position.
     */
    function getBoard(uint256 gameId)
        external
        view
        returns (uint8[12] memory)
    {
        GameData storage gd = games[gameId];
        require(
            msg.sender == gd.player1 || msg.sender == gd.player2,
            "Not your game"
        );
        return gd.board;
    }

    /**
     * @notice Returns a boolean mask showing which card positions are permanently matched.
     *
     * @dev    revealed[i] == true means card i has been matched and should be
     *         displayed face-up and locked in the frontend. Useful for reconnecting
     *         a player mid-game: fetch the mask and restore the UI state.
     *
     * @param gameId ID of the game to query.
     *
     * @return A 12-element boolean array; true at index i means that card is matched.
     */
    function getRevealedMask(uint256 gameId)
        external
        view
        returns (bool[12] memory)
    {
        return games[gameId].revealed;
    }

    /**
     * @notice Returns a summary of the current game state in a single RPC call.
     *
     * @dev    Intended for frontends and off-chain indexers that need player
     *         addresses, current turn, scores, and live status without multiple
     *         separate calls.
     *
     * @param gameId ID of the game to query.
     *
     * @return player1       Address of the game creator.
     * @return player2       Address of the second player (zero address if not joined yet).
     * @return currentPlayer Address whose turn it currently is.
     * @return pairs1        Pairs collected by player1 so far.
     * @return pairs2        Pairs collected by player2 so far.
     * @return active        False if the game has ended.
     */
    function getGameInfo(uint256 gameId)
        external
        view
        returns (
            address player1,
            address player2,
            address currentPlayer,
            uint8   pairs1,
            uint8   pairs2,
            bool    active
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

    // ══════════════════════════════════════════════════════════════════════════
    //  EXTERNAL — OWNER-ONLY ADMINISTRATION
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Mints additional $MEMORY tokens into the owner's address.
     *
     * @dev    The owner's $MEMORY balance serves as the prize pool from which
     *         50-token winner bonuses are paid at the end of each game via
     *         safeTransferFrom inside _endGame(). Call this to top up the pool
     *         if it runs low. Only the contract owner may call this function.
     *
     * @param amount Number of $MEMORY tokens to mint in 1e18 units.
     *               Example: pass 1000 * 1e18 to add 1 000 tokens.
     */
    function mintRewardPool(uint256 amount) external onlyOwner {
        _mint(msg.sender, MEMORY_TOKEN, amount, "");
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  INTERNAL HELPERS
    // ══════════════════════════════════════════════════════════════════════════

    /**
     * @notice Populates the board for `gameId` with a deterministic Fisher-Yates
     *         shuffle seeded by `seed`.
     *
     * @dev    Build phase: create an ordered array of pairs — [1,1,2,2,...,6,6].
     *
     *         Shuffle phase: for i from 11 down to 1, compute
     *             j = keccak256(seed || i) mod (i + 1)
     *         then swap cards[i] and cards[j]. This produces a uniform random
     *         permutation given a uniformly random seed.
     *
     *         The function takes `gameId` (not a storage pointer) to sidestep the
     *         Solidity 0.8.20 "Identifier not found or not unique" compiler error
     *         that occurs when a struct named GameData is passed by storage ref
     *         to an internal function inside a contract also named MemoryGame.
     *
     * @param gameId The game whose board array should be written to storage.
     * @param seed   Caller-supplied entropy value for the shuffle.
     */
    function _shuffleBoard(uint256 gameId, uint256 seed) internal {
        uint8[12] memory cards;

        // Populate: two copies of each shape ID 1–6.
        for (uint8 i = 0; i < 6; i++) {
            cards[i * 2]     = i + 1;
            cards[i * 2 + 1] = i + 1;
        }

        // Fisher-Yates in-place shuffle (Knuth variant, i counts down).
        for (uint8 i = 11; i > 0; i--) {
            uint8 j = uint8(
                uint256(keccak256(abi.encodePacked(seed, i))) % (uint256(i) + 1)
            );
            (cards[i], cards[j]) = (cards[j], cards[i]);
        }

        games[gameId].board = cards;
    }

    /**
     * @notice Returns true when every card position in the game has been matched.
     *
     * @dev    Iterates the revealed[] array linearly (12 elements, constant gas).
     *         Returns false early on the first unmatched position to save iterations.
     *         Called at the end of every successful match to detect game completion.
     *
     * @param gameId The game to inspect.
     *
     * @return True if all 12 positions are revealed; false otherwise.
     */
    function _allRevealed(uint256 gameId) internal view returns (bool) {
        bool[12] storage rev = games[gameId].revealed;
        for (uint8 i = 0; i < 12; i++) {
            if (!rev[i]) return false;
        }
        return true;
    }

    /**
     * @notice Finalises a completed game: marks it inactive, determines the
     *         winner, transfers the bonus prize if the pool is funded, and
     *         emits the GameOver event.
     *
     * @dev    Winner determination: the player with strictly more pairs wins.
     *         On a tie (3 pairs each), player1 is declared the winner — this
     *         is intentional behaviour and should be disclosed to players.
     *
     *         Bonus transfer: 50 $MEMORY are sent from the owner's wallet via
     *         safeTransferFrom. The owner must have approved this contract or
     *         called setApprovalForAll. If the owner's $MEMORY balance is below
     *         50 × 1e18 the bonus is silently skipped — the game still ends
     *         normally and GameOver is still emitted.
     *
     *         For a production deployment consider holding the prize pool inside
     *         the contract itself (funded by entry fees) rather than relying on
     *         the owner's personal token balance.
     *
     * @param gameId The game to finalise.
     */
    function _endGame(uint256 gameId) internal {
        GameData storage gd = games[gameId];
        gd.active = false;

        // Determine winner; player1 wins on a tie.
        address winner;
        uint8   winPairs;
        if (gd.pairs1 >= gd.pairs2) {
            winner   = gd.player1;
            winPairs = gd.pairs1;
        } else {
            winner   = gd.player2;
            winPairs = gd.pairs2;
        }

        // Pay 50 $MEMORY bonus from owner pool if sufficiently funded.
        if (balanceOf(owner(), MEMORY_TOKEN) >= 50 * 1e18) {
            safeTransferFrom(owner(), winner, MEMORY_TOKEN, 50 * 1e18, "");
        }

        emit GameOver(gameId, winner, winPairs);
    }
}
