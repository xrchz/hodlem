'use strict'

require('dotenv').config()

const fs = require('node:fs')
const ethers = require('ethers')
const express = require('express')
const app = express()

app.get('/', (req, res) => {
  res.sendFile(`${__dirname}/index.html`)
})
app.use(express.static(__dirname))

const server = require('http').createServer(app)
const io = require('socket.io')(server)

server.listen(process.env.PORT || 8080)

;(async () => {

  const provider = new ethers.providers.JsonRpcProvider(process.env.RPC)

  const network = await provider.getNetwork()
  console.log(`Connected to ${JSON.stringify(network)}`)

  const game = new ethers.Contract(process.env.GAME,
    JSON.parse(fs.readFileSync(process.env.GAME_ABI || '../interfaces/Game.json', 'utf8')),
    provider)
  console.log(`Game is ${game.address}`)
  const room = new ethers.Contract(process.env.ROOM,
    JSON.parse(fs.readFileSync(process.env.ROOM_ABI || '../interfaces/Room.json', 'utf8')),
    provider)
  console.log(`Room is ${room.address}`)
  const deck = new ethers.Contract(process.env.DECK,
    JSON.parse(fs.readFileSync(process.env.DECK_ABI || '../interfaces/Deck.json', 'utf8')),
    provider)
  console.log(`Deck is ${deck.address}`)

  async function refreshBalance(socket) {
    async function b() {
      console.log(`querying balance for ${socket.account.address}...`)
      const bal = await provider.getBalance(socket.account.address)
      console.log(`...done [balance]`)
      return bal
    }
    socket.emit('balance',
      socket.account && socket.account.privateKey != ''
      ? ethers.utils.formatUnits(await b(), 'ether')
      : '')
  }

  async function refreshFeeData(socket) {
    if (!('customFees' in socket)) {
      console.log(`querying fee data...`)
      socket.feeData = await provider.getFeeData()
      console.log(`...done [fee]`)
      socket.emit('maxFeePerGas', ethers.utils.formatUnits(socket.feeData.maxFeePerGas, 'gwei'))
      socket.emit('maxPriorityFeePerGas', ethers.utils.formatUnits(socket.feeData.maxPriorityFeePerGas, 'gwei'))
    }
  }

  async function getPendingGames() {
    console.log('querying pending games...')
    const tableIds = []
    let id = await room.nextWaitingTable(0)
    console.log(`${id}... [pending]`)
    while (!ethers.BigNumber.from(id).isZero()) {
      tableIds.push(id)
      id = await room.nextWaitingTable(id)
      console.log(`${id}... [pending]`)
     }
    console.log('...done [pending]')
    return tableIds
  }

  async function getActiveGames() {
    console.log('querying active games...')
    const tableIds = []
    let id = await room.nextLiveTable(0)
    while (!ethers.BigNumber.from(id).isZero()) {
      tableIds.push(id)
      id = await room.nextLiveTable(id)
    }
    console.log('...done [active]')
    return tableIds
  }

  const configKeys = [
    'buyIn', 'bond', 'startsWith', 'untilLeft', 'levelBlocks', 'verifRounds',
    'prepBlocks', 'shuffBlocks', 'verifBlocks', 'dealBlocks', 'actBlocks']

  async function refreshPendingGames(socket) {
    const tableIds = await getPendingGames()
    if (!('gameConfigs' in socket))
      socket.gameConfigs = {}
    const seats = {}
    console.log(`querying seats for pending tables...`)
    await Promise.all(tableIds.map(async idNum => {
      const id = idNum.toString()
      if (!(id in socket.gameConfigs)) {
        console.log(`querying config for table ${id}...`)
        const data = {id: id}
        socket.gameConfigs[id] = data
        data.structure = await room.configStructure(idNum)
        ;(await room.configParams(id)).forEach((v, i) => {
          data[configKeys[i]] = v
        })
        console.log('...done [config]')
      }
      seats[id] = []
      for (const seatIndex of Array(socket.gameConfigs[id].startsWith.toNumber()).keys()) {
        seats[id].push(await room.playerAt(idNum, seatIndex))
      }
    }))
    console.log(`...done [seats]`)
    socket.emit('pendingGames',
      tableIds.map(idNum => {
        const config = socket.gameConfigs[idNum.toString()]
        const result = Object.fromEntries(
          configKeys.map(k => [k, ['bond', 'buyIn'].includes(k)
                                  ? ethers.utils.formatUnits(config[k], 'ether')
                                  : config[k].toString()]))
        result.id = config.id
        result.structure = config.structure.map(x => ethers.utils.formatUnits(x, 'ether'))
        return result
      }),
      seats)
  }

  async function refreshNetworkInfo(socket) {
    await refreshBalance(socket)
    await refreshFeeData(socket)
    if (!('playing' in socket)) {
      await refreshPendingGames(socket)
    }
  }

  async function changeAccount(socket) {
    socket.emit('account', socket.account.address, socket.account.privateKey)
    await refreshBalance(socket)
    if (socket.account.privateKey != '') {
      await refreshPendingGames(socket)
      // TODO: update active games
    }
  }

  io.on('connection', async socket => {
    await refreshNetworkInfo(socket)

    socket.on('newAccount', async () => {
      socket.account = ethers.Wallet.createRandom().connect(provider)
      await changeAccount(socket)
    })

    provider.on('block', async blockNumber => {
      await refreshNetworkInfo(socket)
    })

    socket.on('resetFees', async () => {
      console.log('in reset fees')
      delete socket.customFees
      await refreshFeeData(socket)
    })

    socket.on('customFees', (maxFeePerGas, maxPriorityFeePerGas) => {
      console.log(`Setting custom gas prices`)
      socket.customFees = {
        maxFeePerGas: ethers.utils.parseUnits(maxFeePerGas, 'gwei'),
        maxPriorityFeePerGas: ethers.utils.parseUnits(maxPriorityFeePerGas, 'gwei')
      }
      socket.feeData = socket.customFees
    })

    socket.on('privkey', async privkey => {
      try {
        socket.account = new ethers.Wallet(privkey, provider)
      }
      catch {
        socket.account = {address: '', privateKey: ''}
      }
      await changeAccount(socket)
    })

    socket.on('send', async (to, amount) => {
      try {
        const tx = {
          to: to,
          type: 2,
          maxFeePerGas: socket.feeData.maxFeePerGas,
          maxPriorityFeePerGas: socket.feeData.maxPriorityFeePerGas,
          value: ethers.utils.parseEther(amount)
        }
        console.log(`sending ${amount} to ${to} from ${socket.account.address}...`)
        const response = await socket.account.sendTransaction(tx)
        console.log(`awaiting receipt... [send]`)
        const receipt = await response.wait()
        console.log(`...done [send]`)
      }
      catch (e) {
        socket.emit('errorMsg', e.toString())
      }
    })

    socket.on('createGame', async data => {
      try {
        const { seatIndex, ...config } = data
        config.buyIn = ethers.utils.parseEther(config.buyIn)
        config.bond = ethers.utils.parseEther(config.bond)
        config.gameAddress = game.address
        config.structure = config.structure.split(/\s/).map(x => ethers.utils.parseEther(x))
        console.log(`sending createGame transaction...`)
        const response = await room.connect(socket.account).createTable(
          seatIndex, config, deck.address, {
            value: config.buyIn.add(config.bond),
            maxFeePerGas: socket.feeData.maxFeePerGas,
            maxPriorityFeePerGas: socket.feeData.maxPriorityFeePerGas
          })
        console.log(`awaiting receipt... [create]`)
        const receipt = await response.wait()
        console.log(`...done [create]`)
      }
      catch (e) {
        socket.emit('errorMsg', e.toString())
      }
    })
  })

})()
