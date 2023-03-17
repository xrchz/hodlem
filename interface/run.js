import 'dotenv/config'
import * as fs from 'node:fs'
import { ethers } from 'ethers'
import express from 'express'
import { fileURLToPath } from 'url'
import * as path from 'node:path'
import { createServer } from 'http'
import { Server as SocketIOServer } from 'socket.io'
import { JsonDB, Config as JsonDBConfig } from 'node-json-db'
import { bn254 } from '@noble/curves/bn'
import { invert } from '@noble/curves/abstract/modular'

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
  JSON.parse(fs.readFileSync(process.env.GAME_ABI || '../build/contracts/Game.json', 'utf8')).abi,
  provider)
console.log(`Game is ${game.address}`)
const room = new ethers.Contract(process.env.ROOM,
  JSON.parse(fs.readFileSync(process.env.ROOM_ABI || '../build/contracts/Room.json', 'utf8')).abi,
  provider)
console.log(`Room is ${room.address}`)
const deck = new ethers.Contract(process.env.DECK,
  JSON.parse(fs.readFileSync(process.env.DECK_ABI || '../build/contracts/Deck.json', 'utf8')).abi,
  provider)
console.log(`Deck is ${deck.address}`)

function processArg(arg, index, name) {
  if (['RaiseBet', 'CallBet', 'PostBlind', 'CollectPot'].includes(name) && index >= 1) return ethers.utils.formatEther(arg)
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
    console.log(`querying balance for ${socket.account.address}...`)
    const bal = await provider.getBalance(socket.account.address)
    console.log(`...done [balance]`)
    return bal
  }
  socket.emit('balance',
    socket.account && socket.account.privateKey != ''
    ? ethers.utils.formatEther(await b())
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

async function getActiveGames(socket) {
  console.log(`querying active games for ${socket.account.address}...`)
  const tableIds = []
  let id = await room.nextLiveTable(socket.account.address, 0)
  while (!ethers.BigNumber.from(id).isZero()) {
    tableIds.push(id)
    id = await room.nextLiveTable(socket.account.address, id)
  }
  console.log('...done [active]')
  return tableIds
}

const MAX_SECURITY = 63
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
      console.log(`querying config for table ${id}...`)
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
      console.log('...done [config]')
    }
  }))
}

async function refreshPendingGames(socket) {
  const tableIds = await getPendingGames()
  await getGameConfigs(socket, tableIds)
  const seats = {}
  console.log(`querying seats for pending tables...`)
  await Promise.all(tableIds.map(async idNum => {
    const id = idNum.toString()
    seats[id] = []
    for (const seatIndex of Array(socket.gameConfigs[id].startsWith.toNumber()).keys()) {
      seats[id].push(await room.playerAt(idNum, seatIndex))
    }
  }))
  console.log(`...done [seats]`)
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
    data.bet = gameData.bet.slice(0, numPlayers).map(b => ethers.utils.formatEther(b))
    data.betIndex = gameData.betIndex.toNumber()
    data.pot = gameData.pot.slice(0, numPlayers).flatMap(p => p.isZero() ? [] : [ethers.utils.formatEther(p)])
    if (!data.pot.length) data.pot.push(0)
    data.actionIndex = gameData.actionIndex.toNumber()
    data.minRaise = ethers.utils.formatEther(gameData.minRaise)
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
      for (const idx of gameData.hands[data.seatIndex])
        data.hand.push((await lookAtCard(socket, id, deckId, idx)).openIndex)
    }
    if (data.phase === Phase_SHOW) {
      for (const idx of gameData.hands[data.seatIndex])
        data.hand.push((await lookAtCard(socket, id, deckId, idx)).openIndex)
    }
  }
  socket.emit('activeGames',
    tableIds.map(idNum => socket.gameConfigs[idNum.toString()].formatted),
    socket.activeGames)
}

function randomPoint() {
  return bn254.ProjectivePoint.fromPrivateKey(bn254.utils.randomPrivateKey())
}

function randomScalar() {
  return bn254.utils.normPrivateKeyToScalar(bn254.utils.randomPrivateKey())
}

function uint256ToBytes(n) {
  const s = n.toString(16)
  const h = s.padStart(64, '0')
  const b = new Uint8Array(32)
  let i = 0
  while (i < 64) {
    b[i/2] = parseInt(h.slice(i, i+2), 16)
    i += 2
  }
  return b
}

function bytesToUint256(a) {
  return BigInt(`0x${Array.from(a).map(i => i.toString(16).padStart(2, '0')).join('')}`)
}

function pointToUints(p) {
  const a = p.toAffine()
  return [a.x, a.y]
}

function bigIntegersToPoint(a) {
  return bn254.ProjectivePoint.fromAffine({
    x: BigInt(a[0].toString()),
    y: BigInt(a[1].toString())
  })
}

function pointToBytes(p) {
  const byteArrs = pointToUints(p).map(n => uint256ToBytes(n))
  const r = new Uint8Array(64)
  r.set(byteArrs[0], 0)
  r.set(byteArrs[1], 32)
  return r
}

function bytesToPoint(b) {
  return bn254.ProjectivePoint.fromAffine({
    x: bytesToUint256(b.slice(0, 32)),
    y: bytesToUint256(b.slice(32))
  })
}

async function prepareDeck(socket, id) {
  const key = `/${socket.account.address}/${id}/prep`
  const hash = new Uint8Array(32 + 3 * 64)
  for (const i of Array(53).keys()) {
    const g = randomPoint()
    const gb = pointToBytes(g)
    await db.push(`${key}/${i}/g`, gb.join())
    const x = randomScalar()
    await db.push(`${key}/${i}/x`, x.toString())
    const gx = g.multiply(x)
    const gxb = pointToBytes(gx)
    await db.push(`${key}/${i}/gx`, gxb.join())
    const h = randomPoint()
    const hb = pointToBytes(h)
    await db.push(`${key}/${i}/h`, hb.join())
    hash.set(gb, 32)
    hash.set(gxb, 32 + 64)
    hash.set(hb, 32 + 128)
    hash.set(bn254.CURVE.hash(hash))
  }
  return hash.slice(0, 32)
}

async function revealPrep(socket, id) {
  const key = `/${socket.account.address}/${id}/prep`
  const cards = []
  for (const i of Array(53).keys()) {
    const gb = Uint8Array.from((await db.getData(`${key}/${i}/g`)).split(','))
    const g = bytesToPoint(gb)
    const x = BigInt(await db.getData(`${key}/${i}/x`))
    const gxb = Uint8Array.from((await db.getData(`${key}/${i}/gx`)).split(','))
    const gx = bytesToPoint(gxb)
    const hb = Uint8Array.from((await db.getData(`${key}/${i}/h`)).split(','))
    const h = bytesToPoint(hb)
    const hx = h.multiply(x)
    const s = randomScalar()
    const gs = g.multiply(s)
    const hs = h.multiply(s)
    const toHash = new Uint8Array(6 * 64)
    ;[gb, hb, gxb, pointToBytes(hx), pointToBytes(gs), pointToBytes(hs)].forEach((p, i) => {
      toHash.set(p, i * 64)
    })
    const c = bytesToUint256(bn254.CURVE.hash(toHash))
    cards.push({
      g: pointToUints(g),
      h: pointToUints(h),
      gx: pointToUints(gx),
      hx: pointToUints(hx),
      p: {
        gs: pointToUints(gs),
        hs: pointToUints(hs),
        scx: (s + c * x) % bn254.CURVE.n
      }
    })
  }
  return cards
}

function shuffleArray(array) {
  for (let i = array.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * i)
    ;[array[i], array[j]] = [array[j], array[i]]
  }
}

function hashCommitment(c) {
  const hash = new Uint8Array(32 * 3)
  c.forEach(d => {
    d.forEach(p => {
      hash.set(uint256ToBytes(p[0]), 32)
      hash.set(uint256ToBytes(p[1]), 64)
      hash.set(bn254.CURVE.hash(hash))
    })
  })
  return hash.slice(0, 32)
}

async function shuffle(socket, tableId) {
  const data = socket.activeGames[tableId]
  const config = socket.gameConfigs[tableId]
  const x = randomScalar()
  await db.push(`/${socket.account.address}/${tableId}/shuffle/secret`, x.toString())
  const permutation = Array.from({length: 52}, (_, i) => i + 1)
  shuffleArray(permutation)
  await db.push(`/${socket.account.address}/${tableId}/shuffle/permutation`, permutation)
  const lastCards = await deck.lastShuffle(config.deckId)
  permutation.unshift(0)
  console.log(`created permutation: ${JSON.stringify(permutation)}`)
  const cards = permutation.map(i =>
    pointToUints(
      bigIntegersToPoint(lastCards[i]).multiply(x)
    )
  )
  const secrets = Array.from({length: config.formatted.verifRounds}, _ => randomScalar())
  const permutations = secrets.map(_ => {
    const a = Array.from({length: 53}, (_, i) => i)
    shuffleArray(a)
    return a
  })
  await db.push(`/${socket.account.address}/${tableId}/shuffle/secrets`, secrets.map(x => x.toString()))
  await db.push(`/${socket.account.address}/${tableId}/shuffle/permutations`, permutations)
  const commitment = permutations.map((p, k) =>
    p.map(i => pointToUints(
        bn254.ProjectivePoint.fromAffine(
          {x: cards[i][0],
           y: cards[i][1]})
        .multiply(secrets[k]))))
  await db.push(`/${socket.account.address}/${tableId}/shuffle/commitment`,
                commitment.map(d => d.map(c => c.map(i => i.toString()))))
  return [cards, hashCommitment(commitment)]
}

const emptyCommitment = Array.from({length: 53}, _ => [0, 0])
const emptyPermutation = Array(53).fill(0)

async function verifyShuffle(socket, tableId) {
  let challenge = await deck.challengeRnd(
    socket.gameConfigs[tableId].deckId,
    socket.activeGames[tableId].seatIndex)
  const secret = BigInt(await db.getData(`/${socket.account.address}/${tableId}/shuffle/secret`))
  const permutation = await db.getData(`/${socket.account.address}/${tableId}/shuffle/permutation`)
  const secrets = await db.getData(`/${socket.account.address}/${tableId}/shuffle/secrets`)
  const permutations = await db.getData(`/${socket.account.address}/${tableId}/shuffle/permutations`)
  const commitment = await db.getData(`/${socket.account.address}/${tableId}/shuffle/commitment`)
  const scalars = []
  const responsePermutations = []
  permutations.forEach((p, i) => {
    if (challenge.mod(2).isZero()) {
      scalars.push((secret * BigInt(secrets[i])) % bn254.CURVE.n)
      responsePermutations.push(p.map(j => permutation[j]))
    }
    else {
      scalars.push(secrets[i])
      responsePermutations.push(p)
    }
    challenge = challenge.div(2)
  })
  const pad = {length: MAX_SECURITY - scalars.length}
  commitment.push(...Array.from(pad, _ => emptyCommitment))
  scalars.push(...Array.from(pad, _ => 0))
  responsePermutations.push(...Array.from(pad, _ => emptyPermutation))
  return [commitment, scalars, responsePermutations]
}

async function decryptCards(socket, tableId, cardIndices) {
  const deckId = socket.gameConfigs[tableId].deckId
  const data = socket.activeGames[tableId]
  const result = []
  for (const cardIndex of cardIndices) {
    const lastDecrypt = await deck.lastDecrypt(deckId, cardIndex)
    if (data.drawIndex[cardIndex] === data.seatIndex) {
      result.push([cardIndex, lastDecrypt[0], lastDecrypt[1], 0, 0, 0, 0, 0])
    }
    else {
      /*
        g: self.decks[_id].shuffle[_playerIdx][0],
        h: _card, <- aka decrypt
        gx: self.decks[_id].shuffle[unsafe_add(_playerIdx, 1)][0],
        hx: self.decks[_id].cards[_cardIdx].c[_playerIdx], <- aka lastDecrypt
      */
      const secret = BigInt(await db.getData(`/${socket.account.address}/${tableId}/shuffle/secret`))
      const inverse = invert(secret, bn254.CURVE.n)
      const hx = bigIntegersToPoint(lastDecrypt)
      const decrypt = hx.multiply(inverse)
      const g = bigIntegersToPoint(await deck.shuffleBase(deckId, data.seatIndex))
      const gx = bigIntegersToPoint(await deck.shuffleBase(deckId, data.seatIndex + 1))
      const s = randomScalar()
      const gs = g.multiply(s)
      const hs = decrypt.multiply(s)
      const toHash = new Uint8Array(6 * 64)
      ;[g, decrypt, gx, hx, gs, hs].forEach((p, i) => {
        toHash.set(pointToBytes(p), i * 64)
      })
      const c = bytesToUint256(bn254.CURVE.hash(toHash))
      const proof = {
          gs: pointToUints(gs),
          hs: pointToUints(hs),
          scx: (s + c * secret) % bn254.CURVE.n
        }
      const card = pointToUints(decrypt)
      result.push([cardIndex, card[0], card[1], proof.gs[0], proof.gs[1], proof.hs[0], proof.hs[1], proof.scx])
    }
  }
  return result
}

async function lookAtCard(socket, tableId, deckId, cardIndex) {
  const secret = BigInt(await db.getData(`/${socket.account.address}/${tableId}/shuffle/secret`))
  const inverse = invert(secret, bn254.CURVE.n)
  const bases = (await deck.baseCards(deckId)).map(c => bigIntegersToPoint(c))
  const lastDecrypt = bigIntegersToPoint(await deck.lastDecrypt(deckId, cardIndex))
  let openIndex = 0
  for (const b of bases) {
    if (lastDecrypt.multiply(inverse).equals(bases[openIndex])) break
    openIndex += 1
  }
  return {openIndex, card: bases[openIndex], lastDecrypt, secret}
}

async function revealCards(socket, tableId, cardIndices) {
  const deckId = socket.gameConfigs[tableId].deckId
  const data = socket.activeGames[tableId]
  const g = bigIntegersToPoint(await deck.shuffleBase(deckId, data.seatIndex))
  const gx = bigIntegersToPoint(await deck.shuffleBase(deckId, data.seatIndex + 1))
  const result = []
  for (const cardIndex of cardIndices) {
    const {secret, card: h, lastDecrypt: hx, openIndex} =
      await lookAtCard(socket, tableId, deckId, cardIndex)
    const s = randomScalar()
    const gs = g.multiply(s)
    const hs = h.multiply(s)
    const toHash = new Uint8Array(6 * 64)
    ;[g, h, gx, hx, gs, hs].forEach((p, i) => {
      toHash.set(pointToBytes(p), i * 64)
    })
    const c = bytesToUint256(bn254.CURVE.hash(toHash))
    const proof = {
        gs: pointToUints(gs),
        hs: pointToUints(hs),
        scx: (s + c * secret) % bn254.CURVE.n
      }
    result.push([cardIndex, openIndex, proof.gs[0], proof.gs[1], proof.hs[0], proof.hs[1], proof.scx])
  }
  return result
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

async function changeAccount(socket) {
  socket.emit('account', socket.account.address, socket.account.privateKey)
  await db.push(`/${socket.account.address}/privateKey`, socket.account.privateKey)
  await refreshBalance(socket)
  await refreshPendingGames(socket)
  await refreshActiveGames(socket)
}

function simpleTxn(socket, contract, func) {
  return async (...args) => {
    try {
      socket.emit('requestTransaction',
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
      await changeAccount(socket)
    }
    catch (e) {
      socket.emit('errorMsg', e.toString())
    }
  })

  socket.on('transaction', async tx => {
    try {
      console.log('sending transaction...')
      const response = await socket.account.sendTransaction(tx)
      console.log(`awaiting receipt... [txn]`)
      const receipt = await response.wait()
      console.log(`...done [txn]`)
    }
    catch (e) {
      socket.emit('errorMsg', e.toString())
    }
  })

  socket.on('send', async (to, amount) => {
    try {
      socket.emit('requestTransaction',
        await socket.account.populateTransaction({
          to: to,
          type: 2,
          maxFeePerGas: socket.feeData.maxFeePerGas,
          maxPriorityFeePerGas: socket.feeData.maxPriorityFeePerGas,
          value: ethers.utils.parseEther(amount)
        }))
    }
    catch (e) {
      socket.emit('errorMsg', e.toString())
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
      socket.emit('requestTransaction',
        await room.connect(socket.account).populateTransaction
        .createTable(
          seatIndex, config, game.address, {
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
      socket.emit('requestTransaction',
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
      const hash = await prepareDeck(socket, tableId)
      socket.emit('requestTransaction',
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
      const deckPrep = await revealPrep(socket, tableId)
      socket.emit('requestTransaction',
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
      const [shuffledCards, commitmentHash] = await shuffle(socket, tableId)
      socket.emit('requestTransaction',
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

  socket.on('submitVerif', async tableId => {
    try {
      const [commitment, scalars, permutations] = await verifyShuffle(socket, tableId)
      socket.emit('requestTransaction',
        await room.connect(socket.account).populateTransaction
        .submitVerif(
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

  socket.on('decryptCards', async (tableId, cardIndices) => {
    try {
      const data = await decryptCards(socket, tableId, cardIndices)
      socket.emit('requestTransaction',
        await room.connect(socket.account).populateTransaction
        .decryptCards(
          tableId, socket.activeGames[tableId].seatIndex, data, {
            maxFeePerGas: socket.feeData.maxFeePerGas,
            maxPriorityFeePerGas: socket.feeData.maxPriorityFeePerGas
          }))
    }
    catch (e) {
      socket.emit('errorMsg', e.toString())
    }
  })

  socket.on('openCards', async (tableId, cardIndices) => {
    try {
      const data = await revealCards(socket, tableId, cardIndices)
      socket.emit('requestTransaction',
        await room.connect(socket.account).populateTransaction
        .revealCards(
          tableId, socket.activeGames[tableId].seatIndex, data, {
            maxFeePerGas: socket.feeData.maxFeePerGas,
            maxPriorityFeePerGas: socket.feeData.maxPriorityFeePerGas
          }))
    }
    catch (e) {
      socket.emit('errorMsg', e.toString())
    }
  })

  socket.on('endDeal', simpleTxn(socket, game, 'endDeal'))

  socket.on('foldCards', simpleTxn(socket, game, 'foldCards'))

  socket.on('show', simpleTxn(socket, game, 'showCards'))

  socket.on('fold', simpleTxn(socket, game, 'fold'))

  socket.on('call', simpleTxn(socket, game, 'callBet'))

  socket.on('raise', async (tableId, seatIndex, raiseBy, bet) => {
    try {
      const raiseTo = ethers.utils.parseEther(bet).add(ethers.utils.parseEther(raiseBy))
      socket.emit('requestTransaction',
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
