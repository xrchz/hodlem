import pytest
import json
from brownie import accounts, reverts, chain, Deck, Room, Game

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
def two_players_prepped(room, game):
    tx = room.createTable(
            0, (300, 500, 2, 1, [10, 20, 30, 40], 20, 4, 10, 10, 15, 10, 15), game.address,
            {"from": accounts[0], "value": "800 wei"} | fee_args)
    tableId = tx.return_value
    tx = room.joinTable(tableId, 1, {"from": accounts[1], "value": "800 wei"} | fee_args)
    room.submitPrep(tableId, 0, '0x9514297892c9e1e0d69c800e248236c91d33ba9c7fbb33364d457bd0dd041f9c', fee_args)
    room.submitPrep(tableId, 1, '0x0f9b47e0d799755d4d214e8533c69a2302d2e8347032138c76e92d83d8389d66', {"from": accounts[1]} | fee_args)
    def str2num(x):
        if type(x) == list:
            return [str2num(y) for y in x]
        else:
            return int(x)
    with open("tests/prep0.json", "r") as f:
        prep0 = str2num(json.load(f))
    with open("tests/prep1.json", "r") as f:
        prep1 = str2num(json.load(f))
    room.verifyPrep(tableId, 1, prep1, {"from": accounts[1]} | fee_args)
    room.verifyPrep(tableId, 0, prep0, fee_args)
    return tableId

def test_no_timeout_after_prep(fn_isolation, two_players_prepped, room):
    tableId = two_players_prepped
    with reverts("wrong phase"):
        room.submitPrepTimeout(tableId, 0, fee_args)
    with reverts("wrong phase"):
        room.verifyPrepTimeout(tableId, 1, fee_args)
