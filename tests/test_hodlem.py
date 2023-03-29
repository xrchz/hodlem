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

def test_too_many_players(accounts, room, game):
    config = dict(
            buyIn=1000,
            bond=2000,
            startsWith=10,
            untilLeft=1,
            structure=[10, 20, 30, 40],
            levelBlocks=20,
            verifRounds=4,
            prepBlocks=10,
            shuffBlocks=10,
            verifBlocks=15,
            dealBlocks=10,
            actBlocks=15)
    with reverts("invalid startsWith"):
        room.createTable(0, config, game.address,
                         sender=accounts[1], value="3000 wei")

def test_max_players(accounts, room, game):
    config = dict(
            buyIn=1000,
            bond=2000,
            startsWith=9,
            untilLeft=1,
            structure=[10, 20, 30, 40],
            levelBlocks=20,
            verifRounds=4,
            prepBlocks=10,
            shuffBlocks=10,
            verifBlocks=15,
            dealBlocks=10,
            actBlocks=15)
    tx = room.createTable(0, config, game.address,
                          sender=accounts[1], value="3000 wei")
    assert len(tx.events) == 1
    assert tx.events[0].event_name == "JoinTable"

def test_one_too_many_until_left(accounts, room, game):
    config = dict(
            buyIn=1000,
            bond=2000,
            startsWith=3,
            untilLeft=3,
            structure=[10, 20, 30, 40],
            levelBlocks=20,
            verifRounds=4,
            prepBlocks=10,
            shuffBlocks=10,
            verifBlocks=15,
            dealBlocks=10,
            actBlocks=15)
    with reverts("invalid untilLeft"):
        room.createTable(0, config, game.address,
                         sender=accounts[1], value="3000 wei")

def test_one_level(accounts, room, game):
    config = dict(
            buyIn=1000,
            bond=2000,
            startsWith=3,
            untilLeft=2,
            structure=[100],
            levelBlocks=20,
            verifRounds=4,
            prepBlocks=10,
            shuffBlocks=10,
            verifBlocks=15,
            dealBlocks=10,
            actBlocks=15)
    tx = room.createTable(0, config, game.address,
                          sender=accounts[0], value="3000 wei")
    assert len(tx.events) == 1
    assert tx.events[0].event_name == "JoinTable"

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
def deckArgs(networks, deck):
    db_path = "tests/db.json"
    try:
        os.remove(db_path)
    except FileNotFoundError:
        pass
    return ["interface/deck.js", "--db", db_path,
            "--rpc", networks.active_provider.web3.provider.endpoint_uri,
            "--deck", deck.address,
            "--id", "0"]

def submitPrep(deckArgs, account, room, tableId, seatIndex):
    result = subprocess.run(
                 deckArgs + ["--from", account.address, "submitPrep"],
                 capture_output=True, check=True, text=True).stdout.strip()
    return room.submitPrep(tableId, seatIndex, result, sender=account)

def verifyPrep(deckArgs, account, room, tableId, seatIndex):
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
        deckArgs + ["--from", account.address, "verifyPrep"],
        capture_output=True, check=True, text=True).stdout.splitlines())
    return room.verifyPrep(tableId, seatIndex, readPrep(lines), sender=account)

@pytest.fixture(scope="session")
def two_players_prepped(networks, accounts, deck, room, game, deckArgs):
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

    submitPrep(deckArgs, accounts[0], room, tableId, 0)
    submitPrep(deckArgs, accounts[1], room, tableId, 1)
    verifyPrep(deckArgs, accounts[0], room, tableId, 0)
    verifyPrep(deckArgs, accounts[1], room, tableId, 1)

    return dict(tableId=tableId, config=config)

@pytest.fixture(scope="session")
def three_players_prepped(networks, accounts, deck, room, game, deckArgs):
    config = dict(
            buyIn=1000,
            bond=5000000,
            startsWith=3,
            untilLeft=1,
            structure=[50, 100, 200, 400, 800],
            levelBlocks=50,
            verifRounds=3,
            prepBlocks=20,
            shuffBlocks=25,
            verifBlocks=35,
            dealBlocks=15,
            actBlocks=10)
    value = f"{config['bond'] + config['buyIn']} wei"
    tx = room.createTable(0, config, game.address, sender=accounts[0], value=value)
    tableId = tx.return_value
    tx = room.joinTable(tableId, 2, sender=accounts[2], value=value)
    tx = room.joinTable(tableId, 1, sender=accounts[1], value=value)

    submitPrep(deckArgs, accounts[0], room, tableId, 0)
    submitPrep(deckArgs, accounts[1], room, tableId, 1)
    submitPrep(deckArgs, accounts[2], room, tableId, 2)
    verifyPrep(deckArgs, accounts[2], room, tableId, 2)
    verifyPrep(deckArgs, accounts[1], room, tableId, 1)
    verifyPrep(deckArgs, accounts[0], room, tableId, 0)

    return dict(tableId=tableId, config=config)

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

def shuffle(deckArgs, account, verifRounds, deckId, perm, tableId, seatIndex, room):
    def readShuffle(f):
        a = []
        def n():
            return int(next(f), 16)
        for _ in range(53):
            a.append([n(), n()])
        return a

    lines = iter(subprocess.run(
             deckArgs + ["--from", account.address, "shuffle",
                         "-v", str(verifRounds), "-j", str(deckId),
                         "--order", ','.join([str(n) for n in perm])],
            stdout=subprocess.PIPE, check=True, text=True).stdout.splitlines())

    return room.submitShuffle(tableId, seatIndex, readShuffle(lines), next(lines), sender=account)

def verifyShuffle(deckArgs, account, deckId, seatIndex, tableId, room):
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
             deckArgs + ["--from", account.address, "verifyShuffle",
                         "-j", str(deckId), "-s", str(seatIndex)],
            stdout=subprocess.PIPE, check=True, text=True).stdout.splitlines())
    c, s, p = readVerification(lines)
    return room.verifyShuffle(tableId, seatIndex, c, s, p, sender=account)

def two_players_shuffle(accounts, two_players_prepped, deckArgs, room, perm0, perm1):
    tableId = two_players_prepped["tableId"]
    deckId = room.configParams(tableId)[-1]
    config = two_players_prepped["config"]
    verifRounds = config["verifRounds"]
    shuffle(deckArgs, accounts[0], verifRounds, deckId, perm0, tableId, 0, room)
    shuffle(deckArgs, accounts[1], verifRounds, deckId, perm1, tableId, 1, room)
    verifyShuffle(deckArgs, accounts[0], deckId, 0, tableId, room)
    verifyShuffle(deckArgs, accounts[1], deckId, 1, tableId, room)

def three_players_shuffle(accounts, three_players_prepped, deckArgs, room, perms):
    tableId = three_players_prepped["tableId"]
    deckId = room.configParams(tableId)[-1]
    config = three_players_prepped["config"]
    verifRounds = config["verifRounds"]
    shuffle(deckArgs, accounts[0], verifRounds, deckId, perms[0], tableId, 0, room)
    shuffle(deckArgs, accounts[1], verifRounds, deckId, perms[1], tableId, 1, room)
    shuffle(deckArgs, accounts[2], verifRounds, deckId, perms[2], tableId, 2, room)
    verifyShuffle(deckArgs, accounts[0], deckId, 0, tableId, room)
    verifyShuffle(deckArgs, accounts[1], deckId, 1, tableId, room)
    return verifyShuffle(deckArgs, accounts[2], deckId, 2, tableId, room)

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
    lists = readIntLists(lines, 8)
    return room.decryptCards(tableId, seatIndex, lists, end, sender=account)

def revealCardsLists(deckArgs, deckId, seatIndex, account, indices):
    lines = iter(subprocess.run(
             deckArgs + ["--from", account.address, "revealCards",
                         "--indices", ",".join(map(str, indices)),
                         "-j", str(deckId), "-s", str(seatIndex)],
            stdout=subprocess.PIPE, check=True, text=True).stdout.splitlines())
    return readIntLists(lines, 7)

def revealCards(deckArgs, deckId, seatIndex, account, tableId, room, indices, end=False):
    lists = revealCardsLists(deckArgs, deckId, seatIndex, account, indices)
    return room.revealCards(tableId, seatIndex, lists, end, sender=account)

@pytest.fixture(scope="session")
def two_players_selected_dealer(accounts, room, two_players_prepped, deckArgs):
    perm0, perm1 = two_players_empty_shuffle

    two_players_shuffle(accounts, two_players_prepped, deckArgs, room, perm0, perm1)

    tableId = two_players_prepped["tableId"]
    deckId = room.configParams(tableId)[-1]

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

def two_players_hole_cards(accounts, two_players_selected_dealer, deckArgs, room, perm0, perm1):
    two_players_shuffle(accounts, two_players_selected_dealer, deckArgs, room, perm0, perm1)

    tableId = two_players_selected_dealer["tableId"]
    deckId = room.configParams(tableId)[-1]

    decryptCards(deckArgs, deckId, 0, accounts[0], tableId, room, [0,1,2,3], [0,1,0,1])
    decryptCards(deckArgs, deckId, 1, accounts[1], tableId, room, [0,1,2,3], [0,1,0,1], True)

def test_fold_blind(accounts, two_players_selected_dealer, deckArgs, room, game):
    perm0, perm1 = two_players_empty_shuffle

    two_players_hole_cards(accounts, two_players_selected_dealer, deckArgs, room, perm0, perm1)

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

def test_dealer_fold_blind(accounts, two_players_selected_dealer, deckArgs, room, game):
    perm0, perm1 = two_players_empty_shuffle

    two_players_hole_cards(accounts, two_players_selected_dealer, deckArgs, room, perm0, perm1)

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

def test_split_pot(accounts, two_players_selected_dealer, deckArgs, room, game):
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

    two_players_hole_cards(accounts, two_players_selected_dealer, deckArgs, room, perm0, perm1)

    tableId = two_players_selected_dealer["tableId"]
    deckId = room.configParams(tableId)[-1]

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

    lists = revealCardsLists(deckArgs, deckId, 0, accounts[0], [0,2])

    with reverts("wrong turn"):
        game.showCards(tableId, 1, lists, sender=accounts[1])

    with reverts("wrong turn"):
        game.foldCards(tableId, 1, sender=accounts[1])

    tx = game.showCards(tableId, 0, lists, sender=accounts[0])
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

    lists = revealCardsLists(deckArgs, deckId, 1, accounts[1], [1,3])
    tx = game.showCards(tableId, 1, lists, sender=accounts[1])
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

def test_raise_all_in_blind_call(accounts, two_players_selected_dealer, deckArgs, room, game):
    perm0, perm1 = two_players_empty_shuffle

    two_players_hole_cards(accounts, two_players_selected_dealer, deckArgs, room, perm0, perm1)

    tableId = two_players_selected_dealer["tableId"]
    config = two_players_selected_dealer["config"]

    game.callBet(tableId, 0, sender=accounts[0])

    buyIn = config["buyIn"]

    with reverts("size exceeds stack"):
        game.raiseBet(tableId, 1, buyIn + 1, sender=accounts[1])

    tx = game.raiseBet(tableId, 1, buyIn, sender=accounts[1])

    smallBlind = config["structure"][0]
    bigBlind = smallBlind * 2

    assert len(tx.events) == 1
    raise_event = tx.events[0]
    assert raise_event.event_name == "RaiseBet"
    assert raise_event.event_arguments == {
            "table": tableId,
            "seat": 1,
            "bet": buyIn,
            "placed": buyIn - bigBlind}

    tx = game.callBet(tableId, 0, sender=accounts[0])

    assert len(tx.events) == 4
    call_event = tx.events[0]
    assert call_event.event_name == "CallBet"
    assert call_event.event_arguments == {
            "table": tableId,
            "seat": 0,
            "bet": buyIn,
            "placed": buyIn - bigBlind}

    round_event = tx.events[1]
    assert round_event.event_name == "DealRound"
    assert round_event.event_arguments == {"table": tableId, "street": 2}

    round_event = tx.events[2]
    assert round_event.event_name == "DealRound"
    assert round_event.event_arguments == {"table": tableId, "street": 3}

    round_event = tx.events[3]
    assert round_event.event_name == "DealRound"
    assert round_event.event_arguments == {"table": tableId, "street": 4}

    with reverts("unauthorised"):
        game.showCards(tableId, 0, [list(range(7)), list(range(7))], sender=accounts[0])

    deckId = room.configParams(tableId)[-1]

    cards = [5,6,7,9,11]
    decryptCards(deckArgs, deckId, 0, accounts[0], tableId, room, cards, [1,1,1,1,1])
    decryptCards(deckArgs, deckId, 1, accounts[1], tableId, room, cards, [1,1,1,1,1])
    revealCards(deckArgs, deckId, 0, accounts[0], tableId, room, [0,2])
    tx = revealCards(deckArgs, deckId, 1, accounts[1], tableId, room, cards + [1,3], True)
    assert len(tx.events) == 12
    for event, i in zip(tx.events, cards + [1,3]):
        assert event.event_name == "Show"
        assert event.event_arguments == {
                "table": tableId,
                "player": accounts[1].address,
                "card": i,
                "show": i+1}
    round_event = tx.events[7]
    assert round_event.event_name == "DealRound"
    assert round_event.event_arguments == {"table": tableId, "street": 5}

    # shown 2 4 6 7 8 10 12 = flush with ranks 3 5 7 8 9 J K
    rank = (6 << (5 * 8)) + (11 << (4 * 8)) + (9 << (3 * 8)) + (7 << (2 * 8)) + (6 << (1 * 8)) + 5
    event = tx.events[8]
    assert event.event_name == "ShowHand"
    assert event.event_arguments == { "table": tableId, "seat": 0, "rank": rank}

    # shown 1 3 6 7 8 10 12, so same best hand
    event = tx.events[9]
    assert event.event_name == "ShowHand"
    assert event.event_arguments == { "table": tableId, "seat": 1, "rank": rank}

    event = tx.events[10]
    assert event.event_name == "CollectPot"
    assert event.event_arguments == {"table": tableId, "seat": 0, "pot": buyIn}

    event = tx.events[11]
    assert event.event_name == "CollectPot"
    assert event.event_arguments == {"table": tableId, "seat": 1, "pot": buyIn}

@pytest.fixture(scope="session")
def three_players_arbitrary_shuffled(
        accounts, three_players_prepped, deckArgs, room):
    perm0, perm1 = two_players_empty_shuffle
    three_players_shuffle(accounts, three_players_prepped, deckArgs, room, [perm0, perm1, perm0])
    return three_players_prepped

def test_three_players_deal_timeout(accounts, chain, three_players_arbitrary_shuffled, deckArgs, room):
    tableId = three_players_arbitrary_shuffled["tableId"]
    with reverts("deadline not passed"):
        room.decryptTimeout(tableId, 0, 0, sender=accounts[1])
    dealBlocks = three_players_arbitrary_shuffled["config"]["dealBlocks"]
    chain.mine(dealBlocks)
    tx = room.decryptTimeout(tableId, 0, 0, sender=accounts[1])
    assert len(tx.events) == 5
    assert tx.events[0].event_name == "Challenge"
    assert tx.events[0].event_arguments == {
            "table": tableId,
            "player": accounts[0].address,
            "sender": accounts[1].address,
            "type": 4
        }
    assert tx.events[1].event_name == "LeaveTable"
    assert tx.events[2].event_name == "LeaveTable"
    assert tx.events[3].event_name == "LeaveTable"
    assert tx.events[4].event_name == "EndGame"
    assert tx.events[4].event_arguments == {"table": tableId}

@pytest.fixture(scope="session")
def three_players_selected_dealer(accounts, room, three_players_arbitrary_shuffled, deckArgs):
    tableId = three_players_arbitrary_shuffled["tableId"]
    deckId = room.configParams(tableId)[-1]

    decryptCards(deckArgs, deckId, 0, accounts[0], tableId, room, [0,1,2], [0,1,2])
    decryptCards(deckArgs, deckId, 1, accounts[1], tableId, room, [0,1,2], [0,1,2])
    decryptCards(deckArgs, deckId, 2, accounts[2], tableId, room, [0,1,2], [0,1,2])

    revealCards(deckArgs, deckId, 0, accounts[0], tableId, room, [0])
    revealCards(deckArgs, deckId, 1, accounts[1], tableId, room, [1])
    revealCards(deckArgs, deckId, 2, accounts[2], tableId, room, [2], True)

    return three_players_arbitrary_shuffled

def test_uneven_split(accounts, room, game, deckArgs, three_players_selected_dealer):
    config = three_players_selected_dealer["config"]
    tableId = three_players_selected_dealer["tableId"]
    deckId = room.configParams(tableId)[-1]
    smallBlind = config["structure"][0]
    bigBlind = smallBlind * 2

    perm = list(range(1, 53))
    # ensure we get a flush by swapping the burned A with the 2 of the next suit
    perm[13] = 13
    perm[12] = 14

    three_players_shuffle(accounts, three_players_selected_dealer, deckArgs, room,
                          two_players_empty_shuffle + (perm,))
    holeCards = [0,1,2,3,4,5]
    drawnTo   = [2,0,1,2,0,1]
    decryptCards(deckArgs, deckId, 0, accounts[0], tableId, room, holeCards, drawnTo)
    decryptCards(deckArgs, deckId, 1, accounts[1], tableId, room, holeCards, drawnTo)
    decryptCards(deckArgs, deckId, 2, accounts[2], tableId, room, holeCards, drawnTo, True)

    with reverts("wrong turn"):
        game.raiseBet(tableId, 0, 1, sender=accounts[0])

    with reverts("not a bet/raise"):
        game.raiseBet(tableId, 1, 1, sender=accounts[1])

    with reverts("below minimum"):
        game.raiseBet(tableId, 1, bigBlind + smallBlind, sender=accounts[1])

    tx = game.raiseBet(tableId, 1, bigBlind + bigBlind + 1, sender=accounts[1])
    assert len(tx.events) == 1
    assert tx.events[0].event_name == "RaiseBet"
    assert tx.events[0].event_arguments == {
            "table": tableId, "seat": 1,
            "bet": bigBlind * 2 + 1, "placed": bigBlind * 2 + 1
            }

    tx = game.callBet(tableId, 2, sender=accounts[2])
    assert len(tx.events) == 1
    assert tx.events[0].event_name == "CallBet"
    assert tx.events[0].event_arguments == {
            "table": tableId, "seat": 2,
            "bet": bigBlind * 2 + 1, "placed": smallBlind + bigBlind + 1}

    tx = game.callBet(tableId, 0, sender=accounts[0])
    assert len(tx.events) == 2
    assert tx.events[0].event_name == "CallBet"
    assert tx.events[0].event_arguments == {
            "table": tableId, "seat": 0,
            "bet": bigBlind * 2 + 1, "placed": bigBlind + 1}
    assert tx.events[1].event_name == "DealRound"
    assert tx.events[1].event_arguments == {"table": tableId, "street": 2}

    flop = [7,8,9]
    drawnTo = [1,1,1]
    decryptCards(deckArgs, deckId, 0, accounts[0], tableId, room, flop, drawnTo)
    decryptCards(deckArgs, deckId, 1, accounts[1], tableId, room, flop, drawnTo)
    decryptCards(deckArgs, deckId, 2, accounts[2], tableId, room, flop, drawnTo)
    revealCards(deckArgs, deckId, 1, accounts[1], tableId, room, flop, True)

    game.callBet(tableId, 2, sender=accounts[2])
    game.callBet(tableId, 0, sender=accounts[0])
    tx = game.fold(tableId, 1, sender=accounts[1])
    assert len(tx.events) == 2
    assert tx.events[0].event_name == "Fold"
    assert tx.events[0].event_arguments == {"table": tableId, "seat": 1}

    turn = [11]
    drawnTo = [1]
    decryptCards(deckArgs, deckId, 0, accounts[0], tableId, room, turn, drawnTo)
    decryptCards(deckArgs, deckId, 1, accounts[1], tableId, room, turn, drawnTo)
    decryptCards(deckArgs, deckId, 2, accounts[2], tableId, room, turn, drawnTo)
    revealCards(deckArgs, deckId, 1, accounts[1], tableId, room, turn, True)

    game.callBet(tableId, 2, sender=accounts[2])
    tx = game.callBet(tableId, 0, sender=accounts[0])
    with reverts("unauthorised"):
        game.callBet(tableId, 1, sender=accounts[1])
    assert len(tx.events) == 2
    assert tx.events[1].event_name == "DealRound"
    assert tx.events[1].event_arguments == {"table": tableId, "street": 4}

    river = [13]
    drawnTo = [1]
    decryptCards(deckArgs, deckId, 0, accounts[0], tableId, room, river, drawnTo)
    decryptCards(deckArgs, deckId, 1, accounts[1], tableId, room, river, drawnTo)
    decryptCards(deckArgs, deckId, 2, accounts[2], tableId, room, river, drawnTo)
    tx = revealCards(deckArgs, deckId, 1, accounts[1], tableId, room, river, True)
    assert len(tx.events) == 1
    show_event = tx.events[0]
    assert show_event.event_name == "Show"
    assert show_event.event_arguments == {
            "table": tableId, "player": accounts[1].address,
            "card": 13, "show": 13}

    game.callBet(tableId, 2, sender=accounts[2])
    tx = game.callBet(tableId, 0, sender=accounts[0])
    assert len(tx.events) == 2
    assert tx.events[1].event_name == "DealRound"
    assert tx.events[1].event_arguments == {"table": tableId, "street": 5}

    lists = revealCardsLists(deckArgs, deckId, 2, accounts[2], [0,3])
    tx = game.showCards(tableId, 2, lists, sender=accounts[2])
    assert len(tx.events) == 2
    show_event = tx.events[0]
    assert show_event.event_name == "Show"
    assert show_event.event_arguments == {
            "table": tableId, "player": accounts[2].address,
            "card": 0, "show": 1}
    show_event = tx.events[1]
    assert show_event.event_name == "Show"
    assert show_event.event_arguments == {
            "table": tableId, "player": accounts[2].address,
            "card": 3, "show": 4}

    lists = revealCardsLists(deckArgs, deckId, 0, accounts[0], [1,4])
    tx = game.showCards(tableId, 0, lists, sender=accounts[0])
    assert len(tx.events) == 6

    # shown indices: 1/2 4/5 8 9 10 12 13
    # flush ranks: 2/3 5/6 9 10 J K A
    rank = (6 << (5 * 8)) + (12 << (4 * 8)) + (11 << (3 * 8)) + (9 << (2 * 8)) + (8 << (1 * 8)) + 7
    show_event = tx.events[2]
    assert show_event.event_name == "ShowHand"
    assert show_event.event_arguments == {
            "table": tableId, "seat": 0, "rank": rank}

    show_event = tx.events[3]
    assert show_event.event_name == "ShowHand"
    assert show_event.event_arguments == {
            "table": tableId, "seat": 2, "rank": rank}

    # pot was 3 * (bigBlind * 2 + 1) == 6 * bigBlind + 3
    # split is 3 * bigBlind + 1.5
    # 0 gets the extra chip because they have the higher card in hand
    collect_event = tx.events[4]
    assert collect_event.event_name == "CollectPot"
    assert collect_event.event_arguments == {
            "table": tableId, "seat": 0, "pot": bigBlind * 3 + 2}
    collect_event = tx.events[5]
    assert collect_event.event_name == "CollectPot"
    assert collect_event.event_arguments == {
            "table": tableId, "seat": 2, "pot": bigBlind * 3 + 1}

def test_side_pot(accounts, three_players_selected_dealer, deckArgs, room, game):
    # one player all-in, the other two keep betting
    # (first need one hand to establish a short stack)
    config = three_players_selected_dealer["config"]
    tableId = three_players_selected_dealer["tableId"]
    deckId = room.configParams(tableId)[-1]
    smallBlind = config["structure"][0]
    bigBlind = smallBlind * 2

    perm = list(range(1, 53))

    three_players_shuffle(accounts, three_players_selected_dealer, deckArgs, room,
                          two_players_empty_shuffle + (perm,))
    cards   = [0,1,2,3,4,5]
    drawnTo = [2,0,1,2,0,1]
    decryptCards(deckArgs, deckId, 0, accounts[0], tableId, room, cards, drawnTo)
    decryptCards(deckArgs, deckId, 1, accounts[1], tableId, room, cards, drawnTo)
    decryptCards(deckArgs, deckId, 2, accounts[2], tableId, room, cards, drawnTo, True)

    game.raiseBet(tableId, 1, bigBlind * 3, sender=accounts[1])
    game.callBet(tableId, 2, sender=accounts[2])
    game.fold(tableId, 0, sender=accounts[0])

    cards   = [7,8,9]
    drawnTo = [1,1,1]
    decryptCards(deckArgs, deckId, 0, accounts[0], tableId, room, cards, drawnTo)
    decryptCards(deckArgs, deckId, 1, accounts[1], tableId, room, cards, drawnTo)
    decryptCards(deckArgs, deckId, 2, accounts[2], tableId, room, cards, drawnTo)
    revealCards(deckArgs, deckId, 1, accounts[1], tableId, room, cards, True)

    game.callBet(tableId, 2, sender=accounts[2])
    game.raiseBet(tableId, 1, bigBlind * 3, sender=accounts[1])
    game.callBet(tableId, 2, sender=accounts[2])

    cards   = [11]
    drawnTo = [1]
    decryptCards(deckArgs, deckId, 0, accounts[0], tableId, room, cards, drawnTo)
    decryptCards(deckArgs, deckId, 1, accounts[1], tableId, room, cards, drawnTo)
    decryptCards(deckArgs, deckId, 2, accounts[2], tableId, room, cards, drawnTo)
    revealCards(deckArgs, deckId, 1, accounts[1], tableId, room, cards, True)

    tx = game.fold(tableId, 2, sender=accounts[2])

    assert len(tx.events) == 2
    assert tx.events[1].event_name == "CollectPot"
    pot = bigBlind + 2 * (bigBlind * 3 * 2)
    assert tx.events[1].event_arguments == {
            "table": tableId, "seat": 1, "pot": pot}

    # 1 is up 7BB, 2 is down 6BB, 0 is down 1BB

    # now 2 is dealer
    three_players_shuffle(accounts, three_players_selected_dealer, deckArgs, room,
                          (perm,) + two_players_empty_shuffle)
    cards   = [0,1,2,3,4,5]
    drawnTo = [0,1,2,0,1,2]
    decryptCards(deckArgs, deckId, 0, accounts[0], tableId, room, cards, drawnTo)
    decryptCards(deckArgs, deckId, 1, accounts[1], tableId, room, cards, drawnTo)
    decryptCards(deckArgs, deckId, 2, accounts[2], tableId, room, cards, drawnTo, True)

    buyIn = config["buyIn"]
    game.raiseBet(tableId, 2, buyIn - 6 * bigBlind, sender=accounts[2])
    game.callBet(tableId, 0, sender=accounts[0])
    game.callBet(tableId, 1, sender=accounts[1])

    cards   = [7,8,9]
    drawnTo = [2,2,2]
    decryptCards(deckArgs, deckId, 0, accounts[0], tableId, room, cards, drawnTo)
    decryptCards(deckArgs, deckId, 1, accounts[1], tableId, room, cards, drawnTo)
    decryptCards(deckArgs, deckId, 2, accounts[2], tableId, room, cards, drawnTo)
    revealCards(deckArgs, deckId, 2, accounts[2], tableId, room, cards, True)

    game.callBet(tableId, 0, sender=accounts[0])
    tx = game.raiseBet(tableId, 1, bigBlind, sender=accounts[1])
    assert tx.events[0].event_name == "RaiseBet"
    assert tx.events[0].event_arguments == {
            "table": tableId, "seat": 1,
            "bet": bigBlind, "placed": bigBlind}
    tx = game.callBet(tableId, 0, sender=accounts[0])
    assert tx.events[0].event_name == "CallBet"
    assert tx.events[0].event_arguments == {
            "table": tableId, "seat": 0,
            "bet": bigBlind, "placed": bigBlind}

    cards   = [11]
    drawnTo = [2]
    decryptCards(deckArgs, deckId, 0, accounts[0], tableId, room, cards, drawnTo)
    decryptCards(deckArgs, deckId, 1, accounts[1], tableId, room, cards, drawnTo)
    decryptCards(deckArgs, deckId, 2, accounts[2], tableId, room, cards, drawnTo)
    revealCards(deckArgs, deckId, 2, accounts[2], tableId, room, cards, True)

    game.callBet(tableId, 0, sender=accounts[0])
    tx = game.raiseBet(tableId, 1, bigBlind, sender=accounts[1])
    assert tx.events[0].event_name == "RaiseBet"
    assert tx.events[0].event_arguments == {
            "table": tableId, "seat": 1,
            "bet": bigBlind, "placed": bigBlind}
    tx = game.fold(tableId, 0, sender=accounts[0])

    assert len(tx.events) == 3
    assert tx.events[0].event_name == "Fold"
    assert tx.events[0].event_arguments == {"table": tableId, "seat": 0}
    assert tx.events[1].event_name == "CollectPot"
    assert tx.events[1].event_arguments == {
            "table": tableId,
            "seat": 1,
            "pot": 3 * bigBlind}
    assert tx.events[2].event_name == "DealRound"
    assert tx.events[2].event_arguments == {
            "table": tableId,
            "street": 4}

    cards   = [13]
    drawnTo = [2]
    decryptCards(deckArgs, deckId, 0, accounts[0], tableId, room, cards, drawnTo)
    decryptCards(deckArgs, deckId, 1, accounts[1], tableId, room, cards, drawnTo)
    decryptCards(deckArgs, deckId, 2, accounts[2], tableId, room, cards, drawnTo)
    with reverts("reveal not allowed"):
        revealCards(deckArgs, deckId, 2, accounts[2], tableId, room, [2,5])
    tx = revealCards(deckArgs, deckId, 2, accounts[2], tableId, room, cards, True)

    assert len(tx.events) == 2
    assert tx.events[0].event_name == "Show"
    assert tx.events[1].event_name == "DealRound"

    with reverts("unauthorised"):
        game.raiseBet(tableId, 1, 2 * bigBlind, sender=accounts[1])

    with reverts("wrong phase"):
        revealCards(deckArgs, deckId, 2, accounts[2], tableId, room, [2,5], True)

    lists = revealCardsLists(deckArgs, deckId, 1, accounts[1], [1,4])
    game.showCards(tableId, 1, lists, sender=accounts[1])

    tx = revealCards(deckArgs, deckId, 2, accounts[2], tableId, room, [2,5], True)

    assert len(tx.events) == 5
    assert tx.events[0].event_name == "Show"
    assert tx.events[1].event_name == "Show"
    assert tx.events[2].event_name == "ShowHand"
    assert tx.events[3].event_name == "ShowHand"
    assert tx.events[4].event_name == "CollectPot"

def test_all_in_blinds_eliminate(accounts, deckArgs, room, game):
    config = dict(
            buyIn=10,
            bond=3000,
            startsWith=3,
            untilLeft=2,
            structure=[10],
            levelBlocks=50,
            verifRounds=3,
            prepBlocks=20,
            shuffBlocks=25,
            verifBlocks=35,
            dealBlocks=15,
            actBlocks=10)
    value = f"{config['bond'] + config['buyIn']} wei"
    tx = room.createTable(0, config, game.address, sender=accounts[0], value=value)
    tableId = tx.return_value
    tx = room.joinTable(tableId, 2, sender=accounts[2], value=value)
    tx = room.joinTable(tableId, 1, sender=accounts[1], value=value)

    submitPrep(deckArgs, accounts[0], room, tableId, 0)
    submitPrep(deckArgs, accounts[1], room, tableId, 1)
    submitPrep(deckArgs, accounts[2], room, tableId, 2)
    verifyPrep(deckArgs, accounts[2], room, tableId, 2)
    verifyPrep(deckArgs, accounts[1], room, tableId, 1)
    verifyPrep(deckArgs, accounts[0], room, tableId, 0)

    prepped = dict(tableId=tableId, config=config)
    three_players_shuffle(accounts, prepped, deckArgs, room,
                          two_players_empty_shuffle + (two_players_empty_shuffle[0],))

    deckId = room.configParams(tableId)[-1]

    cards = [0,1,2]
    decryptCards(deckArgs, deckId, 0, accounts[0], tableId, room, cards, cards)
    decryptCards(deckArgs, deckId, 1, accounts[1], tableId, room, cards, cards)
    decryptCards(deckArgs, deckId, 2, accounts[2], tableId, room, cards, cards)

    revealCards(deckArgs, deckId, 0, accounts[0], tableId, room, [0])
    revealCards(deckArgs, deckId, 1, accounts[1], tableId, room, [1])
    tx = revealCards(deckArgs, deckId, 2, accounts[2], tableId, room, [2], True)
    assert len(tx.events) == 2
    assert tx.events[-1].event_name == "SelectDealer"
    dealer = tx.events[-1].event_arguments["seat"]
    small = (dealer + 1) % 3
    big = (small + 1) % 3

    tx = three_players_shuffle(accounts, prepped, deckArgs, room,
                               two_players_empty_shuffle + (two_players_empty_shuffle[1],))
    assert len(tx.events) == 2
    assert tx.events[-2].event_name == "Shuffle"
    assert tx.events[-1].event_name == "DealRound"

    cards   = list(range(6))
    drawnTo = [small, big, dealer] * 2
    decryptCards(deckArgs, deckId, 0, accounts[0], tableId, room, cards, drawnTo)
    decryptCards(deckArgs, deckId, 1, accounts[1], tableId, room, cards, drawnTo)
    tx = decryptCards(deckArgs, deckId, 2, accounts[2], tableId, room, cards, drawnTo, True)

    # blinds are both all-in
    with reverts("wrong turn"):
        game.fold(tableId, small, sender=accounts[small])

    tx = game.fold(tableId, dealer, sender=accounts[dealer])
    assert len(tx.events) == 4
    assert tx.events[0].event_name == 'Fold'

    # deal the whole board
    assert tx.events[1].event_name == 'DealRound'
    assert tx.events[2].event_name == 'DealRound'
    assert tx.events[3].event_name == 'DealRound'
    cards = [7,8,9,11,13]
    drawnTo = [dealer] * 5
    decryptCards(deckArgs, deckId, 0, accounts[0], tableId, room, cards, drawnTo)
    decryptCards(deckArgs, deckId, 1, accounts[1], tableId, room, cards, drawnTo)
    decryptCards(deckArgs, deckId, 2, accounts[2], tableId, room, cards, drawnTo)
    revealCards(deckArgs, deckId, dealer, accounts[dealer], tableId, room, cards)
    # and show cards
    revealCards(deckArgs, deckId, small, accounts[small], tableId, room, [0,3])
    tx = revealCards(deckArgs, deckId, big, accounts[big], tableId, room, [1,4], True)

    assert len(tx.events) == 11
    assert tx.events[0].event_name == 'Show'
    assert tx.events[1].event_name == 'Show'
    assert tx.events[2].event_name == 'DealRound'
    assert tx.events[3].event_name == 'ShowHand'
    assert tx.events[4].event_name == 'ShowHand'
    assert tx.events[5].event_name == 'CollectPot'
    assert tx.events[6].event_name == 'Eliminate'
    assert tx.events[7].event_name == 'LeaveTable'
    assert tx.events[8].event_name == 'LeaveTable'
    assert tx.events[9].event_name == 'LeaveTable'
    assert tx.events[10].event_name == 'EndGame'
