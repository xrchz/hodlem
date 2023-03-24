from ape import reverts
import json
import os
import pytest
import subprocess

MAX_SECURITY = 63

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

@pytest.fixture(scope="session")
def two_players_selected_dealer(accounts, room, two_players_prepped):
    #        1   2    3   4   5   6   7   8   9  10  11  12  13  14  15  16
    perm0 = [32, 11,  4,  9,  8, 42,  1,  3,  5,  7, 22, 25, 51, 31, 30,  2,
    #        17  18  19  20  21  22  23  24  25  26  27  28  29  30  31  32
             13, 23, 50, 44, 33, 35, 27, 21, 16, 39, 43, 10, 19, 34,  6, 12,
    #        33  34  35  36  37  38  39  40  41  42  43  44  45  46  47  48
             28, 18, 36, 41, 52, 14, 48, 37, 24, 49, 17, 47, 20, 38, 40, 45,
    #        49  50  51  52
             46, 15, 26, 29]

    perm1 = [ 7, 16,  8,  3,  9, 31, 10,  5,  4, 28,  2, 32, 17, 38, 50, 25,
             43, 34, 29, 45, 24, 11, 18, 41, 12, 51, 23, 33, 52, 15, 14,  1,
             21, 30, 22, 35, 40, 46, 26, 47, 36,  6, 27, 20, 48, 49, 44, 39,
             42, 19, 13, 37]

    tableId = two_players_prepped["tableId"]
    deckArgs = two_players_prepped["deckArgs"]
    config = two_players_prepped["config"]
    verifRounds = config["verifRounds"]
    deckId = room.configParams(tableId)[-1]

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

    def readLines(f, z):
        a = []
        def n():
            return int(next(f), 16)
        for _ in range(26):
            try:
                a.append([n() for _ in range(z)])
            except StopIteration:
                break
        return a

    lines = iter(subprocess.run(
             deckArgs + ["--from", accounts[0].address, "decryptCards",
                         "--indices", "0,1", "--draw-indices", "0,1",
                         "-j", str(deckId), "-s", '0'],
            stdout=subprocess.PIPE, check=True, text=True).stdout.splitlines())
    tx = room.decryptCards(tableId, 0, readLines(lines, 8), False, sender=accounts[0])

    lines = iter(subprocess.run(
             deckArgs + ["--from", accounts[1].address, "decryptCards",
                         "--indices", "0,1", "--draw-indices", "0,1",
                         "-j", str(deckId), "-s", '1'],
            stdout=subprocess.PIPE, check=True, text=True).stdout.splitlines())
    tx = room.decryptCards(tableId, 1, readLines(lines, 8), False, sender=accounts[1])


    lines = iter(subprocess.run(
             deckArgs + ["--from", accounts[0].address, "revealCards",
                         "--indices", "0",
                         "-j", str(deckId), "-s", '0'],
            stdout=subprocess.PIPE, check=True, text=True).stdout.splitlines())
    tx = room.revealCards(tableId, 0, readLines(lines, 7), False, sender=accounts[0])

    lines = iter(subprocess.run(
             deckArgs + ["--from", accounts[1].address, "revealCards",
                         "--indices", "1",
                         "-j", str(deckId), "-s", '1'],
            stdout=subprocess.PIPE, check=True, text=True).stdout.splitlines())
    tx = room.revealCards(tableId, 1, readLines(lines, 7), True, sender=accounts[1])

    return two_players_prepped

def test_select_dealer(two_players_selected_dealer, game):
    tableId = two_players_selected_dealer["tableId"]
    assert game.games(tableId)['dealer'] == 1
