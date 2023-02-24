# @version ^0.3.8

# copied from Deck.vy because https://github.com/vyperlang/vyper/issues/2670
MAX_SIZE: constant(uint256) = 9000
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
# end of copy
import Deck as DeckManager

# player registry

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
  self.pendingPlayerAddress[_playerId] = _newAddress

@external
def confirmChangePlayerAddress(_playerId: uint256):
  assert self.pendingPlayerAddress[_playerId] == msg.sender, "unauthorised"
  self.pendingPlayerAddress[_playerId] = empty(address)
  self.playerAddress[_playerId] = msg.sender

MAX_SEATS:  constant(uint256) =   9 # maximum seats per table
MAX_LEVELS: constant(uint256) = 100 # maximum number of levels in tournament structure

Req_DECK: constant(uint256) = 0 # not drawn
Req_HAND: constant(uint256) = 1 # drawn to hand
Req_MUCK: constant(uint256) = 2 # may be revealed, not required
Req_SHOW: constant(uint256) = 3 # must be shown

# not using Vyper enum because of this bug
# https://github.com/vyperlang/vyper/pull/3196/files#r1062141796
Phase_JOIN:    constant(uint256) = 0 # before the game has started, taking seats
Phase_PREP:    constant(uint256) = 1 # all players seated, preparing the deck
Phase_SHUFFLE: constant(uint256) = 2 # submitting shuffles and verifications in order
Phase_DEAL:    constant(uint256) = 3 # drawing and possibly opening cards as currently required
Phase_PLAY:    constant(uint256) = 4 # betting; new card revelations may become required
Phase_SHOW:    constant(uint256) = 5 # showdown TODO

struct Config:
  gameAddress: address             # address of game manager
  buyIn:       uint256             # entry ticket price per player
  bond:        uint256             # liveness bond for each player
  startsWith:  uint256             # game can start when this many players are seated
  untilLeft:   uint256             # game ends when this many players are left
  structure:   uint256[100]        # small blind levels (right-padded with blanks)
  levelBlocks: uint256             # blocks between levels
  verifRounds: uint256             # number of shuffle verifications required
  prepBlocks:  uint256             # blocks to submit deck preparation
  shuffBlocks: uint256             # blocks to submit shuffle
  verifBlocks: uint256             # blocks to submit shuffle verification
  dealBlocks:  uint256             # blocks to submit card decryptions
  actBlocks:   uint256             # blocks to act before folding can be triggered

struct Table:
  tableId:     uint256
  config:      Config
  seats:       uint256[9]           # playerIds in seats as at the start of the game
  deck:        DeckManager          # deck contract
  deckId:      uint256              # id of deck in deck contract
  phase:       uint256
  present:     bool[9]              # whether each player contributes to the current shuffle
  gameId:      uint256              # id of game in game contract
  commitBlock: uint256              # block from which new commitments were required
  deckIndex:   uint256              # index of next card in deck
  drawIndex:   uint256[26]          # player the card is drawn to
  requirement: uint256[26]          # revelation requirement level

nextTableId: public(uint256)
tables: HashMap[uint256, Table]

@external
def __init__():
  self.nextPlayerId = 1
  self.nextTableId = 1

# lobby

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

@external
def leaveTable(_tableId: uint256, _seatIndex: uint256):
  assert self.tables[_tableId].tableId == _tableId, "invalid tableId"
  assert self.playerAddress[self.tables[_tableId].seats[_seatIndex]] == msg.sender, "unauthorised"
  assert self.tables[_tableId].phase == Phase_JOIN, "wrong phase"
  self.tables[_tableId].seats[_seatIndex] = empty(uint256)
  send(msg.sender, self.tables[_tableId].config.bond + self.tables[_tableId].config.buyIn)

@external
def startGame(_tableId: uint256):
  assert self.tables[_tableId].tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].phase == Phase_JOIN, "wrong phase"
  for seatIndex in range(MAX_SEATS):
    if seatIndex == self.tables[_tableId].config.startsWith:
      break
    assert self.tables[_tableId].seats[seatIndex] != empty(uint256), "not enough players"
    self.tables[_tableId].present[seatIndex] = True
  self.tables[_tableId].phase = Phase_PREP
  self.tables[_tableId].commitBlock = block.number

@external
def refundPlayer(_tableId: uint256, _seatIndex: uint256, _stack: uint256):
  assert self.tables[_tableId].config.gameAddress == msg.sender, "unauthorised"
  send(self.playerAddress[self.tables[_tableId].seats[_seatIndex]],
       unsafe_add(self.tables[_tableId].config.bond, _stack))

@external
def deleteTable(_tableId: uint256):
  assert self.tables[_tableId].config.gameAddress == msg.sender, "unauthorised"
  self.tables[_tableId] = empty(Table)

# timeouts

@external
def prepareTimeout(_tableId: uint256, _seatIndex: uint256):
  assert self.tables[_tableId].tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].phase == Phase_PREP, "wrong phase"
  assert block.number > (self.tables[_tableId].commitBlock +
                         self.tables[_tableId].config.prepBlocks), "deadline not passed"
  assert not self.tables[_tableId].deck.hasSubmittedPrep(
    self.tables[_tableId].deckId, _seatIndex), "already submitted"
  self.failChallenge(_tableId, _seatIndex)

@external
def shuffleTimeout(_tableId: uint256, _seatIndex: uint256):
  assert self.tables[_tableId].tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].phase == Phase_SHUFFLE, "wrong phase"
  assert block.number > (self.tables[_tableId].commitBlock +
                         self.tables[_tableId].config.shuffBlocks), "deadline not passed"
  assert self.tables[_tableId].deck.shuffleCount(
           self.tables[_tableId].deckId) == _seatIndex, "wrong player"
  self.failChallenge(_tableId, _seatIndex)

@external
def verificationTimeout(_tableId: uint256, _seatIndex: uint256):
  assert self.tables[_tableId].tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].phase == Phase_SHUFFLE, "wrong phase"
  assert block.number > (self.tables[_tableId].commitBlock +
                         self.tables[_tableId].config.verifBlocks), "deadline not passed"
  assert self.tables[_tableId].deck.shuffleCount(
           self.tables[_tableId].deckId) == _seatIndex, "wrong player"
  assert not self.tables[_tableId].deck.challengeActive(
    self.tables[_tableId].deckId, _seatIndex), "already verified"
  self.failChallenge(_tableId, _seatIndex)

@external
def decryptTimeout(_tableId: uint256, _seatIndex: uint256, _cardIndex: uint256):
  assert self.tables[_tableId].tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].phase == Phase_DEAL, "wrong phase"
  assert block.number > (self.tables[_tableId].commitBlock +
                         self.tables[_tableId].config.dealBlocks), "deadline not passed"
  assert self.tables[_tableId].requirement[_cardIndex] != Req_DECK, "not required"
  assert self.tables[_tableId].deck.decryptCount(
    self.tables[_tableId].deckId, _cardIndex) == _seatIndex, "already decrypted"
  self.failChallenge(_tableId, _seatIndex)

@external
def revealTimeout(_tableId: uint256, _seatIndex: uint256, _cardIndex: uint256):
  assert self.tables[_tableId].tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].phase == Phase_DEAL, "wrong phase"
  assert block.number > (self.tables[_tableId].commitBlock +
                         self.tables[_tableId].config.dealBlocks), "deadline not passed"
  assert self.tables[_tableId].drawIndex[_cardIndex] == _seatIndex, "wrong player"
  assert self.tables[_tableId].requirement[_cardIndex] == Req_SHOW, "not required"
  assert self.tables[_tableId].deck.openedCard(
    self.tables[_tableId].deckId, _cardIndex) == 0, "already opened"
  self.failChallenge(_tableId, _seatIndex)

@internal
def failChallenge(_tableId: uint256, _challIndex: uint256):
  perPlayer: uint256 = self.tables[_tableId].config.bond + self.tables[_tableId].config.buyIn
  # burn the offender's bond + buyIn
  send(empty(address), perPlayer)
  self.tables[_tableId].seats[_challIndex] = empty(uint256)
  # refund the others' bonds and buyIns
  for playerId in self.tables[_tableId].seats:
    if playerId != empty(uint256):
      send(self.playerAddress[playerId], perPlayer)
  # delete the game
  self.tables[_tableId] = empty(Table)

# deck setup

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
    self.failChallenge(_tableId, failIndex)

# shuffle

@external
def submitShuffle(_tableId: uint256, _seatIndex: uint256,
                  _shuffle: DynArray[uint256[2], 9000],
                  _commitment: DynArray[DynArray[uint256[2], 9000], 256]) -> uint256:
  assert self.tables[_tableId].tableId == _tableId, "invalid tableId"
  assert self.playerAddress[self.tables[_tableId].seats[_seatIndex]] == msg.sender, "unauthorised"
  assert self.tables[_tableId].phase == Phase_SHUFFLE, "wrong phase"
  self.tables[_tableId].deck.submitShuffle(self.tables[_tableId].deckId, _seatIndex, _shuffle)
  self.tables[_tableId].deck.challenge(
    self.tables[_tableId].deckId, _seatIndex, self.tables[_tableId].config.verifRounds)
  self.tables[_tableId].commitBlock = block.number
  return self.tables[_tableId].deck.respondChallenge(
    self.tables[_tableId].deckId, _seatIndex, _commitment)

@external
def submitVerif(_tableId: uint256, _seatIndex: uint256,
                _scalars: DynArray[uint256, 256],
                _permutations: DynArray[DynArray[uint256, 9000], 256]):
  assert self.tables[_tableId].tableId == _tableId, "invalid tableId"
  assert self.playerAddress[self.tables[_tableId].seats[_seatIndex]] == msg.sender, "unauthorised"
  assert self.tables[_tableId].phase == Phase_SHUFFLE, "wrong phase"
  self.tables[_tableId].deck.defuseChallenge(
    self.tables[_tableId].deckId, _seatIndex, _scalars, _permutations)
  self.autoShuffle(_tableId)

@internal
def autoShuffle(_tableId: uint256):
  seatIndex: uint256 = self.tables[_tableId].deck.shuffleCount(self.tables[_tableId].deckId)
  for _ in range(MAX_SEATS):
    if seatIndex == self.tables[_tableId].config.startsWith:
      self.finishShuffle(_tableId)
      break
    if not self.tables[_tableId].present[seatIndex]:
      # just copy the shuffle: use identity permutation and secret key = 1
      # do not challenge it; external challenges can just be ignored
      self.tables[_tableId].deck.submitShuffle(
        self.tables[_tableId].deckId, seatIndex,
        self.tables[_tableId].deck.lastShuffle(self.tables[_tableId].deckId))
      seatIndex = unsafe_add(seatIndex, 1)
    else:
      self.tables[_tableId].commitBlock = block.number
      break

@internal
def finishShuffle(_tableId: uint256):
  self.tables[_tableId].phase = Phase_DEAL
  for cardIndex in range(26):
    if self.tables[_tableId].requirement[cardIndex] != Req_DECK:
      self.tables[_tableId].deck.drawCard(
        self.tables[_tableId].deckId,
        self.tables[_tableId].drawIndex[cardIndex],
        cardIndex)
      self.autoDecrypt(_tableId, cardIndex)
  self.tables[_tableId].commitBlock = block.number

@external
def reshuffle(_tableId: uint256):
  assert self.tables[_tableId].config.gameAddress == msg.sender, "unauthorised"
  self.tables[_tableId].deck.resetShuffle(self.tables[_tableId].deckId)
  self.tables[_tableId].phase = Phase_SHUFFLE
  self.tables[_tableId].commitBlock = block.number

# deal

@internal
def autoDecrypt(_tableId: uint256, _cardIndex: uint256):
  seatIndex: uint256 = self.tables[_tableId].deck.decryptCount(
                         self.tables[_tableId].deckId, _cardIndex)
  for _ in range(MAX_SEATS):
    if seatIndex == self.tables[_tableId].config.startsWith:
      break
    if not self.tables[_tableId].present[seatIndex]:
      card: uint256[2] = self.tables[_tableId].deck.lastDecrypt(
                           self.tables[_tableId].deckId, _cardIndex)
      self.tables[_tableId].deck.decryptCard(
        self.tables[_tableId].deckId, seatIndex, _cardIndex, card,
        self.tables[_tableId].deck.emptyProof(card))
      seatIndex = unsafe_add(seatIndex, 1)
    else:
      break
  self.tables[_tableId].commitBlock = block.number

@external
def decryptCard(_tableId: uint256, _seatIndex: uint256, _cardIndex: uint256,
                _card: uint256[2], _proof: Proof):
  assert self.tables[_tableId].tableId == _tableId, "invalid tableId"
  assert self.playerAddress[self.tables[_tableId].seats[_seatIndex]] == msg.sender, "unauthorised"
  assert self.tables[_tableId].phase == Phase_DEAL, "wrong phase"
  assert self.tables[_tableId].requirement[_cardIndex] != Req_DECK, "decrypt not allowed"
  self.tables[_tableId].deck.decryptCard(
    self.tables[_tableId].deckId, _seatIndex, _cardIndex, _card, _proof)
  self.autoDecrypt(_tableId, _cardIndex)

@external
def revealCard(_tableId: uint256, _seatIndex: uint256, _cardIndex: uint256,
               _openIndex: uint256, _proof: Proof):
  assert self.tables[_tableId].tableId == _tableId, "invalid tableId"
  assert self.playerAddress[self.tables[_tableId].seats[_seatIndex]] == msg.sender, "unauthorised"
  assert self.tables[_tableId].phase == Phase_DEAL, "wrong phase"
  assert self.tables[_tableId].drawIndex[_cardIndex] == _seatIndex, "wrong player"
  assert self.tables[_tableId].requirement[_cardIndex] >= Req_MUCK, "decrypt not allowed"
  self.tables[_tableId].deck.openCard(
    self.tables[_tableId].deckId, _seatIndex, _cardIndex, _openIndex, _proof)

@internal
@view
def checkRevelations(_tableId: uint256) -> bool:
  for cardIndex in range(26):
    if (self.tables[_tableId].requirement[cardIndex] == Req_SHOW and
        self.tables[_tableId].deck.openedCard(
          self.tables[_tableId].deckId, cardIndex) == 0):
      return False
    if (self.tables[_tableId].requirement[cardIndex] != Req_DECK and
        self.tables[_tableId].deck.decryptCount(self.tables[_tableId].deckId, cardIndex) <=
        self.tables[_tableId].drawIndex[cardIndex]):
      return False
  return True

@external
def endDeal(_tableId: uint256):
  assert self.tables[_tableId].tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].phase == Phase_DEAL, "wrong phase"
  assert self.checkRevelations(_tableId), "revelations missing"
  self.tables[_tableId].phase = Phase_PLAY

@external
def startDeal(_tableId: uint256):
  assert self.tables[_tableId].config.gameAddress == msg.sender, "unauthorised"
  self.tables[_tableId].phase = Phase_DEAL
  self.tables[_tableId].commitBlock = block.number

@external
def dealTo(_tableId: uint256, _seatIndex: uint256):
  assert self.tables[_tableId].config.gameAddress == msg.sender, "unauthorised"
  self.tables[_tableId].drawIndex[self.tables[_tableId].deckIndex] = _seatIndex
  self.tables[_tableId].requirement[self.tables[_tableId].deckIndex] = Req_HAND
  self.tables[_tableId].deck.drawCard(
    self.tables[_tableId].deckId, _seatIndex, self.tables[_tableId].deckIndex)
  self.tables[_tableId].deckIndex = unsafe_add(self.tables[_tableId].deckIndex, 1)

# view info

@external
@view
def authorised(_tableId: uint256, _phase: uint256,
               _seatIndex: uint256 = empty(uint256),
               _address: address = empty(address)) -> bool:
  return (self.tables[_tableId].tableId == _tableId and
          self.tables[_tableId].phase == _phase and
          (_address == empty(address) or
           _address == self.playerAddress[
                         self.tables[_tableId].seats[_seatIndex]]))

@external
@view
def gameId(_tableId: uint256) -> uint256:
  return self.tables[_tableId].gameId

@external
@view
def cardAt(_tableId: uint256, _deckIndex: uint256) -> uint256:
  return self.tables[_tableId].deck.openedCard(
    self.tables[_tableId].deckId, _deckIndex)

@external
@view
def deckIndex(_tableId: uint256) -> uint256:
  return self.tables[_tableId].deckIndex

@external
@view
def numPlayers(_tableId: uint256) -> uint256:
  return self.tables[_tableId].config.startsWith

@external
@view
def maxPlayers(_tableId: uint256) -> uint256:
  return self.tables[_tableId].config.untilLeft

@external
@view
def buyIn(_tableId: uint256) -> uint256:
  return self.tables[_tableId].config.buyIn

@external
@view
def actBlocks(_tableId: uint256) -> uint256:
  return self.tables[_tableId].config.actBlocks

@external
@view
def levelBlocks(_tableId: uint256) -> uint256:
  return self.tables[_tableId].config.levelBlocks

@external
@view
def level(_tableId: uint256, level: uint256) -> uint256:
  return self.tables[_tableId].config.structure[level]
