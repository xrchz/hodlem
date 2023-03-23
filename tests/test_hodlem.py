import pytest
from brownie import accounts, reverts, Deck, Room, Game

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
