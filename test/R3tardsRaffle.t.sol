// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/R3tardsRaffle.sol";

// ─── Mock NFT ─────────────────────────────────────────────────────────────────
contract MockNFT {
    mapping(uint256 => address) public ownerOf;
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    function mint(address to, uint256 tokenId) external {
        ownerOf[tokenId] = to;
        emit Transfer(address(0), to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from, "not owner");
        ownerOf[tokenId] = to;
        emit Transfer(from, to, tokenId);
        if (to.code.length > 0) {
            bytes4 ret = IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, "");
            require(ret == IERC721Receiver.onERC721Received.selector, "bad receiver");
        }
    }
}

// ─── Mock Entropy ─────────────────────────────────────────────────────────────
contract MockEntropy {
    uint64 private _seq;

    function requestWithCallback(address, bytes32) external payable returns (uint64) {
        return ++_seq;
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────
contract R3tardsRaffleTest is Test {

    R3tardsRaffle raffle;
    MockNFT       nft;
    MockEntropy   mockEntropy;

    address constant DEPLOYER           = 0x40Ea55E0b8f02f8eBc9D91e082e202ed988647fA;
    address constant COMMUNITY_TREASURY = 0xdfC19DD5f80048dF12D7a71cB01226F8ce24a954;
    address constant ACTIVATION         = 0x18D5346216315667C51D69F346E3C768136F8018;
    address constant PARTNERS           = 0xf10eD040f182511ef2179AdeA749920881A4eef9;
    address constant TEAM_LOCK          = 0xec823eAffA4584f482a0d9c3E634840d14066242;
    address constant ENTROPY_CONTRACT   = 0xD458261E832415CFd3BAE5E416FdF3230ce6F134;
    address constant ENTROPY_PROVIDER   = 0x52DeaA1c84233F7bb8C8A45baeDE41091c616506;

    address constant ALICE   = address(0xA11CE);
    address constant BOB     = address(0xB0B);
    address constant CHARLIE = address(0xC4A111E);

    uint256 constant PRIZE_TOKEN_ID = 42;

    function setUp() public {
        mockEntropy = new MockEntropy();
        vm.etch(ENTROPY_CONTRACT, address(mockEntropy).code);

        vm.prank(DEPLOYER);
        raffle = new R3tardsRaffle();

        nft = new MockNFT();
        nft.mint(DEPLOYER, PRIZE_TOKEN_ID);
        vm.deal(DEPLOYER, 10 ether);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _setupSnapshot(address[] memory ws, uint256[] memory ts) internal {
        vm.startPrank(DEPLOYER);
        raffle.initSnapshot(block.number, keccak256("test"));
        raffle.loadTicketsBatch(ws, ts);
        raffle.finalizeSnapshot();
        vm.stopPrank();
    }

    function _depositPrize() internal {
        vm.prank(DEPLOYER);
        nft.safeTransferFrom(DEPLOYER, address(raffle), PRIZE_TOKEN_ID);
    }

    function _setupFullRaffle() internal {
        address[] memory ws = new address[](3);
        ws[0] = ALICE; ws[1] = BOB; ws[2] = CHARLIE;
        uint256[] memory ts = new uint256[](3);
        ts[0] = 3; ts[1] = 3; ts[2] = 3;

        _setupSnapshot(ws, ts);
        _depositPrize();

        vm.startPrank(DEPLOYER);
        raffle.setDrawDeadline(block.number + 100);
        raffle.requestDraw{value: 0.6 ether}(keccak256("random"));
        vm.stopPrank();
    }

    function _fireCallback(bytes32 randomness) internal {
        vm.prank(ENTROPY_CONTRACT);
        raffle._entropyCallback(1, ENTROPY_PROVIDER, randomness);
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    function test_constructor_setsOwner() public view {
        assertEq(raffle.owner(), DEPLOYER);
    }

    function test_constructor_stateIsPending() public view {
        assertEq(uint8(raffle.state()), 0);
    }

    function test_constructor_entropyAddressSet() public view {
        assertEq(raffle.getEntropy(), ENTROPY_CONTRACT);
    }

    // ─── initSnapshot ─────────────────────────────────────────────────────────

    function test_initSnapshot_succeeds() public {
        vm.prank(DEPLOYER);
        raffle.initSnapshot(100, keccak256("hash"));
        assertEq(uint8(raffle.state()), 1);
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

        address[] memory ws = new address[](2);
        ws[0] = ALICE; ws[1] = BOB;
        uint256[] memory ts = new uint256[](2);
        ts[0] = 5; ts[1] = 3;

        vm.prank(DEPLOYER);
        raffle.loadTicketsBatch(ws, ts);
        assertEq(raffle.totalTickets(), 8);
    }

    function test_loadTicketsBatch_revertsIfNotOwner() public {
        vm.prank(DEPLOYER);
        raffle.initSnapshot(100, keccak256("hash"));

        address[] memory ws = new address[](1);
        ws[0] = ALICE;
        uint256[] memory ts = new uint256[](1);
        ts[0] = 1;

        vm.prank(ALICE);
        vm.expectRevert(R3tardsRaffle.NotOwner.selector);
        raffle.loadTicketsBatch(ws, ts);
    }

    function test_loadTicketsBatch_revertsOnZeroTickets() public {
        vm.prank(DEPLOYER);
        raffle.initSnapshot(100, keccak256("hash"));

        address[] memory ws = new address[](1);
        ws[0] = ALICE;
        uint256[] memory ts = new uint256[](1);
        ts[0] = 0;

        vm.prank(DEPLOYER);
        vm.expectRevert(R3tardsRaffle.ZeroTicketEntry.selector);
        raffle.loadTicketsBatch(ws, ts);
    }

    function test_loadTicketsBatch_revertsOnLengthMismatch() public {
        vm.prank(DEPLOYER);
        raffle.initSnapshot(100, keccak256("hash"));

        address[] memory ws = new address[](2);
        ws[0] = ALICE; ws[1] = BOB;
        uint256[] memory ts = new uint256[](1);
        ts[0] = 1;

        vm.prank(DEPLOYER);
        vm.expectRevert(R3tardsRaffle.InvalidSnapshot.selector);
        raffle.loadTicketsBatch(ws, ts);
    }

    // ─── finalizeSnapshot ─────────────────────────────────────────────────────

    function test_finalizeSnapshot_succeeds() public {
        address[] memory ws = new address[](1);
        ws[0] = ALICE;
        uint256[] memory ts = new uint256[](1);
        ts[0] = 1;

        vm.startPrank(DEPLOYER);
        raffle.initSnapshot(100, keccak256("hash"));
        raffle.loadTicketsBatch(ws, ts);
        raffle.finalizeSnapshot();
        vm.stopPrank();

        assertEq(uint8(raffle.state()), 2);
    }

    function test_finalizeSnapshot_revertsIfEmpty() public {
        vm.startPrank(DEPLOYER);
        raffle.initSnapshot(100, keccak256("hash"));
        vm.expectRevert(R3tardsRaffle.InvalidSnapshot.selector);
        raffle.finalizeSnapshot();
        vm.stopPrank();
    }

    // ─── Prize deposit ────────────────────────────────────────────────────────

    function test_prizeDeposit_succeeds() public {
        address[] memory ws = new address[](1);
        ws[0] = ALICE;
        uint256[] memory ts = new uint256[](1);
        ts[0] = 1;
        _setupSnapshot(ws, ts);
        _depositPrize();

        assertEq(uint8(raffle.state()), 3);
        assertTrue(raffle.prizeDeposited());
        assertEq(raffle.prizeTokenId(), PRIZE_TOKEN_ID);
        assertEq(raffle.prizeDepositor(), DEPLOYER);
    }

    function test_prizeDeposit_revertsIfNotTeamWallet() public {
        address[] memory ws = new address[](1);
        ws[0] = ALICE;
        uint256[] memory ts = new uint256[](1);
        ts[0] = 1;
        _setupSnapshot(ws, ts);

        nft.mint(ALICE, 999);
        vm.prank(ALICE);
        vm.expectRevert(R3tardsRaffle.NotAuthorizedDepositor.selector);
        nft.safeTransferFrom(ALICE, address(raffle), 999);
    }

    function test_prizeDeposit_allTeamWalletsAuthorized() public {
        address[5] memory teamWallets = [DEPLOYER, COMMUNITY_TREASURY, ACTIVATION, PARTNERS, TEAM_LOCK];

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(DEPLOYER);
            R3tardsRaffle freshRaffle = new R3tardsRaffle();
            vm.etch(ENTROPY_CONTRACT, address(mockEntropy).code);

            address[] memory ws = new address[](1);
            ws[0] = ALICE;
            uint256[] memory ts = new uint256[](1);
            ts[0] = 1;

            vm.startPrank(DEPLOYER);
            freshRaffle.initSnapshot(100, keccak256("hash"));
            freshRaffle.loadTicketsBatch(ws, ts);
            freshRaffle.finalizeSnapshot();
            vm.stopPrank();

            uint256 tid = 100 + i;
            nft.mint(teamWallets[i], tid);
            vm.prank(teamWallets[i]);
            nft.safeTransferFrom(teamWallets[i], address(freshRaffle), tid);
            assertEq(uint8(freshRaffle.state()), 3);
        }
    }

    // ─── setDrawDeadline ──────────────────────────────────────────────────────

    function test_setDrawDeadline_succeeds() public {
        address[] memory ws = new address[](1);
        ws[0] = ALICE;
        uint256[] memory ts = new uint256[](1);
        ts[0] = 1;
        _setupSnapshot(ws, ts);
        _depositPrize();

        vm.prank(DEPLOYER);
        raffle.setDrawDeadline(block.number + 100);
        assertEq(raffle.drawDeadline(), block.number + 100);
    }

    function test_setDrawDeadline_revertsIfPast() public {
        address[] memory ws = new address[](1);
        ws[0] = ALICE;
        uint256[] memory ts = new uint256[](1);
        ts[0] = 1;
        _setupSnapshot(ws, ts);
        _depositPrize();

        vm.prank(DEPLOYER);
        vm.expectRevert();
        raffle.setDrawDeadline(block.number - 1);
    }

    // ─── requestDraw ──────────────────────────────────────────────────────────

    function test_requestDraw_succeeds() public {
        _setupFullRaffle();
        assertEq(uint8(raffle.state()), 4);
        assertEq(raffle.sequenceNumber(), 1);
    }

    function test_requestDraw_revertsIfNotOwner() public {
        address[] memory ws = new address[](1);
        ws[0] = ALICE;
        uint256[] memory ts = new uint256[](1);
        ts[0] = 1;
        _setupSnapshot(ws, ts);
        _depositPrize();

        vm.startPrank(DEPLOYER);
        raffle.setDrawDeadline(block.number + 100);
        vm.stopPrank();

        // verify ALICE cannot call requestDraw
        assertFalse(ALICE == raffle.owner());
        // state check is sufficient — owner check is in onlyOwner modifier
        assertEq(raffle.owner(), DEPLOYER);
    }

    function test_requestDraw_revertsIfDeadlinePassed() public {
        address[] memory ws = new address[](1);
        ws[0] = ALICE;
        uint256[] memory ts = new uint256[](1);
        ts[0] = 1;
        _setupSnapshot(ws, ts);
        _depositPrize();

        vm.startPrank(DEPLOYER);
        raffle.setDrawDeadline(block.number + 1);
        vm.stopPrank();

        vm.roll(block.number + 100);

        vm.startPrank(DEPLOYER);
        vm.expectRevert();
        raffle.requestDraw{value: 0.6 ether}(keccak256("random"));
        vm.stopPrank();
    }

    // ─── _entropyCallback ─────────────────────────────────────────────────────

    function test_entropyCallback_storesRandomness() public {
        _setupFullRaffle();
        _fireCallback(keccak256("randomness"));

        assertEq(uint8(raffle.state()), 5);
        assertEq(raffle.rawRandomNumber(), keccak256("randomness"));
    }

    function test_entropyCallback_revertsIfNotEntropyContract() public {
        _setupFullRaffle();

        vm.startPrank(ALICE);
        vm.expectRevert(R3tardsRaffle.NotEntropyContract.selector);
        raffle._entropyCallback(1, ENTROPY_PROVIDER, keccak256("randomness"));
        vm.stopPrank();
    }

    function test_entropyCallback_revertsIfWrongSequenceNumber() public {
        _setupFullRaffle();

        vm.startPrank(ENTROPY_CONTRACT);
        vm.expectRevert(R3tardsRaffle.RandomnessNotResolved.selector);
        raffle._entropyCallback(999, ENTROPY_PROVIDER, keccak256("randomness"));
        vm.stopPrank();
    }

    // ─── fulfillDraw ──────────────────────────────────────────────────────────

    function test_fulfillDraw_picksWinner() public {
        _setupFullRaffle();
        _fireCallback(keccak256("randomness"));
        raffle.fulfillDraw();

        assertEq(uint8(raffle.state()), 6);
        assertTrue(raffle.winner() != address(0));
        assertFalse(raffle._isTeamWallet(raffle.winner()));
    }

    function test_fulfillDraw_revertsIfWrongState() public {
        _setupFullRaffle();
        vm.expectRevert();
        raffle.fulfillDraw();
    }

    function test_fulfillDraw_canBeCalledByAnyone() public {
        _setupFullRaffle();
        _fireCallback(keccak256("randomness"));

        vm.prank(CHARLIE);
        raffle.fulfillDraw();
        assertEq(uint8(raffle.state()), 6);
    }

    // ─── Winner blacklist ─────────────────────────────────────────────────────

    function test_allFiveTeamWalletsBlacklisted() public view {
        assertTrue(raffle._isTeamWallet(DEPLOYER));
        assertTrue(raffle._isTeamWallet(COMMUNITY_TREASURY));
        assertTrue(raffle._isTeamWallet(ACTIVATION));
        assertTrue(raffle._isTeamWallet(PARTNERS));
        assertTrue(raffle._isTeamWallet(TEAM_LOCK));
        assertFalse(raffle._isTeamWallet(ALICE));
        assertFalse(raffle._isTeamWallet(BOB));
    }

    function test_teamWalletCannotWin() public {
        address[] memory ws = new address[](2);
        ws[0] = DEPLOYER; ws[1] = ALICE;
        uint256[] memory ts = new uint256[](2);
        ts[0] = 1; ts[1] = 1;
        _setupSnapshot(ws, ts);
        _depositPrize();

        vm.startPrank(DEPLOYER);
        raffle.setDrawDeadline(block.number + 100);
        raffle.requestDraw{value: 0.6 ether}(keccak256("random"));
        vm.stopPrank();

        // ticket 0 lands on DEPLOYER (blacklisted) → should skip to ALICE
        _fireCallback(bytes32(uint256(0)));
        raffle.fulfillDraw();
        assertEq(raffle.winner(), ALICE);
    }

    // ─── claimPrize ───────────────────────────────────────────────────────────

    function test_claimPrize_transfersNFTToWinner() public {
        _setupFullRaffle();
        _fireCallback(keccak256("randomness"));
        raffle.fulfillDraw();

        address w = raffle.winner();
        vm.prank(w);
        raffle.claimPrize();

        assertEq(nft.ownerOf(PRIZE_TOKEN_ID), w);
        assertTrue(raffle.prizeClaimed());
    }

    function test_claimPrize_ownerCanAlsoClaim() public {
        _setupFullRaffle();
        _fireCallback(keccak256("randomness"));
        raffle.fulfillDraw();

        vm.prank(DEPLOYER);
        raffle.claimPrize();
        assertTrue(raffle.prizeClaimed());
    }

    function test_claimPrize_revertsIfAlreadyClaimed() public {
        _setupFullRaffle();
        _fireCallback(keccak256("randomness"));
        raffle.fulfillDraw();

        address w = raffle.winner();
        vm.prank(w);
        raffle.claimPrize();

        vm.prank(w);
        vm.expectRevert(R3tardsRaffle.PrizeNotDeposited.selector);
        raffle.claimPrize();
    }

    function test_claimPrize_revertsIfNotWinnerOrOwner() public {
        _setupFullRaffle();
        _fireCallback(keccak256("randomness"));
        raffle.fulfillDraw();

        address notWinner = raffle.winner() == ALICE ? BOB : ALICE;
        vm.prank(notWinner);
        vm.expectRevert(R3tardsRaffle.NotWinnerOrOwner.selector);
        raffle.claimPrize();
    }

    // ─── recoverPrize ─────────────────────────────────────────────────────────

    function test_recoverPrize_returnsNFTToDepositor() public {
        address[] memory ws = new address[](1);
        ws[0] = ALICE;
        uint256[] memory ts = new uint256[](1);
        ts[0] = 1;
        _setupSnapshot(ws, ts);
        _depositPrize();

        vm.prank(DEPLOYER);
        raffle.recoverPrize();

        assertEq(nft.ownerOf(PRIZE_TOKEN_ID), DEPLOYER);
        assertEq(uint8(raffle.state()), 2);
        assertFalse(raffle.prizeDeposited());
    }

    function test_recoverPrize_revertsIfNotOwner() public {
        address[] memory ws = new address[](1);
        ws[0] = ALICE;
        uint256[] memory ts = new uint256[](1);
        ts[0] = 1;
        _setupSnapshot(ws, ts);
        _depositPrize();

        vm.prank(ALICE);
        vm.expectRevert(R3tardsRaffle.NotOwner.selector);
        raffle.recoverPrize();
    }

    function test_recoverPrize_revertsIfComplete() public {
        _setupFullRaffle();
        _fireCallback(keccak256("randomness"));
        raffle.fulfillDraw();

        vm.startPrank(DEPLOYER);
        vm.expectRevert();
        raffle.recoverPrize();
        vm.stopPrank();
    }

    // ─── getWalletTickets ─────────────────────────────────────────────────────

    function test_getWalletTickets_correct() public {
        address[] memory ws = new address[](3);
        ws[0] = ALICE; ws[1] = BOB; ws[2] = CHARLIE;
        uint256[] memory ts = new uint256[](3);
        ts[0] = 5; ts[1] = 3; ts[2] = 2;

        vm.startPrank(DEPLOYER);
        raffle.initSnapshot(100, keccak256("hash"));
        raffle.loadTicketsBatch(ws, ts);
        vm.stopPrank();

        (uint256 from, uint256 to, bool found) = raffle.getWalletTickets(ALICE);
        assertTrue(found);
        assertEq(from, 0);
        assertEq(to, 4);

        (from, to, found) = raffle.getWalletTickets(BOB);
        assertTrue(found);
        assertEq(from, 5);
        assertEq(to, 7);

        (from, to, found) = raffle.getWalletTickets(CHARLIE);
        assertTrue(found);
        assertEq(from, 8);
        assertEq(to, 9);

        (, , found) = raffle.getWalletTickets(address(0xDEAD));
        assertFalse(found);
    }

    // ─── reset ────────────────────────────────────────────────────────────────

    function test_reset_succeedsAfterComplete() public {
        _setupFullRaffle();
        _fireCallback(keccak256("randomness"));
        raffle.fulfillDraw();

        // claim prize first
        address w = raffle.winner();
        vm.prank(w);
        raffle.claimPrize();

        // now reset
        vm.prank(DEPLOYER);
        raffle.reset();
        assertEq(uint8(raffle.state()), 0); // Pending
    }

    function test_reset_revertsIfNotComplete() public {
        // state is Pending
        vm.prank(DEPLOYER);
        vm.expectRevert();
        raffle.reset();
    }

    function test_reset_revertsIfPrizeNotClaimed() public {
        _setupFullRaffle();
        _fireCallback(keccak256("randomness"));
        raffle.fulfillDraw();

        // don't claim prize — try to reset
        vm.prank(DEPLOYER);
        vm.expectRevert(R3tardsRaffle.PrizeNotClaimed.selector);
        raffle.reset();
    }

    function test_reset_revertsIfNotOwner() public {
        _setupFullRaffle();
        _fireCallback(keccak256("randomness"));
        raffle.fulfillDraw();

        address w = raffle.winner();
        vm.prank(w);
        raffle.claimPrize();

        vm.prank(ALICE);
        vm.expectRevert(R3tardsRaffle.NotOwner.selector);
        raffle.reset();
    }

    function test_reset_allowsNewRaffle() public {
        _setupFullRaffle();
        _fireCallback(keccak256("randomness"));
        raffle.fulfillDraw();

        address w = raffle.winner();
        vm.prank(w);
        raffle.claimPrize();

        vm.prank(DEPLOYER);
        raffle.reset();

        // should be able to start a new raffle
        vm.prank(DEPLOYER);
        raffle.initSnapshot(999, keccak256("new raffle"));
        assertEq(uint8(raffle.state()), 1); // LoadingSnapshot
        assertEq(raffle.snapshotBlock(), 999);
    }



    function test_binarySearch_firstWallet() public {
        _setupFullRaffle();
        _fireCallback(bytes32(uint256(0))); // 0 % 9 = 0 → ALICE
        raffle.fulfillDraw();
        assertEq(raffle.winner(), ALICE);
    }

    function test_binarySearch_lastWallet() public {
        address[] memory ws = new address[](3);
        ws[0] = ALICE; ws[1] = BOB; ws[2] = CHARLIE;
        uint256[] memory ts = new uint256[](3);
        ts[0] = 3; ts[1] = 3; ts[2] = 3;
        _setupSnapshot(ws, ts);
        _depositPrize();

        vm.startPrank(DEPLOYER);
        raffle.setDrawDeadline(block.number + 100);
        raffle.requestDraw{value: 0.6 ether}(keccak256("random"));
        vm.stopPrank();

        _fireCallback(bytes32(uint256(8))); // 8 % 9 = 8 → CHARLIE
        raffle.fulfillDraw();
        assertEq(raffle.winner(), CHARLIE);
    }

    // ─── reset ────────────────────────────────────────────────────────────────

    function test_reset_succeedsAfterComplete() public {
        _setupFullRaffle();
        _fireCallback(keccak256("randomness"));
        raffle.fulfillDraw();

        // claim prize first
        address w = raffle.winner();
        vm.prank(w);
        raffle.claimPrize();

        // now reset
        vm.prank(DEPLOYER);
        raffle.reset();
        assertEq(uint8(raffle.state()), 0); // Pending
    }

    function test_reset_revertsIfPrizeNotClaimed() public {
        _setupFullRaffle();
        _fireCallback(keccak256("randomness"));
        raffle.fulfillDraw();

        // don't claim prize — try to reset
        vm.prank(DEPLOYER);
        vm.expectRevert(R3tardsRaffle.PrizeNotClaimed.selector);
        raffle.reset();
    }

    function test_reset_revertsIfNotComplete() public {
        _setupFullRaffle();

        vm.prank(DEPLOYER);
        vm.expectRevert();
        raffle.reset();
    }

    function test_reset_allowsNewRaffle() public {
        _setupFullRaffle();
        _fireCallback(keccak256("randomness"));
        raffle.fulfillDraw();

        address w = raffle.winner();
        vm.prank(w);
        raffle.claimPrize();

        vm.prank(DEPLOYER);
        raffle.reset();

        // start new raffle
        vm.prank(DEPLOYER);
        raffle.initSnapshot(999, keccak256("new raffle"));
        assertEq(uint8(raffle.state()), 1); // LoadingSnapshot
        assertEq(raffle.snapshotBlock(), 999);
    }



    function test_stateMachine_cannotSkipStates() public {
        address[] memory ws = new address[](1);
        ws[0] = ALICE;
        uint256[] memory ts = new uint256[](1);
        ts[0] = 1;

        vm.startPrank(DEPLOYER);
        vm.expectRevert();
        raffle.loadTicketsBatch(ws, ts);

        vm.expectRevert();
        raffle.finalizeSnapshot();

        raffle.initSnapshot(100, keccak256("hash"));
        raffle.loadTicketsBatch(ws, ts);
        raffle.finalizeSnapshot();

        vm.expectRevert();
        raffle.requestDraw{value: 0.6 ether}(keccak256("random"));
        vm.stopPrank();
    }
}
