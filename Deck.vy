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

GROUP_ORDER: constant(uint256) = 21888242871839275222246405745257275088696311157297823662689037894645226208583

# arbitrary (large) limits on deck size and number of players sharing a deck
# note: MAX_SIZE must be < GROUP_ORDER
MAX_SIZE: constant(uint256) = 2 ** 16
MAX_PLAYERS: constant(uint256) = 2 ** 16
MAX_SECURITY: constant(uint256) = 256

struct DeckPrepCard:
  # g and h are random points, x is a random secret scalar
  g:   uint256[2]
  gx:  uint256[2] # g ** x
  h:   uint256[2]
  hx:  uint256[2] # h ** x
  # signature to confirm log_g(gx) = log_h(hx)
  # s is a random secret scalar
  gs:  uint256[2] # g ** s
  hs:  uint256[2] # h ** s
  scx: uint256 # s + cx (mod q), where c = hash(h, hx, gs, hs)

struct DeckPrep:
  cards: DynArray[DeckPrepCard, MAX_SIZE]

struct Deck:
  # authorised address for each player
  addrs: DynArray[address, MAX_PLAYERS]
  # shuffle[0] is the unencrypted cards
  # shuffle[j+1] is the shuffled encrypted cards from player index j
  shuffle: DynArray[DynArray[uint256[2], MAX_SIZE], MAX_PLAYERS + 1]
  challengeReq: DynArray[uint256, MAX_PLAYERS]
  challengeRes: DynArray[DynArray[DynArray[uint256[2], MAX_SIZE], MAX_SECURITY], MAX_PLAYERS]
  challengeRnd: uint256
  # data for deck preparation
  prep: DynArray[DeckPrep, MAX_PLAYERS]

decks: HashMap[uint256, Deck]

@external
def newDeck(_id: uint256, _size: uint256, _players: uint256):
  assert 0 < _size, "invalid size"
  assert _size <= MAX_SIZE, "invalid size"
  assert 0 < _players, "invalid players"
  assert _players <= MAX_PLAYERS, "invalid players"
  assert len(self.decks[_id].addrs) == 0, "id in use"
  for i in range(MAX_PLAYERS):
    if i == _players:
      break
    self.decks[_id].addrs.append(msg.sender)
    self.decks[_id].prep.append(empty(DeckPrep))
  self.decks[_id].shuffle.append([])
  for i in range(MAX_SIZE + 1):
    self.decks[_id].shuffle[0].append(empty(uint256[2]))
    if i == _size:
      break

@external
def deleteDeck(_id: uint256):
  assert self.decks[_id].addrs[0] == msg.sender, "unauthorised"
  self.decks[_id] = empty(Deck)

@external
def changeAddress(_id: uint256, _playerIdx: uint256, _newAddress: address):
  assert self.decks[_id].addrs[_playerIdx] == msg.sender, "unauthorised"
  self.decks[_id].addrs[_playerIdx] = _newAddress

@external
def submitPrep(_id: uint256, _playerIdx: uint256, _prep: DeckPrep):
  assert self.decks[_id].addrs[_playerIdx] == msg.sender, "unauthorised"
  assert len(self.decks[_id].prep[_playerIdx].cards) == 0, "already prepared"
  assert len(_prep.cards) == len(self.decks[_id].shuffle[0]), "wrong length"
  for c in _prep.cards:
    assert (c.hx[0] != 0 or c.hx[1] != 0), "invalid point"
  self.decks[_id].prep[_playerIdx] = _prep

@internal
@view
def checkPrep(_id: uint256, _playerIdx: uint256, _cardIdx: uint256) -> bool:
  c: uint256 = convert(sha256(concat(
      # unlike Chaum & Pederson we also include g and gx in the hash
      # so we are hashing the statement as well as the commitment
      # (see https://ia.cr/2016/771)
      convert(self.decks[_id].prep[_playerIdx].cards[_cardIdx].g[0], bytes32),
      convert(self.decks[_id].prep[_playerIdx].cards[_cardIdx].g[1], bytes32),
      convert(self.decks[_id].prep[_playerIdx].cards[_cardIdx].gx[0], bytes32),
      convert(self.decks[_id].prep[_playerIdx].cards[_cardIdx].gx[1], bytes32),
      convert(self.decks[_id].prep[_playerIdx].cards[_cardIdx].h[0], bytes32),
      convert(self.decks[_id].prep[_playerIdx].cards[_cardIdx].h[1], bytes32),
      convert(self.decks[_id].prep[_playerIdx].cards[_cardIdx].hx[0], bytes32),
      convert(self.decks[_id].prep[_playerIdx].cards[_cardIdx].hx[1], bytes32),
      convert(self.decks[_id].prep[_playerIdx].cards[_cardIdx].gs[0], bytes32),
      convert(self.decks[_id].prep[_playerIdx].cards[_cardIdx].gs[1], bytes32),
      convert(self.decks[_id].prep[_playerIdx].cards[_cardIdx].hs[0], bytes32),
      convert(self.decks[_id].prep[_playerIdx].cards[_cardIdx].hs[1], bytes32))),
    uint256) % GROUP_ORDER
  gs_gxc: uint256[2] = ecadd(
    self.decks[_id].prep[_playerIdx].cards[_cardIdx].gs,
    ecmul(self.decks[_id].prep[_playerIdx].cards[_cardIdx].gx, c))
  hs_hxc: uint256[2] = ecadd(
    self.decks[_id].prep[_playerIdx].cards[_cardIdx].hs,
    ecmul(self.decks[_id].prep[_playerIdx].cards[_cardIdx].hx, c))
  g_scx: uint256[2] = ecmul(
    self.decks[_id].prep[_playerIdx].cards[_cardIdx].g,
    self.decks[_id].prep[_playerIdx].cards[_cardIdx].scx)
  h_scx: uint256[2] = ecmul(
    self.decks[_id].prep[_playerIdx].cards[_cardIdx].h,
    self.decks[_id].prep[_playerIdx].cards[_cardIdx].scx)
  return (gs_gxc[0] == g_scx[0] and
          gs_gxc[1] == g_scx[1] and
          hs_hxc[0] == h_scx[0] and
          hs_hxc[1] == h_scx[1])

@external
# returns index of first player that fails verification
# or number of players on success
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
      if self.checkPrep(_id, playerIdx, cardIdx):
        self.decks[_id].shuffle[0][cardIdx] = ecadd(
          self.decks[_id].shuffle[0][cardIdx],
          self.decks[_id].prep[playerIdx].cards[cardIdx].hx)
      else:
        return playerIdx
  self.decks[_id].prep = empty(DynArray[DeckPrep, MAX_PLAYERS])
  return numPlayers

@external
def submitShuffle(_id: uint256, _playerIdx: uint256, _shuffle: DynArray[uint256[2], MAX_SIZE]):
  assert self.decks[_id].addrs[_playerIdx] == msg.sender, "unauthorised"
  assert len(self.decks[_id].shuffle) == _playerIdx + 1, "wrong player"
  assert len(self.decks[_id].shuffle[0]) == len(_shuffle), "wrong length"
  self.decks[_id].shuffle.append(_shuffle)
  self.decks[_id].challengeReq.append(0)

@external
def challenge(_id: uint256, _playerIdx: uint256, _rounds: uint256):
  assert self.decks[_id].challengeReq[_playerIdx] == 0, "ongoing challenge"
  assert 0 < _rounds and _rounds <= MAX_SECURITY, "invalid rounds"
  self.decks[_id].challengeReq[_playerIdx] = _rounds

@external
@view
def challengeActive(_id: uint256, _playerIdx: uint256) -> bool:
  return self.decks[_id].challengeReq[_playerIdx] != 0

@external
def respondChallenge(_id: uint256, _playerIdx: uint256,
                     _data: DynArray[DynArray[uint256[2], MAX_SIZE], MAX_SECURITY]):
  assert self.decks[_id].challengeReq[_playerIdx] != 0, "no challenge"
  assert self.decks[_id].addrs[_playerIdx] == msg.sender, "unauthorised"
  assert self.decks[_id].challengeReq[_playerIdx] == len(_data), "wrong length"
  assert len(self.decks[_id].challengeRes[_playerIdx]) == 0, "already responded"
  self.decks[_id].challengeRes[_playerIdx] = _data
  self.decks[_id].challengeRnd = block.prevrandao

@external
def defuseChallenge(_id: uint256, _playerIdx: uint256,
                    _scalars: DynArray[uint256, MAX_SECURITY],
                    _permutations: DynArray[DynArray[uint256, MAX_SIZE], MAX_SECURITY]):
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
      j += 1
    for i in range(MAX_SIZE):
      if i == len(self.decks[_id].shuffle[0]):
        break
      c: uint256[2] = self.decks[_id].challengeRes[_playerIdx][k][i]
      d: uint256[2] = ecmul(self.decks[_id].shuffle[j][_permutations[k][i]], _scalars[k])
      assert (c[0] == d[0] and c[1] == d[1]), "verification failed"
    bits = shift(bits, -1)
  self.decks[_id].challengeReq[_playerIdx] = 0

@external
def revealCard(_id: uint256, _playerIdx: uint256, _cardIdx: uint256, _card: uint256[2]):
  pass # TODO
