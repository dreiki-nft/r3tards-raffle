// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title R3tardsRaffle
 * @notice Verifiable onchain raffle for r3tards NFT holders on Monad.
 *         Randomness provided by Switchboard VRF via TEE-secured oracles.
 *
 * Flow:
 *   1. initSnapshot(snapshotBlock, snapshotHash)
 *   2. loadTicketsBatch(wallets[], tickets[])  ← repeat if needed
 *   3. finalizeSnapshot()
 *   4. prizeNFT.safeTransferFrom(owner, raffleAddress, tokenId)
 *   5. setDrawDeadline(blockNumber)
 *   6. requestDraw()  [pays Switchboard fee]
 *   7. fulfillDraw(randomnessObject)  [anyone can call]
 *
 * Getting encodedRandomness after requestDraw():
 *   1. Read randomnessId from the DrawRequested event
 *   2. Call Crossbar: resolveEVMRandomness(randomnessId)
 *   3. Send updateFee() worth of MON as msg.value to fulfillDraw()
 *   4. Pass the encoded bytes to fulfillDraw()
 *
 * Switchboard addresses:
 *   Monad Testnet  (chainId 10143): 0xD3860E2C66cBd5c969Fa7343e6912Eff0416bA33
 *   Monad Mainnet  (chainId 143):   0xB7F03eee7B9F56347e32cC71DaD65B303D5a0E67
 */

// ─── Interfaces ───────────────────────────────────────────────────────────────

interface IERC721 {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

interface ISwitchboard {
    struct RandomnessData {
        bytes32 randId;
        uint256 createdAt;
        address authority;
        uint256 rollTimestamp;
        uint64  minSettlementDelay;
        address oracle;
        uint256 value;
        uint256 settledAt;
    }

    /// @notice Create a randomness request
    function createRandomness(bytes32 randomnessId, uint64 minSettlementDelay) external returns (address oracle);

    /// @notice Settle randomness with encoded payload from Crossbar
    function settleRandomness(bytes calldata encodedRandomness) external payable;

    /// @notice Read the randomness result struct
    function getRandomness(bytes32 randomnessId) external view returns (RandomnessData memory);

    function updateFee() external view returns (uint256);
}

// ─── Contract ─────────────────────────────────────────────────────────────────

contract R3tardsRaffle is IERC721Receiver {

    // ── State ──────────────────────────────────────────────────────────────────

    address public immutable owner;
    ISwitchboard public immutable switchboard;
    address public immutable switchboardAddress; // stored for transparency / verification

    // Snapshot
    address[] public wallets;
    uint256[] public cumTickets;     // cumulative ticket counts — for binary search
    uint256   public totalTickets;
    uint256   public snapshotBlock;
    bytes32   public snapshotHash;   // onchain audit anchor: keccak256 of CSV or git commit hash

    // Prize
    address public prizeNFT;
    uint256 public prizeTokenId;
    bool    public prizeDeposited;

    // Draw
    enum State { Pending, LoadingSnapshot, SnapshotLoaded, PrizeDeposited, DrawRequested, Complete }
    State public state;

    bytes32 public randomnessId;
    uint256 public drawDeadline;     // block number — draw must be requested by this block
    address public winner;
    uint256 public winningTicket;

    // ── Events ─────────────────────────────────────────────────────────────────

    event SnapshotBatchLoaded(uint256 batchSize, uint256 totalWallets, uint256 totalTicketsSoFar);
    event SnapshotFinalized(uint256 walletCount, uint256 totalTickets, uint256 snapshotBlock, bytes32 snapshotHash);
    event PrizeDeposited(address indexed nft, uint256 tokenId);
    event DrawDeadlineSet(uint256 blockNumber);
    event DrawRequested(bytes32 indexed randomnessId, uint256 switchboardFee);
    event DrawComplete(address indexed winner, uint256 winningTicket, uint256 totalTickets);
    event PrizeRecovered(address indexed to);

    // ── Errors ─────────────────────────────────────────────────────────────────

    error NotOwner();
    error WrongState(State current);
    error InvalidSnapshot();
    error InsufficientFee(uint256 sent, uint256 required);
    error RandomnessNotResolved();
    error DeadlinePassed(uint256 current, uint256 deadline);
    error DeadlineNotSet();
    error RefundFailed();

    // ── Constructor ────────────────────────────────────────────────────────────

    /**
     * @param _switchboard Switchboard contract address for the target network:
     *   Testnet  (chainId 10143): 0xD3860E2C66cBd5c969Fa7343e6912Eff0416bA33
     *   Mainnet  (chainId 143):   0xB7F03eee7B9F56347e32cC71DaD65B303D5a0E67
     */
    constructor(address _switchboard) {
        require(_switchboard != address(0), "Invalid Switchboard address");
        owner             = msg.sender;
        switchboard       = ISwitchboard(_switchboard);
        switchboardAddress = _switchboard;
        state             = State.Pending;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ── Step 1a: Init snapshot ─────────────────────────────────────────────────

    /**
     * @notice Begin loading the snapshot. Clears any previous data.
     * @param _snapshotBlock  block the snapshot was taken at (for public verification)
     * @param _snapshotHash   keccak256 of the snapshot CSV or git commit hash
     *                        Use: ethers.utils.id(gitCommitHash) or keccak256(csvBytes)
     */
    function initSnapshot(uint256 _snapshotBlock, bytes32 _snapshotHash) external onlyOwner {
        if (state != State.Pending) revert WrongState(state);

        delete wallets;
        delete cumTickets;
        totalTickets  = 0;
        snapshotBlock = _snapshotBlock;
        snapshotHash  = _snapshotHash;
        state         = State.LoadingSnapshot;
    }

    // ── Step 1b: Load batches ──────────────────────────────────────────────────

    /**
     * @notice Append wallets+tickets to the snapshot. Call once per batch.
     *         Batching avoids block gas limit for large snapshots.
     *         Typical safe batch size: 200–500 wallets per tx.
     */
    function loadTicketsBatch(
        address[] calldata _wallets,
        uint256[] calldata _tickets
    ) external onlyOwner {
        if (state != State.LoadingSnapshot) revert WrongState(state);
        if (_wallets.length == 0 || _wallets.length != _tickets.length) revert InvalidSnapshot();

        uint256 cumulative = totalTickets;
        for (uint256 i = 0; i < _wallets.length; i++) {
            require(_tickets[i] > 0, "Zero ticket entry");
            wallets.push(_wallets[i]);
            cumulative += _tickets[i];
            cumTickets.push(cumulative);
        }
        totalTickets = cumulative;

        emit SnapshotBatchLoaded(_wallets.length, wallets.length, totalTickets);
    }

    // ── Step 1c: Finalize snapshot ─────────────────────────────────────────────

    /**
     * @notice Lock the snapshot after all batches are loaded.
     *         After this, snapshot data cannot be modified.
     */
    function finalizeSnapshot() external onlyOwner {
        if (state != State.LoadingSnapshot) revert WrongState(state);
        if (wallets.length == 0) revert InvalidSnapshot();

        state = State.SnapshotLoaded;
        emit SnapshotFinalized(wallets.length, totalTickets, snapshotBlock, snapshotHash);
    }

    // ── Step 2: Deposit prize NFT ──────────────────────────────────────────────

    /**
     * @notice Auto-triggered when owner sends prize NFT via safeTransferFrom.
     *         Call: prizeNFT.safeTransferFrom(owner, address(this), tokenId)
     *
     * @dev msg.sender is the NFT contract — cannot be spoofed unlike `from`.
     *      `from` is still checked against owner for access control.
     */
    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata
    ) external override returns (bytes4) {
        require(from == owner, "Only owner can deposit prize");
        require(state == State.SnapshotLoaded, "Finalize snapshot first");

        prizeNFT       = msg.sender;
        prizeTokenId   = tokenId;
        prizeDeposited = true;
        state          = State.PrizeDeposited;

        emit PrizeDeposited(msg.sender, tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }

    // ── Step 3: Set draw deadline ──────────────────────────────────────────────

    /**
     * @notice Set the deadline block by which requestDraw() must be called.
     *         Prevents owner from delaying the draw indefinitely.
     *         Recommended: ~24–48h of blocks from now.
     */
    function setDrawDeadline(uint256 _deadlineBlock) external onlyOwner {
        if (state != State.PrizeDeposited) revert WrongState(state);
        require(_deadlineBlock > block.number, "Deadline must be in the future");
        drawDeadline = _deadlineBlock;
        emit DrawDeadlineSet(_deadlineBlock);
    }

    // ── Step 4: Request randomness ─────────────────────────────────────────────

    /**
     * @notice Pay Switchboard fee and request a verifiable random number.
     *         Check getRequiredFee() first and send that amount as msg.value.
     *         Excess MON is refunded automatically.
     */
    function requestDraw() external onlyOwner {
        if (state != State.PrizeDeposited) revert WrongState(state);
        if (drawDeadline == 0) revert DeadlineNotSet();
        if (block.number > drawDeadline) revert DeadlinePassed(block.number, drawDeadline);

        // Generate unique randomnessId from block data + address
        bytes32 randId = keccak256(abi.encodePacked(block.number, block.timestamp, msg.sender, address(this)));

        // minSettlementDelay = 1 — settle after at least 1 block
        switchboard.createRandomness(randId, 1);
        randomnessId = randId;
        state        = State.DrawRequested;

        emit DrawRequested(randomnessId, 0);
    }

    // ── Step 5: Fulfill draw ───────────────────────────────────────────────────

    /**
     * @notice Settle the raffle with the Switchboard oracle response.
     *         Anyone can call this — fully permissionless settlement.
     *
     * Steps to get encodedRandomness:
     *   1. After requestDraw(), note the randomnessId from DrawRequested event
     *   2. Call Crossbar: resolveEVMRandomness(randomnessId)
     *   3. Pass the returned encoded bytes here
     *   4. Send updateFee() worth of MON as msg.value
     *
     * @param encodedRandomness  encoded payload from Switchboard Crossbar
     */
    function fulfillDraw(bytes calldata encodedRandomness) external payable {
        if (state != State.DrawRequested) revert WrongState(state);

        // Get required fee
        uint256 fee = switchboard.updateFee();
        if (msg.value < fee) revert InsufficientFee(msg.value, fee);

        // Settle — Switchboard verifies TEE proof onchain, reverts if invalid
        switchboard.settleRandomness{value: fee}(encodedRandomness);

        // Read verified result
        ISwitchboard.RandomnessData memory data = switchboard.getRandomness(randomnessId);
        if (data.settledAt == 0) revert RandomnessNotResolved();

        // Map result to ticket index [0, totalTickets) then binary search
        winningTicket = data.value % totalTickets;
        address w     = _findWinner(winningTicket);
        winner        = w;
        state         = State.Complete;

        emit DrawComplete(w, winningTicket, totalTickets);

        // Refund excess MON
        uint256 excess = msg.value - fee;
        if (excess > 0) {
            (bool ok,) = msg.sender.call{value: excess}("");
            if (!ok) revert RefundFailed();
        }

        // Transfer prize NFT to winner atomically in same tx
        IERC721(prizeNFT).safeTransferFrom(address(this), w, prizeTokenId);
    }

    // ── Emergency ──────────────────────────────────────────────────────────────

    /**
     * @notice Recover prize NFT if the raffle needs to be cancelled.
     *         Cannot be called after the draw is complete.
     *         Resets to SnapshotLoaded state so a new prize can be deposited.
     */
    function recoverPrize() external onlyOwner {
        require(state != State.Complete, "Raffle already complete");
        require(prizeDeposited, "No prize deposited");

        address nft    = prizeNFT;
        uint256 tid    = prizeTokenId;

        // Clear prize + stale randomness state
        prizeDeposited = false;
        prizeNFT       = address(0);
        prizeTokenId   = 0;
        randomnessId   = bytes32(0);
        drawDeadline   = 0;
        state          = State.SnapshotLoaded;

        emit PrizeRecovered(owner);
        IERC721(nft).safeTransferFrom(address(this), owner, tid);
    }

    // ── Views ──────────────────────────────────────────────────────────────────

    /// @dev Upper-bound binary search on cumTickets array — O(log n)
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

    /**
     * @notice Returns a wallet's ticket range [from, to] inclusive.
     *         Use this to verify a specific wallet's allocation matches the snapshot.
     *         Returns found=false if wallet is not in snapshot (no revert).
     */
    function getWalletTickets(address wallet)
        external view
        returns (uint256 from, uint256 to, bool found)
    {
        for (uint256 i = 0; i < wallets.length; i++) {
            if (wallets[i] == wallet) {
                from  = i == 0 ? 0 : cumTickets[i - 1];
                to    = cumTickets[i] - 1;
                found = true;
                return (from, to, found);
            }
        }
        return (0, 0, false);
    }

    /// @notice Full raffle state in one call — for frontends and explorers
    function getRaffleInfo() external view returns (
        uint256 _totalTickets,
        uint256 _walletCount,
        uint256 _snapshotBlock,
        bytes32 _snapshotHash,
        address _prizeNFT,
        uint256 _prizeTokenId,
        uint256 _drawDeadline,
        State   _state,
        bytes32 _randomnessId,
        address _winner,
        uint256 _winningTicket
    ) {
        return (
            totalTickets,
            wallets.length,
            snapshotBlock,
            snapshotHash,
            prizeNFT,
            prizeTokenId,
            drawDeadline,
            state,
            randomnessId,
            winner,
            winningTicket
        );
    }

    /// @notice Returns Switchboard settlement fee — send this as msg.value to fulfillDraw()
    function getRequiredFee() external view returns (uint256) {
        return switchboard.updateFee();
    }

    receive() external payable {}
}
