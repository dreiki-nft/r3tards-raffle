// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title R3tardsRaffle
 * @notice Verifiable onchain raffle for r3tards NFT holders on Monad mainnet.
 *         Randomness provided by Switchboard VRF via TEE-secured oracles.
 *
 * Flow:
 *   1. Owner loads the snapshot: loadTickets(wallets[], tickets[])
 *   2. Owner deposits the prize NFT: IERC721.safeTransferFrom(owner, thisContract, tokenId)
 *   3. Owner requests randomness: requestDraw()
 *      → Switchboard oracle is assigned
 *   4. Anyone calls fulfillDraw(randomnessObject) with the Switchboard response
 *      → Contract verifies it onchain, picks winner, transfers NFT
 *
 * Switchboard Monad Mainnet: 0xB7F03eee7B9F56347e32cC71DaD65B303D5a0E67
 */

// ─── Minimal interfaces ───────────────────────────────────────────────────────

interface IERC721 {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

/// @dev Minimal Switchboard ISwitchboard interface for randomness
interface ISwitchboard {
    struct RandomnessRequest {
        bytes32 id;
        address authority;
        address callback;       // address to call with result (unused in pull model)
        uint256 timestamp;
        bool resolved;
        bytes32 result;
    }

    /// @notice Request a new randomness value
    /// @return randomnessId unique ID for this request
    function createRandomness() external payable returns (bytes32 randomnessId);

    /// @notice Verify and settle a randomness request with oracle response
    /// @param randomnessId the ID returned by createRandomness
    /// @param randomnessObject the raw bytes payload from Crossbar/oracle
    function revealRandomness(
        bytes32 randomnessId,
        bytes calldata randomnessObject
    ) external;

    /// @notice Read the resolved randomness result
    function getRandomnessResult(bytes32 randomnessId) external view returns (bytes32 result, bool resolved);

    /// @notice Fee required by Switchboard to create a randomness request
    function randomnessFee() external view returns (uint256);
}

// ─── Contract ─────────────────────────────────────────────────────────────────

contract R3tardsRaffle is IERC721Receiver {

    // ── State ──────────────────────────────────────────────────────────────────

    address public immutable owner;
    ISwitchboard public immutable switchboard;

    // Snapshot data
    address[] public wallets;
    uint256[] public cumTickets;   // cumulative ticket counts (for binary search)
    uint256   public totalTickets;
    uint256   public snapshotBlock;

    // Prize
    address public prizeNFT;
    uint256 public prizeTokenId;
    bool    public prizeDeposited;

    // Draw state
    enum State { Pending, SnapshotLoaded, PrizeDeposited, DrawRequested, Complete }
    State public state;

    bytes32 public randomnessId;
    address public winner;

    // ── Events ─────────────────────────────────────────────────────────────────

    event SnapshotLoaded(uint256 walletCount, uint256 totalTickets, uint256 snapshotBlock);
    event PrizeDeposited(address nft, uint256 tokenId);
    event DrawRequested(bytes32 randomnessId);
    event DrawComplete(address indexed winner, uint256 winningTicket, uint256 totalTickets);

    // ── Errors ─────────────────────────────────────────────────────────────────

    error NotOwner();
    error WrongState(State current, State required);
    error InvalidSnapshot();
    error PrizeNotDeposited();
    error InsufficientFee(uint256 sent, uint256 required);
    error RandomnessNotResolved();
    error AlreadyComplete();

    // ── Constructor ────────────────────────────────────────────────────────────

    /// @param _switchboard Switchboard contract on Monad mainnet
    constructor(address _switchboard) {
        owner = msg.sender;
        switchboard = ISwitchboard(_switchboard);
        state = State.Pending;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ── Step 1: Load snapshot ──────────────────────────────────────────────────

    /**
     * @notice Load the raffle snapshot from the CSV output.
     *         wallets[i] must correspond to tickets[i].
     *         Can only be called once (state = Pending).
     * @param _wallets  array of eligible wallet addresses
     * @param _tickets  array of ticket counts per wallet (raw, not cumulative)
     * @param _snapshotBlock the block number the snapshot was taken at
     */
    function loadTickets(
        address[] calldata _wallets,
        uint256[] calldata _tickets,
        uint256 _snapshotBlock
    ) external onlyOwner {
        if (state != State.Pending) revert WrongState(state, State.Pending);
        if (_wallets.length == 0 || _wallets.length != _tickets.length) revert InvalidSnapshot();

        delete wallets;
        delete cumTickets;

        uint256 cumulative = 0;
        for (uint256 i = 0; i < _wallets.length; i++) {
            require(_tickets[i] > 0, "Zero ticket entry");
            wallets.push(_wallets[i]);
            cumulative += _tickets[i];
            cumTickets.push(cumulative);
        }

        totalTickets  = cumulative;
        snapshotBlock = _snapshotBlock;
        state         = State.SnapshotLoaded;

        emit SnapshotLoaded(_wallets.length, totalTickets, _snapshotBlock);
    }

    // ── Step 2: Deposit prize NFT ──────────────────────────────────────────────

    /**
     * @notice Called automatically when the prize NFT is safeTransferFrom'd to this contract.
     *         Owner must call nftContract.safeTransferFrom(owner, raffleAddress, tokenId) externally.
     */
    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata
    ) external override returns (bytes4) {
        require(from == owner, "Only owner can deposit prize");
        require(state == State.SnapshotLoaded, "Load snapshot first");

        prizeNFT      = msg.sender;
        prizeTokenId  = tokenId;
        prizeDeposited = true;
        state         = State.PrizeDeposited;

        emit PrizeDeposited(msg.sender, tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }

    // ── Step 3: Request randomness ─────────────────────────────────────────────

    /**
     * @notice Request a verifiable random number from Switchboard.
     *         Caller must send enough MON to cover the Switchboard fee.
     *         Any excess is refunded to owner.
     */
    function requestDraw() external payable onlyOwner {
        if (state != State.PrizeDeposited) revert WrongState(state, State.PrizeDeposited);

        uint256 fee = switchboard.randomnessFee();
        if (msg.value < fee) revert InsufficientFee(msg.value, fee);

        randomnessId = switchboard.createRandomness{value: fee}();
        state        = State.DrawRequested;

        emit DrawRequested(randomnessId);

        // Refund excess
        uint256 excess = msg.value - fee;
        if (excess > 0) {
            (bool ok,) = owner.call{value: excess}("");
            require(ok, "Refund failed");
        }
    }

    // ── Step 4: Fulfill draw ───────────────────────────────────────────────────

    /**
     * @notice Submit the Switchboard oracle response to resolve the randomness
     *         and pick the winner. Anyone can call this once the oracle responds.
     * @param randomnessObject raw bytes payload from Crossbar (pass through as-is)
     */
    function fulfillDraw(bytes calldata randomnessObject) external {
        if (state != State.DrawRequested) revert WrongState(state, State.DrawRequested);

        // Submit to Switchboard — it verifies the TEE proof onchain
        switchboard.revealRandomness(randomnessId, randomnessObject);

        // Read verified result
        (bytes32 result, bool resolved) = switchboard.getRandomnessResult(randomnessId);
        if (!resolved) revert RandomnessNotResolved();

        // Map random bytes to a ticket index [0, totalTickets)
        uint256 winningTicket = uint256(result) % totalTickets;

        // Binary search cumTickets to find winner
        address w = _findWinner(winningTicket);
        winner = w;
        state  = State.Complete;

        emit DrawComplete(w, winningTicket, totalTickets);

        // Transfer prize NFT to winner
        IERC721(prizeNFT).safeTransferFrom(address(this), w, prizeTokenId);
    }

    // ── View helpers ───────────────────────────────────────────────────────────

    /// @notice Binary search: find which wallet owns the winning ticket index
    function _findWinner(uint256 ticketIndex) internal view returns (address) {
        uint256 lo = 0;
        uint256 hi = cumTickets.length - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (cumTickets[mid] <= ticketIndex) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return wallets[lo];
    }

    /// @notice Get a wallet's ticket range for verification
    function getWalletTickets(address wallet) external view returns (uint256 from, uint256 to) {
        for (uint256 i = 0; i < wallets.length; i++) {
            if (wallets[i] == wallet) {
                from = i == 0 ? 0 : cumTickets[i - 1];
                to   = cumTickets[i] - 1;
                return (from, to);
            }
        }
        revert("Wallet not in snapshot");
    }

    /// @notice Full raffle summary — useful for frontends / block explorers
    function getRaffleInfo() external view returns (
        uint256 _totalTickets,
        uint256 _walletCount,
        uint256 _snapshotBlock,
        address _prizeNFT,
        uint256 _prizeTokenId,
        State   _state,
        address _winner
    ) {
        return (
            totalTickets,
            wallets.length,
            snapshotBlock,
            prizeNFT,
            prizeTokenId,
            state,
            winner
        );
    }

    /// @notice Emergency: owner can recover NFT if raffle is cancelled before draw
    function recoverPrize() external onlyOwner {
        require(state != State.Complete, "Raffle complete");
        require(prizeDeposited, "No prize deposited");
        IERC721(prizeNFT).safeTransferFrom(address(this), owner, prizeTokenId);
        prizeDeposited = false;
        state = State.SnapshotLoaded;
    }

    receive() external payable {}
}
