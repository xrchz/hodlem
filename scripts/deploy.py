from brownie import accounts, Deck, Room, Game

fee_args = {"max_fee": "16 gwei", "priority_fee": "2 gwei"}

def deploy():
    kwargs = {"from": accounts[0], **fee_args}
    deck = Deck.deploy(kwargs)
    room = Room.deploy(deck.address, kwargs)
    game = Game.deploy(room.address, kwargs)

def main():
    deploy()
    with open("interface/.env", "a") as f:
        f.write(f'DECK={Deck[0].address}\n')
        f.write(f'ROOM={Room[0].address}\n')
        f.write(f'GAME={Game[0].address}\n')
    accounts[0].transfer(
            to='0xCcbd1e8d367F6AC608b97260D8De9bad27C11ADc',
            amount="6.9 ether",
            max_fee="16 gwei",
            priority_fee="2 gwei")
