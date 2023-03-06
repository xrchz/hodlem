'use strict'

require('dotenv').config()

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

var account

io.on('connection', socket => {
  socket.on('newAccount', () => {
    account = ethers.Wallet.createRandom()
    socket.emit('account', account.address, account.privateKey)
  })

  socket.on('privkey', privkey => {
    try {
      account = new ethers.Wallet(privkey)
    }
    catch {
      account = {address: '', privateKey: ''}
    }
    socket.emit('account', account.address, account.privateKey)
  })
})
