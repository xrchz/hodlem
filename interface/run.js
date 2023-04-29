import 'dotenv/config'
import * as fs from 'node:fs'
import { ethers } from 'ethers'
import express from 'express'
import { fileURLToPath } from 'url'
import * as path from 'node:path'
import { createServer } from 'http'
import { Server as SocketIOServer } from 'socket.io'
import { JsonDB, Config as JsonDBConfig } from 'node-json-db'
import { submitPrep, verifyPrep, shuffle, verifyShuffle, decryptCards, lookAtCard, revealCards } from './lib.js'

const app = express()
const dirname = path.dirname(fileURLToPath(import.meta.url))

app.get('/', (req, res) => {
  res.sendFile(`${dirname}/index.html`)
})
app.use(express.static(dirname))

const httpServer = createServer(app)
const io = new SocketIOServer(httpServer)

httpServer.listen(process.env.PORT || 8080)

const db = new JsonDB(new JsonDBConfig('db'))

const provider = new ethers.providers.JsonRpcProvider(process.env.RPC)

const network = await provider.getNetwork()
console.log(`Connected to ${JSON.stringify(network)}`)

const game = new ethers.Contract(process.env.GAME,
  JSON.parse(fs.readFileSync(process.env.GAME_ABI || '../.build/Game.json', 'utf8')).abi,
  provider)
console.log(`Game is ${game.address}`)
const room = new ethers.Contract(await game.roomAddress(),
  JSON.parse(fs.readFileSync(process.env.ROOM_ABI || '../.build/Room.json', 'utf8')).abi,
  provider)
console.log(`Room is ${room.address}`)
const deck = new ethers.Contract(await room.deckAddress(),
  JSON.parse(fs.readFileSync(process.env.DECK_ABI || '../.build/Deck.json', 'utf8')).abi,
  provider)
console.log(`Deck is ${deck.address}`)

function processArg(arg, index, name) {
  if (['RaiseBet', 'CallBet', 'PostBlind', 'CollectPot'].includes(name) && index >= 1) return ethers.utils.formatEther(arg)
  else if (name === 'ShowHand' && index == 1) return arg.toHexString()
  else if (ethers.BigNumber.isBigNumber(arg)) return arg.toNumber()
  else return arg
}

async function onLog(iface, log) {
  if (!log.removed) {
    const id = parseInt(log.topics[1])
    const key = `/logs/t${id}`
    const ev = iface.parseLog(log)
    const val = {
      index: [log.blockNumber, log.logIndex],
      name: ev.name,
      args: ev.args.slice(1).map((a, i) => processArg(a, i, ev.name))
    }
    if (await db.exists(key)) {
      const blockNumber = await db.getData(`${key}[-1]/index[0]`)
      if (blockNumber < log.blockNumber ||
          (blockNumber === log.blockNumber &&
           (await db.getData(`${key}[-1]/index[1]`)) < log.logIndex)) {
        await db.push(`${key}[]`, val)
      }
      else {
        const a = await db.getData(key)
        if (!a.map(x => x.index.join()).includes(`${log.blockNumber},${log.logIndex}`)) {
          a.push(val)
          a.sort((x, y) => x.index[0] === y.index[0] ?
                           x.index[1] - y.index[1] :
                           x.index[0] - y.index[0])
          await db.push(key, a)
        }
      }
    }
    else {
      await db.push(`${key}[]`, val)
    }
  }
}

room.on({ address: room.address, topics: [null, null, null, null] },
  log => onLog(room.interface, log))
game.on({ address: game.address, topics: [null, null, null, null] },
  log => onLog(game.interface, log))

async function refreshBalance(socket) {
  async function b() {
    return (await provider.getBalance(socket.account.address))
  }
  socket.emit('balance',
    socket.account && socket.account.privateKey != ''
    ? ethers.utils.formatEther(await b())
    : '')
}

async function refreshFeeData(socket) {
  if (!('customFees' in socket)) {
    socket.feeData = await provider.getFeeData()
    socket.emit('maxFeePerGas', ethers.utils.formatUnits(socket.feeData.maxFeePerGas, 'gwei'))
    socket.emit('maxPriorityFeePerGas', ethers.utils.formatUnits(socket.feeData.maxPriorityFeePerGas, 'gwei'))
  }
}

async function getPendingGames() {
  const tableIds = []
  let id = await room.nextWaitingTable(0)
  while (!ethers.BigNumber.from(id).isZero()) {
    tableIds.push(id)
    id = await room.nextWaitingTable(id)
   }
  return tableIds
}

async function getActiveGames(socket) {
  const tableIds = []
  let id = await room.nextLiveTable(socket.account.address, 0)
  while (!ethers.BigNumber.from(id).isZero()) {
    tableIds.push(id)
    id = await room.nextLiveTable(socket.account.address, id)
  }
  return tableIds
}

const Phase_PREP = 2
const Phase_SHUF = 3
const Phase_DEAL = 4
const Phase_PLAY = 5
const Phase_SHOW = 6
const Req_DECK = 0
const Req_SHOW = 2

const configKeys = [
  'buyIn', 'bond', 'startsWith', 'untilLeft', 'levelBlocks', 'verifRounds',
  'prepBlocks', 'shuffBlocks', 'verifBlocks', 'dealBlocks', 'actBlocks', 'deckId']

async function getGameConfigs(socket, tableIds) {
  if (!('gameConfigs' in socket))
    socket.gameConfigs = {}
  await Promise.all(tableIds.map(async idNum => {
    const id = idNum.toString()
    if (!(id in socket.gameConfigs)) {
      const data = {id: id}
      socket.gameConfigs[id] = data
      data.structure = await room.configStructure(idNum)
      ;(await room.configParams(id)).forEach((v, i) => {
        data[configKeys[i]] = v
      })
      data.formatted = Object.fromEntries(
        configKeys.map(k => [k, ['bond', 'buyIn'].includes(k)
                                ? ethers.utils.formatEther(data[k])
                                : data[k].toNumber()]))
      data.formatted.id = data.id
      data.formatted.structure = data.structure.map(x => ethers.utils.formatEther(x))
    }
  }))
}

async function refreshPendingGames(socket) {
  const tableIds = await getPendingGames()
  await getGameConfigs(socket, tableIds)
  const seats = {}
  await Promise.all(tableIds.map(async idNum => {
    const id = idNum.toString()
    seats[id] = []
    for (const seatIndex of Array(socket.gameConfigs[id].startsWith.toNumber()).keys()) {
      seats[id].push(await room.playerAt(idNum, seatIndex))
    }
  }))
  socket.emit('pendingGames',
    tableIds.map(idNum => socket.gameConfigs[idNum.toString()].formatted),
    seats)
}

async function refreshActiveGames(socket) {
  const tableIds = await getActiveGames(socket)
  await getGameConfigs(socket, tableIds)
  if (!('activeGames' in socket))
    socket.activeGames = {}
  await Promise.all(tableIds.map(async idNum => {
    const id = idNum.toString()
    const numPlayers = socket.gameConfigs[id].startsWith.toNumber()
    if (!(id in socket.activeGames)) {
      const players = []
      for (const seatIndex of Array(numPlayers).keys()) {
        const player = await room.playerAt(idNum, seatIndex)
        players.push(player)
        if (player === socket.account.address) {
          socket.activeGames[id] = { seatIndex, players }
        }
      }
    }
  }))
  for (const [id, data] of Object.entries(socket.activeGames)) {
    const config = socket.gameConfigs[id]
    const deckId = config.deckId
    const numPlayers = config.formatted.startsWith
    ;[data.phase, data.commitBlock] = (await room.phaseCommit(id)).map(i => i.toNumber())
    const gameData = await game.games(id)
    data.board = gameData.board.flatMap(i => i.isZero() ? [] : [i.toNumber()])
    data.hand = []
    data.stack = gameData.stack.slice(0, numPlayers).map(s => ethers.utils.formatEther(s))
    const playerBets = gameData.bet.slice(0, numPlayers)
    data.bet = playerBets.map(b => ethers.utils.formatEther(b))
    data.betIndex = gameData.betIndex.toNumber()
    data.pot = gameData.pot.slice(0, numPlayers).flatMap(p => p.isZero() ? [] : [ethers.utils.formatEther(p)])
    if (data.phase > Phase_DEAL || (data.phase === Phase_DEAL && data.pot.length)) {
      for (const idx of gameData.hands[data.seatIndex])
        data.hand.push((await lookAtCard(db, deck, socket, id, deckId, idx)).openIndex)
    }
    if (!data.pot.length) data.pot.push('0')
    const betsTotal = playerBets.reduce((a, b) => a.add(b))
    data.lastPotWithBets = ethers.utils.formatEther(
      ethers.utils.parseEther(data.pot.at(-1)).add(betsTotal))
    data.actionIndex = gameData.actionIndex.toNumber()
    const minRaiseBy = gameData.minRaise.add(gameData.bet[data.betIndex]).sub(gameData.bet[data.seatIndex])
    data.minRaiseBy = ethers.utils.formatEther(minRaiseBy.lte(gameData.stack[data.seatIndex]) ? minRaiseBy : gameData.stack[data.seatIndex])
    data.dealer = gameData.dealer.toNumber()
    if (data.phase === Phase_PREP) {
      delete data.reveal
      data.waitingOn = []
      if (await deck.allSubmittedPrep(deckId)) {
        data.reveal = true
      }
      const func = data.reveal ? 'hasVerifiedPrep' : 'hasSubmittedPrep'
      for (const seatIndex of Array(numPlayers).keys()) {
        if (!(await deck[func](deckId, seatIndex))) {
          data.waitingOn.push(seatIndex)
        }
      }
    }
    if (data.phase === Phase_SHUF) {
      let shuffled = await room.shuffled(id)
      data.shuffleCount = (await deck.shuffleCount(deckId)).toNumber()
      if (data.shuffleCount === numPlayers) {
        data.waitingOn = []
        for (const seatIndex of Array(data.shuffleCount).keys()) {
          if (shuffled.mod(2).isZero()) {
            data.waitingOn.push(seatIndex)
          }
          shuffled = shuffled.div(2)
        }
      }
    }
    if (data.phase === Phase_DEAL) {
      const [cardReq, drawIndex, decryptCount, openedCard] = (
        await room.cardInfo(id)).map(a => a.map(i => {
          try { return i.toNumber() } catch { return i }
        }))
      data.waitingOn = []
      data.drawIndex = {}
      for (const i of Array(26).keys()) {
        if (cardReq[i] !== Req_DECK) {
          data.drawIndex[i] = drawIndex[i]
          if (decryptCount[i] === numPlayers) {
            if (cardReq[i] === Req_SHOW && openedCard[i] === 0) {
              data.waitingOn.push({what: i, who: drawIndex[i], open: true})
            }
          }
          else {
            data.waitingOn.push({what: i, who: decryptCount[i]})
          }
        }
      }
    }
    if (data.phase === Phase_PLAY) {
      if (data.actionIndex == data.seatIndex) {
        data.callBy = ethers.utils.formatEther(
          gameData.bet[data.betIndex].sub(gameData.bet[data.seatIndex]))
      }
    }
  }
  socket.emit('activeGames',
    tableIds.map(idNum => socket.gameConfigs[idNum.toString()].formatted),
    socket.activeGames)
}

async function refreshNetworkInfo(socket) {
  await refreshBalance(socket)
  await refreshFeeData(socket)
  if (!('hidePending' in socket)) {
    await refreshPendingGames(socket)
  }
  if ('account' in socket) {
    await refreshActiveGames(socket)
  }
}

async function refreshPreferences(socket) {
  const key = `/${socket.account.address}/preferences`
  if (await db.exists(key)) {
    socket.emit('preferences', await db.getData(key))
  }
}

async function changeAccount(socket) {
  socket.emit('account', socket.account.address, socket.account.privateKey)
  await db.push(`/${socket.account.address}/privateKey`, socket.account.privateKey)
  await refreshBalance(socket)
  await refreshPendingGames(socket)
  await refreshActiveGames(socket)
  await refreshPreferences(socket)
}

function requestTransaction(socket, method, tx) {
  const formatted = {...tx}
  formatted.value = ethers.BigNumber.isBigNumber(formatted.value) ?
                    ethers.utils.formatEther(formatted.value) : '0'
  formatted.value += ' ether'
  formatted.maxFeePerGas = ethers.utils.formatUnits(formatted.maxFeePerGas, 'gwei')
  formatted.maxFeePerGas += ' gwei'
  formatted.maxPriorityFeePerGas = ethers.utils.formatUnits(formatted.maxPriorityFeePerGas, 'gwei')
  formatted.maxPriorityFeePerGas += ' gwei'
  if ('gasLimit' in formatted)
    formatted.gasLimit = formatted.gasLimit.toString()
  formatted.method = method
  socket.emit('requestTransaction', tx, formatted)
}

function simpleTxn(socket, contract, func) {
  return async (...args) => {
    try {
      requestTransaction(socket, func,
        await contract.connect(socket.account).populateTransaction[func](
          ...args, {
            maxFeePerGas: socket.feeData.maxFeePerGas,
            maxPriorityFeePerGas: socket.feeData.maxPriorityFeePerGas
          }))
    }
    catch (e) {
      socket.emit('errorMsg', e.toString())
    }
  }
}

io.on('connection', async socket => {
  await refreshNetworkInfo(socket)

  socket.on('newAccount', async () => {
    try {
      socket.account = ethers.Wallet.createRandom().connect(provider)
      await changeAccount(socket)
    }
    catch (e) {
      socket.emit('errorMsg', e.toString())
    }
  })

  provider.on('block', async blockNumber => {
    await refreshNetworkInfo(socket)
  })

  socket.on('resetFees', async () => {
    delete socket.customFees
    await refreshFeeData(socket)
  })

  socket.on('customFees', (maxFeePerGas, maxPriorityFeePerGas) => {
    socket.customFees = {
      maxFeePerGas: ethers.utils.parseUnits(maxFeePerGas, 'gwei'),
      maxPriorityFeePerGas: ethers.utils.parseUnits(maxPriorityFeePerGas, 'gwei')
    }
    socket.feeData = socket.customFees
  })

  socket.on('privkey', async privkey => {
    try {
      socket.account = new ethers.Wallet(privkey, provider)
      await changeAccount(socket)
    }
    catch (e) {
      socket.emit('errorMsg', e.toString())
    }
  })

  socket.on('transaction', async tx => {
    try {
      const response = await socket.account.sendTransaction(tx)
      const receipt = await response.wait()
    }
    catch (e) {
      socket.emit('errorMsg', e.toString())
    }
  })

  socket.on('send', async (to, amount) => {
    try {
      const tx = await socket.account
        .populateTransaction({
          to: to,
          type: 2,
          maxFeePerGas: socket.feeData.maxFeePerGas,
          maxPriorityFeePerGas: socket.feeData.maxPriorityFeePerGas,
          value: ethers.utils.parseEther(amount)
        })
      requestTransaction(socket, 'send', tx)
    }
    catch (e) {
      socket.emit('errorMsg', e.toString())
    }
  })

  socket.on('addPreference', async (key, value) => {
    if (socket.account) {
      const dbkey = `/${socket.account.address}/preferences/${key}`
      const a = (await db.exists(dbkey)) ? (await db.getData(dbkey)) : []
      const s = new Set(a)
      s.add(value)
      await db.push(dbkey, Array.from(s.keys()))
    }
  })

  socket.on('deletePreference', async (key, value) => {
    if (socket.account) {
      const dbkey = `/${socket.account.address}/preferences/${key}`
      const a = (await db.exists(dbkey)) ? (await db.getData(dbkey)) : []
      const s = new Set(a)
      s.delete(value)
      await db.push(dbkey, Array.from(s.keys()))
    }
  })

  socket.on('requestLogCount', async (tableId) => {
    socket.emit('logCount', tableId,
      (await db.exists(`/logs/t${tableId}`)) ?
      (await db.count(`/logs/t${tableId}`)) : 0)
  })

  socket.on('requestLogs', async (tableId, lastN) => {
    socket.emit('logs', tableId,
      lastN === 1 ? [await db.getData(`/logs/t${tableId}[-1]`)] :
      (await db.getData(`/logs/t${tableId}`)).slice(-lastN))
  })

  socket.on('createGame', async data => {
    try {
      const { seatIndex, ...config } = data
      config.buyIn = ethers.utils.parseEther(config.buyIn)
      config.bond = ethers.utils.parseEther(config.bond)
      config.gameAddress = game.address
      config.structure = config.structure.split(/\s/).map(x => ethers.utils.parseEther(x))
      requestTransaction(socket, 'createTable',
        await room.connect(socket.account).populateTransaction
        .createTable(
          seatIndex, config, {
            value: config.buyIn.add(config.bond),
            maxFeePerGas: socket.feeData.maxFeePerGas,
            maxPriorityFeePerGas: socket.feeData.maxPriorityFeePerGas
          }))
    }
    catch (e) {
      socket.emit('errorMsg', e.toString())
    }
  })

  socket.on('leaveGame', simpleTxn(socket, room, 'leaveTable'))

  socket.on('joinGame', async (tableId, seatIndex) => {
    try {
      requestTransaction(socket, 'joinTable',
        await room.connect(socket.account).populateTransaction
        .joinTable(
          tableId, seatIndex, {
            value: socket.gameConfigs[tableId].bond.add(socket.gameConfigs[tableId].buyIn),
            maxFeePerGas: socket.feeData.maxFeePerGas,
            maxPriorityFeePerGas: socket.feeData.maxPriorityFeePerGas
          }))
    }
    catch (e) {
      socket.emit('errorMsg', e.toString())
    }
  })

  socket.on('submitPrep', async (tableId, seatIndex) => {
    try {
      const hash = await submitPrep(db, socket, tableId)
      requestTransaction(socket, 'submitPrep',
        await room.connect(socket.account).populateTransaction
        .submitPrep(
          tableId, seatIndex, hash, {
            maxFeePerGas: socket.feeData.maxFeePerGas,
            maxPriorityFeePerGas: socket.feeData.maxPriorityFeePerGas
          }))
    }
    catch (e) {
      socket.emit('errorMsg', e.toString())
    }
  })

  socket.on('verifyPrep', async (tableId, seatIndex) => {
    try {
      const deckPrep = await verifyPrep(db, socket, tableId)
      requestTransaction(socket, 'verifyPrep',
        await room.connect(socket.account).populateTransaction
        .verifyPrep(
          tableId, seatIndex, deckPrep, {
            maxFeePerGas: socket.feeData.maxFeePerGas,
            maxPriorityFeePerGas: socket.feeData.maxPriorityFeePerGas
          }))
    }
    catch (e) {
      socket.emit('errorMsg', e.toString())
    }
  })

  socket.on('submitShuffle', async tableId => {
    try {
      const [shuffledCards, commitmentHash] = await shuffle(db, deck, socket, tableId)
      requestTransaction(socket, 'submitShuffle',
        await room.connect(socket.account).populateTransaction
        .submitShuffle(
          tableId, socket.activeGames[tableId].seatIndex,
          shuffledCards, commitmentHash, {
            maxFeePerGas: socket.feeData.maxFeePerGas,
            maxPriorityFeePerGas: socket.feeData.maxPriorityFeePerGas
          }))
    }
    catch (e) {
      socket.emit('errorMsg', e.toString())
    }
  })

  socket.on('verifyShuffle', async tableId => {
    try {
      const [commitment, scalars, permutations] = await verifyShuffle(db, deck, socket, tableId)
      requestTransaction(socket, 'verifyShuffle',
        await room.connect(socket.account).populateTransaction
        .verifyShuffle(
          tableId, socket.activeGames[tableId].seatIndex,
          commitment, scalars, permutations, {
            maxFeePerGas: socket.feeData.maxFeePerGas,
            maxPriorityFeePerGas: socket.feeData.maxPriorityFeePerGas
          }))
    }
    catch (e) {
      socket.emit('errorMsg', e.toString())
    }
  })

  socket.on('decryptCards', async (tableId, cardIndices, end) => {
    try {
      const data = await decryptCards(db, deck, socket, tableId, cardIndices)
      const args = [
        tableId, socket.activeGames[tableId].seatIndex, data, true, {
          maxFeePerGas: socket.feeData.maxFeePerGas,
          maxPriorityFeePerGas: socket.feeData.maxPriorityFeePerGas
        }
      ]
      const room_a = room.connect(socket.account)
      try { await room_a.callStatic.decryptCards(...args) }
      catch (e) {
        args[3] = false
      }
      requestTransaction(socket, 'decryptCards',
        await room_a.populateTransaction.decryptCards(...args))
    }
    catch (e) {
      socket.emit('errorMsg', e.toString())
    }
  })

  socket.on('openCards', async (tableId, cardIndices, end) => {
    try {
      const data = await revealCards(db, deck, socket, tableId, cardIndices)
      const args = [
        tableId, socket.activeGames[tableId].seatIndex, data, true, {
          maxFeePerGas: socket.feeData.maxFeePerGas,
          maxPriorityFeePerGas: socket.feeData.maxPriorityFeePerGas
        }
      ]
      const room_a = room.connect(socket.account)
      try { await room_a.callStatic.revealCards(...args) }
      catch (e) {
        args[3] = false
      }
      requestTransaction(socket, 'revealCards',
        await room_a.populateTransaction.revealCards(...args))
    }
    catch (e) {
      socket.emit('errorMsg', e.toString())
    }
  })

  socket.on('show', async (tableId, seatIndex) => {
    try {
      const indices = (await game.games(tableId)).hands[seatIndex].map(n => n.toNumber())
      const data = await revealCards(db, deck, socket, tableId, indices)
      requestTransaction(socket, 'showCards',
        await game.connect(socket.account).populateTransaction
        .showCards(
          tableId, seatIndex, data, {
            maxFeePerGas: socket.feeData.maxFeePerGas,
            maxPriorityFeePerGas: socket.feeData.maxPriorityFeePerGas
          }))
    }
    catch (e) {
      socket.emit('errorMsg', e.toString())
    }
  })

  socket.on('foldCards', simpleTxn(socket, game, 'foldCards'))

  socket.on('fold', simpleTxn(socket, game, 'fold'))

  socket.on('call', simpleTxn(socket, game, 'callBet'))

  socket.on('raise', async (tableId, seatIndex, raiseBy, bet) => {
    try {
      const raiseTo = ethers.utils.parseEther(bet).add(raiseBy)
      requestTransaction(socket, 'raiseBet',
        await game.connect(socket.account).populateTransaction
        .raiseBet(
          tableId, seatIndex, raiseTo, {
            maxFeePerGas: socket.feeData.maxFeePerGas,
            maxPriorityFeePerGas: socket.feeData.maxPriorityFeePerGas
          }))
    }
    catch (e) {
      socket.emit('errorMsg', e.toString())
    }
  })
})
