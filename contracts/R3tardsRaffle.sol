// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title R3tardsRaffle
 * @notice Verifiable onchain raffle for r3tards NFT holders on Monad.
 *         Randomness provided by Switchboard VRF via TEE-secured oracles.
 *
 * Flow:
 *   1. initSnapshot(snapshotBlock, snapshotHash)
 *   2. loadTicketsBatch(wallets[], tickets[])  ← repeat until all loaded
 *   3. finalizeSnapshot()
 *   4. prizeNFT.safeTransferFrom(authorizedWallet, raffleAddress, tokenId)
 *   5. setDrawDeadline(blockNumber)
 *   6. requestDraw()
 *   7. Wait rollTimestamp + minSettlementDelay + buffer
 *   8. node settle-randomness.js <CONTRACT> --network mainnet
 *   9. fulfillDraw(encodedRandomness)
 *  10. claimPrize()
 *
 * Switchboard:
 *   Monad Mainnet (chainId 143):   0xB7F03eee7B9F56347e32cC71DaD65B303D5a0E67
 *   Monad Testnet (chainId 10143): 0x6724818814927e057a693f4e3A172b6cC1eA690C
 */

interface IERC721 {
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
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

    function createRandomness(bytes32 randomnessId, uint64 minSettlementDelay) external returns (address oracle);
    function settleRandomness(bytes calldata encodedRandomness) external payable;
    function getRandomness(bytes32 randomnessId) external view returns (RandomnessData memory);
}

contract R3tardsRaffle is IERC721Receiver {

    // ─── Constants ────────────────────────────────────────────────────────────

    /// @notice Switchboard minimum settlement delay in seconds
    uint64 public constant MIN_SETTLEMENT_DELAY = 5;

    /// @notice Team wallets — cannot deposit prize OR win
    address public constant DEPLOYER           = 0x40Ea55E0b8f02f8eBc9D91e082e202ed988647fA;
    address public constant COMMUNITY_TREASURY = 0xdfC19DD5f80048dF12D7a71cB01226F8ce24a954;
    address public constant ACTIVATION         = 0x18D5346216315667C51D69F346E3C768136F8018;
    address public constant PARTNERS           = 0xf10eD040f182511ef2179AdeA749920881A4eef9;
    address public constant TEAM_LOCK          = 0xec823eAffA4584f482a0d9c3E634840d14066242;

    // ─── Immutables ───────────────────────────────────────────────────────────

    address public immutable owner;
    ISwitchboard public immutable switchboard;
    address public immutable switchboardAddress;

    // ─── Snapshot state ───────────────────────────────────────────────────────

    address[] public wallets;
    uint256[] public cumTickets;
    uint256   public totalTickets;
    uint256   public snapshotBlock;
    bytes32   public snapshotHash;

    // ─── Prize state ──────────────────────────────────────────────────────────

    address public prizeNFT;
    uint256 public prizeTokenId;
    address public prizeDepositor;   // who deposited — NFT returns here on recovery
    bool    public prizeDeposited;
    bool    public prizeClaimed;

    // ─── Draw state ───────────────────────────────────────────────────────────

    enum State { Pending, LoadingSnapshot, SnapshotLoaded, PrizeDeposited, DrawRequested, Complete }
    State public state;

    uint256 private _drawNonce;      // ensures unique randomnessId across retries
    bytes32 public randomnessId;
    uint256 public drawDeadline;
    address public winner;
    uint256 public winningTicket;

    // ─── Events ───────────────────────────────────────────────────────────────

    event SnapshotBatchLoaded(uint256 batchSize, uint256 totalWallets, uint256 totalTicketsSoFar);
    event SnapshotFinalized(uint256 walletCount, uint256 totalTickets, uint256 snapshotBlock, bytes32 snapshotHash);
    event PrizeDeposited(address indexed depositor, address indexed nft, uint256 tokenId);
    event DrawDeadlineSet(uint256 blockNumber);
    event DrawRequested(bytes32 indexed randomnessId, uint64 minSettlementDelay);
    event DrawComplete(address indexed winner, uint256 winningTicket, uint256 totalTickets, bytes32 indexed randomnessId, uint256 randomnessValue);
    event PrizeClaimed(address indexed winner, address indexed nft, uint256 tokenId);
    event PrizeRecovered(address indexed to, address indexed nft, uint256 tokenId);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error NotOwner();
    error NotWinnerOrOwner();
    error WrongState(State current);
    error InvalidSnapshot();
    error RandomnessNotResolved();
    error DeadlinePassed(uint256 current, uint256 deadline);
    error DeadlineNotSet();
    error PrizeAlreadyClaimed();
    error PrizeNotDeposited();
    error RandomnessIdMismatch(bytes32 expected, bytes32 actual);
    error SettlementFailedString(string reason);
    error SettlementFailedBytes(bytes reason);
    error NoEligibleWinner();
    error ZeroTicketEntry();

    // ─── Constructor ──────────────────────────────────────────────────────────

    constructor(address _switchboard) {
        require(_switchboard != address(0), "Invalid Switchboard address");
        owner              = msg.sender;
        switchboard        = ISwitchboard(_switchboard);
        switchboardAddress = _switchboard;
        state              = State.Pending;
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

    /// @dev Returns true if addr is a team wallet (authorized depositor AND winner blacklist)
    function _isTeamWallet(address addr) internal pure returns (bool) {
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
        randomnessId   = bytes32(0);
        drawDeadline   = 0;
        winner         = address(0);
        winningTicket  = 0;
        // _drawNonce intentionally NOT reset — prevents randomnessId reuse across raffles

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

    /**
     * @notice Triggered automatically when a team wallet sends the prize NFT here.
     *         Call: prizeNFT.safeTransferFrom(teamWallet, raffleAddress, tokenId)
     *         Only team wallets (DEPLOYER, COMMUNITY_TREASURY, ACTIVATION, PARTNERS, TEAM_LOCK)
     *         are authorized to deposit.
     */
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

    function requestDraw() external onlyOwner {
        if (state != State.PrizeDeposited) revert WrongState(state);
        if (drawDeadline == 0) revert DeadlineNotSet();
        if (block.number > drawDeadline) revert DeadlinePassed(block.number, drawDeadline);

        bytes32 randId = keccak256(
            abi.encodePacked(block.number, block.timestamp, msg.sender, address(this), _drawNonce++)
        );

        switchboard.createRandomness(randId, MIN_SETTLEMENT_DELAY);

        randomnessId = randId;
        state        = State.DrawRequested;

        emit DrawRequested(randId, MIN_SETTLEMENT_DELAY);
    }

    // ─── Step 5: Fulfill draw ─────────────────────────────────────────────────

    /**
     * @notice Settle the raffle with the Switchboard oracle response.
     *         Anyone can call this — permissionless settlement.
     *         Get encodedRandomness by running: node settle-randomness.js <CONTRACT> --network mainnet
     */
    function fulfillDraw(bytes calldata encodedRandomness) external {
        if (state != State.DrawRequested) revert WrongState(state);

        try switchboard.settleRandomness(encodedRandomness) {
            // settled
        } catch Error(string memory reason) {
            revert SettlementFailedString(reason);
        } catch (bytes memory reason) {
            revert SettlementFailedBytes(reason);
        }

        ISwitchboard.RandomnessData memory data = switchboard.getRandomness(randomnessId);

        if (data.randId != randomnessId) revert RandomnessIdMismatch(randomnessId, data.randId);
        if (data.settledAt == 0) revert RandomnessNotResolved();
        if (totalTickets == 0) revert InvalidSnapshot();

        winningTicket = data.value % totalTickets;
        winner        = _findWinner(winningTicket);
        state         = State.Complete;

        emit DrawComplete(winner, winningTicket, totalTickets, randomnessId, data.value);
    }

    // ─── Step 6: Claim prize ──────────────────────────────────────────────────

    /// @notice Winner or owner triggers NFT transfer to winner.
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

    /// @notice Recover prize NFT if raffle needs to be cancelled.
    ///         Returns NFT to original depositor. Resets to SnapshotLoaded state.
    function recoverPrize() external onlyOwner {
        if (state == State.Complete) revert WrongState(state);
        if (!prizeDeposited) revert PrizeNotDeposited();

        address nft       = prizeNFT;
        uint256 tid       = prizeTokenId;
        address depositor = prizeDepositor;

        prizeDeposited = false;
        prizeClaimed   = false;
        prizeNFT       = address(0);
        prizeTokenId   = 0;
        prizeDepositor = address(0);
        randomnessId   = bytes32(0);
        drawDeadline   = 0;

        state = State.SnapshotLoaded;

        emit PrizeRecovered(depositor, nft, tid);
        IERC721(nft).safeTransferFrom(address(this), depositor, tid);
    }

    // ─── Internal ─────────────────────────────────────────────────────────────

    /// @dev Binary search + blacklist skip. If draw lands on a team wallet,
    ///      walks forward to next eligible holder.
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

    /// @notice Returns Switchboard resolver params needed for Crossbar.
    ///         Call after requestDraw() to get oracle, rollTimestamp, minSettlementDelay.
    function getResolverParams() external view returns (
        uint256 chainId,
        bytes32 _randomnessId,
        address oracle,
        uint256 rollTimestamp,
        uint64  minSettlementDelay,
        uint256 fee
    ) {
        ISwitchboard.RandomnessData memory data = switchboard.getRandomness(randomnessId);
        return (
            block.chainid,
            randomnessId,
            data.oracle,
            data.rollTimestamp,
            data.minSettlementDelay,
            0 // fee is 0 on Switchboard Monad
        );
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
        bytes32 _randomnessId,
        address _winner,
        uint256 _winningTicket,
        bool    _prizeDeposited,
        bool    _prizeClaimed
    ) {
        return (
            state,
            randomnessId,
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

    /// @notice Fee is always 0 on Switchboard Monad
    function getRequiredFee() external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}
