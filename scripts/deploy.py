import IPython
from ape import networks, accounts, project

acc = accounts.test_accounts

def deploy():
    deck = project.Deck.deploy(sender=acc[0])
    room = project.Room.deploy(deck.address, sender=acc[0])
    game = project.Game.deploy(room.address, sender=acc[0])
    room.setGameAddress(game.address, sender=acc[0])
    return deck, room, game

def main():
    _, _, game = deploy()
    with open("interface/.env", "w") as f:
        f.write(f'RPC={networks.active_provider.web3.provider.endpoint_uri}\n')
        f.write(f'GAME={game.address}\n')
    acc[0].transfer('0xCcbd1e8d367F6AC608b97260D8De9bad27C11ADc', '6.9 ether')
    IPython.embed()
