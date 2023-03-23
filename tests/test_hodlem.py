from brownie import accounts, network, reverts, chain, Deck, Room, Game
import json
import os
import pytest
import subprocess

fee_args = {"max_fee": "16 gwei", "priority_fee": "2 gwei"}

def deploy_deck():
    kwargs = {"from": accounts[0], **fee_args}
    return Deck.deploy(kwargs)

def deploy_room(deck):
    kwargs = {"from": accounts[0], **fee_args}
    return Room.deploy(deck.address, kwargs)

def deploy_game(room):
    kwargs = {"from": accounts[0], **fee_args}
    return Game.deploy(room.address, kwargs)

@pytest.fixture(scope="module")
def deck():
    return deploy_deck()

@pytest.fixture(scope="module")
def room(deck):
    return deploy_room(deck)

@pytest.fixture(scope="module")
def game(room):
    return deploy_game(room)

def test_new_deck_ids_distinct(fn_isolation, deck):
    tx1 = deck.newDeck(13, fee_args)
    tx2 = deck.newDeck(9, fee_args)
    assert tx1.return_value != tx2.return_value

def test_new_deck_invalid_players(fn_isolation, deck):
    with reverts("invalid players"):
        deck.newDeck(0, fee_args)
    with reverts("invalid players"):
        deck.newDeck(128, fee_args)
    tx = deck.newDeck(127, fee_args)
    assert tx.return_value == 0

def test_create_invalid_seatIndex(fn_isolation, room, game):
    with reverts("invalid seatIndex"):
        room.createTable(
                12, (1, 2, 3, 2, [1,2,3], 2, 2, 2, 2, 2, 2, 2), game.address,
                fee_args)

def test_create_wrong_value(fn_isolation, room, game):
    with reverts("incorrect bond + buyIn"):
        room.createTable(
                0, (1, 2, 3, 2, [1,2,3], 2, 2, 2, 2, 2, 2, 2), game.address,
                fee_args)

def test_join_leave_join(fn_isolation, room, game):
    seatIndex = 1
    tx = room.createTable(
            seatIndex, (100, 200, 3, 2, [1,2,3], 2, 2, 2, 2, 2, 2, 2), game.address,
            {"value": "300 wei"} | fee_args)
    tableId = tx.return_value
    tx = room.leaveTable(tableId, seatIndex, fee_args)
    assert tx.internal_transfers == [{"from": room.address, "to": accounts[0], "value": 300}]
    with reverts("incorrect bond + buyIn"):
        room.joinTable(tableId, seatIndex, fee_args)
    room.joinTable(tableId, seatIndex, {"value": "300 wei"} | fee_args)

def test_submit_prep_timeout(fn_isolation, room, game):
    prepBlocks = 2
    tx = room.createTable(
            1, (100, 200, 2, 1, [1,2,3], 2, 2, prepBlocks, 2, 2, 2, 2), game.address,
            {"from": accounts[0], "value": "300 wei"} | fee_args)
    tableId = tx.return_value
    tx = room.joinTable(tableId, 0, {"from": accounts[1], "value": "300 wei"} | fee_args)
    tx = room.submitPrep(tableId, 1, 0x1, fee_args)
    chain.mine(prepBlocks + 1)
    assert chain.height > tx.block_number + prepBlocks, "mine harder"
    with reverts("not submitted"):
        room.verifyPrepTimeout(tableId, 0, fee_args)
    tx = room.submitPrepTimeout(tableId, 0, fee_args)
    assert tx.internal_transfers == [
            {"from": room.address, "to": "0x0000000000000000000000000000000000000000", "value": 300},
            {"from": room.address, "to": accounts[0], "value": 300},
    ]
    with reverts("wrong phase"):
        room.joinTable(tableId, 0, {"from": accounts[1], "value": "300 wei"} | fee_args)

def test_submit_prep_timeout_self(fn_isolation, room, game):
    prepBlocks = 2
    tx = room.createTable(
            1, (100, 200, 2, 1, [1,2,3], 2, 2, prepBlocks, 2, 2, 2, 2), game.address,
            {"from": accounts[0], "value": "300 wei"} | fee_args)
    tableId = tx.return_value
    tx = room.joinTable(tableId, 0, {"from": accounts[1], "value": "300 wei"} | fee_args)
    chain.mine(prepBlocks + 1)
    assert chain.height > tx.block_number + prepBlocks, "mine harder"
    tx = room.submitPrepTimeout(tableId, 1, fee_args)
    assert tx.internal_transfers == [
            {"from": room.address, "to": accounts[1], "value": 300},
            {"from": room.address, "to": "0x0000000000000000000000000000000000000000", "value": 300},
    ]

def test_verify_prep_timeout(fn_isolation, room, game):
    prepBlocks = 1
    tx = room.createTable(
            0, (300, 200, 2, 1, [1,2,3], 2, 2, prepBlocks, 2, 2, 2, 2), game.address,
            {"from": accounts[0], "value": "500 wei"} | fee_args)
    tableId = tx.return_value
    tx = room.joinTable(tableId, 1, {"from": accounts[1], "value": "500 wei"} | fee_args)
    tx = room.submitPrep(tableId, 0, 0x1, fee_args)
    tx = room.submitPrep(tableId, 1, 0x2, {"from": accounts[1]} | fee_args)
    chain.mine(prepBlocks + 1)
    assert chain.height > tx.block_number + prepBlocks, "mine harder"
    with reverts("already submitted"):
        room.submitPrepTimeout(tableId, 0, fee_args)
    tx = room.verifyPrepTimeout(tableId, 0, {"from": accounts[1]} | fee_args)
    assert tx.internal_transfers == [
            {"from": room.address, "to": "0x0000000000000000000000000000000000000000", "value": 500},
            {"from": room.address, "to": accounts[1], "value": 500},
    ]
    with reverts("wrong phase"):
        room.verifyPrepTimeout(tableId, 1, {"from": accounts[0]} | fee_args)

@pytest.fixture(scope="module")
def two_players_prepped(deck, room, game):
    tx = room.createTable(
            0, (300, 500, 2, 1, [10, 20, 30, 40], 20, 4, 10, 10, 15, 10, 15), game.address,
            {"from": accounts[0], "value": "800 wei"} | fee_args)
    tableId = tx.return_value
    tx = room.joinTable(tableId, 1, {"from": accounts[1], "value": "800 wei"} | fee_args)

    db_path = "tests/db.json"

    try:
        os.remove(db_path)
    except FileNotFoundError:
        pass

    deckArgs = ["interface/deck.js", "--db", db_path,
                "--rpc", network.web3.provider.endpoint_uri, "--deck", deck.address]

    hash0 = subprocess.run(
            deckArgs + ["--from", accounts[0].address, "submitPrep", "--id", "0"],
            capture_output=True, check=True, text=True).stdout.strip()
    room.submitPrep(tableId, 0, hash0, fee_args)

    hash1 = subprocess.run(
            deckArgs + ["--from", accounts[1].address, "submitPrep", "--id", "0"],
            capture_output=True, check=True, text=True).stdout.strip()
    room.submitPrep(tableId, 1, hash1, {"from": accounts[1]} | fee_args)

    def readPrep(f):
        a = []
        def n():
            return int(next(f), 16)
        for _ in range(53):
            a.append([[n(), n()], [n(), n()],
                      [n(), n()], [n(), n()],
                      [[n(), n()], [n(), n()], n()]])
        return a

    lines = iter(subprocess.run(
        deckArgs + ["--from", accounts[0].address, "verifyPrep", "--id", "0"],
        capture_output=True, check=True, text=True).stdout.splitlines())
    room.verifyPrep(tableId, 0, readPrep(lines), fee_args)

    lines = iter(subprocess.run(
             deckArgs + ["--from", accounts[1].address, "verifyPrep", "--id", "0"],
            stdout=subprocess.PIPE, check=True, text=True).stdout.splitlines())
    room.verifyPrep(tableId, 1, readPrep(lines), {"from": accounts[1]} | fee_args)

    return tableId

def test_no_timeout_after_prep(fn_isolation, two_players_prepped, room):
    tableId = two_players_prepped
    with reverts("wrong phase"):
        room.submitPrepTimeout(tableId, 0, fee_args)
    with reverts("wrong phase"):
        room.verifyPrepTimeout(tableId, 1, fee_args)
