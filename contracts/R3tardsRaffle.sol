// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title R3tardsRaffle
 * @notice Verifiable onchain raffle for r3tards NFT holders on Monad.
 *         Randomness provided by Pyth Entropy via callback pattern.
 *
 * Flow:
 *   1. initSnapshot(snapshotBlock, snapshotHash)
 *   2. loadTicketsBatch(wallets[], tickets[])  ← repeat until all loaded
 *   3. finalizeSnapshot()
 *   4. prizeNFT.safeTransferFrom(authorizedWallet, raffleAddress, tokenId)
 *   5. setDrawDeadline(blockNumber)
 *   6. requestDraw()  — pays Pyth Entropy fee in MON, send getDrawFee() as msg.value
 *   7. Wait for Pyth oracle callback (automatic, usually within a few blocks)
 *   8. claimPrize()  — winner or owner triggers NFT transfer
 *
 * Pyth Entropy on Monad Mainnet:
 *   Entropy contract: 0xD458261E832415CFd3BAE5E416FdF3230ce6F134
 *   Default provider: 0x52DeaA1c84233F7bb8C8A45baeDE41091c616506
 */

interface IERC721 {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

interface IEntropy {
    function requestWithCallback(
        address provider,
        bytes32 userRandomNumber
    ) external payable returns (uint64 sequenceNumber);
}

interface IEntropyConsumer {
    // Called by Pyth Entropy contract with the random number
    // Must be internal in implementing contracts
    function _entropyCallback(
        uint64 sequenceNumber,
        address provider,
        bytes32 randomNumber
    ) external;

    // Must return the Entropy contract address
    function getEntropy() external view returns (address);
}

contract R3tardsRaffle is IERC721Receiver, IEntropyConsumer {

    // ─── Constants ────────────────────────────────────────────────────────────

    /// @notice Pyth Entropy contract on Monad Mainnet
    address public constant ENTROPY_CONTRACT = 0xD458261E832415CFd3BAE5E416FdF3230ce6F134;

    /// @notice Pyth default provider on Monad Mainnet
    address public constant ENTROPY_PROVIDER = 0x52DeaA1c84233F7bb8C8A45baeDE41091c616506;

    /// @notice Gas limit for Pyth callback — covers _findWinner loop for large snapshots
    uint32 public constant CALLBACK_GAS_LIMIT = 500_000;
    address public constant DEPLOYER           = 0x40Ea55E0b8f02f8eBc9D91e082e202ed988647fA;
    address public constant COMMUNITY_TREASURY = 0xdfC19DD5f80048dF12D7a71cB01226F8ce24a954;
    address public constant ACTIVATION         = 0x18D5346216315667C51D69F346E3C768136F8018;
    address public constant PARTNERS           = 0xf10eD040f182511ef2179AdeA749920881A4eef9;
    address public constant TEAM_LOCK          = 0xec823eAffA4584f482a0d9c3E634840d14066242;

    // ─── Immutables ───────────────────────────────────────────────────────────

    address public immutable owner;
    IEntropy public immutable entropy;

    // ─── Snapshot state ───────────────────────────────────────────────────────

    address[] public wallets;
    uint256[] public cumTickets;
    uint256   public totalTickets;
    uint256   public snapshotBlock;
    bytes32   public snapshotHash;

    // ─── Prize state ──────────────────────────────────────────────────────────

    address public prizeNFT;
    uint256 public prizeTokenId;
    address public prizeDepositor;
    bool    public prizeDeposited;
    bool    public prizeClaimed;

    // ─── Draw state ───────────────────────────────────────────────────────────

    enum State { Pending, LoadingSnapshot, SnapshotLoaded, PrizeDeposited, DrawRequested, RandomnessReceived, Complete }
    State public state;

    uint64  public sequenceNumber;
    bytes32 public rawRandomNumber;  // stored by callback, used by fulfillDraw
    uint256 public drawDeadline;
    address public winner;
    uint256 public winningTicket;

    // ─── Events ───────────────────────────────────────────────────────────────

    event SnapshotBatchLoaded(uint256 batchSize, uint256 totalWallets, uint256 totalTicketsSoFar);
    event SnapshotFinalized(uint256 walletCount, uint256 totalTickets, uint256 snapshotBlock, bytes32 snapshotHash);
    event PrizeDeposited(address indexed depositor, address indexed nft, uint256 tokenId);
    event DrawDeadlineSet(uint256 blockNumber);
    event DrawRequested(uint64 indexed sequenceNumber, bytes32 userRandomNumber, uint256 feePaid);
    event DrawComplete(address indexed winner, uint256 winningTicket, uint256 totalTickets, bytes32 randomNumber);
    event PrizeClaimed(address indexed winner, address indexed nft, uint256 tokenId);
    event PrizeRecovered(address indexed to, address indexed nft, uint256 tokenId);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error NotOwner();
    error NotWinnerOrOwner();
    error NotEntropyContract();
    error WrongState(State current);
    error InvalidSnapshot();
    error RandomnessNotResolved();
    error DeadlinePassed(uint256 current, uint256 deadline);
    error DeadlineNotSet();
    error PrizeAlreadyClaimed();
    error PrizeNotDeposited();
    error NoEligibleWinner();
    error NotAuthorizedDepositor();
    error ZeroTicketEntry();

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor() {
        owner   = msg.sender;
        entropy = IEntropy(ENTROPY_CONTRACT);
        state   = State.Pending;
    }

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyWinnerOrOwner() {
        if (msg.sender != winner && msg.sender != owner) revert NotWinnerOrOwner();
        _;
    }

    // ─── Internal helpers ─────────────────────────────────────────────────────

    function _isTeamWallet(address addr) public pure returns (bool) {
        return addr == DEPLOYER
            || addr == COMMUNITY_TREASURY
            || addr == ACTIVATION
            || addr == PARTNERS
            || addr == TEAM_LOCK;
    }

    // ─── Step 1a: Init snapshot ───────────────────────────────────────────────

    function initSnapshot(uint256 _snapshotBlock, bytes32 _snapshotHash) external onlyOwner {
        if (state != State.Pending) revert WrongState(state);

        delete wallets;
        delete cumTickets;

        totalTickets   = 0;
        snapshotBlock  = _snapshotBlock;
        snapshotHash   = _snapshotHash;
        prizeNFT       = address(0);
        prizeTokenId   = 0;
        prizeDepositor = address(0);
        prizeDeposited = false;
        prizeClaimed   = false;
        sequenceNumber = 0;
        drawDeadline   = 0;
        winner         = address(0);
        winningTicket  = 0;

        state = State.LoadingSnapshot;
    }

    // ─── Step 1b: Load batches ────────────────────────────────────────────────

    function loadTicketsBatch(address[] calldata _wallets, uint256[] calldata _tickets) external onlyOwner {
        if (state != State.LoadingSnapshot) revert WrongState(state);
        if (_wallets.length == 0 || _wallets.length != _tickets.length) revert InvalidSnapshot();

        uint256 cumulative = totalTickets;
        for (uint256 i = 0; i < _wallets.length; i++) {
            if (_tickets[i] == 0) revert ZeroTicketEntry();
            wallets.push(_wallets[i]);
            cumulative += _tickets[i];
            cumTickets.push(cumulative);
        }

        totalTickets = cumulative;
        emit SnapshotBatchLoaded(_wallets.length, wallets.length, totalTickets);
    }

    // ─── Step 1c: Finalize snapshot ───────────────────────────────────────────

    function finalizeSnapshot() external onlyOwner {
        if (state != State.LoadingSnapshot) revert WrongState(state);
        if (wallets.length == 0 || totalTickets == 0) revert InvalidSnapshot();

        state = State.SnapshotLoaded;
        emit SnapshotFinalized(wallets.length, totalTickets, snapshotBlock, snapshotHash);
    }

    // ─── Step 2: Deposit prize NFT ────────────────────────────────────────────

    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata
    ) external override returns (bytes4) {
        if (!_isTeamWallet(from)) revert NotAuthorizedDepositor();
        if (state != State.SnapshotLoaded) revert WrongState(state);

        prizeNFT       = msg.sender;
        prizeTokenId   = tokenId;
        prizeDepositor = from;
        prizeDeposited = true;
        prizeClaimed   = false;
        state          = State.PrizeDeposited;

        emit PrizeDeposited(from, msg.sender, tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }

    // ─── Step 3: Set draw deadline ────────────────────────────────────────────

    function setDrawDeadline(uint256 _deadlineBlock) external onlyOwner {
        if (state != State.PrizeDeposited) revert WrongState(state);
        if (_deadlineBlock <= block.number) revert DeadlinePassed(block.number, _deadlineBlock);

        drawDeadline = _deadlineBlock;
        emit DrawDeadlineSet(_deadlineBlock);
    }

    // ─── Step 4: Request randomness ───────────────────────────────────────────

    /**
     * @notice Request randomness from Pyth Entropy. Send getDrawFee() as msg.value.
     * @param userRandomNumber A random bytes32 you generate off-chain for added entropy.
     *        Use: ethers.randomBytes(32) or any random hex bytes32.
     */
    function requestDraw(bytes32 userRandomNumber) external payable onlyOwner {
        if (state != State.PrizeDeposited) revert WrongState(state);
        if (drawDeadline == 0) revert DeadlineNotSet();
        if (block.number > drawDeadline) revert DeadlinePassed(block.number, drawDeadline);

        uint64 seq = entropy.requestWithCallback{value: msg.value}(ENTROPY_PROVIDER, userRandomNumber);

        sequenceNumber = seq;
        state          = State.DrawRequested;

        emit DrawRequested(seq, userRandomNumber, msg.value);
    }

    // ─── Pyth required ────────────────────────────────────────────────────────

    function getEntropy() external pure override returns (address) {
        return ENTROPY_CONTRACT;
    }

    // ─── Step 5a: Pyth callback — just stores randomness (cheap) ─────────────

    /**
     * @notice Called automatically by Pyth oracle. Stores the random number onchain.
     *         Intentionally cheap — winner selection happens in fulfillDraw().
     */
    function _entropyCallback(
        uint64 _sequenceNumber,
        address, /* provider */
        bytes32 randomNumber
    ) external override {
        if (msg.sender != ENTROPY_CONTRACT) revert NotEntropyContract();
        if (state != State.DrawRequested) revert WrongState(state);
        if (_sequenceNumber != sequenceNumber) revert RandomnessNotResolved();

        rawRandomNumber = randomNumber;
        state           = State.RandomnessReceived;

        emit DrawComplete(address(0), 0, totalTickets, randomNumber);
    }

    // ─── Step 5b: fulfillDraw — picks winner from stored randomness ───────────

    /**
     * @notice Call this after the Pyth callback fires (state = RandomnessReceived).
     *         Runs _findWinner and sets the winner. Anyone can call.
     */
    function fulfillDraw() external {
        if (state != State.RandomnessReceived) revert WrongState(state);
        if (totalTickets == 0) revert InvalidSnapshot();

        winningTicket = uint256(rawRandomNumber) % totalTickets;
        winner        = _findWinner(winningTicket);
        state         = State.Complete;

        emit DrawComplete(winner, winningTicket, totalTickets, rawRandomNumber);
    }

    // ─── Step 6: Claim prize ──────────────────────────────────────────────────

    function claimPrize() external onlyWinnerOrOwner {
        if (state != State.Complete) revert WrongState(state);
        if (!prizeDeposited) revert PrizeNotDeposited();
        if (prizeClaimed) revert PrizeAlreadyClaimed();

        prizeClaimed   = true;
        prizeDeposited = false;

        emit PrizeClaimed(winner, prizeNFT, prizeTokenId);
        IERC721(prizeNFT).safeTransferFrom(address(this), winner, prizeTokenId);
    }

    // ─── Emergency ────────────────────────────────────────────────────────────

    function recoverPrize() external onlyOwner {
        if (state == State.Complete) revert WrongState(state);
        if (!prizeDeposited) revert PrizeNotDeposited();

        address nft       = prizeNFT;
        uint256 tid       = prizeTokenId;
        address depositor = prizeDepositor;

        prizeDeposited  = false;
        prizeClaimed    = false;
        prizeNFT        = address(0);
        prizeTokenId    = 0;
        prizeDepositor  = address(0);
        sequenceNumber  = 0;
        rawRandomNumber = bytes32(0);
        drawDeadline    = 0;

        state = State.SnapshotLoaded;

        emit PrizeRecovered(depositor, nft, tid);
        IERC721(nft).safeTransferFrom(address(this), depositor, tid);
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

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

        uint256 len = wallets.length;
        for (uint256 i = 0; i < len; i++) {
            uint256 idx = (lo + i) % len;
            if (!_isTeamWallet(wallets[idx])) {
                return wallets[idx];
            }
        }

        revert NoEligibleWinner();
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    /// @notice Returns recommended MON fee for requestDraw(). Send this as msg.value.
    ///         Based on empirical testing — 0.6 MON worked on Monad mainnet.
    function getDrawFee() external pure returns (uint256) {
        return 0.6 ether;
    }

    /// @notice Snapshot + prize + deadline info
    function getRaffleInfo() external view returns (
        uint256 _totalTickets,
        uint256 _walletCount,
        uint256 _snapshotBlock,
        bytes32 _snapshotHash,
        address _prizeNFT,
        uint256 _prizeTokenId,
        address _prizeDepositor,
        uint256 _drawDeadline
    ) {
        return (
            totalTickets,
            wallets.length,
            snapshotBlock,
            snapshotHash,
            prizeNFT,
            prizeTokenId,
            prizeDepositor,
            drawDeadline
        );
    }

    /// @notice Draw + winner state
    function getRaffleState() external view returns (
        State   _state,
        uint64  _sequenceNumber,
        bytes32 _rawRandomNumber,
        address _winner,
        uint256 _winningTicket,
        bool    _prizeDeposited,
        bool    _prizeClaimed
    ) {
        return (
            state,
            sequenceNumber,
            rawRandomNumber,
            winner,
            winningTicket,
            prizeDeposited,
            prizeClaimed
        );
    }

    /// @notice Returns a wallet's ticket range [from, to] inclusive.
    function getWalletTickets(address wallet) external view returns (uint256 from, uint256 to, bool found) {
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

    receive() external payable {}
}
