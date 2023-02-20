# @version ^0.3.7
# no-limit hold'em sit-n-go tournament contract

# copied from Deck.vy because https://github.com/vyperlang/vyper/issues/2670
MAX_SIZE: constant(uint256) = 16384
MAX_SECURITY: constant(uint256) = 256

struct Proof:
  # signature to confirm log_g(gx) = log_h(hx)
  # s is a random secret scalar
  gs:  uint256[2] # g ** s
  hs:  uint256[2] # h ** s
  scx: uint256 # s + cx (mod q), where c = hash(g, h, gx, hx, gs, hs)

struct DeckPrepCard:
  # g and h are random points, x is a random secret scalar
  g:   uint256[2]
  h:   uint256[2]
  gx:  uint256[2] # g ** x
  hx:  uint256[2] # h ** x
  p: Proof

struct DeckPrep:
  cards: DynArray[DeckPrepCard, MAX_SIZE]
# end of copy
import Deck as DeckManager

# TODO: add rake (rewards tabs for progress txns)?
# TODO: add penalties (instead of full abort on failure)?

MAX_SEATS:  constant(uint256) =   9 # maximum seats per table
MAX_LEVELS: constant(uint256) = 100 # maximum number of levels in tournament structure

nextPlayerId: public(uint256)
playerAddress: public(HashMap[uint256, address])
pendingPlayerAddress: public(HashMap[uint256, address])

@external
def register() -> uint256:
  playerId: uint256 = self.nextPlayerId
  self.playerAddress[playerId] = msg.sender
  self.nextPlayerId = unsafe_add(playerId, 1)
  return playerId

@external
def changePlayerAddress(_playerId: uint256, _newAddress: address):
  assert self.playerAddress[_playerId] == msg.sender, "unauthorised"
  assert _newAddress != empty(address), "empty address"
  self.pendingPlayerAddress[_playerId] = _newAddress

@external
def confirmChangePlayerAddress(_playerId: uint256):
  assert self.pendingPlayerAddress[_playerId] == msg.sender, "unauthorised"
  self.pendingPlayerAddress[_playerId] = empty(address)
  self.playerAddress[_playerId] = msg.sender

# the deck is represented by the numbers 1, ..., 52
# spades (01-13), clubs (14-26), diamonds (27-39), hearts (40-52)
PENDING_REVEAL: constant(uint256) = 53

@internal
@pure
def rank(card: uint256) -> uint256:
  return (card - 1) % 13

@internal
@pure
def suit(card: uint256) -> uint256:
  return (card - 1) / 13

# not using enum because arrays are not supported
Req_DECK: constant(uint256) = 0 # not drawn
Req_HAND: constant(uint256) = 1 # drawn to hand
Req_MUCK: constant(uint256) = 2 # may be revealed, not required
Req_SHOW: constant(uint256) = 3 # must be shown

struct Hand:
  dealer:      uint256            # seat index of current dealer
  deckIndex:   uint256            # index of next card in deck
  board:       uint256[5]         # board cards
  bet:         uint256[MAX_SEATS] # current round bet of each player
  live:        bool[MAX_SEATS]    # whether this player has a live hand
  betIndex:    uint256            # seat index of player who introduced the current bet
  actionIndex: uint256            # seat index of currently active player
  actionBlock: uint256            # block from which action was on the active player
  revealBlock: uint256            # block from which new revelations were required
  pot:         uint256            # pot for the hand (from previous rounds)

struct Config:
  buyIn:       uint256             # entry ticket price per player
  bond:        uint256             # liveness bond for each player
  startsWith:  uint256             # game can start when this many players are seated
  untilLeft:   uint256             # game ends when this many players are left
  structure:   uint256[MAX_LEVELS] # small blind levels (right-padded with blanks)
  levelBlocks: uint256             # blocks between levels
  verifRounds: uint256             # number of shuffle verifications required
  prepBlocks:  uint256             # blocks to submit deck preparation
  shuffBlocks: uint256             # blocks to submit shuffle
  verifBlocks: uint256             # blocks to submit shuffle verification
  revBlocks:   uint256             # blocks to meet a revelation requirement
  actBlocks:   uint256             # blocks to act before folding can be triggered

# not using Vyper enum because of this bug
# https://github.com/vyperlang/vyper/pull/3196/files#r1062141796
#enum Phase:
#  JOIN       # before the game has started, taking seats
#  PREP       # all players seated, preparing the deck
#  SHUFFLE    # submitting shuffles and verifications in order
#  DEAL       # drawing and possibly opening cards as currently required
#  PLAY       # betting; new card revelations may become required
Phase_JOIN:    constant(uint256) = 0
Phase_PREP:    constant(uint256) = 1
Phase_SHUFFLE: constant(uint256) = 2
Phase_DEAL:    constant(uint256) = 3
Phase_PLAY:    constant(uint256) = 4

nextTableId: public(uint256)

struct Table:
  tableId:     uint256
  config:      Config
  phase:       uint256
  startBlock:  uint256              # block number when game started
  seats:       uint256[MAX_SEATS]   # playerIds in seats as at the start of the game
  stacks:      uint256[MAX_SEATS]   # stack at each seat (zero for eliminated or all-in players)
  deck:        DeckManager          # deck contract
  deckId:      uint256              # id of deck in deck contract
  hand:        Hand                 # current Hand
  commitBlock: uint256                # block from which new commitments were required
  drawIndex:   uint256[26]            # player the card is drawn to
  requirement: uint256[26]            # revelation requirement level
  challIndex:  uint256                # index of a player being actively challenged
  challBlock:  uint256                # block when challenge was issued (or empty if no challenge)

tables: HashMap[uint256, Table]

@external
def __init__():
  self.nextPlayerId = 1
  self.nextTableId = 1

@external
@payable
def createTable(_playerId: uint256, _seatIndex: uint256, _config: Config, _deckAddr: address) -> uint256:
  assert self.playerAddress[_playerId] == msg.sender, "unauthorised"
  assert 1 < _config.startsWith, "invalid startsWith"
  assert _config.startsWith <= MAX_SEATS, "invalid startsWith"
  assert _config.untilLeft < _config.startsWith, "invalid untilLeft"
  assert 0 < _config.untilLeft, "invalid untilLeft"
  assert 0 < _config.structure[0], "invalid structure"
  assert 0 < _config.buyIn, "invalid buyIn"
  assert _seatIndex < _config.startsWith, "invalid seatIndex"
  assert msg.value == _config.bond + _config.buyIn, "incorrect bond + buyIn"
  tableId: uint256 = self.nextTableId
  self.tables[tableId].tableId = tableId
  self.tables[tableId].deck = DeckManager(_deckAddr)
  self.tables[tableId].deckId = self.tables[tableId].deck.newDeck(52, _config.startsWith)
  self.tables[tableId].phase = Phase_JOIN
  self.tables[tableId].config = _config
  self.tables[tableId].seats[_seatIndex] = _playerId
  self.tables[tableId].stacks[_seatIndex] = _config.buyIn
  self.nextTableId = unsafe_add(tableId, 1)
  return tableId

@external
@payable
def joinTable(_playerId: uint256, _tableId: uint256, _seatIndex: uint256):
  assert self.playerAddress[_playerId] == msg.sender, "unauthorised"
  assert self.tables[_tableId].tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].phase == Phase_JOIN, "wrong phase"
  assert _seatIndex < self.tables[_tableId].config.startsWith, "invalid seatIndex"
  assert self.tables[_tableId].seats[_seatIndex] == empty(uint256), "seatIndex unavailable"
  assert msg.value == self.tables[_tableId].config.bond + self.tables[_tableId].config.buyIn, "incorrect bond + buyIn"
  self.tables[_tableId].seats[_seatIndex] = _playerId
  self.tables[_tableId].stacks[_seatIndex] = self.tables[_tableId].config.buyIn

@external
def leaveTable(_tableId: uint256, _seatIndex: uint256):
  assert self.tables[_tableId].tableId == _tableId, "invalid tableId"
  assert self.playerAddress[self.tables[_tableId].seats[_seatIndex]] == msg.sender, "unauthorised"
  assert self.tables[_tableId].phase == Phase_JOIN, "wrong phase"
  self.tables[_tableId].seats[_seatIndex] = empty(uint256)
  self.tables[_tableId].stacks[_seatIndex] = empty(uint256)
  send(msg.sender, self.tables[_tableId].config.bond + self.tables[_tableId].config.buyIn)

@external
def startGame(_tableId: uint256):
  assert self.tables[_tableId].tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].phase == Phase_JOIN, "wrong phase"
  for seatIndex in range(MAX_SEATS):
    if seatIndex == self.tables[_tableId].config.startsWith:
      break
    assert self.tables[_tableId].seats[seatIndex] != empty(uint256), "not enough players"
  self.tables[_tableId].phase = Phase_PREP
  self.tables[_tableId].commitBlock = block.number

@external
def prepareDeck(_tableId: uint256, _seatIndex: uint256, _deckPrep: DeckPrep):
  assert self.tables[_tableId].tableId == _tableId, "invalid tableId"
  assert self.playerAddress[self.tables[_tableId].seats[_seatIndex]] == msg.sender, "unauthorised"
  assert self.tables[_tableId].phase == Phase_PREP, "wrong phase"
  self.tables[_tableId].deck.submitPrep(self.tables[_tableId].deckId, _seatIndex, _deckPrep)

@external
def finishDeckPrep(_tableId: uint256):
  assert self.tables[_tableId].tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].phase == Phase_PREP, "wrong phase"
  failIndex: uint256 = self.tables[_tableId].deck.finishPrep(self.tables[_tableId].deckId)
  if failIndex == self.tables[_tableId].config.startsWith:
    for cardIndex in range(MAX_SEATS):
      if cardIndex == failIndex: break
      self.tables[_tableId].drawIndex[cardIndex] = cardIndex
      self.tables[_tableId].requirement[cardIndex] = Req_SHOW
    self.tables[_tableId].phase = Phase_SHUFFLE
    self.tables[_tableId].commitBlock = block.number
  else:
    self.tables[_tableId].challIndex = failIndex
    self.failChallenge(_tableId)

@external
def submitShuffle(_tableId: uint256, _seatIndex: uint256,
                  _shuffle: DynArray[uint256[2], MAX_SIZE],
                  _commitment: DynArray[DynArray[uint256[2], MAX_SIZE], MAX_SECURITY]) -> uint256:
  assert self.tables[_tableId].tableId == _tableId, "invalid tableId"
  assert self.playerAddress[self.tables[_tableId].seats[_seatIndex]] == msg.sender, "unauthorised"
  assert self.tables[_tableId].phase == Phase_SHUFFLE, "wrong phase"
  self.tables[_tableId].deck.submitShuffle(self.tables[_tableId].deckId, _seatIndex, _shuffle)
  self.tables[_tableId].deck.challenge(
    self.tables[_tableId].deckId, _seatIndex, self.tables[_tableId].config.verifRounds)
  self.tables[_tableId].deck.respondChallenge(
    self.tables[_tableId].deckId, _seatIndex, _commitment)
  self.tables[_tableId].commitBlock = block.number
  return self.tables[_tableId].deck.challengeRnd(
    self.tables[_tableId].deckId, _seatIndex)

@external
def submitVerif(_tableId: uint256, _seatIndex: uint256,
                _scalars: DynArray[uint256, MAX_SECURITY],
                _permutations: DynArray[DynArray[uint256, MAX_SIZE], MAX_SECURITY]):
  assert self.tables[_tableId].tableId == _tableId, "invalid tableId"
  assert self.playerAddress[self.tables[_tableId].seats[_seatIndex]] == msg.sender, "unauthorised"
  assert self.tables[_tableId].phase == Phase_SHUFFLE, "wrong phase"
  self.tables[_tableId].deck.defuseChallenge(
    self.tables[_tableId].deckId, _seatIndex, _scalars, _permutations)
  self.tables[_tableId].commitBlock = block.number

@external
def finishShuffle(_tableId: uint256):
  assert self.tables[_tableId].tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].phase == Phase_SHUFFLE, "wrong phase"
  assert self.tables[_tableId].deck.shuffleCount(
           self.tables[_tableId].deckId) == unsafe_add(
             1, self.tables[_tableId].config.startsWith), "not enough shuffles"
  for cardIndex in range(26):
    if self.tables[_tableId].requirement[cardIndex] != Req_DECK:
      self.tables[_tableId].deck.drawCard(
        self.tables[_tableId].deckId,
        self.tables[_tableId].drawIndex[cardIndex],
        cardIndex)
  self.tables[_tableId].phase = Phase_DEAL
  self.tables[_tableId].commitBlock = block.number

@internal
def failChallenge(_tableId: uint256):
  challIndex: uint256 = self.tables[_tableId].challIndex
  perPlayer: uint256 = self.tables[_tableId].config.bond + self.tables[_tableId].config.buyIn
  # burn the offender's bond + buyIn
  send(empty(address), perPlayer)
  self.tables[_tableId].seats[challIndex] = empty(uint256)
  # refund the others' bonds and buyIns
  for playerId in self.tables[_tableId].seats:
    if playerId != empty(uint256):
      send(self.playerAddress[playerId], perPlayer)
  # delete the game
  self.tables[_tableId] = empty(Table)

@external
def prepareTimeout(_tableId: uint256, _seatIndex: uint256):
  assert self.tables[_tableId].tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].phase == Phase_PREP, "wrong phase"
  assert block.number > (self.tables[_tableId].commitBlock +
                         self.tables[_tableId].config.prepBlocks), "deadline not passed"
  assert not self.tables[_tableId].deck.hasSubmittedPrep(
    self.tables[_tableId].deckId, _seatIndex), "already submitted"
  self.tables[_tableId].challIndex = _seatIndex
  self.failChallenge(_tableId)

@external
def shuffleTimeout(_tableId: uint256, _seatIndex: uint256):
  assert self.tables[_tableId].tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].phase == Phase_SHUFFLE, "wrong phase"
  assert block.number > (self.tables[_tableId].commitBlock +
                         self.tables[_tableId].config.shuffBlocks), "deadline not passed"
  assert self.tables[_tableId].deck.shuffleCount(
           self.tables[_tableId].deckId) == _seatIndex, "wrong player"
  self.tables[_tableId].challIndex = _seatIndex
  self.failChallenge(_tableId)

@external
def verificationTimeout(_tableId: uint256, _seatIndex: uint256):
  assert self.tables[_tableId].tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].phase == Phase_SHUFFLE, "wrong phase"
  assert block.number > (self.tables[_tableId].commitBlock +
                         self.tables[_tableId].config.verifBlocks), "deadline not passed"
  assert self.tables[_tableId].deck.shuffleCount(
           self.tables[_tableId].deckId) == unsafe_add(1, _seatIndex), "wrong player"
  assert not self.tables[_tableId].deck.challengeActive(
    self.tables[_tableId].deckId, _seatIndex), "already verified"
  self.tables[_tableId].challIndex = _seatIndex
  self.failChallenge(_tableId)

#@internal
#@view
#def nextPlayer(_tableId: uint256, _seatIndex: uint256) -> uint256:
#  nextIndex: uint256 = _seatIndex
#  for _ in range(MAX_SEATS):
#    if nextIndex == self.tables[_tableId].config.startsWith:
#      nextIndex = 0
#    else:
#      nextIndex += 1
#    if (self.tables[_tableId].stacks[nextIndex] == empty(uint256) and
#        not self.tables[_tableId].hand.live[nextIndex]):
#      # TODO: decide if this function lands on all-in players or not
#      continue
#    else:
#      return nextIndex
#  raise "no live players"
#
#@internal
#@view
#def smallBlind(_tableId: uint256) -> uint256:
#  level: uint256 = empty(uint256)
#  if (self.tables[_tableId].startBlock +
#      MAX_LEVELS * self.tables[_tableId].config.levelBlocks <
#      block.number):
#    level = ((block.number - self.tables[_tableId].startBlock) /
#             self.tables[_tableId].config.levelBlocks)
#  else:
#    level = MAX_LEVELS - 1
#  for _ in range(MAX_LEVELS):
#    if self.tables[_tableId].config.structure[level] == empty(uint256):
#      level -= 1
#    else:
#      break
#  return self.tables[_tableId].config.structure[level]
#
#@internal
#def placeBet(_tableId: uint256, _seatIndex: uint256, _size: uint256):
#  amount: uint256 = min(_size, self.tables[_tableId].stacks[_seatIndex])
#  self.tables[_tableId].stacks[_seatIndex] -= amount
#  self.tables[_tableId].hand.bet[_seatIndex] += amount
#
#@external
#def commit(_tableId: uint256, _seatIndex: uint256, _hashed_commitment: bytes32):
#  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
#  assert self.playerAddress[self.tables[_tableId].seats[_seatIndex]] == msg.sender, "unauthorised"
#  assert self.tables[_tableId].phase == Phase_COMMIT, "wrong phase"
#  assert self.tables[_tableId].commitments[_seatIndex] == empty(bytes32), "already committed"
#  self.tables[_tableId].commitments[_seatIndex] = _hashed_commitment
#
#@external
#def revealCard(_tableId: uint256, _seatIndex: uint256, _cardIndex: uint256, _reveal: uint256):
#  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
#  assert self.playerAddress[self.tables[_tableId].seats[_seatIndex]] == msg.sender, "unauthorised"
#  assert self.tables[_tableId].phase == Phase_PLAY, "wrong phase"
#  assert _reveal != empty(uint256), "invalid reveal"
#  assert _reveal <= 52, "invalid reveal"
#  assert _cardIndex < 26, "invalid cardIndex"
#  assert self.tables[_tableId].revRequired[_seatIndex][_cardIndex] != Req_HIDE, "reveal not allowed"
#  assert self.tables[_tableId].revelations[_seatIndex][_cardIndex] == empty(uint256), "already revealed"
#  # TODO: the next two are unnecessary given the phase
#  # assert self.tables[_tableId].openCommits[_seatIndex] == empty(bytes32), "previous commitment open"
#  # assert self.tables[_tableId].commitments[_seatIndex] != empty(bytes32), "not committed"
#  self.tables[_tableId].revelations[_seatIndex][_cardIndex] = _reveal
#
#@internal
#@view
#def checkRevelations(_tableId: uint256) -> bool:
#  for seatIndex in range(MAX_SEATS):
#    if seatIndex == self.tables[_tableId].config.startsWith:
#      break
#    if (self.tables[_tableId].stacks[seatIndex] == empty(uint256) and
#        not self.tables[_tableId].hand.live[seatIndex]):
#      continue
#    for cardIndex in range(26):
#      if (self.tables[_tableId].revRequired[seatIndex][cardIndex] == Req_MUST_SHOW and
#          self.tables[_tableId].revelations[seatIndex][cardIndex] == empty(uint256)):
#        return False
#  return True
#
#@internal
#@view
#def revealedCard(_tableId: uint256, _cardIndex: uint256) -> uint256:
#  cardIndex: uint256 = _cardIndex
#  seatIndex: uint256 = 0
#  for stack in self.tables[_tableId].stacks:
#    if stack != empty(uint256) or self.tables[_tableId].hand.live[seatIndex]:
#      cardIndex = self.tables[_tableId].revelations[seatIndex][cardIndex] - 1
#    seatIndex += 1
#  return cardIndex + 1
#
#@internal
#@view
#def checkProof(_tableId: uint256) -> bool:
#  challIndex: uint256 = self.tables[_tableId].challIndex
#  if (sha256(self.tables[_tableId].proofs[challIndex].proof) !=
#      self.tables[_tableId].openCommits[challIndex]):
#    return False
#  used: uint256 = 2**52 - 1
#  for i in range(52):
#    card: uint256 = convert(slice(self.tables[_tableId].proofs[challIndex].proof, i, 1), uint256)
#    if (i < 26 and
#        self.tables[_tableId].revelations[challIndex][i] != empty(uint256) and
#        self.tables[_tableId].revelations[challIndex][i] != card):
#      return False
#    used &= ~shift(1, convert(card - 1, int128))
#  return used == 0

#@internal
#def verifyChallenge(_tableId: uint256):
#  if self.checkProof(_tableId):
#    self.tables[_tableId].openCommits[self.tables[_tableId].challIndex] = empty(bytes32)
#    self.tables[_tableId].challBlock = empty(uint256)
#  else:
#    self.failChallenge(_tableId)
#
#@external
#def prove(_tableId: uint256, _seatIndex: uint256, _proof: Bytes[52]):
#  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
#  assert self.playerAddress[self.tables[_tableId].seats[_seatIndex]] == msg.sender, "unauthorised"
#  assert self.tables[_tableId].phase == Phase_COMMIT, "wrong phase"
#  assert self.tables[_tableId].proofs[_seatIndex].proof == empty(Bytes[52]), "already provided"
#  self.tables[_tableId].proofs[_seatIndex] = Proof({proof: _proof})
#  if self.tables[_tableId].challIndex == _seatIndex:
#    self.verifyChallenge(_tableId)
#
#@external
#def challenge(_tableId: uint256, _seatIndex: uint256):
#  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
#  assert self.tables[_tableId].phase == Phase_COMMIT, "wrong phase"
#  assert _seatIndex < self.tables[_tableId].config.startsWith, "invalid seatIndex"
#  assert self.tables[_tableId].openCommits[_seatIndex] != empty(bytes32), "no open commitment"
#  assert self.tables[_tableId].challBlock == empty(uint256), "ongoing challenge"
#  self.tables[_tableId].challBlock = block.number
#  self.tables[_tableId].challIndex = _seatIndex
#  if self.tables[_tableId].proofs[_seatIndex].proof != empty(Bytes[52]):
#    self.verifyChallenge(_tableId)

#@external
#def commitTimeout(_tableId: uint256, _seatIndex: uint256):
#  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
#  assert self.tables[_tableId].phase == Phase_COMMIT, "wrong phase"
#  assert self.tables[_tableId].commitBlock != empty(uint256), "commitments not required"
#  assert block.number > (self.tables[_tableId].commitBlock +
#                         self.tables[_tableId].config.dealBlocks), "deadline not passed"
#  assert self.tables[_tableId].stacks[_seatIndex] != empty(uint256), "already eliminated"
#  assert self.tables[_tableId].commitments[_seatIndex] == empty(bytes32), "already committed"
#  self.tables[_tableId].challIndex = _seatIndex
#  self.failChallenge(_tableId)
#
#@external
#def challengeTimeout(_tableId: uint256):
#  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
#  assert self.tables[_tableId].phase == Phase_COMMIT, "wrong phase"
#  assert self.tables[_tableId].challBlock != empty(uint256), "no ongoing challenge"
#  assert block.number > (self.tables[_tableId].challBlock +
#                         self.tables[_tableId].config.proveBlocks), "deadline not passed"
#  self.failChallenge(_tableId)
#
#@external
#def revealTimeout(_tableId: uint256, _seatIndex: uint256, _cardIndex: uint256):
#  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
#  assert self.tables[_tableId].phase == Phase_PLAY, "wrong phase"
#  assert self.tables[_tableId].revRequired[_seatIndex][_cardIndex] != Req_HIDE, "reveal not required"
#  # assert self.tables[_tableId].hand.revealBlock != empty(uint256), "no ongoing revelations" # TODO: unnecessary?
#  assert block.number > (self.tables[_tableId].hand.revealBlock +
#                         self.tables[_tableId].config.revBlocks), "deadline not passed"
#  assert self.tables[_tableId].revelations[_seatIndex][_cardIndex] == empty(uint256), "already revealed"
#  self.tables[_tableId].challIndex = _seatIndex
#  self.failChallenge(_tableId)
#
#@external
#def endChallengePeriod(_tableId: uint256):
#  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
#  assert self.tables[_tableId].phase == Phase_COMMIT, "wrong phase"
#  assert self.tables[_tableId].challBlock == empty(uint256), "ongoing challenge"
#  for seatIndex in range(MAX_SEATS):
#    if seatIndex == self.tables[_tableId].config.startsWith:
#      break
#    if self.tables[_tableId].stacks[seatIndex] == empty(uint256):
#      continue
#    assert self.tables[_tableId].commitments[seatIndex] != empty(bytes32), "missing commitment"
#  self.tables[_tableId].openCommits = empty(bytes32[MAX_SEATS])
#  self.tables[_tableId].revRequired = empty(uint256[26][MAX_SEATS])
#  self.tables[_tableId].revelations = empty(uint256[26][MAX_SEATS])
#  self.tables[_tableId].commitBlock = empty(uint256)
#  self.tables[_tableId].phase = Phase_PLAY
#
#@external
#def selectDealer(_tableId: uint256):
#  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
#  assert self.tables[_tableId].phase == Phase_PLAY, "wrong phase"
#  assert self.tables[_tableId].startBlock == empty(uint256), "already started"
#  highestCard: uint256 = empty(uint256)
#  highestCardSeatIndex: uint256 = empty(uint256)
#  seatIndex: uint256 = 0
#  for playerId in self.tables[_tableId].seats:
#    card: uint256 = self.revealedCard(_tableId, seatIndex)
#    rankCard: uint256 = self.rank(card)
#    rankHighestCard: uint256 = self.rank(highestCard)
#    if highestCard == empty(uint256) or rankHighestCard < rankCard or (
#         rankHighestCard == rankCard and self.suit(highestCard) < self.suit(card)):
#      highestCard = card
#      highestCardSeatIndex = seatIndex
#    self.tables[_tableId].openCommits[seatIndex] = self.tables[_tableId].commitments[seatIndex]
#    seatIndex += 1
#  self.tables[_tableId].commitments = empty(bytes32[MAX_SEATS])
#  self.tables[_tableId].hand.dealer = highestCardSeatIndex
#  self.tables[_tableId].startBlock = block.number
#  self.tables[_tableId].phase = Phase_COMMIT
#
#@external
#def dealHoleCards(_tableId: uint256):
#  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
#  assert self.tables[_tableId].phase == Phase_PLAY, "wrong phase"
#  assert self.tables[_tableId].startBlock != empty(uint256), "not started"
#  self.tables[_tableId].hand.live = empty(bool[MAX_SEATS])
#  self.tables[_tableId].hand.bet = empty(uint256[MAX_SEATS]) # TODO: unnecessary?
#  self.tables[_tableId].hand.pot = empty(uint256)
#  self.tables[_tableId].hand.deckIndex = 0
#  seatIndex: uint256 = self.tables[_tableId].hand.dealer
#  for __ in range(2):
#    for _ in range(MAX_SEATS):
#      seatIndex = self.nextPlayer(_tableId, seatIndex)
#      for otherIndex in range(MAX_SEATS):
#        if otherIndex == self.tables[_tableId].config.startsWith:
#          break
#        if self.tables[_tableId].seats[otherIndex] != empty(uint256) and otherIndex != seatIndex:
#          self.tables[_tableId].revRequired[otherIndex][self.tables[_tableId].hand.deckIndex] = Req_MUST_SHOW
#      self.tables[_tableId].hand.live[seatIndex] = True
#      self.tables[_tableId].hand.deckIndex += 1
#      if seatIndex == self.tables[_tableId].hand.dealer:
#        break
#  self.tables[_tableId].hand.revealBlock = block.number
#  self.tables[_tableId].hand.actionBlock = empty(uint256)
#
#@external
#def postBlinds(_tableId: uint256):
#  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
#  assert self.tables[_tableId].phase == Phase_PLAY, "wrong phase"
#  assert self.tables[_tableId].startBlock != empty(uint256), "not started"
#  assert self.tables[_tableId].hand.board[0] == empty(uint256), "board not empty"
#  assert self.tables[_tableId].hand.actionBlock == empty(uint256), "already betting"
#  assert self.checkRevelations(_tableId), "required revelations missing"
#  seatIndex: uint256 = self.nextPlayer(_tableId, self.tables[_tableId].hand.dealer)
#  smallBlind: uint256 = self.smallBlind(_tableId)
#  self.placeBet(_tableId, seatIndex, smallBlind)
#  seatIndex = self.nextPlayer(_tableId, seatIndex)
#  self.placeBet(_tableId, seatIndex, smallBlind + smallBlind)
#  seatIndex = self.nextPlayer(_tableId, seatIndex)
#  self.tables[_tableId].hand.revealBlock = empty(uint256)
#  self.tables[_tableId].hand.actionIndex = seatIndex
#  self.tables[_tableId].hand.betIndex = seatIndex
#  self.tables[_tableId].hand.actionBlock = block.number
#
#@external
#def startRound(_tableId: uint256):
#  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
#  assert self.tables[_tableId].phase == Phase_PLAY, "wrong phase"
#  assert self.tables[_tableId].startBlock != empty(uint256), "not started" # TODO: unnecessary?
#  assert self.tables[_tableId].hand.board[2] != empty(uint256), "board empty"
#  assert self.tables[_tableId].hand.actionBlock == empty(uint256), "already betting"
#  assert self.checkRevelations(_tableId), "required revelations missing"
#  # fill the board with the revealedCards
#  boardIndex: uint256 = 5
#  cardIndex: uint256 = self.tables[_tableId].hand.deckIndex
#  for _ in range(5):
#    boardIndex -= 1
#    if self.tables[_tableId].hand.board[boardIndex] == empty(uint256):
#      continue
#    elif self.tables[_tableId].hand.board[boardIndex] == PENDING_REVEAL:
#      cardIndex -= 1
#      self.tables[_tableId].hand.board[boardIndex] = self.revealedCard(_tableId, cardIndex)
#    else:
#      break
#  self.tables[_tableId].hand.revealBlock = empty(uint256)
#  self.tables[_tableId].hand.actionIndex = self.nextPlayer(_tableId, self.tables[_tableId].hand.dealer)
#  self.tables[_tableId].hand.betIndex = self.tables[_tableId].hand.actionIndex
#  self.tables[_tableId].hand.actionBlock = block.number
#
#@internal
#def foldNext(_tableId: uint256, _seatIndex: uint256):
#  self.tables[_tableId].hand.live[_seatIndex] = False
#  self.tables[_tableId].hand.actionIndex = self.nextPlayer(_tableId, _seatIndex)
#  if self.tables[_tableId].hand.actionIndex == self.nextPlayer(_tableId, self.tables[_tableId].hand.actionIndex):
#    # actionIndex wins the round as last player standing
#    # give the winner the pot
#    self.tables[_tableId].stacks[self.tables[_tableId].hand.actionIndex] += self.tables[_tableId].hand.pot
#    self.tables[_tableId].hand.pot = 0
#    # (eliminate any all-in players -- impossible as only winner left standing)
#    # (check if untilLeft is reached -- impossible as nobody was eliminated)
#    # progress the dealer
#    for seatIndex in range(MAX_SEATS):
#      if seatIndex == self.tables[_tableId].config.startsWith:
#        break
#      self.tables[_tableId].hand.live[seatIndex] = self.tables[_tableId].stacks[seatIndex] > 0
#    self.tables[_tableId].hand.dealer = self.nextPlayer(_tableId, self.tables[_tableId].hand.dealer)
#    # reshuffle: enter commit phase for next hand
#    self.tables[_tableId].openCommits = self.tables[_tableId].commitments
#    self.tables[_tableId].commitments = empty(bytes32[MAX_SEATS])
#    self.tables[_tableId].commitBlock = block.number
#    self.tables[_tableId].phase = Phase_COMMIT
#  else:
#    self.tables[_tableId].hand.actionBlock = block.number
#
#@internal
#def actNext(_tableId: uint256, _seatIndex: uint256):
#  self.tables[_tableId].hand.actionIndex = self.nextPlayer(_tableId, _seatIndex)
#  self.tables[_tableId].hand.actionBlock = block.number
#  # check if the round is complete
#  if self.tables[_tableId].hand.actionIndex == self.tables[_tableId].hand.betIndex:
#    # collect pot
#    for seatIndex in range(MAX_SEATS):
#      if seatIndex == self.tables[_tableId].config.startsWith:
#        break
#      self.tables[_tableId].hand.pot += self.tables[_tableId].hand.bet[seatIndex]
#      self.tables[_tableId].hand.bet[seatIndex] = 0
#    # require revelations of next round's cards
#    if self.tables[_tableId].hand.board[0] == empty(uint256):
#      # deal flop
#      # burn card
#      self.tables[_tableId].hand.deckIndex += 1
#      # flop cards
#      for boardIndex in range(3):
#        for seatIndex in range(MAX_SEATS):
#          if seatIndex == self.tables[_tableId].config.startsWith:
#            break
#          self.tables[_tableId].revRequired[seatIndex][self.tables[_tableId].hand.deckIndex] = Req_MUST_SHOW
#        self.tables[_tableId].hand.deckIndex += 1
#        self.tables[_tableId].hand.board[boardIndex] = PENDING_REVEAL
#      self.tables[_tableId].hand.revealBlock = block.number
#      self.tables[_tableId].hand.actionBlock = empty(uint256)
#    elif self.tables[_tableId].hand.board[3] == empty(uint256):
#      # TODO: deal turn
#      pass
#    elif self.tables[_tableId].hand.board[4] == empty(uint256):
#      # TODO: deal river
#      pass
#    else:
#      # TODO: showdown
#      pass
#
#@external
#def fold(_tableId: uint256, _seatIndex: uint256):
#  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
#  assert self.playerAddress[self.tables[_tableId].seats[_seatIndex]] == msg.sender, "unauthorised"
#  assert self.tables[_tableId].phase == Phase_PLAY, "wrong phase"
#  assert self.tables[_tableId].startBlock != empty(uint256), "not started"
#  assert self.tables[_tableId].hand.actionBlock != empty(uint256), "not active"
#  assert self.tables[_tableId].hand.actionIndex == _seatIndex, "wrong turn"
#  self.foldNext(_tableId, _seatIndex)
#
#@external
#def actTimeout(_tableId: uint256):
#  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
#  assert self.tables[_tableId].phase == Phase_PLAY, "wrong phase"
#  assert self.tables[_tableId].startBlock != empty(uint256), "not started" # TODO: unnecessary?
#  assert self.tables[_tableId].hand.actionBlock != empty(uint256), "not active"
#  assert block.number > (self.tables[_tableId].hand.actionBlock +
#                         self.tables[_tableId].config.actBlocks), "deadline not passed"
#  self.foldNext(_tableId, self.tables[_tableId].hand.actionIndex)
#
#@external
#def check(_tableId: uint256, _seatIndex: uint256):
#  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
#  assert self.playerAddress[self.tables[_tableId].seats[_seatIndex]] == msg.sender, "unauthorised"
#  assert self.tables[_tableId].phase == Phase_PLAY, "wrong phase"
#  assert self.tables[_tableId].startBlock != empty(uint256), "not started" # TODO: unnecessary?
#  assert self.tables[_tableId].hand.actionBlock != empty(uint256), "not active"
#  assert self.tables[_tableId].hand.actionIndex == _seatIndex, "wrong turn"
#  assert self.tables[_tableId].hand.bet[self.tables[_tableId].hand.betIndex] == 0, "bet required"
#  self.actNext(_tableId, _seatIndex)
#
#@external
#def callBet(_tableId: uint256, _seatIndex: uint256):
#  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
#  assert self.playerAddress[self.tables[_tableId].seats[_seatIndex]] == msg.sender, "unauthorised"
#  assert self.tables[_tableId].phase == Phase_PLAY, "wrong phase"
#  assert self.tables[_tableId].startBlock != empty(uint256), "not started" # TODO: unnecessary?
#  assert self.tables[_tableId].hand.actionBlock != empty(uint256), "not active"
#  assert self.tables[_tableId].hand.actionIndex == _seatIndex, "wrong turn"
#  assert self.tables[_tableId].hand.bet[self.tables[_tableId].hand.betIndex] > 0, "no bet"
#  self.placeBet(_tableId, _seatIndex, self.tables[_tableId].hand.bet[self.tables[_tableId].hand.betIndex])
#  self.actNext(_tableId, _seatIndex)
