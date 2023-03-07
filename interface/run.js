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

  async function refreshBalance(socket) {
    async function b() {
      console.log(`querying balance for ${socket.account.address}...`)
      const bal = await provider.getBalance(socket.account.address)
      console.log(`...done`)
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
      console.log(`...done`)
      socket.emit('maxFeePerGas', ethers.utils.formatUnits(socket.feeData.maxFeePerGas, 'gwei'))
      socket.emit('maxPriorityFeePerGas', ethers.utils.formatUnits(socket.feeData.maxPriorityFeePerGas, 'gwei'))
    }
  }

  async function refreshNetworkInfo(socket) {
    await refreshBalance(socket)
    await refreshFeeData(socket)
  }

  async function changeAccount(socket) {
    socket.emit('account', socket.account.address, socket.account.privateKey)
    await refreshBalance(socket)
    if (socket.account.privateKey != '') {
      console.log(`querying joined games for ${socket.account.address}...`)
      const joins = await room.queryFilter(
        room.filters.JoinTable(null, socket.account.address, null),
        -10 // TODO configure this properly
      )
      console.log(`filtering left games...`)
      const liveJoins = (await Promise.all(joins.map(ev =>
        room.queryFilter(
          room.filters.LeaveTable(ev.args.table, ev.args.player, ev.args.seat),
          ev.blockNumber)
        .then(a => a.length ? null : ev)))).filter(x => x)
      console.log(`checking which games have started...`)
      const pendingStarted = (await Promise.all(liveJoins.map(ev =>
        room.queryFilter(
          room.filters.StartGame(ev.args.table),
          ev.blockNumber)
        .then(a => [a.length, ev]))))
      .reduce((acc, tup) => acc[tup[0] ? 1 : 0].push(tup[1]) && acc, [[], []])
      console.log(`filtering finished games...`)
      const active = (await Promise.all(pendingStarted[1].map(ev =>
        room.queryFilter(
          room.filters.EndGame(ev.args.table),
          ev.blockNumber)
        .then(a => a.length ? null : ev)))).filter(x => x)
      console.log(`...done`)
      pendingStarted[0].forEach(ev => {
        socket.emit('waiting', ev.args.table)
      })
      active.forEach(ev => {
        socket.emit('playing', ev.args.table)
      })
    }
  }

  io.on('connection', socket => {
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
        console.log(`awaiting receipt...`)
        const receipt = await response.wait()
        console.log(`...done`)
        await refreshBalance(socket)
      }
      catch (e) {
        socket.emit('errorMsg', e.toString())
      }
    })
  })

})()
