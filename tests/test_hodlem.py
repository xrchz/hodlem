from ape import reverts
import json
import os
import pytest
import subprocess

@pytest.fixture(scope="module")
def deck(project, accounts):
    return project.Deck.deploy(sender=accounts[0])

@pytest.fixture(scope="module")
def room(project, accounts, deck):
    return project.Room.deploy(deck.address, sender=accounts[0])

@pytest.fixture(scope="module")
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

@pytest.fixture(scope="module")
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
                "--rpc", networks.active_provider.web3.provider.endpoint_uri, "--deck", deck.address]

    hash0 = subprocess.run(
            deckArgs + ["--from", accounts[0].address, "submitPrep", "--id", "0"],
            capture_output=True, check=True, text=True).stdout.strip()
    room.submitPrep(tableId, 0, hash0, sender=accounts[0])

    hash1 = subprocess.run(
            deckArgs + ["--from", accounts[1].address, "submitPrep", "--id", "0"],
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
        deckArgs + ["--from", accounts[0].address, "verifyPrep", "--id", "0"],
        capture_output=True, check=True, text=True).stdout.splitlines())
    room.verifyPrep(tableId, 0, readPrep(lines), sender=accounts[0])

    lines = iter(subprocess.run(
             deckArgs + ["--from", accounts[1].address, "verifyPrep", "--id", "0"],
            stdout=subprocess.PIPE, check=True, text=True).stdout.splitlines())
    room.verifyPrep(tableId, 1, readPrep(lines), sender=accounts[1])

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
