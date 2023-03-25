from ape import reverts
import json
import os
import pytest
import subprocess

MAX_SECURITY = 63
Phase_SHUF = 3

@pytest.fixture(scope="session")
def deck(project, accounts):
    return project.Deck.deploy(sender=accounts[0])

@pytest.fixture(scope="session")
def room(project, accounts, deck):
    return project.Room.deploy(deck.address, sender=accounts[0])

@pytest.fixture(scope="session")
def game(project, accounts, room):
    return project.Game.deploy(room.address, sender=accounts[0])

def test_new_deck_ids_distinct(accounts, deck):
    tx1 = deck.newDeck(13, sender=accounts[0])
    tx2 = deck.newDeck(9, sender=accounts[0])
    assert tx1.return_value != tx2.return_value

def test_new_deck_invalid_players(accounts, deck):
    with reverts("invalid players"):
        deck.newDeck(0, sender=accounts[0])
    with reverts("invalid players"):
        deck.newDeck(128, sender=accounts[0])
    tx = deck.newDeck(127, sender=accounts[0])
    assert tx.return_value == 0

def test_create_invalid_seatIndex(accounts, room, game):
    with reverts("invalid seatIndex"):
        room.createTable(
                12, (1, 2, 3, 2, [1,2,3], 2, 2, 2, 2, 2, 2, 2), game.address,
                sender=accounts[0])

def test_create_wrong_value(accounts, room, game):
    with reverts("incorrect bond + buyIn"):
        room.createTable(
                0, (1, 2, 3, 2, [1,2,3], 2, 2, 2, 2, 2, 2, 2), game.address,
                sender=accounts[0])

def test_join_leave_join(accounts, room, game):
    seatIndex = 1
    tx = room.createTable(
            seatIndex, (100, 200, 3, 2, [1,2,3], 2, 2, 2, 2, 2, 2, 2), game.address,
            sender=accounts[0], value="300 wei")
    tableId = tx.return_value
    room_prev_balance = room.balance
    acc0_prev_balance = accounts[0].balance
    tx = room.leaveTable(tableId, seatIndex, sender=accounts[0])
    assert accounts[0].balance + (tx.gas_used * tx.gas_price) - acc0_prev_balance == 300
    assert room_prev_balance - room.balance == 300
    with reverts("incorrect bond + buyIn"):
        room.joinTable(tableId, seatIndex, sender=accounts[0])
    room.joinTable(tableId, seatIndex, sender=accounts[0], value="300 wei")

def test_submit_prep_timeout(networks, accounts, chain, room, game):
    prepBlocks = 2
    tx = room.createTable(
            1, (100, 200, 2, 1, [1,2,3], 2, 2, prepBlocks, 2, 2, 2, 2), game.address,
            sender=accounts[0], value="300 wei")
    tableId = tx.return_value
    tx = room.joinTable(tableId, 0, sender=accounts[1], value="300 wei")
    tx = room.submitPrep(tableId, 1, b'1', sender=accounts[0])
    chain.mine(prepBlocks + 1)
    assert chain.blocks.height > tx.block_number + prepBlocks, "mine harder"
    with reverts("not submitted"):
        room.verifyPrepTimeout(tableId, 0, sender=accounts[0])
    room_prev_balance = room.balance
    acc0_prev_balance = accounts[0].balance
    acc1_prev_balance = accounts[1].balance
    tx = room.submitPrepTimeout(tableId, 0, sender=accounts[0])
    assert accounts[0].balance == acc0_prev_balance - (tx.gas_used * tx.gas_price) + 300
    assert accounts[1].balance == acc1_prev_balance
    assert room_prev_balance - room.balance == 300 + 300
    with reverts("wrong phase"):
        room.joinTable(tableId, 0, sender=accounts[1], value="300 wei")

def test_submit_prep_timeout_self(accounts, chain, room, game):
    prepBlocks = 2
    tx = room.createTable(
            1, (100, 200, 2, 1, [1,2,3], 2, 2, prepBlocks, 2, 2, 2, 2), game.address,
            sender=accounts[0], value="300 wei")
    tableId = tx.return_value
    tx = room.joinTable(tableId, 0, sender=accounts[1], value="300 wei")
    chain.mine(prepBlocks + 1)
    assert chain.blocks.height > tx.block_number + prepBlocks, "mine harder"
    room_prev_balance = room.balance
    acc0_prev_balance = accounts[0].balance
    acc1_prev_balance = accounts[1].balance
    tx = room.submitPrepTimeout(tableId, 1, sender=accounts[0])
    assert accounts[0].balance == acc0_prev_balance - (tx.gas_used * tx.gas_price)
    assert accounts[1].balance == acc1_prev_balance + 300
    assert room_prev_balance - room.balance == 300 + 300

def test_verify_prep_timeout(accounts, chain, room, game):
    prepBlocks = 1
    tx = room.createTable(
            0, (300, 200, 2, 1, [1,2,3], 2, 2, prepBlocks, 2, 2, 2, 2), game.address,
            sender=accounts[0], value="500 wei")
    tableId = tx.return_value
    tx = room.joinTable(tableId, 1, sender=accounts[1], value="500 wei")
    tx = room.submitPrep(tableId, 0, b'1', sender=accounts[0])
    tx = room.submitPrep(tableId, 1, b'2', sender=accounts[1])
    chain.mine(prepBlocks + 1)
    assert chain.blocks.height > tx.block_number + prepBlocks, "mine harder"
    with reverts("already submitted"):
        room.submitPrepTimeout(tableId, 0, sender=accounts[0])
    room_prev_balance = room.balance
    acc0_prev_balance = accounts[0].balance
    acc1_prev_balance = accounts[1].balance
    tx = room.verifyPrepTimeout(tableId, 0, sender=accounts[1])
    assert accounts[0].balance == acc0_prev_balance
    assert accounts[1].balance == acc1_prev_balance + 500 - (tx.gas_used * tx.gas_price)
    assert room.balance == room_prev_balance - 500 - 500
    with reverts("wrong phase"):
        room.verifyPrepTimeout(tableId, 1, sender=accounts[0])

@pytest.fixture(scope="session")
def two_players_prepped(networks, accounts, deck, room, game):
    config = dict(
            buyIn=300,
            bond=500,
            startsWith=2,
            untilLeft=1,
            structure=[10, 20, 30, 40],
            levelBlocks=20,
            verifRounds=4,
            prepBlocks=10,
            shuffBlocks=10,
            verifBlocks=15,
            dealBlocks=10,
            actBlocks=15)
    value = f"{config['bond'] + config['buyIn']} wei"
    tx = room.createTable(
            0, config, game.address,
            sender=accounts[0], value=value)
    tableId = tx.return_value
    tx = room.joinTable(tableId, 1, sender=accounts[1], value=value)

    db_path = "tests/db.json"

    try:
        os.remove(db_path)
    except FileNotFoundError:
        pass

    deckArgs = ["interface/deck.js", "--db", db_path,
                "--rpc", networks.active_provider.web3.provider.endpoint_uri,
                "--deck", deck.address,
                "--id", "0"]

    hash0 = subprocess.run(
            deckArgs + ["--from", accounts[0].address, "submitPrep"],
            capture_output=True, check=True, text=True).stdout.strip()
    room.submitPrep(tableId, 0, hash0, sender=accounts[0])

    hash1 = subprocess.run(
            deckArgs + ["--from", accounts[1].address, "submitPrep"],
            capture_output=True, check=True, text=True).stdout.strip()
    room.submitPrep(tableId, 1, hash1, sender=accounts[1])

    def readPrep(f):
        a = []
        def n():
            return int(next(f), 16)
        for _ in range(53):
            a.append(dict(g=[n(), n()], h=[n(), n()],
                          gx=[n(), n()], hx=[n(), n()],
                          p=([n(), n()], [n(), n()], n())))
        return a

    lines = iter(subprocess.run(
        deckArgs + ["--from", accounts[0].address, "verifyPrep"],
        capture_output=True, check=True, text=True).stdout.splitlines())
    room.verifyPrep(tableId, 0, readPrep(lines), sender=accounts[0])

    lines = iter(subprocess.run(
             deckArgs + ["--from", accounts[1].address, "verifyPrep"],
            stdout=subprocess.PIPE, check=True, text=True).stdout.splitlines())
    room.verifyPrep(tableId, 1, readPrep(lines), sender=accounts[1])

    return dict(tableId=tableId, config=config, deckArgs=deckArgs)

def test_no_timeout_after_prep(accounts, two_players_prepped, room):
    tableId = two_players_prepped["tableId"]
    with reverts("wrong phase"):
        room.submitPrepTimeout(tableId, 0, sender=accounts[0])
    with reverts("wrong phase"):
        room.verifyPrepTimeout(tableId, 1, sender=accounts[0])

def test_no_leave_after_prep(accounts, two_players_prepped, room):
    tableId = two_players_prepped["tableId"]
    with reverts("wrong phase"):
        room.leaveTable(tableId, 0, sender=accounts[0])

def test_no_refund_delete(accounts, two_players_prepped, room):
    tableId = two_players_prepped["tableId"]
    with reverts("unauthorised"):
        room.refundPlayer(tableId, 0, 100, sender=accounts[0])
    with reverts("unauthorised"):
        room.deleteTable(tableId, sender=accounts[0])

def test_submit_shuffle_timeout(accounts, chain, two_players_prepped, room):
    tableId = two_players_prepped["tableId"]
    shuffBlocks = two_players_prepped["config"]["shuffBlocks"]
    value = two_players_prepped["config"]["bond"] + two_players_prepped["config"]["buyIn"]
    block_number = chain.blocks.height
    chain.mine(shuffBlocks + 1)
    assert chain.blocks.height > block_number + shuffBlocks, "mine harder"
    room_prev_balance = room.balance
    acc0_prev_balance = accounts[0].balance
    acc1_prev_balance = accounts[1].balance
    tx = room.submitShuffleTimeout(tableId, 0, sender=accounts[0])
    assert accounts[0].balance == acc0_prev_balance - (tx.gas_used * tx.gas_price)
    assert accounts[1].balance == acc1_prev_balance + value
    assert room.balance == room_prev_balance - value - value

def two_players_shuffle(accounts, two_players_prepped, room, perm0, perm1):
    tableId = two_players_prepped["tableId"]
    deckId = room.configParams(tableId)[-1]
    deckArgs = two_players_prepped["deckArgs"]
    config = two_players_prepped["config"]
    verifRounds = config["verifRounds"]

    def readShuffle(f):
        a = []
        def n():
            return int(next(f), 16)
        for _ in range(53):
            a.append([n(), n()])
        return a

    lines = iter(subprocess.run(
             deckArgs + ["--from", accounts[0].address, "shuffle",
                         "-v", str(verifRounds), "-j", str(deckId),
                         "--order", ','.join([str(n) for n in perm0])],
            stdout=subprocess.PIPE, check=True, text=True).stdout.splitlines())

    tx = room.submitShuffle(tableId, 0, readShuffle(lines), next(lines), sender=accounts[0])

    lines = iter(subprocess.run(
             deckArgs + ["--from", accounts[1].address, "shuffle",
                         "-v", str(verifRounds), "-j", str(deckId),
                         "--order", ','.join([str(n) for n in perm1])],
            stdout=subprocess.PIPE, check=True, text=True).stdout.splitlines())

    tx = room.submitShuffle(tableId, 1, readShuffle(lines), next(lines), sender=accounts[1])

    def readVerification(f):
        c = []
        s = []
        p = []
        def n():
            return int(next(f), 16)
        for _ in range(MAX_SECURITY):
            d = []
            for _ in range(53):
                d.append([n(), n()])
            c.append(d)
        for _ in range(MAX_SECURITY):
            s.append(n())
        for _ in range(MAX_SECURITY):
            d = []
            for _ in range(53):
                d.append(n())
            p.append(d)
        return c, s, p

    lines = iter(subprocess.run(
             deckArgs + ["--from", accounts[0].address, "verifyShuffle",
                         "-j", str(deckId), "-s", '0'],
            stdout=subprocess.PIPE, check=True, text=True).stdout.splitlines())
    c, s, p = readVerification(lines)
    tx = room.verifyShuffle(tableId, 0, c, s, p, sender=accounts[0])

    lines = iter(subprocess.run(
             deckArgs + ["--from", accounts[1].address, "verifyShuffle",
                         "-j", str(deckId), "-s", '1'],
            stdout=subprocess.PIPE, check=True, text=True).stdout.splitlines())
    c, s, p = readVerification(lines)
    tx = room.verifyShuffle(tableId, 1, c, s, p, sender=accounts[1])

def readIntLists(f, z):
    a = []
    def n():
        return int(next(f), 16)
    for _ in range(26):
        try:
            a.append([n() for _ in range(z)])
        except StopIteration:
            break
    return a

two_players_empty_shuffle = (
    #        1   2    3   4   5   6   7   8   9  10  11  12  13  14  15  16
            [32, 11,  4,  9,  8, 42,  1,  3,  5,  7, 22, 25, 51, 31, 30,  2,
    #        17  18  19  20  21  22  23  24  25  26  27  28  29  30  31  32
             13, 23, 50, 44, 33, 35, 27, 21, 16, 39, 43, 10, 19, 34,  6, 12,
    #        33  34  35  36  37  38  39  40  41  42  43  44  45  46  47  48
             28, 18, 36, 41, 52, 14, 48, 37, 24, 49, 17, 47, 20, 38, 40, 45,
    #        49  50  51  52
             46, 15, 26, 29],
            [ 7, 16,  8,  3,  9, 31, 10,  5,  4, 28,  2, 32, 17, 38, 50, 25,
             43, 34, 29, 45, 24, 11, 18, 41, 12, 51, 23, 33, 52, 15, 14,  1,
             21, 30, 22, 35, 40, 46, 26, 47, 36,  6, 27, 20, 48, 49, 44, 39,
             42, 19, 13, 37]
    )

def decryptCards(deckArgs, deckId, seatIndex, account, tableId, room, indices, drawIndices, end=False):
    lines = iter(subprocess.run(
             deckArgs + ["--from", account.address, "decryptCards",
                         "--indices", ",".join(map(str, indices)),
                         "--draw-indices", ",".join(map(str, drawIndices)),
                         "-j", str(deckId), "-s", str(seatIndex)],
            stdout=subprocess.PIPE, check=True, text=True).stdout.splitlines())
    return room.decryptCards(tableId, seatIndex, readIntLists(lines, 8), end, sender=account)

def revealCards(deckArgs, deckId, seatIndex, account, tableId, room, indices, end=False):
    lines = iter(subprocess.run(
             deckArgs + ["--from", account.address, "revealCards",
                         "--indices", ",".join(map(str, indices)),
                         "-j", str(deckId), "-s", str(seatIndex)],
            stdout=subprocess.PIPE, check=True, text=True).stdout.splitlines())
    return room.revealCards(tableId, seatIndex, readIntLists(lines, 7), end, sender=account)

@pytest.fixture(scope="session")
def two_players_selected_dealer(accounts, room, two_players_prepped):
    perm0, perm1 = two_players_empty_shuffle

    two_players_shuffle(accounts, two_players_prepped, room, perm0, perm1)

    tableId = two_players_prepped["tableId"]
    deckId = room.configParams(tableId)[-1]
    deckArgs = two_players_prepped["deckArgs"]

    decryptCards(deckArgs, deckId, 0, accounts[0], tableId, room, [0,1], [0,1])
    decryptCards(deckArgs, deckId, 1, accounts[1], tableId, room, [0,1], [0,1])

    tx3 = revealCards(deckArgs, deckId, 0, accounts[0], tableId, room, [0])
    tx4 = revealCards(deckArgs, deckId, 1, accounts[1], tableId, room, [1], True)

    return two_players_prepped | {"revealCards0": tx3, "revealCards1": tx4}

def test_select_dealer(accounts, two_players_selected_dealer, game):
    tableId = two_players_selected_dealer["tableId"]
    assert game.games(tableId)['dealer'] == 1
    show_event = two_players_selected_dealer["revealCards0"].events[0]
    assert show_event.event_name == "Show"
    assert show_event.event_arguments == {
            "table": tableId,
            "player": accounts[0].address,
            "card": 0,
            "show": 1}
    show_event = two_players_selected_dealer["revealCards1"].events[0]
    assert show_event.event_name == "Show"
    assert show_event.event_arguments == {
            "table": tableId,
            "player": accounts[1].address,
            "card": 1,
            "show": 2}

def is_permutation(perm):
    return set(perm) == set(range(1, 53))

def two_players_hole_cards(accounts, two_players_selected_dealer, room, perm0, perm1):
    two_players_shuffle(accounts, two_players_selected_dealer, room, perm0, perm1)

    tableId = two_players_selected_dealer["tableId"]
    deckId = room.configParams(tableId)[-1]
    deckArgs = two_players_selected_dealer["deckArgs"]

    decryptCards(deckArgs, deckId, 0, accounts[0], tableId, room, [0,1,2,3], [0,1,0,1])
    decryptCards(deckArgs, deckId, 1, accounts[1], tableId, room, [0,1,2,3], [0,1,0,1], True)

def test_fold_blind(accounts, two_players_selected_dealer, room, game):
    perm0, perm1 = two_players_empty_shuffle

    two_players_hole_cards(accounts, two_players_selected_dealer, room, perm0, perm1)

    tableId = two_players_selected_dealer["tableId"]

    with reverts("unauthorised"):
        game.fold(tableId, 1, sender=accounts[0])

    with reverts("wrong turn"):
        game.fold(tableId, 1, sender=accounts[1])

    tx = game.fold(tableId, 0, sender=accounts[0])

    config = two_players_selected_dealer["config"]

    smallBlind = config["structure"][0]

    fold_event = tx.events[0]
    assert fold_event.event_name == "Fold"
    assert fold_event.event_arguments == {"table": tableId, "seat": 0}

    collect_event = tx.events[1]
    assert collect_event.event_name == "CollectPot"
    assert collect_event.event_arguments == {"table": tableId, "seat": 1, "pot": smallBlind * 3}

    assert len(tx.events) == 2

    assert game.games(tableId)["stack"][0] == config["buyIn"] - smallBlind
    assert game.games(tableId)["stack"][1] == config["buyIn"] + smallBlind

def test_dealer_fold_blind(accounts, two_players_selected_dealer, room, game):
    perm0, perm1 = two_players_empty_shuffle

    two_players_hole_cards(accounts, two_players_selected_dealer, room, perm0, perm1)

    tableId = two_players_selected_dealer["tableId"]

    tx = game.callBet(tableId, 0, sender=accounts[0])

    tx = game.fold(tableId, 1, sender=accounts[1])

    config = two_players_selected_dealer["config"]

    smallBlind = config["structure"][0]
    bigBlind = smallBlind * 2
    pot = bigBlind * 2

    fold_event = tx.events[0]
    assert fold_event.event_name == "Fold"
    assert fold_event.event_arguments == {"table": tableId, "seat": 1}

    collect_event = tx.events[1]
    assert collect_event.event_name == "CollectPot"
    assert collect_event.event_arguments == {"table": tableId, "seat": 0, "pot": pot}

    assert game.games(tableId)["stack"][0] == config["buyIn"] + bigBlind
    assert game.games(tableId)["stack"][1] == config["buyIn"] - bigBlind

def test_split_pot(accounts, two_players_selected_dealer, room, game):
    # card indices of the deal:
    # 0 1 2 3 4 5 6 7 8 9 a b
    # 0 1 0 1 b f f f b t b r
    # royal flush in the last suit is cards 48, 49, 50, 51, 52
    # so put these as the ffftr cards (i.e. on the board)
    #        1   2    3   4   5   6   7   8   9  10  11  12  13  14  15  16
    perm0 = [32, 11,  4,  9,  8, 42,  1,  3,  5,  7, 22, 25, 51, 31, 30,  2,
    #        17  18  19  20  21  22  23  24  25  26  27  28  29  30  31  32
             13, 23, 50, 44, 33, 35, 27, 21, 16, 39, 43, 10, 19, 34,  6, 12,
    #        33  34  35  36  37  38  39  40  41  42  43  44  45  46  47  48
             28, 18, 36, 41, 52, 14, 48, 37, 24, 49, 17, 47, 20, 38, 40, 45,
    #        49  50  51  52
             46, 15, 26, 29]
    perm1 = [ 7, 16,  8,  3,  9, 39, 42, 19,  4, 13,  2, 37, 17, 38, 50, 25,
             43, 34, 32, 45, 24, 11,  5, 41, 12, 51, 23, 33, 52, 28, 14,  1,
             21, 30, 22, 35, 40, 46, 15, 47, 36,  6, 27, 20, 48, 49, 44, 31,
             10, 18, 26, 29]

    assert is_permutation(perm0)
    assert is_permutation(perm1)

    two_players_hole_cards(accounts, two_players_selected_dealer, room, perm0, perm1)

    tableId = two_players_selected_dealer["tableId"]
    deckId = room.configParams(tableId)[-1]
    deckArgs = two_players_selected_dealer["deckArgs"]

    game.callBet(tableId, 0, sender=accounts[0])
    game.callBet(tableId, 1, sender=accounts[1])

    decryptCards(deckArgs, deckId, 0, accounts[0], tableId, room, [5,6,7], [1,1,1])
    decryptCards(deckArgs, deckId, 1, accounts[1], tableId, room, [5,6,7], [1,1,1])
    tx = revealCards(deckArgs, deckId, 1, accounts[1], tableId, room, [5,6,7], True)
    show_event = tx.events[0]
    assert show_event.event_name == "Show"
    assert show_event.event_arguments == {
            "table": tableId, "player": accounts[1].address,
            "card": 5, "show": 48}
    show_event = tx.events[1]
    assert show_event.event_name == "Show"
    assert show_event.event_arguments == {
            "table": tableId, "player": accounts[1].address,
            "card": 6, "show": 49}
    show_event = tx.events[2]
    assert show_event.event_name == "Show"
    assert show_event.event_arguments == {
            "table": tableId, "player": accounts[1].address,
            "card": 7, "show": 50}

    game.callBet(tableId, 0, sender=accounts[0])
    game.callBet(tableId, 1, sender=accounts[1])

    decryptCards(deckArgs, deckId, 0, accounts[0], tableId, room, [9], [1])
    decryptCards(deckArgs, deckId, 1, accounts[1], tableId, room, [9], [1])
    tx = revealCards(deckArgs, deckId, 1, accounts[1], tableId, room, [9], True)
    show_event = tx.events[0]
    assert show_event.event_name == "Show"
    assert show_event.event_arguments == {
            "table": tableId, "player": accounts[1].address,
            "card": 9, "show": 51}

    game.callBet(tableId, 0, sender=accounts[0])
    game.callBet(tableId, 1, sender=accounts[1])

    decryptCards(deckArgs, deckId, 0, accounts[0], tableId, room, [11], [1])
    decryptCards(deckArgs, deckId, 1, accounts[1], tableId, room, [11], [1])
    tx = revealCards(deckArgs, deckId, 1, accounts[1], tableId, room, [11], True)
    show_event = tx.events[0]
    assert show_event.event_name == "Show"
    assert show_event.event_arguments == {
            "table": tableId, "player": accounts[1].address,
            "card": 11, "show": 52}

    game.callBet(tableId, 0, sender=accounts[0])
    game.callBet(tableId, 1, sender=accounts[1])

    with reverts("wrong turn"):
        game.showCards(tableId, 1, sender=accounts[1])

    with reverts("wrong turn"):
        game.foldCards(tableId, 1, sender=accounts[1])

    game.showCards(tableId, 0, sender=accounts[0])

    tx = revealCards(deckArgs, deckId, 0, accounts[0], tableId, room, [0,2], True)
    show_event = tx.events[0]
    assert show_event.event_name == "Show"
    assert show_event.event_arguments == {
            "table": tableId, "player": accounts[0].address,
            "card": 0, "show": 1}
    show_event = tx.events[1]
    assert show_event.event_name == "Show"
    assert show_event.event_arguments == {
            "table": tableId, "player": accounts[0].address,
            "card": 2, "show": 3}

    rank = (9 << (5 * 8)) + (12 << (4 * 8))

    game.showCards(tableId, 1, sender=accounts[1])
    tx = revealCards(deckArgs, deckId, 1, accounts[1], tableId, room, [1,3], True)
    show_event = tx.events[0]
    assert show_event.event_name == "Show"
    assert show_event.event_arguments == {
            "table": tableId, "player": accounts[1].address,
            "card": 1, "show": 2}
    show_event = tx.events[1]
    assert show_event.event_name == "Show"
    assert show_event.event_arguments == {
            "table": tableId, "player": accounts[1].address,
            "card": 3, "show": 4}
    show_event = tx.events[2]
    assert show_event.event_name == "ShowHand"
    assert show_event.event_arguments == {
            "table": tableId, "seat": 0, "rank": rank }
    show_event = tx.events[3]
    assert show_event.event_name == "ShowHand"
    assert show_event.event_arguments == {
            "table": tableId, "seat": 1, "rank": rank }

    config = two_players_selected_dealer["config"]
    smallBlind = config["structure"][0]
    bigBlind = smallBlind * 2
    pot = bigBlind * 2
    share = pot // 2

    collect_event = tx.events[4]
    assert collect_event.event_name == "CollectPot"
    assert collect_event.event_arguments == {"table": tableId, "seat": 0, "pot": share}

    collect_event = tx.events[5]
    assert collect_event.event_name == "CollectPot"
    assert collect_event.event_arguments == {"table": tableId, "seat": 1, "pot": share}

    assert share + share == pot, "two players always split evenly"

    assert room.phaseCommit(tableId)[0] == Phase_SHUF, "onto shuffle for next hand"

def test_raise_all_in_blind_call(accounts, two_players_selected_dealer, room, game):
    perm0, perm1 = two_players_empty_shuffle

    two_players_hole_cards(accounts, two_players_selected_dealer, room, perm0, perm1)

    tableId = two_players_selected_dealer["tableId"]
    config = two_players_selected_dealer["config"]

    game.callBet(tableId, 0, sender=accounts[0])

    with reverts("size exceeds stack"):
        game.raiseBet(tableId, 1, config["buyIn"] + 1, sender=accounts[1])

    tx = game.raiseBet(tableId, 1, config["buyIn"], sender=accounts[1])

    smallBlind = config["structure"][0]
    bigBlind = smallBlind * 2

    raise_event = tx.events[0]
    assert raise_event.event_name == "RaiseBet"
    assert raise_event.event_arguments == {
            "table": tableId,
            "seat": 1,
            "bet": config["buyIn"],
            "placed": config["buyIn"] - bigBlind}

    tx = game.callBet(tableId, 0, sender=accounts[0])

    round_event = tx.events[1]
    assert round_event.event_name == "DealRound"
    assert round_event.event_arguments == {"table": tableId, "street": 2}
