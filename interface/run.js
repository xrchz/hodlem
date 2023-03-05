'use strict'

require('dotenv').config()

const express = require('express')
const app = express()

app.get('/', (req, res) => {
  res.sendFile(`${__dirname}/index.html`)
})
app.use(express.static(__dirname))

const server = require('http').createServer(app)
const io = require('socket.io')(server)

server.listen(process.env.PORT || 8080)

io.on('connection', socket => {
  socket.emit('hello')
})
