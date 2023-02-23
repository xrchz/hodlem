# @version ^0.3.8
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

GROUP_ORDER: constant(uint256) = 21888242871839275222246405745257275088696311157297823662689037894645226208583

# arbitrary limits on deck size and number of players sharing a deck
# note: MAX_SIZE must be < GROUP_ORDER
# TODO: we inline these because of https://github.com/vyperlang/vyper/issues/3294
MAX_SIZE: constant(uint256) = 9000
MAX_PLAYERS: constant(uint256) = 8000 # to distinguish from MAX_SIZE when inlining
MAX_SECURITY: constant(uint256) = 256

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

struct DeckPrep:
  cards: DynArray[CP, 9000]

struct DrawCard:
  # successive decryptions
  c: DynArray[uint256[2], 8000]
  # 1 + index of player the card is initially drawn to (i.e. they skip decryption)
  # note: a card can only be drawn to a single player
  drawnTo: uint256
  # 1 + original index after reveal
  opensAs: uint256

struct Deck:
  # authorised address for drawing cards and reshuffling
  dealer: address
  # authorised address for each player
  addrs: DynArray[address, 8000]
  # shuffle[0] is the unencrypted cards (including base card at index 0)
  # shuffle[j+1] is the shuffled encrypted cards from player index j
  shuffle: DynArray[DynArray[uint256[2], 9000], 8001] # 8000 + 1] <- another Vyper bug with importing
  challengeReq: DynArray[uint256, 8000]
  challengeRes: DynArray[DynArray[DynArray[uint256[2], 9000], 256], 8000]
  challengeRnd: uint256
  # for decrypting shuffled cards
  # note: cards[i] corresponds to shuffle[_][i+1]
  cards: DynArray[DrawCard, 9000]
  # data for deck preparation
  prep: DynArray[DeckPrep, 8000]

decks: HashMap[uint256, Deck]
nextId: public(uint256)

@external
def newDeck(_size: uint256, _players: uint256) -> uint256:
  assert 0 < _size and _size < MAX_SIZE, "invalid size"
  assert 0 < _players and _players <= MAX_PLAYERS, "invalid players"
  id: uint256 = self.nextId
  self.decks[id].dealer = msg.sender
  for i in range(MAX_PLAYERS):
    if i == _players:
      break
    self.decks[id].addrs.append(msg.sender)
    self.decks[id].prep.append(empty(DeckPrep))
  self.decks[id].shuffle.append([])
  for i in range(MAX_SIZE):
    self.decks[id].shuffle[0].append(empty(uint256[2]))
    if i == _size:
      break
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
@view
def hasSubmittedPrep(_id: uint256, _playerIdx: uint256) -> bool:
  return len(self.decks[_id].prep[_playerIdx].cards) != 0

@external
def submitPrep(_id: uint256, _playerIdx: uint256, _prep: DeckPrep):
  assert self.decks[_id].addrs[_playerIdx] == msg.sender, "unauthorised"
  assert len(self.decks[_id].prep[_playerIdx].cards) == 0, "already prepared"
  assert len(_prep.cards) == len(self.decks[_id].shuffle[0]), "wrong length"
  for c in _prep.cards:
    assert (c.hx[0] != 0 or c.hx[1] != 0), "invalid point"
  self.decks[_id].prep[_playerIdx] = _prep

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
def emptyProof(card: uint256[2]) -> Proof:
  return Proof({
    gs: empty(uint256[2]),
    hs: empty(uint256[2]),
    scx: self.hash(card, card, card, card, empty(uint256[2]), empty(uint256[2]))})

@internal
@pure
def chaumPederson(cp: CP) -> bool:
  # unlike Chaum & Pederson we also include g and gx in the hash
  # so we are hashing the statement as well as the commitment
  # (see https://ia.cr/2016/771)
  c: uint256 = self.hash(cp.g, cp.h, cp.gx, cp.hx, cp.p.gs, cp.p.hs)
  gs_gxc: uint256[2] = ecadd(cp.p.gs, ecmul(cp.gx, c))
  hs_hxc: uint256[2] = ecadd(cp.p.hs, ecmul(cp.hx, c))
  g_scx: uint256[2] = ecmul(cp.g, cp.p.scx)
  h_scx: uint256[2] = ecmul(cp.h, cp.p.scx)
  return (gs_gxc[0] == g_scx[0] and gs_gxc[1] == g_scx[1] and
          hs_hxc[0] == h_scx[0] and hs_hxc[1] == h_scx[1])

@external
# returns index of first player that fails verification
# or number of players on success
# (deck state is undefined after failure)
def finishPrep(_id: uint256) -> uint256:
  numPlayers: uint256 = len(self.decks[_id].prep)
  for cardIdx in range(MAX_SIZE):
    if cardIdx == len(self.decks[_id].shuffle[0]):
      break
    assert (self.decks[_id].shuffle[0][cardIdx][0] == 0 and
            self.decks[_id].shuffle[0][cardIdx][1] == 0), "already finished"
    for playerIdx in range(MAX_PLAYERS):
      if playerIdx == numPlayers:
        break
      if self.chaumPederson(self.decks[_id].prep[playerIdx].cards[cardIdx]):
        self.decks[_id].shuffle[0][cardIdx] = ecadd(
          self.decks[_id].shuffle[0][cardIdx],
          self.decks[_id].prep[playerIdx].cards[cardIdx].hx)
      else:
        return playerIdx
    self.decks[_id].cards.append(empty(DrawCard))
  self.decks[_id].prep = empty(DynArray[DeckPrep, MAX_PLAYERS])
  return numPlayers

@external
@view
def shuffleCount(_id: uint256) -> uint256:
  return unsafe_sub(len(self.decks[_id].shuffle), 1)

@external
@view
def lastShuffle(_id: uint256) -> DynArray[uint256[2], 9000]:
  return self.decks[_id].shuffle[unsafe_sub(len(self.decks[_id].shuffle), 1)]

@external
def submitShuffle(_id: uint256, _playerIdx: uint256, _shuffle: DynArray[uint256[2], 9000]):
  assert self.decks[_id].addrs[_playerIdx] == msg.sender, "unauthorised"
  assert len(self.decks[_id].shuffle) == unsafe_add(_playerIdx, 1), "wrong player"
  assert len(self.decks[_id].shuffle[0]) == len(_shuffle), "wrong length"
  self.decks[_id].shuffle.append(_shuffle)
  self.decks[_id].challengeReq.append(0)
  self.decks[_id].challengeRes.append([])

@external
def challenge(_id: uint256, _playerIdx: uint256, _rounds: uint256):
  assert _playerIdx + 1 < len(self.decks[_id].shuffle), "not submitted"
  assert self.decks[_id].challengeReq[_playerIdx] == 0, "ongoing challenge"
  assert 0 < _rounds and _rounds <= MAX_SECURITY, "invalid rounds"
  self.decks[_id].challengeReq[_playerIdx] = _rounds

@external
@view
def challengeActive(_id: uint256, _playerIdx: uint256) -> bool:
  return self.decks[_id].challengeReq[_playerIdx] != 0

@external
def respondChallenge(_id: uint256, _playerIdx: uint256,
                     _data: DynArray[DynArray[uint256[2], 9000], 256]) -> uint256:
  assert self.decks[_id].challengeReq[_playerIdx] != 0, "no challenge"
  assert self.decks[_id].addrs[_playerIdx] == msg.sender, "unauthorised"
  assert self.decks[_id].challengeReq[_playerIdx] == len(_data), "wrong length"
  assert len(self.decks[_id].challengeRes[_playerIdx]) == 0, "already responded"
  self.decks[_id].challengeRes[_playerIdx] = _data
  self.decks[_id].challengeRnd = block.prevrandao
  return block.prevrandao

@external
def defuseChallenge(_id: uint256, _playerIdx: uint256,
                    _scalars: DynArray[uint256, 256],
                    _permutations: DynArray[DynArray[uint256, 9000], 256]):
  assert self.decks[_id].challengeReq[_playerIdx] != 0, "no challenge"
  assert self.decks[_id].addrs[_playerIdx] == msg.sender, "unauthorised"
  assert len(self.decks[_id].challengeRes[_playerIdx]) == len(_scalars), "no response"
  assert len(_scalars) == len(_permutations), "length mismatch"
  bits: uint256 = self.decks[_id].challengeRnd
  for k in range(MAX_SECURITY):
    if k == len(_scalars):
      break
    assert len(_permutations[k]) == len(self.decks[_id].shuffle[0]), "invalid permutation"
    j: uint256 = _playerIdx
    if not convert(bits & 1, bool):
      j = unsafe_add(j, 1)
    for i in range(MAX_SIZE):
      if i == len(self.decks[_id].shuffle[0]):
        break
      c: uint256[2] = self.decks[_id].challengeRes[_playerIdx][k][i]
      d: uint256[2] = ecmul(self.decks[_id].shuffle[j][_permutations[k][i]], _scalars[k])
      assert (c[0] == d[0] and c[1] == d[1]), "verification failed"
    bits = shift(bits, -1)
  self.decks[_id].challengeReq[_playerIdx] = 0
  self.decks[_id].challengeRes[_playerIdx] = empty(
    DynArray[DynArray[uint256[2], MAX_SIZE], MAX_SECURITY])

@external
def drawCard(_id: uint256, _playerIdx: uint256, _cardIdx: uint256):
  assert self.decks[_id].dealer == msg.sender, "unauthorised"
  assert self.decks[_id].cards[_cardIdx].drawnTo == 0, "already drawn"
  self.decks[_id].cards[_cardIdx].drawnTo = unsafe_add(_playerIdx, 1)
  self.decks[_id].cards[_cardIdx].c.append(
    self.decks[_id].shuffle[len(self.decks[_id].addrs)][unsafe_add(_cardIdx, 1)])

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
def decryptCard(_id: uint256, _playerIdx: uint256, _cardIdx: uint256,
                _card: uint256[2], _proof: Proof):
  assert self.decks[_id].addrs[_playerIdx] == msg.sender, "unauthorised"
  assert self.decks[_id].cards[_cardIdx].drawnTo != 0, "not drawn"
  assert len(self.decks[_id].cards[_cardIdx].c) == unsafe_add(_playerIdx, 1), "out of turn"
  if _playerIdx == self.decks[_id].cards[_cardIdx].drawnTo:
    assert (_card[0] == self.decks[_id].cards[_cardIdx].c[_playerIdx][0] and
            _card[1] == self.decks[_id].cards[_cardIdx].c[_playerIdx][1]), "wrong card"
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

@external
@view
def openedCard(_id: uint256, _cardIdx: uint256) -> uint256:
  return self.decks[_id].cards[_cardIdx].opensAs

@external
def resetShuffle(_id: uint256):
  assert self.decks[_id].dealer == msg.sender, "unauthorised"
  self.decks[_id].shuffle = [self.decks[_id].shuffle[0]]
  self.decks[_id].challengeReq = empty(DynArray[uint256, MAX_PLAYERS])
  self.decks[_id].challengeRes = empty(
    DynArray[DynArray[DynArray[uint256[2], MAX_SIZE], MAX_SECURITY], MAX_PLAYERS])
  for cardIdx in range(MAX_SIZE):
    if cardIdx == len(self.decks[_id].shuffle[0]):
      break
    self.decks[_id].cards[cardIdx] = empty(DrawCard)
