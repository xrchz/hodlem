# @version ^0.3.7
# mental poker deck protocol
#
# Implements the paper
# A Fast Mental Poker Protocol by Tzer-Jen Wei & Lih-Chung Wang
# https://ia.cr/2009/439
# using the alt-bn128's G1 (https://neuromancer.sk/std/bn/bn254) for G
#
# For discrete log equality non-interactive ZK proofs, we use the scheme
# described in Wallet Databases with Observers by David Chaum & Torben Pryds Pederson
# https://dx.doi.org/10.1007/3-540-48071-4_7
# section 3.2

GROUP_ORDER: constant(uint256) = 21888242871839275222246405745257275088548364400416034343698204186575808495617

# TODO: we inline these because of https://github.com/vyperlang/vyper/issues/3294
# TODO: the SIZE is fixed, rather than using DynArrays, because of
#       gas costs without https://github.com/vyperlang/vyper/issues/3319
# TODO: the MAX_SECURITY is rather small because of code size
#       costs https://github.com/vyperlang/vyper/issues/2656
SIZE: constant(uint256) = 52
MAX_PLAYERS: constant(uint256) = 127
MAX_SECURITY: constant(uint256) = 63

struct Proof:
  # signature to confirm log_g(gx) = log_h(hx)
  # s is a random secret scalar
  gs:  uint256[2] # g ** s
  hs:  uint256[2] # h ** s
  scx: uint256 # s + cx (mod q), where c = hash(g, h, gx, hx, gs, hs)

struct CP:
  # g and h are random points, x is a random secret scalar
  g:   uint256[2]
  h:   uint256[2]
  gx:  uint256[2] # g ** x
  hx:  uint256[2] # h ** x
  p: Proof

struct DrawCard:
  # successive decryptions
  c: DynArray[uint256[2], 127]
  # 1 + index of player the card is initially drawn to (i.e. they skip decryption)
  # note: a card can only be drawn to a single player
  drawnTo: uint256
  # 1 + original index after reveal
  opensAs: uint256

struct Deck:
  # authorised address for drawing cards and reshuffling
  dealer: address
  # authorised address for each player
  addrs: DynArray[address, 127]
  # shuffle[0] is the unencrypted cards (including base card at index 0)
  # shuffle[j+1] is the shuffled encrypted cards from player index j
  shuffle: DynArray[uint256[2][53], 128] # 127 + 1] <- another Vyper bug with importing
  challengeReq: DynArray[uint256, 127]
  challengeRes: DynArray[bytes32[2], 127]
  challengeRnd: DynArray[uint256, 127]
  # for decrypting shuffled cards
  # note: cards[i] corresponds to shuffle[_][i+1]
  cards: DrawCard[53]

decks: HashMap[uint256, Deck]
nextId: uint256

@external
def newDeck(_players: uint256) -> uint256:
  assert 0 < _players and _players <= MAX_PLAYERS, "invalid players"
  id: uint256 = self.nextId
  self.decks[id].dealer = msg.sender
  for i in range(MAX_PLAYERS):
    if i == _players:
      break
    self.decks[id].addrs.append(msg.sender)
    self.decks[id].challengeRes.append(empty(bytes32[2]))
  self.decks[id].shuffle.append(empty(uint256[2][SIZE+1]))
  self.nextId = unsafe_add(id, 1)
  return id

@external
def changeDealer(_id: uint256, _newAddress: address):
  assert self.decks[_id].dealer == msg.sender, "unauthorised"
  self.decks[_id].dealer = _newAddress

@external
def changeAddress(_id: uint256, _playerIdx: uint256, _newAddress: address):
  assert self.decks[_id].addrs[_playerIdx] == msg.sender, "unauthorised"
  self.decks[_id].addrs[_playerIdx] = _newAddress

@external
def submitPrep(_id: uint256, _playerIdx: uint256, _hash: bytes32):
  assert self.decks[_id].addrs[_playerIdx] == msg.sender, "unauthorised"
  assert len(self.decks[_id].challengeRnd) == 0, "already finished"
  assert not self._hasSubmittedPrep(_id, _playerIdx), "already prepared"
  assert _hash != empty(bytes32), "invalid commitment"
  self.decks[_id].challengeRes[_playerIdx][0] = _hash

@external
def finishSubmit(_id: uint256):
  numPlayers: uint256 = len(self.decks[_id].addrs)
  assert (len(self.decks[_id].challengeRnd) == 0 and
          self.decks[_id].cards[0].drawnTo == 0), "already finished"
  for playerIdx in range(MAX_PLAYERS):
    if playerIdx == numPlayers: break
    assert self._hasSubmittedPrep(_id, playerIdx), "not submitted"
  self.decks[_id].cards[0].drawnTo = 1

@external
def verifyPrep(_id: uint256, _playerIdx: uint256, _prep: CP[53]):
  assert self.decks[_id].addrs[_playerIdx] == msg.sender, "unauthorised"
  assert self.decks[_id].cards[0].drawnTo == 1, "not submitted"
  assert len(self.decks[_id].challengeRnd) == 0, "already finished"
  assert not self._hasVerifiedPrep(_id, _playerIdx), "already verified"
  hash: bytes32 = empty(bytes32)
  for cardIdx in range(SIZE+1):
    hash = sha256(concat(hash,
             convert(_prep[cardIdx].g[0], bytes32),
             convert(_prep[cardIdx].g[1], bytes32),
             convert(_prep[cardIdx].gx[0], bytes32),
             convert(_prep[cardIdx].gx[1], bytes32),
             convert(_prep[cardIdx].h[0], bytes32),
             convert(_prep[cardIdx].h[1], bytes32)))
  assert hash == self.decks[_id].challengeRes[_playerIdx][0], "invalid commitment"
  self.decks[_id].challengeRes[_playerIdx][1] = convert(1, bytes32)
  for cardIdx in range(SIZE+1):
    assert self.chaumPederson(_prep[cardIdx]), "invalid prep"
    self.decks[_id].shuffle[0][cardIdx] = ecadd(
      self.decks[_id].shuffle[0][cardIdx], _prep[cardIdx].hx)

@external
def finishPrep(_id: uint256):
  numPlayers: uint256 = len(self.decks[_id].addrs)
  assert self.decks[_id].cards[0].drawnTo == 1, "not submitted"
  assert len(self.decks[_id].challengeRnd) == 0, "already finished"
  for playerIdx in range(MAX_PLAYERS):
    if playerIdx == numPlayers: break
    assert self._hasVerifiedPrep(_id, playerIdx), "not finished"
    self.decks[_id].challengeRnd.append(0)
  self.decks[_id].cards[0].drawnTo = empty(uint256)

@external
def resetShuffle(_id: uint256):
  assert self.decks[_id].dealer == msg.sender, "unauthorised"
  self.decks[_id].shuffle = [self.decks[_id].shuffle[0]]
  self.decks[_id].challengeReq = []
  self.decks[_id].cards = empty(DrawCard[SIZE+1])

@external
def submitShuffle(_id: uint256, _playerIdx: uint256, _shuffle: uint256[2][53]):
  assert self.decks[_id].addrs[_playerIdx] == msg.sender, "unauthorised"
  assert len(self.decks[_id].shuffle) == unsafe_add(_playerIdx, 1), "wrong player"
  self.decks[_id].shuffle.append(_shuffle)
  self.decks[_id].challengeReq.append(0)
  self.decks[_id].challengeRes[_playerIdx] = empty(bytes32[2])

@external
def challenge(_id: uint256, _playerIdx: uint256, _rounds: uint256):
  assert _playerIdx + 1 < len(self.decks[_id].shuffle), "not submitted"
  assert self.decks[_id].challengeReq[_playerIdx] == 0, "ongoing challenge"
  assert 0 < _rounds and _rounds <= MAX_SECURITY, "invalid rounds"
  self.decks[_id].challengeReq[_playerIdx] = _rounds

@external
def respondChallenge(_id: uint256, _playerIdx: uint256, _hash: bytes32) -> uint256:
  assert self.decks[_id].challengeReq[_playerIdx] != 0, "no challenge"
  assert self.decks[_id].addrs[_playerIdx] == msg.sender, "unauthorised"
  assert self.decks[_id].challengeRes[_playerIdx][0] == empty(bytes32), "already responded"
  self.decks[_id].challengeRes[_playerIdx][0] = _hash
  self.decks[_id].challengeRes[_playerIdx][1] = empty(bytes32)
  self.decks[_id].challengeRnd[_playerIdx] = block.prevrandao
  return block.prevrandao

@external
def defuseNextChallenge(_id: uint256, _playerIdx: uint256,
                        _commitment: uint256[2][53], _scalar: uint256, _permutation: uint256[53]):
  assert self.decks[_id].addrs[_playerIdx] == msg.sender, "unauthorised"
  k: uint256 = self.decks[_id].challengeReq[_playerIdx]
  assert k != 0, "no challenge"
  hash: bytes32 = self.decks[_id].challengeRes[_playerIdx][1]
  for p in _commitment:
    hash = sha256(concat(hash, convert(p[0], bytes32), convert(p[1], bytes32)))
  self.decks[_id].challengeRes[_playerIdx][1] = hash
  self.decks[_id].challengeReq[_playerIdx] = unsafe_sub(k, 1)
  if self.decks[_id].challengeReq[_playerIdx] == 0:
    assert self.decks[_id].challengeRes[_playerIdx][0] == hash, "invalid commitments"
  bits: uint256 = self.decks[_id].challengeRnd[_playerIdx]
  self.decks[_id].challengeRnd[_playerIdx] = shift(bits, -1)
  j: uint256 = unsafe_add(_playerIdx, bits & 1)
  for i in range(SIZE+1):
    assert self.pointEq(
      _commitment[i],
      ecmul(self.decks[_id].shuffle[j][_permutation[i]], _scalar)
    ), "verification failed"

@external
def drawCard(_id: uint256, _playerIdx: uint256, _cardIdx: uint256):
  assert self.decks[_id].dealer == msg.sender, "unauthorised"
  assert self.decks[_id].cards[_cardIdx].drawnTo == 0, "already drawn"
  self.decks[_id].cards[_cardIdx].drawnTo = unsafe_add(_playerIdx, 1)
  self.decks[_id].cards[_cardIdx].c.append(
    self.decks[_id].shuffle[len(self.decks[_id].addrs)][unsafe_add(_cardIdx, 1)])

@external
def decryptCard(_id: uint256, _playerIdx: uint256, _cardIdx: uint256,
                _card: uint256[2], _proof: Proof):
  assert self.decks[_id].addrs[_playerIdx] == msg.sender, "unauthorised"
  assert self.decks[_id].cards[_cardIdx].drawnTo != 0, "not drawn"
  assert len(self.decks[_id].cards[_cardIdx].c) == unsafe_add(_playerIdx, 1), "out of turn"
  if unsafe_add(_playerIdx, 1) == self.decks[_id].cards[_cardIdx].drawnTo:
    assert self.pointEq(_card, self.decks[_id].cards[_cardIdx].c[_playerIdx]), "wrong card"
  else:
    assert self.chaumPederson(CP({
      g: self.decks[_id].shuffle[_playerIdx][0],
      h: _card,
      gx: self.decks[_id].shuffle[unsafe_add(_playerIdx, 1)][0],
      hx: self.decks[_id].cards[_cardIdx].c[_playerIdx],
      p: _proof})), "verification failed"
  self.decks[_id].cards[_cardIdx].c.append(_card)

@external
def openCard(_id: uint256, _playerIdx: uint256, _cardIdx: uint256,
             _openIdx: uint256, _proof: Proof):
  assert self.decks[_id].addrs[_playerIdx] == msg.sender, "unauthorised"
  assert self.decks[_id].cards[_cardIdx].drawnTo == unsafe_add(_playerIdx, 1), "wrong player"
  assert len(self.decks[_id].cards[_cardIdx].c) == unsafe_add(
    len(self.decks[_id].addrs), 1), "not decrypted"
  assert self.decks[_id].cards[_cardIdx].opensAs == 0, "already open"
  assert self.chaumPederson(CP({
    g: self.decks[_id].shuffle[_playerIdx][0],
    h: self.decks[_id].shuffle[0][_openIdx],
    gx: self.decks[_id].shuffle[unsafe_add(_playerIdx, 1)][0],
    hx: self.decks[_id].cards[_cardIdx].c[len(self.decks[_id].addrs)],
    p: _proof})), "verification failed"
  self.decks[_id].cards[_cardIdx].opensAs = unsafe_add(_openIdx, 1)

@internal
@pure
def pointEq(a: uint256[2], b: uint256[2]) -> bool:
  return a[0] == b[0] and a[1] == b[1]

@internal
@pure
def hash(g: uint256[2], h: uint256[2],
         gx: uint256[2], hx: uint256[2],
         gs: uint256[2], hs: uint256[2]) -> uint256:
  return convert(
    sha256(concat(
      convert(g[0], bytes32), convert(g[1], bytes32),
      convert(h[0], bytes32), convert(h[1], bytes32),
      convert(gx[0], bytes32), convert(gx[1], bytes32),
      convert(hx[0], bytes32), convert(hx[1], bytes32),
      convert(gs[0], bytes32), convert(gs[1], bytes32),
      convert(hs[0], bytes32), convert(hs[1], bytes32))),
    uint256) % GROUP_ORDER

@external
@pure
def emptyProof(base: uint256[2], card: uint256[2]) -> Proof:
  return Proof({
    gs: empty(uint256[2]),
    hs: empty(uint256[2]),
    scx: self.hash(base, card, base, card, empty(uint256[2]), empty(uint256[2]))})

@internal
@pure
def cp1(p: uint256[2], px: uint256[2], ps: uint256[2], c: uint256, scx: uint256) -> bool:
  return self.pointEq(ecadd(ps, ecmul(px, c)), ecmul(p, scx))

@internal
@pure
def chaumPederson(cp: CP) -> bool:
  # unlike Chaum & Pederson we also include g and gx in the hash
  # so we are hashing the statement as well as the commitment
  # (see https://ia.cr/2016/771)
  c: uint256 = self.hash(cp.g, cp.h, cp.gx, cp.hx, cp.p.gs, cp.p.hs)
  return (self.cp1(cp.g, cp.gx, cp.p.gs, c, cp.p.scx) and
          self.cp1(cp.h, cp.hx, cp.p.hs, c, cp.p.scx))

@internal
@view
def _hasSubmittedPrep(_id: uint256, _playerIdx: uint256) -> bool:
  return self.decks[_id].challengeRes[_playerIdx][0] != empty(bytes32)

@internal
@view
def _hasVerifiedPrep(_id: uint256, _playerIdx: uint256) -> bool:
  return self.decks[_id].challengeRes[_playerIdx][1] != empty(bytes32)

@external
@view
def hasSubmittedPrep(_id: uint256, _playerIdx: uint256) -> bool:
  return self._hasSubmittedPrep(_id, _playerIdx)

@external
@view
def hasVerifiedPrep(_id: uint256, _playerIdx: uint256) -> bool:
  return self._hasVerifiedPrep(_id, _playerIdx)

@external
@view
def allSubmittedPrep(_id: uint256) -> bool:
  return self.decks[_id].cards[0].drawnTo == 1

@external
@view
def shuffleCount(_id: uint256) -> uint256:
  return unsafe_sub(len(self.decks[_id].shuffle), 1)

@external
@view
def lastShuffle(_id: uint256) -> uint256[2][53]:
  return self.decks[_id].shuffle[unsafe_sub(len(self.decks[_id].shuffle), 1)]

@external
@view
def challengeActive(_id: uint256, _playerIdx: uint256) -> bool:
  return self.decks[_id].challengeReq[_playerIdx] != 0

@external
@view
def challengeRnd(_id: uint256, _playerIdx: uint256) -> uint256:
  return self.decks[_id].challengeRnd[_playerIdx]

@external
@view
def decryptCount(_id: uint256, _cardIdx: uint256) -> uint256:
  return unsafe_sub(len(self.decks[_id].cards[_cardIdx].c), 1)

@external
@view
def lastDecrypt(_id: uint256, _cardIdx: uint256) -> uint256[2]:
  return self.decks[_id].cards[_cardIdx].c[
    unsafe_sub(len(self.decks[_id].cards[_cardIdx].c), 1)]

@external
@view
def shuffleBase(_id: uint256, _idx: uint256) -> uint256[2]:
  return self.decks[_id].shuffle[_idx][0]

@external
@view
def baseCards(_id: uint256) -> uint256[2][53]:
  return self.decks[_id].shuffle[0]

@external
@view
def openedCard(_id: uint256, _cardIdx: uint256) -> uint256:
  return self.decks[_id].cards[_cardIdx].opensAs
