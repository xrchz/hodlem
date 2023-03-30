# Hodlem: Texas Hold'em Sit-n-Go Poker Tournaments for Ethereum
The game is fully decentralised.
Players come together to play a tournament entirely via submitting transactions on chain.

## Install and run tests
1. Clone this repository: `git clone https://github.com/xrchz/hodlem`
2. Get dependencies:
    - Node.js: https://nodejs.org/
    - Foundry: https://getfoundry.sh/
    - Vyper: `pip install vyper`
    - Ape: `pip install eth-ape`
3. Install Ape plugins: `ape plugins install`
4. `ape test`

## Run on a local dev net
Follow the installations instructions above first.

1. `ape run deploy -I` to start a local dev net with the contracts deployed
2. `cd interface` and `npm ci` - it should install the required node modules automatically
3. (still in `interface`) `node run` to start the interface, listening on `localhost:8080` by default
4. Visit `http://localhost:8080` to see the interface and take it from there!

## Run on a public network
The contracts have not yet been deployed. When they are, it will be the same as
above (from step 2) to run the interface, providing the deployment address and
an RPC node as environment variables (or in the `.env` file).
