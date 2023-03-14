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
  JSON.parse(fs.readFileSync(process.env.GAME_ABI || '../build/interfaces/Game.json', 'utf8')).abi,
  provider)
console.log(`Game is ${game.address}`)
const room = new ethers.Contract(process.env.ROOM,
  JSON.parse(fs.readFileSync(process.env.ROOM_ABI || '../build/interfaces/Room.json', 'utf8')).abi,
  provider)
console.log(`Room is ${room.address}`)
const deck = new ethers.Contract(process.env.DECK,
  JSON.parse(fs.readFileSync(process.env.DECK_ABI || '../build/interfaces/Deck.json', 'utf8')).abi,
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
      for (const seatIndex of Array(numPlayers).keys()) {
        if (await room.playerAt(idNum, seatIndex) === socket.account.address) {
          socket.activeGames[id] = { seatIndex: seatIndex }
          break
        }
      }
    }
  }))
  for (const [id, data] of Object.entries(socket.activeGames)) {
    console.log(`processing ${id}`)
    const config = socket.gameConfigs[id]
    const deckId = config.deckId
    const numPlayers = config.formatted.startsWith
    ;[data.phase, data.commitBlock] = (await room.phaseCommit(id)).map(i => i.toNumber())
    delete data.toDeal
    if (data.phase === Phase_PREP) {
      data.waitingOn = []
      for (const seatIndex of Array(numPlayers).keys()) {
        if (!(await deck.hasSubmittedPrep(deckId, seatIndex))) {
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
        if (!(shuffled.isZero())) {
          data.toDeal = ((await game.games(id)).startBlock.isZero()) ? 'high card' : 'hole cards'
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
      const gameData = await game.games(id)
      delete data.selectDealer
      if (gameData.startBlock.isZero()) {
        data.cards = []
        for (const seatIndex of Array(numPlayers).keys()) {
          data.cards.push((await deck.openedCard(deckId, seatIndex)).toNumber())
        }
        data.selectDealer = true
      }
      else {
        data.board = gameData.board.flatMap(i => i.isZero() ? [] : [i.toNumber()])
        data.hand = []
        for (const idx of gameData.hands[data.seatIndex])
          data.hand.push((await lookAtCard(socket, id, deckId, idx)).openIndex)
        data.stack = gameData.stack.slice(0, numPlayers).map(s => ethers.utils.formatEther(s))
        data.bet = gameData.bet.slice(0, numPlayers).map(b => ethers.utils.formatEther(b))
        data.betIndex = gameData.betIndex.toNumber()
        data.pot = gameData.pot.slice(0, numPlayers).flatMap(p => p.isZero() ? [] : [ethers.utils.formatEther(p)])
        if (!data.pot.length) data.pot.push(0)
        data.actionIndex = gameData.actionIndex.toNumber()
        data.minRaise = ethers.utils.formatEther(gameData.minRaise)
        data.dealer = gameData.dealer.toNumber()
        data.postBlinds = gameData.board[0].isZero() && gameData.actionBlock.isZero()
      }
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

function prepareDeck() {
  const cards = []
  for (const i of Array(53).keys()) {
    const g = randomPoint()
    const h = randomPoint()
    const x = randomScalar()
    const gx = g.multiply(x)
    const hx = h.multiply(x)
    const s = randomScalar()
    const gs = g.multiply(s)
    const hs = h.multiply(s)
    const toHash = new Uint8Array(6 * 64)
    ;[g, h, gx, hx, gs, hs].forEach((p, i) => {
      toHash.set(pointToBytes(p), i * 64)
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

const emptyProof = {gs: [0, 0], hs: [0, 0], scx: 0}

async function decryptCard(socket, tableId, cardIndex) {
  const deckId = socket.gameConfigs[tableId].deckId
  const lastDecrypt = await deck.lastDecrypt(deckId, cardIndex)
  const data = socket.activeGames[tableId]
  if (data.drawIndex[cardIndex] === data.seatIndex) {
    return [lastDecrypt, emptyProof]
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
    return [pointToUints(decrypt), proof]
  }
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

async function revealCard(socket, tableId, cardIndex) {
  const deckId = socket.gameConfigs[tableId].deckId
  const data = socket.activeGames[tableId]
  const g = bigIntegersToPoint(await deck.shuffleBase(deckId, data.seatIndex))
  const gx = bigIntegersToPoint(await deck.shuffleBase(deckId, data.seatIndex + 1))
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
  return [openIndex, proof]
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
          seatIndex, config, deck.address, {
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

  socket.on('startGame', simpleTxn(socket, room, 'startGame'))

  socket.on('submitPrep', async tableId => {
    try {
      const deckPrep = prepareDeck()
      socket.emit('requestTransaction',
        await room.connect(socket.account).populateTransaction
        .prepareDeck(
          tableId, socket.activeGames[tableId].seatIndex, deckPrep, {
            maxFeePerGas: socket.feeData.maxFeePerGas,
            maxPriorityFeePerGas: socket.feeData.maxPriorityFeePerGas
          }))
    }
    catch (e) {
      socket.emit('errorMsg', e.toString())
    }
  })

  socket.on('finishPrep', simpleTxn(socket, room, 'finishDeckPrep'))

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

  socket.on('decryptCard', async (tableId, cardIndex) => {
    try {
      const [card, proof] = await decryptCard(socket, tableId, cardIndex)
      socket.emit('requestTransaction',
        await room.connect(socket.account).populateTransaction
        .decryptCard(
          tableId, socket.activeGames[tableId].seatIndex, cardIndex,
          card, proof, {
            maxFeePerGas: socket.feeData.maxFeePerGas,
            maxPriorityFeePerGas: socket.feeData.maxPriorityFeePerGas
          }))
    }
    catch (e) {
      socket.emit('errorMsg', e.toString())
    }
  })

  socket.on('openCard', async (tableId, cardIndex) => {
    try {
      const [openIndex, proof] = await revealCard(socket, tableId, cardIndex)
      socket.emit('requestTransaction',
        await room.connect(socket.account).populateTransaction
        .revealCard(
          tableId, socket.activeGames[tableId].seatIndex, cardIndex,
          openIndex, proof, {
            maxFeePerGas: socket.feeData.maxFeePerGas,
            maxPriorityFeePerGas: socket.feeData.maxPriorityFeePerGas
          }))
    }
    catch (e) {
      socket.emit('errorMsg', e.toString())
    }
  })

  socket.on('endDeal', simpleTxn(socket, game, 'endDeal'))

  socket.on('dealHighCard', simpleTxn(socket, game, 'dealHighCard'))

  socket.on('selectDealer', simpleTxn(socket, game, 'selectDealer'))

  socket.on('dealHoleCards', simpleTxn(socket, game, 'dealHoleCards'))

  socket.on('postBlinds', simpleTxn(socket, game, 'postBlinds'))

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
