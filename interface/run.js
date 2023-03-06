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
    JSON.parse(fs.readFileSync(process.env.GAME_ABI || '../interfaces/Game.json', 'utf8')))

  async function changeAccount(socket) {
    socket.emit('account', socket.account.address, socket.account.privateKey)
    if (socket.account.privateKey != '') {
      socket.emit('balance', ethers.utils.formatUnits(await provider.getBalance(socket.account.address), 'ether'))
      // check which games this address is currently in and display them all
    }
    else {
      socket.emit('balance', '')
    }
  }

  io.on('connection', socket => {
    socket.on('newAccount', async () => {
      socket.account = ethers.Wallet.createRandom()
      await changeAccount(socket)
    })

    socket.on('privkey', async privkey => {
      try {
        socket.account = new ethers.Wallet(privkey)
      }
      catch {
        socket.account = {address: '', privateKey: ''}
      }
      await changeAccount(socket)
    })
  })

})()
