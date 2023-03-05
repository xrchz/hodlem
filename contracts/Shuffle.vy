# @version ^0.3.7
# shuffling implementation

# copy of Deck.vy's storage variables, so delegatecall works
GROUP_ORDER: constant(uint256) = 21888242871839275222246405745257275088696311157297823662689037894645226208583

# arbitrary limits on deck size and number of players sharing a deck
# note: MAX_SIZE must be < GROUP_ORDER
# TODO: we inline these because of https://github.com/vyperlang/vyper/issues/3294
MAX_SIZE: constant(uint256) = 2000
MAX_PLAYERS: constant(uint256) = 1000 # to distinguish from MAX_SIZE when inlining
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
  cards: DynArray[CP, 2000]

struct DrawCard:
  # successive decryptions
  c: DynArray[uint256[2], 1000]
  # 1 + index of player the card is initially drawn to (i.e. they skip decryption)
  # note: a card can only be drawn to a single player
  drawnTo: uint256
  # 1 + original index after reveal
  opensAs: uint256

struct Deck:
  # authorised address for drawing cards and reshuffling
  dealer: address
  # authorised address for each player
  addrs: DynArray[address, 1000]
  # shuffle[0] is the unencrypted cards (including base card at index 0)
  # shuffle[j+1] is the shuffled encrypted cards from player index j
  shuffle: DynArray[DynArray[uint256[2], 2000], 1001] # 1000 + 1] <- another Vyper bug with importing
  challengeReq: DynArray[uint256, 1000]
  challengeRes: DynArray[DynArray[DynArray[uint256[2], 2000], 256], 1000]
  challengeRnd: uint256
  # for decrypting shuffled cards
  # note: cards[i] corresponds to shuffle[_][i+1]
  cards: DynArray[DrawCard, 2000]
  # data for deck preparation
  prep: DynArray[DeckPrep, 1000]

decks: HashMap[uint256, Deck]
nextId: uint256

@internal
@pure
def pointEq(a: uint256[2], b: uint256[2]) -> bool:
  return a[0] == b[0] and a[1] == b[1]
# end copy

@external
def reset(_id: uint256):
  assert self.decks[_id].dealer == msg.sender, "unauthorised"
  self.decks[_id].shuffle = [self.decks[_id].shuffle[0]]
  self.decks[_id].challengeReq = empty(DynArray[uint256, MAX_PLAYERS])
  self.decks[_id].challengeRes = empty(
    DynArray[DynArray[DynArray[uint256[2], MAX_SIZE], MAX_SECURITY], MAX_PLAYERS])
  for cardIdx in range(MAX_SIZE):
    if cardIdx == len(self.decks[_id].shuffle[0]):
      break
    self.decks[_id].cards[cardIdx] = empty(DrawCard)

@external
def submit(_id: uint256, _playerIdx: uint256, _shuffle: DynArray[uint256[2], 2000]):
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
def respond(_id: uint256, _playerIdx: uint256,
            _data: DynArray[DynArray[uint256[2], 2000], 256]):
  assert self.decks[_id].challengeReq[_playerIdx] != 0, "no challenge"
  assert self.decks[_id].addrs[_playerIdx] == msg.sender, "unauthorised"
  assert self.decks[_id].challengeReq[_playerIdx] == len(_data), "wrong length"
  assert len(self.decks[_id].challengeRes[_playerIdx]) == 0, "already responded"
  self.decks[_id].challengeRes[_playerIdx] = _data
  self.decks[_id].challengeRnd = block.prevrandao

@external
def defuse(_id: uint256, _playerIdx: uint256,
           _scalars: DynArray[uint256, 256],
           _permutations: DynArray[DynArray[uint256, 2000], 256]):
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
      assert self.pointEq(
        self.decks[_id].challengeRes[_playerIdx][k][i],
        ecmul(self.decks[_id].shuffle[j][_permutations[k][i]], _scalars[k])
      ), "verification failed"
    bits = shift(bits, -1)
  self.decks[_id].challengeReq[_playerIdx] = 0
  self.decks[_id].challengeRes[_playerIdx] = empty(
    DynArray[DynArray[uint256[2], MAX_SIZE], MAX_SECURITY])
