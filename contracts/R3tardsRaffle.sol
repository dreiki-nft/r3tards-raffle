// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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
    address public immutable owner;
    ISwitchboard public immutable switchboard;
    address public immutable switchboardAddress;

    uint64 public constant MIN_SETTLEMENT_DELAY = 5;

    address[] public wallets;
    uint256[] public cumTickets;
    uint256   public totalTickets;
    uint256   public snapshotBlock;
    bytes32   public snapshotHash;

    address public prizeNFT;
    uint256 public prizeTokenId;
    bool    public prizeDeposited;
    bool    public prizeClaimed;

    enum State {
        Pending,
        LoadingSnapshot,
        SnapshotLoaded,
        PrizeDeposited,
        DrawRequested,
        Complete
    }

    State public state;

    bytes32 public randomnessId;
    uint256 public drawDeadline;
    address public winner;
    uint256 public winningTicket;

    // Switchboard resolver metadata cached at request time
    address public drawOracle;
    uint256 public drawRollTimestamp;
    uint64  public drawMinSettlementDelay;
    uint256 public drawRequestFee;

    event SnapshotBatchLoaded(uint256 batchSize, uint256 totalWallets, uint256 totalTicketsSoFar);
    event SnapshotFinalized(uint256 walletCount, uint256 totalTickets, uint256 snapshotBlock, bytes32 snapshotHash);
    event PrizeDeposited(address indexed nft, uint256 tokenId);
    event DrawDeadlineSet(uint256 blockNumber);

    event DrawRequested(
        bytes32 indexed randomnessId,
        address indexed oracle,
        uint256 rollTimestamp,
        uint64 minSettlementDelay,
        uint256 switchboardFee
    );

    event DrawComplete(
        address indexed winner,
        uint256 winningTicket,
        uint256 totalTickets,
        bytes32 indexed randomnessId,
        uint256 randomnessValue
    );

    event PrizeClaimed(address indexed winner, address indexed nft, uint256 tokenId);
    event PrizeRecovered(address indexed to);
    event ExcessRefundFailed(address indexed to, uint256 amount);

    error NotOwner();
    error NotWinnerOrOwner();
    error WrongState(State current);
    error InvalidSnapshot();
    error InsufficientFee(uint256 sent, uint256 required);
    error RandomnessNotResolved();
    error DeadlinePassed(uint256 current, uint256 deadline);
    error DeadlineNotSet();
    error PrizeAlreadyClaimed();
    error PrizeNotDeposited();
    error RandomnessIdMismatch(bytes32 expected, bytes32 actual);
    error SettlementFailedString(string reason);
    error SettlementFailedBytes(bytes reason);

    // Testnet:  0x6724818814927e057a693f4e3A172b6cC1eA690C
    // Mainnet:  0xB7F03eee7B9F56347e32cC71DaD65B303D5a0E67
    constructor(address _switchboard) {
        require(_switchboard != address(0), "Invalid Switchboard address");
        owner              = msg.sender;
        switchboard        = ISwitchboard(_switchboard);
        switchboardAddress = _switchboard;
        state              = State.Pending;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyWinnerOrOwner() {
        if (msg.sender != winner && msg.sender != owner) revert NotWinnerOrOwner();
        _;
    }

    function initSnapshot(uint256 _snapshotBlock, bytes32 _snapshotHash) external onlyOwner {
        if (state != State.Pending) revert WrongState(state);

        delete wallets;
        delete cumTickets;

        totalTickets           = 0;
        snapshotBlock          = _snapshotBlock;
        snapshotHash           = _snapshotHash;
        prizeNFT               = address(0);
        prizeTokenId           = 0;
        prizeDeposited         = false;
        prizeClaimed           = false;
        randomnessId           = bytes32(0);
        drawDeadline           = 0;
        winner                 = address(0);
        winningTicket          = 0;
        drawOracle             = address(0);
        drawRollTimestamp      = 0;
        drawMinSettlementDelay = 0;
        drawRequestFee         = 0;

        state = State.LoadingSnapshot;
    }

    function loadTicketsBatch(address[] calldata _wallets, uint256[] calldata _tickets) external onlyOwner {
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

    function finalizeSnapshot() external onlyOwner {
        if (state != State.LoadingSnapshot) revert WrongState(state);
        if (wallets.length == 0 || totalTickets == 0) revert InvalidSnapshot();

        state = State.SnapshotLoaded;
        emit SnapshotFinalized(wallets.length, totalTickets, snapshotBlock, snapshotHash);
    }

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
        prizeClaimed   = false;
        state          = State.PrizeDeposited;

        emit PrizeDeposited(msg.sender, tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }

    function setDrawDeadline(uint256 _deadlineBlock) external onlyOwner {
        if (state != State.PrizeDeposited) revert WrongState(state);
        require(_deadlineBlock > block.number, "Deadline must be in the future");

        drawDeadline = _deadlineBlock;
        emit DrawDeadlineSet(_deadlineBlock);
    }

    function requestDraw() external onlyOwner {
        if (state != State.PrizeDeposited) revert WrongState(state);
        if (drawDeadline == 0) revert DeadlineNotSet();
        if (block.number > drawDeadline) revert DeadlinePassed(block.number, drawDeadline);

        bytes32 randId = keccak256(
            abi.encodePacked(block.number, block.timestamp, msg.sender, address(this))
        );

        address oracle = switchboard.createRandomness(randId, MIN_SETTLEMENT_DELAY);

        randomnessId   = randId;
        drawOracle     = oracle;
        drawRequestFee = 0;
        state          = State.DrawRequested;

        emit DrawRequested(randomnessId, drawOracle, 0, MIN_SETTLEMENT_DELAY, 0);
    }

    // Call this after requestDraw() to cache rollTimestamp and oracle from Switchboard
    function fetchDrawData() external onlyOwner {
        if (state != State.DrawRequested) revert WrongState(state);

        ISwitchboard.RandomnessData memory data = switchboard.getRandomness(randomnessId);

        if (data.oracle != address(0)) drawOracle = data.oracle;
        drawRollTimestamp      = data.rollTimestamp;
        drawMinSettlementDelay = data.minSettlementDelay;
    }

    function fulfillDraw(bytes calldata encodedRandomness) external payable {
        if (state != State.DrawRequested) revert WrongState(state);

        uint256 fee = 0; // fee is 0 on Switchboard Monad

        try switchboard.settleRandomness{value: fee}(encodedRandomness) {
            // settlement succeeded
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

        uint256 excess = msg.value - fee;
        if (excess > 0) {
            (bool ok,) = msg.sender.call{value: excess}("");
            if (!ok) emit ExcessRefundFailed(msg.sender, excess);
        }
    }

    function claimPrize() external onlyWinnerOrOwner {
        if (state != State.Complete) revert WrongState(state);
        if (!prizeDeposited) revert PrizeNotDeposited();
        if (prizeClaimed) revert PrizeAlreadyClaimed();

        prizeClaimed   = true;
        prizeDeposited = false;

        emit PrizeClaimed(winner, prizeNFT, prizeTokenId);
        IERC721(prizeNFT).safeTransferFrom(address(this), winner, prizeTokenId);
    }

    function recoverPrize() external onlyOwner {
        require(state != State.Complete, "Draw already complete");
        if (!prizeDeposited) revert PrizeNotDeposited();

        address nft = prizeNFT;
        uint256 tid = prizeTokenId;

        prizeDeposited         = false;
        prizeClaimed           = false;
        prizeNFT               = address(0);
        prizeTokenId           = 0;
        randomnessId           = bytes32(0);
        drawDeadline           = 0;
        drawOracle             = address(0);
        drawRollTimestamp      = 0;
        drawMinSettlementDelay = 0;
        drawRequestFee         = 0;

        state = State.SnapshotLoaded;

        emit PrizeRecovered(owner);
        IERC721(nft).safeTransferFrom(address(this), owner, tid);
    }

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

    function getResolverParams() external view returns (
        uint256 chainId,
        bytes32 _randomnessId,
        address oracle,
        uint256 rollTimestamp,
        uint64 minSettlementDelay,
        uint256 fee
    ) {
        return (
            block.chainid,
            randomnessId,
            drawOracle,
            drawRollTimestamp,
            drawMinSettlementDelay,
            0 // fee is 0 on Switchboard Monad
        );
    }

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

    function getRaffleInfo() external view returns (
        uint256 _totalTickets,
        uint256 _walletCount,
        uint256 _snapshotBlock,
        bytes32 _snapshotHash,
        address _prizeNFT,
        uint256 _prizeTokenId,
        uint256 _drawDeadline
    ) {
        return (
            totalTickets,
            wallets.length,
            snapshotBlock,
            snapshotHash,
            prizeNFT,
            prizeTokenId,
            drawDeadline
        );
    }

    function getRaffleState() external view returns (
        State _state,
        bytes32 _randomnessId,
        address _winner,
        uint256 _winningTicket,
        bool _prizeDeposited,
        bool _prizeClaimed
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

    function getRequiredFee() external pure returns (uint256) {
        return 0; // fee is 0 on Switchboard Monad
    }

    receive() external payable {}
}
