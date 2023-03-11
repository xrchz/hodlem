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

const Phase_PREP = 2
const Phase_SHUF = 3
const Phase_DEAL = 4
const Phase_PLAY = 5
const Phase_SHOW = 6

const configKeys = [
  'buyIn', 'bond', 'startsWith', 'untilLeft', 'levelBlocks', 'verifRounds',
  'prepBlocks', 'shuffBlocks', 'verifBlocks', 'dealBlocks', 'actBlocks']

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
                                ? ethers.utils.formatUnits(data[k], 'ether')
                                : data[k].toNumber()]))
      data.formatted.id = data.id
      data.formatted.structure = data.structure.map(x => ethers.utils.formatUnits(x, 'ether'))
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
    if (!(id in socket.activeGames)) {
      for (const seatIndex of Array(socket.gameConfigs[id].startsWith.toNumber()).keys()) {
        if (await room.playerAt(idNum, seatIndex) === socket.account.address) {
          socket.activeGames[id] = {
            seatIndex: seatIndex,
            deckId: await room.deckId(idNum),
          }
          break
        }
      }
    }
  }))
  for (const [id, data] of Object.entries(socket.activeGames)) {
    console.log(`processing ${id}`)
    data.phase = (await room.phase(id)).toNumber(),
    data.commitBlock = (await room.commitBlock(id)).toNumber()
    if (data.phase === Phase_PREP) {
      data.waitingOn = []
      for (const seatIndex of Array(socket.gameConfigs[id].startsWith.toNumber()).keys()) {
        if (!(await deck.hasSubmittedPrep(data.deckId, seatIndex))) {
          data.waitingOn.push(seatIndex)
        }
      }
    }
    if (data.phase === Phase_SHUF) {
      data.shuffleCount = (await deck.shuffleCount(data.deckId)).toNumber()
      if (data.shuffleCount === socket.gameConfigs[id].startsWith.toNumber()) {
        data.waitingOn = []
        for (const seatIndex of Array(data.shuffleCount).keys()) {
          if (await deck.challengeActive(data.deckId, seatIndex)) {
            data.waitingOn.push(seatIndex)
          }
        }
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
  const indices = Array.from({length: 52}, (_, i) => i + 1)
  shuffleArray(indices)
  await db.push(`/${socket.account.address}/${tableId}/shuffle/permutation`, indices)
  const lastCards = await deck.lastShuffle(data.deckId)
  indices.unshift(0)
  console.log(`created permutation: ${JSON.stringify(indices)}`)
  const cards = indices.map(i =>
    pointToUints(
      bn254.ProjectivePoint.fromAffine(
        {x: BigInt(lastCards[i][0].toString()),
         y: BigInt(lastCards[i][1].toString())})
      .multiply(x)
    )
  )
  const secrets = Array.from({length: config.formatted.verifRounds}, _ => randomScalar())
  const permutations = Array.from({length: config.formatted.verifRounds}, _ => {
    const a = Array.from({length: 53}, (_, i) => i)
    shuffleArray(a)
    return a
  })
  await db.push(`/${socket.account.address}/${tableId}/shuffle/secrets`, secrets.map(x => x.toString()))
  await db.push(`/${socket.account.address}/${tableId}/shuffle/permutations`, permutations)
  const commitment = permutations.map((p, k) =>
    p.map(i => {
      bn254.ProjectivePoint.fromAffine({x: cards[i][0], y: cards[i][1]})
      return pointToUints(
        bn254.ProjectivePoint.fromAffine(
          {x: cards[i][0],
           y: cards[i][1]})
        .multiply(secrets[k])
      )
    }
    )
  )
  await db.push(`/${socket.account.address}/${tableId}/shuffle/commitment`,
                commitment.map(deck => deck.map(card => card.map(i => i.toString()))))
  return [cards, hashCommitment(commitment)]
}

async function verifyShuffle(socket, tableId) {
  let challenge = await deck.challengeRnd(tableId)
  const secret = ethers.BigNumber.from(await db.getData(`/${socket.account.address}/${tableId}/shuffle/secret`))
  const permutation = await db.getData(`/${socket.account.address}/${tableId}/shuffle/permutation`)
  const secrets = await db.getData(`/${socket.account.address}/${tableId}/shuffle/secrets`)
  const permutations = await db.getData(`/${socket.account.address}/${tableId}/shuffle/permutations`)
  const commitment = await db.getData(`/${socket.account.address}/${tableId}/shuffle/commitment`)
  const scalars = []
  const responsePermutations = []
  permutations.forEach((p, i) => {
    if (challenge.mod(2).isZero()) {
      scalars.push(secrets[i])
      responsePermutations.push(p)
    }
    else {
      scalars.push(secret.mul(secrets[i]).mod(bn254.CURVE.n))
      responsePermutations.push(permutation.map(j => p[j]))
    }
    challenge = challenge.div(2)
  })
  return [commitment, scalars, responsePermutations]
}

async function findAutomaticAction(socket) {
  if ('activeGames' in socket) {
    console.log(`looking for auto actions for ${socket.account.address}`)
    for (const [id, data] of Object.entries(socket.activeGames)) {
      console.log(`...auto actions for ${id} ${JSON.stringify(data)}...`)
      if (data.phase === Phase_PREP &&
          !(await deck.hasSubmittedPrep(data.deckId, data.seatIndex))) {
        console.log('doing deckPrep...')
        const deckPrep = prepareDeck()
        socket.emit('requestTransaction',
          await room.connect(socket.account).populateTransaction
          .prepareDeck(
            id, data.seatIndex, deckPrep, {
              maxFeePerGas: socket.feeData.maxFeePerGas,
              maxPriorityFeePerGas: socket.feeData.maxPriorityFeePerGas
            }))
      }
    }
  }
}

async function refreshNetworkInfo(socket) {
  await refreshBalance(socket)
  await refreshFeeData(socket)
  if (!('hidePending' in socket)) {
    await refreshPendingGames(socket)
  }
  if ('account' in socket) {
    await refreshActiveGames(socket)
    await findAutomaticAction(socket)
  }
}

async function changeAccount(socket) {
  socket.emit('account', socket.account.address, socket.account.privateKey)
  await db.push(`/${socket.account.address}/privateKey`, socket.account.privateKey)
  await refreshBalance(socket)
  await refreshPendingGames(socket)
  await refreshActiveGames(socket)
  await findAutomaticAction(socket)
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
      console.log(JSON.stringify(tx))
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

  socket.on('leaveGame', async (tableId, seatIndex) => {
    try {
      socket.emit('requestTransaction',
        await room.connect(socket.account).populateTransaction
        .leaveTable(
          tableId, seatIndex, {
            maxFeePerGas: socket.feeData.maxFeePerGas,
            maxPriorityFeePerGas: socket.feeData.maxPriorityFeePerGas
          }))
    }
    catch (e) {
      socket.emit('errorMsg', e.toString())
    }
  })

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

  socket.on('startGame', async tableId => {
    try {
      socket.emit('requestTransaction',
        await room.connect(socket.account).populateTransaction
        .startGame(
          tableId, {
            maxFeePerGas: socket.feeData.maxFeePerGas,
            maxPriorityFeePerGas: socket.feeData.maxPriorityFeePerGas
          }))
    }
    catch (e) {
      socket.emit('errorMsg', e.toString())
    }
  })

  socket.on('finishPrep', async tableId => {
    try {
      socket.emit('requestTransaction',
        await room.connect(socket.account).populateTransaction
        .finishDeckPrep(
          tableId, {
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
            gasLimit: 10000000,
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
            gasLimit: 20000000,
            maxFeePerGas: socket.feeData.maxFeePerGas,
            maxPriorityFeePerGas: socket.feeData.maxPriorityFeePerGas
          }))
    }
    catch (e) {
      socket.emit('errorMsg', e.toString())
    }
  })
})
