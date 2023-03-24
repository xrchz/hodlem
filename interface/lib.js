import { bn254 } from '@noble/curves/bn'
import { invert } from '@noble/curves/abstract/modular'

function randomPoint() {
  return bn254.ProjectivePoint.fromPrivateKey(bn254.utils.randomPrivateKey())
}

function randomScalar() {
  return bn254.utils.normPrivateKeyToScalar(bn254.utils.randomPrivateKey())
}

function pointToUints(p) {
  const a = p.toAffine()
  return [a.x, a.y]
}

export function bytesToHex(a) {
  return `0x${Array.from(a).map(i => i.toString(16).padStart(2, '0')).join('')}`
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
  return BigInt(bytesToHex(a))
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

function bigIntegersToPoint(a) {
  return bn254.ProjectivePoint.fromAffine({
    x: BigInt(a[0].toString()),
    y: BigInt(a[1].toString())
  })
}

export async function submitPrep(db, socket, id) {
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

export async function verifyPrep(db, socket, id) {
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

export async function shuffleWithPermutation(db, deck, socket, tableId, permutation) {
  const config = socket.gameConfigs[tableId]
  const x = randomScalar()
  await db.push(`/${socket.account.address}/${tableId}/shuffle/secret`, x.toString())
  await db.push(`/${socket.account.address}/${tableId}/shuffle/permutation`, permutation)
  const lastCards = await deck.lastShuffle(config.deckId)
  permutation.unshift(0)
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

export async function shuffle(db, deck, socket, tableId) {
  const permutation = Array.from({length: 52}, (_, i) => i + 1)
  shuffleArray(permutation)
  return shuffleWithPermutation(db, deck, socket, tableId, permutation)
}

const emptyCommitment = Array.from({length: 53}, _ => [0, 0])
const emptyPermutation = Array(53).fill(0)

export async function verifyShuffle(db, deck, socket, tableId) {
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

export async function decryptCards(db, deck, socket, tableId, cardIndices) {
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

async function lookAtCard(db, deck, socket, tableId, deckId, cardIndex) {
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

export async function revealCards(db, deck, socket, tableId, cardIndices) {
  const deckId = socket.gameConfigs[tableId].deckId
  const data = socket.activeGames[tableId]
  const g = bigIntegersToPoint(await deck.shuffleBase(deckId, data.seatIndex))
  const gx = bigIntegersToPoint(await deck.shuffleBase(deckId, data.seatIndex + 1))
  const result = []
  for (const cardIndex of cardIndices) {
    const {secret, card: h, lastDecrypt: hx, openIndex} =
      await lookAtCard(db, deck, socket, tableId, deckId, cardIndex)
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
