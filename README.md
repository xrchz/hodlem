# Hodlem: Texas Hold'em Sit-n-Go Poker Tournaments for Ethereum

The game is fully decentralised. Players come together to play a tournament entirely via submitting transactions on chain.

## Quick start on dev net

Since the contracts are not yet deployed anywhere, you can test on a local devnet.
For example, using [Brownie](https://eth-brownie.readthedocs.io/en/stable/index.html):

1. Clone this repo `git clone https://github.com/xrchz/hodlem`, `cd hodlem`
2. Run `brownie run deploy.py -I` to run the deployment script. You may have to pass an appropriate `--network` argument to choose your devnet. Leave this running to provide the RPC for the interface.
3. `cd interface` and `npm install`. Add `RPC=http://127.0.0.1:8545`, or whatever as appropriate, to point to the RPC provided by brownie.
4. Run `node run` to run the interface
5. Navigate to `http://localhost:8080`

## Interface

The interface is designed to be served locally using Node.js. Run the server, providing it your RPC node, then navigate to the served page in your browser.

## Contracts

The main contract is `contracts/Game.vy`.
