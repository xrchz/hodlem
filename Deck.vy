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
MAX_SIZE: constant(uint256) = 2 ** 64
MAX_PLAYERS: constant(uint256) = 2 ** 64

struct Point:
  point: uint256[2]

struct DeckPrepCard:
  # g and h are random points, x is a random secret scalar
  g:   Point
  gx:  Point # g ** x
  h:   Point
  hx:  Point # h ** x
  # signature to confirm log_g(gx) = log_h(hx)
  # s is a random secret scalar
  gs:  Point # g ** s
  hs:  Point # h ** s
  scx: uint256 # s + cx (mod q), where c = hash(h, hx, gs, hs)

struct DeckPrep:
  cards: DynArray[DeckPrepCard, MAX_SIZE]

struct Deck:
  # authorised address for each player
  addrs: DynArray[address, MAX_PLAYERS]
  # unencrypted cards
  cards: DynArray[Point, MAX_SIZE]
  # shuffled cards
  shuffle: DynArray[Point, MAX_SIZE]
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
  for i in range(MAX_SIZE + 1):
    self.decks[_id].cards.append(empty(Point))
    if i == _size:
      break

@external
def changeAddress(_id: uint256, _playerIdx: uint256, _newAddress: address):
  assert self.decks[_id].addrs[_playerIdx] == msg.sender, "unauthorised"
  self.decks[_id].addrs[_playerIdx] = _newAddress

@external
def submitPrep(_id: uint256, _playerIdx: uint256, _prep: DeckPrep):
  assert self.decks[_id].addrs[_playerIdx] == msg.sender, "unauthorised"
  assert len(self.decks[_id].prep[_playerIdx].cards) == 0, "already prepared"
  assert len(_prep.cards) == len(self.decks[_id].cards), "wrong length"
  for c in _prep.cards:
    assert (c.hx.point[0] != 0 or c.hx.point[1] != 0), "invalid point"
  self.decks[_id].prep[_playerIdx] = _prep

@internal
def checkPrep(_id: uint256, _playerIdx: uint256, _cardIdx: uint256) -> bool:
  c: uint256 = convert(sha256(concat(
      convert(self.decks[_id].prep[_playerIdx].cards[_cardIdx].h.point[0], bytes32),
      convert(self.decks[_id].prep[_playerIdx].cards[_cardIdx].h.point[1], bytes32),
      convert(self.decks[_id].prep[_playerIdx].cards[_cardIdx].hx.point[0], bytes32),
      convert(self.decks[_id].prep[_playerIdx].cards[_cardIdx].hx.point[1], bytes32),
      convert(self.decks[_id].prep[_playerIdx].cards[_cardIdx].gs.point[0], bytes32),
      convert(self.decks[_id].prep[_playerIdx].cards[_cardIdx].gs.point[1], bytes32),
      convert(self.decks[_id].prep[_playerIdx].cards[_cardIdx].hs.point[0], bytes32),
      convert(self.decks[_id].prep[_playerIdx].cards[_cardIdx].hs.point[1], bytes32))),
    uint256) % GROUP_ORDER
  gs_gxc: uint256[2] = ecadd(
    self.decks[_id].prep[_playerIdx].cards[_cardIdx].gs.point,
    ecmul(self.decks[_id].prep[_playerIdx].cards[_cardIdx].gx.point, c))
  hs_hxc: uint256[2] = ecadd(
    self.decks[_id].prep[_playerIdx].cards[_cardIdx].hs.point,
    ecmul(self.decks[_id].prep[_playerIdx].cards[_cardIdx].hx.point, c))
  g_scx: uint256[2] = ecmul(
    self.decks[_id].prep[_playerIdx].cards[_cardIdx].g.point,
    self.decks[_id].prep[_playerIdx].cards[_cardIdx].scx)
  h_scx: uint256[2] = ecmul(
    self.decks[_id].prep[_playerIdx].cards[_cardIdx].h.point,
    self.decks[_id].prep[_playerIdx].cards[_cardIdx].scx)
  return (gs_gxc[0] == g_scx[0] and
          gs_gxc[1] == g_scx[1] and
          hs_hxc[0] == h_scx[0] and
          hs_hxc[1] == h_scx[1])

@external
# returns index of first player that fails verification
# or number of players on success
def finishPrep(_id: uint256) -> uint256:
  assert (self.decks[_id].cards[0].point[0] == 0 and
          self.decks[_id].cards[0].point[1] == 0), "already finished"
  numPlayers: uint256 = len(self.decks[_id].prep)
  for cardIdx in range(MAX_SIZE):
    if cardIdx == len(self.decks[_id].cards):
      break
    for playerIdx in range(MAX_PLAYERS):
      if playerIdx == numPlayers:
        break
      if self.checkPrep(_id, playerIdx, cardIdx):
        self.decks[_id].cards[cardIdx].point = ecadd(
          self.decks[_id].cards[cardIdx].point,
          self.decks[_id].prep[playerIdx].cards[cardIdx].hx.point)
      else:
        return playerIdx
  for playerIdx in range(MAX_PLAYERS):
    if playerIdx == numPlayers:
      break
    self.decks[_id].prep.pop()
  return numPlayers
