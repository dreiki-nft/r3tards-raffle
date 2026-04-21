// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/R3tardsRaffle.sol";

// ─── Mock NFT ─────────────────────────────────────────────────────────────────
contract MockNFT {
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    function mint(address to, uint256 tokenId) external {
        ownerOf[tokenId] = to;
        emit Transfer(address(0), to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "not owner");
        ownerOf[tokenId] = to;
        emit Transfer(from, to, tokenId);
        // call onERC721Received if to is a contract
        if (to.code.length > 0) {
            bytes4 ret = IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, "");
            require(ret == IERC721Receiver.onERC721Received.selector, "bad receiver");
        }
    }
}

interface IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4);
}

// ─── Mock Entropy ─────────────────────────────────────────────────────────────
contract MockEntropy {
    uint64 private _seq;

    function requestWithCallback(address, bytes32) external payable returns (uint64) {
        return ++_seq;
    }

    // simulate Pyth calling back the raffle
    function simulateCallback(address raffle, uint64 seq, bytes32 randomNumber) external {
        R3tardsRaffle(payable(raffle))._entropyCallback(seq, address(this), randomNumber);
    }
}

// ─── Test contract ────────────────────────────────────────────────────────────
contract R3tardsRaffleTest is Test {

    R3tardsRaffle raffle;
    MockNFT       nft;
    MockEntropy   mockEntropy;

    // Team wallets from contract constants
    address constant DEPLOYER           = 0x40Ea55E0b8f02f8eBc9D91e082e202ed988647fA;
    address constant COMMUNITY_TREASURY = 0xdfC19DD5f80048dF12D7a71cB01226F8ce24a954;
    address constant ACTIVATION         = 0x18D5346216315667C51D69F346E3C768136F8018;
    address constant PARTNERS           = 0xf10eD040f182511ef2179AdeA749920881A4eef9;
    address constant TEAM_LOCK          = 0xec823eAffA4584f482a0d9c3E634840d14066242;

    // Test participants (non-team wallets)
    address constant ALICE   = address(0xA11CE);
    address constant BOB     = address(0xB0B);
    address constant CHARLIE = address(0xC4A111E);

    address constant ENTROPY_CONTRACT = 0xD458261E832415CFd3BAE5E416FdF3230ce6F134;
    address constant ENTROPY_PROVIDER = 0x52DeaA1c84233F7bb8C8A45baeDE41091c616506;

    uint256 constant PRIZE_TOKEN_ID = 42;

    function setUp() public {
        // Deploy raffle as DEPLOYER (owner)
        vm.prank(DEPLOYER);
        raffle = new R3tardsRaffle();

        // Deploy mocks
        nft         = new MockNFT();
        mockEntropy = new MockEntropy();

        // Mint prize NFT to DEPLOYER
        nft.mint(DEPLOYER, PRIZE_TOKEN_ID);

        // Override ENTROPY_CONTRACT with mock using vm.etch
        // Copy mock bytecode to the expected entropy address
        vm.etch(ENTROPY_CONTRACT, address(mockEntropy).code);

        // Fund DEPLOYER with MON for fees
        vm.deal(DEPLOYER, 10 ether);
    }

    // ─── Helper ───────────────────────────────────────────────────────────────

    function _setupSnapshot(address[] memory walletList, uint256[] memory tickets) internal {
        vm.startPrank(DEPLOYER);
        raffle.initSnapshot(block.number, keccak256("test"));
        raffle.loadTicketsBatch(walletList, tickets);
        raffle.finalizeSnapshot();
        vm.stopPrank();
    }

    function _depositPrize() internal {
        vm.prank(DEPLOYER);
        nft.safeTransferFrom(DEPLOYER, address(raffle), PRIZE_TOKEN_ID);
    }

    function _setupFullRaffle() internal returns (uint64 seq) {
        address[] memory walletList = new address[](3);
        walletList[0] = ALICE;
        walletList[1] = BOB;
        walletList[2] = CHARLIE;

        uint256[] memory tickets = new uint256[](3);
        tickets[0] = 3;
        tickets[1] = 3;
        tickets[2] = 3;

        _setupSnapshot(walletList, tickets);
        _depositPrize();

        vm.startPrank(DEPLOYER);
        raffle.setDrawDeadline(block.number + 100);
        seq = raffle.requestDraw{value: 0.6 ether}(keccak256("random"));
        vm.stopPrank();
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    function test_constructor_setsOwner() public view {
        assertEq(raffle.owner(), DEPLOYER);
    }

    function test_constructor_stateIsPending() public view {
        assertEq(uint8(raffle.state()), 0); // Pending
    }

    function test_constructor_entropyAddressSet() public view {
        assertEq(raffle.getEntropy(), ENTROPY_CONTRACT);
    }

    // ─── initSnapshot ─────────────────────────────────────────────────────────

    function test_initSnapshot_succeeds() public {
        vm.prank(DEPLOYER);
        raffle.initSnapshot(100, keccak256("hash"));
        assertEq(uint8(raffle.state()), 1); // LoadingSnapshot
        assertEq(raffle.snapshotBlock(), 100);
    }

    function test_initSnapshot_revertsIfNotOwner() public {
        vm.prank(ALICE);
        vm.expectRevert(R3tardsRaffle.NotOwner.selector);
        raffle.initSnapshot(100, keccak256("hash"));
    }

    function test_initSnapshot_revertsIfNotPending() public {
        vm.startPrank(DEPLOYER);
        raffle.initSnapshot(100, keccak256("hash"));
        vm.expectRevert();
        raffle.initSnapshot(200, keccak256("hash2"));
        vm.stopPrank();
    }

    // ─── loadTicketsBatch ─────────────────────────────────────────────────────

    function test_loadTicketsBatch_succeeds() public {
        vm.prank(DEPLOYER);
        raffle.initSnapshot(100, keccak256("hash"));

        address[] memory walletList = new address[](2);
        walletList[0] = ALICE;
        walletList[1] = BOB;

        uint256[] memory tickets = new uint256[](2);
        tickets[0] = 5;
        tickets[1] = 3;

        vm.prank(DEPLOYER);
        raffle.loadTicketsBatch(walletList, tickets);
        assertEq(raffle.totalTickets(), 8);
    }

    function test_loadTicketsBatch_revertsIfNotOwner() public {
        vm.prank(DEPLOYER);
        raffle.initSnapshot(100, keccak256("hash"));

        address[] memory walletList = new address[](1);
        walletList[0] = ALICE;
        uint256[] memory tickets = new uint256[](1);
        tickets[0] = 1;

        vm.prank(ALICE);
        vm.expectRevert(R3tardsRaffle.NotOwner.selector);
        raffle.loadTicketsBatch(walletList, tickets);
    }

    function test_loadTicketsBatch_revertsOnZeroTickets() public {
        vm.prank(DEPLOYER);
        raffle.initSnapshot(100, keccak256("hash"));

        address[] memory walletList = new address[](1);
        walletList[0] = ALICE;
        uint256[] memory tickets = new uint256[](1);
        tickets[0] = 0;

        vm.prank(DEPLOYER);
        vm.expectRevert(R3tardsRaffle.ZeroTicketEntry.selector);
        raffle.loadTicketsBatch(walletList, tickets);
    }

    function test_loadTicketsBatch_revertsOnLengthMismatch() public {
        vm.prank(DEPLOYER);
        raffle.initSnapshot(100, keccak256("hash"));

        address[] memory walletList = new address[](2);
        walletList[0] = ALICE;
        walletList[1] = BOB;
        uint256[] memory tickets = new uint256[](1);
        tickets[0] = 1;

        vm.prank(DEPLOYER);
        vm.expectRevert(R3tardsRaffle.InvalidSnapshot.selector);
        raffle.loadTicketsBatch(walletList, tickets);
    }

    // ─── finalizeSnapshot ─────────────────────────────────────────────────────

    function test_finalizeSnapshot_succeeds() public {
        address[] memory walletList = new address[](1);
        walletList[0] = ALICE;
        uint256[] memory tickets = new uint256[](1);
        tickets[0] = 1;

        vm.startPrank(DEPLOYER);
        raffle.initSnapshot(100, keccak256("hash"));
        raffle.loadTicketsBatch(walletList, tickets);
        raffle.finalizeSnapshot();
        vm.stopPrank();

        assertEq(uint8(raffle.state()), 2); // SnapshotLoaded
    }

    function test_finalizeSnapshot_revertsIfEmpty() public {
        vm.startPrank(DEPLOYER);
        raffle.initSnapshot(100, keccak256("hash"));
        vm.expectRevert(R3tardsRaffle.InvalidSnapshot.selector);
        raffle.finalizeSnapshot();
        vm.stopPrank();
    }

    // ─── onERC721Received (prize deposit) ─────────────────────────────────────

    function test_prizeDeposit_succeeds() public {
        address[] memory walletList = new address[](1);
        walletList[0] = ALICE;
        uint256[] memory tickets = new uint256[](1);
        tickets[0] = 1;

        _setupSnapshot(walletList, tickets);
        _depositPrize();

        assertEq(uint8(raffle.state()), 3); // PrizeDeposited
        assertTrue(raffle.prizeDeposited());
        assertEq(raffle.prizeTokenId(), PRIZE_TOKEN_ID);
        assertEq(raffle.prizeDepositor(), DEPLOYER);
    }

    function test_prizeDeposit_revertsIfNotTeamWallet() public {
        address[] memory walletList = new address[](1);
        walletList[0] = ALICE;
        uint256[] memory tickets = new uint256[](1);
        tickets[0] = 1;
        _setupSnapshot(walletList, tickets);

        nft.mint(ALICE, 999);
        vm.prank(ALICE);
        vm.expectRevert(R3tardsRaffle.NotAuthorizedDepositor.selector);
        nft.safeTransferFrom(ALICE, address(raffle), 999);
    }

    function test_prizeDeposit_allTeamWalletsAuthorized() public {
        address[] memory teamWallets = new address[](5);
        teamWallets[0] = DEPLOYER;
        teamWallets[1] = COMMUNITY_TREASURY;
        teamWallets[2] = ACTIVATION;
        teamWallets[3] = PARTNERS;
        teamWallets[4] = TEAM_LOCK;

        for (uint256 i = 0; i < teamWallets.length; i++) {
            // Fresh raffle for each
            vm.prank(DEPLOYER);
            R3tardsRaffle freshRaffle = new R3tardsRaffle();
            vm.etch(ENTROPY_CONTRACT, address(mockEntropy).code);

            address[] memory walletList = new address[](1);
            walletList[0] = ALICE;
            uint256[] memory tickets = new uint256[](1);
            tickets[0] = 1;

            vm.startPrank(DEPLOYER);
            freshRaffle.initSnapshot(100, keccak256("hash"));
            freshRaffle.loadTicketsBatch(walletList, tickets);
            freshRaffle.finalizeSnapshot();
            vm.stopPrank();

            uint256 tid = 100 + i;
            nft.mint(teamWallets[i], tid);
            vm.prank(teamWallets[i]);
            nft.safeTransferFrom(teamWallets[i], address(freshRaffle), tid);
            assertEq(uint8(freshRaffle.state()), 3); // PrizeDeposited
        }
    }

    // ─── setDrawDeadline ──────────────────────────────────────────────────────

    function test_setDrawDeadline_succeeds() public {
        address[] memory walletList = new address[](1);
        walletList[0] = ALICE;
        uint256[] memory tickets = new uint256[](1);
        tickets[0] = 1;
        _setupSnapshot(walletList, tickets);
        _depositPrize();

        vm.prank(DEPLOYER);
        raffle.setDrawDeadline(block.number + 100);
        assertEq(raffle.drawDeadline(), block.number + 100);
    }

    function test_setDrawDeadline_revertsIfPast() public {
        address[] memory walletList = new address[](1);
        walletList[0] = ALICE;
        uint256[] memory tickets = new uint256[](1);
        tickets[0] = 1;
        _setupSnapshot(walletList, tickets);
        _depositPrize();

        vm.prank(DEPLOYER);
        vm.expectRevert();
        raffle.setDrawDeadline(block.number - 1);
    }

    // ─── requestDraw ──────────────────────────────────────────────────────────

    function test_requestDraw_succeeds() public {
        _setupFullRaffle();
        assertEq(uint8(raffle.state()), 4); // DrawRequested
        assertEq(raffle.sequenceNumber(), 1);
    }

    function test_requestDraw_revertsIfNotOwner() public {
        address[] memory walletList = new address[](1);
        walletList[0] = ALICE;
        uint256[] memory tickets = new uint256[](1);
        tickets[0] = 1;
        _setupSnapshot(walletList, tickets);
        _depositPrize();

        vm.prank(DEPLOYER);
        raffle.setDrawDeadline(block.number + 100);

        vm.prank(ALICE);
        vm.expectRevert(R3tardsRaffle.NotOwner.selector);
        raffle.requestDraw{value: 0.6 ether}(keccak256("random"));
    }

    function test_requestDraw_revertsIfDeadlinePassed() public {
        address[] memory walletList = new address[](1);
        walletList[0] = ALICE;
        uint256[] memory tickets = new uint256[](1);
        tickets[0] = 1;
        _setupSnapshot(walletList, tickets);
        _depositPrize();

        vm.prank(DEPLOYER);
        raffle.setDrawDeadline(block.number + 1);

        vm.roll(block.number + 100);

        vm.prank(DEPLOYER);
        vm.expectRevert();
        raffle.requestDraw{value: 0.6 ether}(keccak256("random"));
    }

    // ─── _entropyCallback ─────────────────────────────────────────────────────

    function test_entropyCallback_storesRandomness() public {
        _setupFullRaffle();

        vm.prank(ENTROPY_CONTRACT);
        raffle._entropyCallback(1, ENTROPY_PROVIDER, keccak256("randomness"));

        assertEq(uint8(raffle.state()), 5); // RandomnessReceived
        assertEq(raffle.rawRandomNumber(), keccak256("randomness"));
    }

    function test_entropyCallback_revertsIfNotEntropyContract() public {
        _setupFullRaffle();

        vm.prank(ALICE);
        vm.expectRevert(R3tardsRaffle.NotEntropyContract.selector);
        raffle._entropyCallback(1, ENTROPY_PROVIDER, keccak256("randomness"));
    }

    function test_entropyCallback_revertsIfWrongSequenceNumber() public {
        _setupFullRaffle();

        vm.prank(ENTROPY_CONTRACT);
        vm.expectRevert(R3tardsRaffle.RandomnessNotResolved.selector);
        raffle._entropyCallback(999, ENTROPY_PROVIDER, keccak256("randomness"));
    }

    // ─── fulfillDraw ──────────────────────────────────────────────────────────

    function test_fulfillDraw_picksWinner() public {
        _setupFullRaffle();

        vm.prank(ENTROPY_CONTRACT);
        raffle._entropyCallback(1, ENTROPY_PROVIDER, keccak256("randomness"));

        raffle.fulfillDraw();

        assertEq(uint8(raffle.state()), 6); // Complete
        assertTrue(raffle.winner() != address(0));
        assertTrue(!raffle.isTeamWallet(raffle.winner())); // winner is not a team wallet -- exposed for test
    }

    function test_fulfillDraw_revertsIfWrongState() public {
        _setupFullRaffle();
        // State is DrawRequested, not RandomnessReceived
        vm.expectRevert();
        raffle.fulfillDraw();
    }

    function test_fulfillDraw_canBeCalledByAnyone() public {
        _setupFullRaffle();

        vm.prank(ENTROPY_CONTRACT);
        raffle._entropyCallback(1, ENTROPY_PROVIDER, keccak256("randomness"));

        vm.prank(CHARLIE); // random person calls fulfillDraw
        raffle.fulfillDraw();
        assertEq(uint8(raffle.state()), 6); // Complete
    }

    // ─── Winner blacklist ─────────────────────────────────────────────────────

    function test_teamWalletCannotWin() public {
        // Load only team wallets + one regular wallet
        address[] memory walletList = new address[](2);
        walletList[0] = DEPLOYER;   // blacklisted
        walletList[1] = ALICE;      // eligible

        uint256[] memory tickets = new uint256[](2);
        tickets[0] = 1;
        tickets[1] = 1;

        _setupSnapshot(walletList, tickets);
        _depositPrize();

        vm.startPrank(DEPLOYER);
        raffle.setDrawDeadline(block.number + 100);
        raffle.requestDraw{value: 0.6 ether}(keccak256("random"));
        vm.stopPrank();

        // Use a random number that would land on DEPLOYER's ticket (ticket 0)
        // ticketIndex = uint256(randomness) % 2 = 0 → DEPLOYER
        // But blacklist walk should skip to ALICE
        bytes32 randomness = bytes32(uint256(0)); // 0 % 2 = 0 → DEPLOYER's ticket
        vm.prank(ENTROPY_CONTRACT);
        raffle._entropyCallback(1, ENTROPY_PROVIDER, randomness);

        raffle.fulfillDraw();
        assertEq(raffle.winner(), ALICE); // skipped DEPLOYER, landed on ALICE
    }

    function test_allFiveTeamWalletsBlacklisted() public view {
        assertTrue(raffle._isTeamWallet(DEPLOYER));
        assertTrue(raffle._isTeamWallet(COMMUNITY_TREASURY));
        assertTrue(raffle._isTeamWallet(ACTIVATION));
        assertTrue(raffle._isTeamWallet(PARTNERS));
        assertTrue(raffle._isTeamWallet(TEAM_LOCK));
        assertFalse(raffle._isTeamWallet(ALICE));
        assertFalse(raffle._isTeamWallet(BOB));
    }

    // ─── claimPrize ───────────────────────────────────────────────────────────

    function test_claimPrize_transfersNFTToWinner() public {
        _setupFullRaffle();

        vm.prank(ENTROPY_CONTRACT);
        raffle._entropyCallback(1, ENTROPY_PROVIDER, keccak256("randomness"));
        raffle.fulfillDraw();

        address w = raffle.winner();
        vm.prank(w);
        raffle.claimPrize();

        assertEq(nft.ownerOf(PRIZE_TOKEN_ID), w);
        assertTrue(raffle.prizeClaimed());
    }

    function test_claimPrize_ownerCanAlsoClaim() public {
        _setupFullRaffle();

        vm.prank(ENTROPY_CONTRACT);
        raffle._entropyCallback(1, ENTROPY_PROVIDER, keccak256("randomness"));
        raffle.fulfillDraw();

        vm.prank(DEPLOYER); // owner triggers claim
        raffle.claimPrize();
        assertTrue(raffle.prizeClaimed());
    }

    function test_claimPrize_revertsIfAlreadyClaimed() public {
        _setupFullRaffle();

        vm.prank(ENTROPY_CONTRACT);
        raffle._entropyCallback(1, ENTROPY_PROVIDER, keccak256("randomness"));
        raffle.fulfillDraw();

        address w = raffle.winner();
        vm.prank(w);
        raffle.claimPrize();

        vm.prank(w);
        vm.expectRevert(R3tardsRaffle.PrizeAlreadyClaimed.selector);
        raffle.claimPrize();
    }

    function test_claimPrize_revertsIfNotWinnerOrOwner() public {
        _setupFullRaffle();

        vm.prank(ENTROPY_CONTRACT);
        raffle._entropyCallback(1, ENTROPY_PROVIDER, keccak256("randomness"));
        raffle.fulfillDraw();

        address notWinner = raffle.winner() == ALICE ? BOB : ALICE;
        vm.prank(notWinner);
        vm.expectRevert(R3tardsRaffle.NotWinnerOrOwner.selector);
        raffle.claimPrize();
    }

    // ─── recoverPrize ─────────────────────────────────────────────────────────

    function test_recoverPrize_returnsNFTToDepositor() public {
        address[] memory walletList = new address[](1);
        walletList[0] = ALICE;
        uint256[] memory tickets = new uint256[](1);
        tickets[0] = 1;
        _setupSnapshot(walletList, tickets);
        _depositPrize();

        vm.prank(DEPLOYER);
        raffle.recoverPrize();

        assertEq(nft.ownerOf(PRIZE_TOKEN_ID), DEPLOYER);
        assertEq(uint8(raffle.state()), 2); // SnapshotLoaded
        assertFalse(raffle.prizeDeposited());
    }

    function test_recoverPrize_revertsIfNotOwner() public {
        address[] memory walletList = new address[](1);
        walletList[0] = ALICE;
        uint256[] memory tickets = new uint256[](1);
        tickets[0] = 1;
        _setupSnapshot(walletList, tickets);
        _depositPrize();

        vm.prank(ALICE);
        vm.expectRevert(R3tardsRaffle.NotOwner.selector);
        raffle.recoverPrize();
    }

    function test_recoverPrize_revertsIfComplete() public {
        _setupFullRaffle();

        vm.prank(ENTROPY_CONTRACT);
        raffle._entropyCallback(1, ENTROPY_PROVIDER, keccak256("randomness"));
        raffle.fulfillDraw();

        vm.prank(DEPLOYER);
        vm.expectRevert();
        raffle.recoverPrize();
    }

    // ─── getWalletTickets ─────────────────────────────────────────────────────

    function test_getWalletTickets_correct() public {
        address[] memory walletList = new address[](3);
        walletList[0] = ALICE;
        walletList[1] = BOB;
        walletList[2] = CHARLIE;

        uint256[] memory tickets = new uint256[](3);
        tickets[0] = 5;
        tickets[1] = 3;
        tickets[2] = 2;

        vm.startPrank(DEPLOYER);
        raffle.initSnapshot(100, keccak256("hash"));
        raffle.loadTicketsBatch(walletList, tickets);
        vm.stopPrank();

        (uint256 from, uint256 to, bool found) = raffle.getWalletTickets(ALICE);
        assertTrue(found);
        assertEq(from, 0);
        assertEq(to, 4); // 5 tickets: 0-4

        (from, to, found) = raffle.getWalletTickets(BOB);
        assertTrue(found);
        assertEq(from, 5);
        assertEq(to, 7); // 3 tickets: 5-7

        (from, to, found) = raffle.getWalletTickets(CHARLIE);
        assertTrue(found);
        assertEq(from, 8);
        assertEq(to, 9); // 2 tickets: 8-9

        (, , found) = raffle.getWalletTickets(address(0xDEAD));
        assertFalse(found);
    }

    // ─── Binary search correctness ────────────────────────────────────────────

    function test_binarySearch_firstWallet() public {
        _setupFullRaffle(); // ALICE=3, BOB=3, CHARLIE=3 → 9 total

        // ticket 0,1,2 → ALICE
        bytes32 r = bytes32(uint256(0)); // 0 % 9 = 0
        vm.prank(ENTROPY_CONTRACT);
        raffle._entropyCallback(1, ENTROPY_PROVIDER, r);
        raffle.fulfillDraw();
        assertEq(raffle.winner(), ALICE);
    }

    function test_binarySearch_lastWallet() public {
        address[] memory walletList = new address[](3);
        walletList[0] = ALICE;
        walletList[1] = BOB;
        walletList[2] = CHARLIE;
        uint256[] memory tickets = new uint256[](3);
        tickets[0] = 3;
        tickets[1] = 3;
        tickets[2] = 3;
        _setupSnapshot(walletList, tickets);
        _depositPrize();

        vm.startPrank(DEPLOYER);
        raffle.setDrawDeadline(block.number + 100);
        raffle.requestDraw{value: 0.6 ether}(keccak256("random"));
        vm.stopPrank();

        // ticket 8 → CHARLIE (tickets 6-8)
        bytes32 r = bytes32(uint256(8)); // 8 % 9 = 8
        vm.prank(ENTROPY_CONTRACT);
        raffle._entropyCallback(1, ENTROPY_PROVIDER, r);
        raffle.fulfillDraw();
        assertEq(raffle.winner(), CHARLIE);
    }

    // ─── State machine ────────────────────────────────────────────────────────

    function test_stateMachine_cannotSkipStates() public {
        // Can't load tickets before initSnapshot
        address[] memory walletList = new address[](1);
        walletList[0] = ALICE;
        uint256[] memory tickets = new uint256[](1);
        tickets[0] = 1;

        vm.prank(DEPLOYER);
        vm.expectRevert();
        raffle.loadTicketsBatch(walletList, tickets);

        // Can't finalize before loading
        vm.prank(DEPLOYER);
        vm.expectRevert();
        raffle.finalizeSnapshot();

        // Can't requestDraw before prize
        vm.prank(DEPLOYER);
        raffle.initSnapshot(100, keccak256("hash"));
        vm.prank(DEPLOYER);
        raffle.loadTicketsBatch(walletList, tickets);
        vm.prank(DEPLOYER);
        raffle.finalizeSnapshot();

        vm.prank(DEPLOYER);
        vm.expectRevert();
        raffle.requestDraw{value: 0.6 ether}(keccak256("random"));
    }
}
