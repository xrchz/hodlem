# @version ^0.3.7

# copied from Deck.vy because https://github.com/vyperlang/vyper/issues/2670
SIZE: constant(uint256) = 52
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
# end of copy

# import Deck as DeckManager
# TODO: define the interface explicitly instead of importing
# because of https://github.com/vyperlang/titanoboa/issues/15
interface DeckManager:
    def newDeck(_players: uint256) -> uint256: nonpayable
    def changeDealer(_id: uint256, _newAddress: address): nonpayable
    def changeAddress(_id: uint256, _playerIdx: uint256, _newAddress: address): nonpayable
    def submitPrep(_id: uint256, _playerIdx: uint256, _prep: CP[53]): nonpayable
    def emptyProof(card: uint256[2]) -> Proof: pure
    def finishPrep(_id: uint256): nonpayable
    def resetShuffle(_id: uint256): nonpayable
    def submitShuffle(_id: uint256, _playerIdx: uint256, _shuffle: uint256[2][53]): nonpayable
    def challenge(_id: uint256, _playerIdx: uint256, _rounds: uint256): nonpayable
    def respondChallenge(_id: uint256, _playerIdx: uint256, _hash: bytes32) -> uint256: nonpayable
    def defuseNextChallenge(_id: uint256, _playerIdx: uint256,
                            _commitment: uint256[2][53], _scalar: uint256, _permutation: uint256[53]): nonpayable
    def drawCard(_id: uint256, _playerIdx: uint256, _cardIdx: uint256): nonpayable
    def decryptCard(_id: uint256, _playerIdx: uint256, _cardIdx: uint256, _card: uint256[2], _proof: Proof): nonpayable
    def openCard(_id: uint256, _playerIdx: uint256, _cardIdx: uint256, _openIdx: uint256, _proof: Proof): nonpayable
    def hasSubmittedPrep(_id: uint256, _playerIdx: uint256) -> bool: view
    def shuffleCount(_id: uint256) -> uint256: view
    def lastShuffle(_id: uint256) -> uint256[2][53]: view
    def challengeActive(_id: uint256, _playerIdx: uint256) -> bool: view
    def challengeRnd(_id: uint256, _playerIdx: uint256) -> uint256: view
    def decryptCount(_id: uint256, _cardIdx: uint256) -> uint256: view
    def lastDecrypt(_id: uint256, _cardIdx: uint256) -> uint256[2]: view
    def openedCard(_id: uint256, _cardIdx: uint256) -> uint256: view

MAX_SEATS:  constant(uint256) =   9 # maximum seats per table
MAX_LEVELS: constant(uint256) = 100 # maximum number of levels in tournament structure

Req_DECK: constant(uint256) = 0 # must be hidden by all
Req_HAND: constant(uint256) = 1 # must be hidden by owner and shown by others
Req_SHOW: constant(uint256) = 2 # must be shown by all

# not using Vyper enum because of this bug
# https://github.com/vyperlang/vyper/pull/3196/files#r1062141796
Phase_JOIN: constant(uint256) = 1 # before the game has started, taking seats
Phase_PREP: constant(uint256) = 2 # all players seated, preparing the deck
Phase_SHUF: constant(uint256) = 3 # submitting shuffles and verifications in order
Phase_DEAL: constant(uint256) = 4 # drawing and possibly opening cards as currently required
Phase_PLAY: constant(uint256) = 5 # betting; new card revelations may become required
Phase_SHOW: constant(uint256) = 6 # showdown; new card revelations may become required

struct Config:
  gameAddress: address             # address of game manager
  buyIn:       uint256             # entry ticket price per player
  bond:        uint256             # liveness bond for each player
  startsWith:  uint256             # game can start when this many players are seated
  untilLeft:   uint256             # game ends when this many players are left
  structure:   DynArray[uint256, 100] # small blind levels
  levelBlocks: uint256             # blocks between levels
  verifRounds: uint256             # number of shuffle verifications required
  prepBlocks:  uint256             # blocks to submit deck preparation
  shuffBlocks: uint256             # blocks to submit shuffle
  verifBlocks: uint256             # blocks to submit shuffle verification
  dealBlocks:  uint256             # blocks to submit card decryptions
  actBlocks:   uint256             # blocks to act before folding can be triggered

struct Table:
  config:      Config
  seats:       address[9]           # playerIds in seats as at the start of the game
  deck:        DeckManager          # deck contract
  deckId:      uint256              # id of deck in deck contract
  phase:       uint256
  nextPhase:   uint256              # phase to enter after deal
  present:     uint256              # whether each player contributes to the current shuffle
  shuffled:    uint256              # whether each player has verified their current shuffle
  commitBlock: uint256              # block from which new commitments were required
  deckIndex:   uint256              # index of next card in deck
  drawIndex:   uint256[26]          # player the card is drawn to
  requirement: uint256[26]          # revelation requirement level

tables: HashMap[uint256, Table]
nextTableId: uint256

nextWaitingTable: public(HashMap[uint256, uint256])
prevWaitingTable: public(HashMap[uint256, uint256])
numWaiting: HashMap[uint256, uint256]
nextLiveTable: public(HashMap[address, HashMap[uint256, uint256]])
prevLiveTable: public(HashMap[address, HashMap[uint256, uint256]])

@external
def __init__():
  self.nextTableId = 1

@internal
def forceSend(_to: address, _amount: uint256) -> bool:
  return raw_call(_to, b"", value=_amount, gas=0, revert_on_failure=False)

# lobby

@internal
def playerJoinWaiting(_tableId: uint256):
  if self.numWaiting[_tableId] == empty(uint256):
    self.nextWaitingTable[_tableId] = self.nextWaitingTable[0]
    self.nextWaitingTable[0] = _tableId
    self.prevWaitingTable[_tableId] = 0
    self.prevWaitingTable[self.nextWaitingTable[_tableId]] = _tableId
  self.numWaiting[_tableId] = unsafe_add(self.numWaiting[_tableId], 1)

@internal
def playerLeaveWaiting(_tableId: uint256, _num: uint256):
  self.numWaiting[_tableId] = unsafe_sub(self.numWaiting[_tableId], _num)
  if self.numWaiting[_tableId] == empty(uint256):
    self.nextWaitingTable[self.prevWaitingTable[_tableId]] = self.nextWaitingTable[_tableId]
    self.prevWaitingTable[self.nextWaitingTable[_tableId]] = self.prevWaitingTable[_tableId]

@internal
def playerLeaveLive(_tableId: uint256, _player: address, _seatIndex: uint256):
  self.nextLiveTable[_player][self.prevLiveTable[_player][_tableId]] = self.nextLiveTable[_player][_tableId]
  self.prevLiveTable[_player][self.nextLiveTable[_player][_tableId]] = self.prevLiveTable[_player][_tableId]

@internal
@pure
def ascending(_a: DynArray[uint256, 100]) -> bool:
  x: uint256 = 0
  for y in _a:
    if y <= x:
      return False
  return True

@external
@payable
def createTable(_seatIndex: uint256, _config: Config, _deckAddr: address) -> uint256:
  assert 1 < _config.startsWith and _config.startsWith <= MAX_SEATS, "invalid startsWith"
  assert 0 < _config.untilLeft and _config.untilLeft < _config.startsWith, "invalid untilLeft"
  assert 0 < len(_config.structure) and self.ascending(_config.structure), "invalid structure"
  assert 0 < _config.buyIn, "invalid buyIn"
  assert _seatIndex < _config.startsWith, "invalid seatIndex"
  assert _config.startsWith * (_config.bond + _config.buyIn) <= max_value(uint256), "amounts too large"
  assert msg.value == unsafe_add(_config.bond, _config.buyIn), "incorrect bond + buyIn"
  tableId: uint256 = self.nextTableId
  self.tables[tableId].deck = DeckManager(_deckAddr)
  self.tables[tableId].deckId = self.tables[tableId].deck.newDeck(_config.startsWith)
  self.tables[tableId].phase = Phase_JOIN
  self.tables[tableId].config = _config
  self.tables[tableId].seats[_seatIndex] = msg.sender
  self.nextTableId = unsafe_add(tableId, 1)
  self.playerJoinWaiting(tableId)
  return tableId

@external
@payable
def joinTable(_tableId: uint256, _seatIndex: uint256):
  assert self.tables[_tableId].phase == Phase_JOIN, "wrong phase"
  assert _seatIndex < self.tables[_tableId].config.startsWith, "invalid seatIndex"
  assert self.tables[_tableId].seats[_seatIndex] == empty(address), "seatIndex unavailable"
  assert msg.value == unsafe_add(
    self.tables[_tableId].config.bond, self.tables[_tableId].config.buyIn), "incorrect bond + buyIn"
  self.tables[_tableId].seats[_seatIndex] = msg.sender
  self.playerJoinWaiting(_tableId)

@external
def leaveTable(_tableId: uint256, _seatIndex: uint256):
  assert self.tables[_tableId].seats[_seatIndex] == msg.sender, "unauthorised"
  assert self.tables[_tableId].phase == Phase_JOIN, "wrong phase"
  self.tables[_tableId].seats[_seatIndex] = empty(address)
  self.forceSend(msg.sender, unsafe_add(self.tables[_tableId].config.bond, self.tables[_tableId].config.buyIn))
  self.playerLeaveWaiting(_tableId, 1)

@external
def startGame(_tableId: uint256):
  assert self.tables[_tableId].phase == Phase_JOIN, "wrong phase"
  numPlayers: uint256 = self.tables[_tableId].config.startsWith
  for seatIndex in range(MAX_SEATS):
    if seatIndex == numPlayers: break
    player: address = self.tables[_tableId].seats[seatIndex]
    assert player != empty(address), "not enough players"
    self.tables[_tableId].present |= shift(1, seatIndex)
    self.nextLiveTable[player][_tableId] = self.nextLiveTable[player][0]
    self.nextLiveTable[player][0] = _tableId
    self.prevLiveTable[player][_tableId] = 0
    self.prevLiveTable[player][self.nextLiveTable[player][_tableId]] = _tableId
  self.playerLeaveWaiting(_tableId, numPlayers)
  self.tables[_tableId].phase = Phase_PREP
  self.tables[_tableId].commitBlock = block.number

@external
def refundPlayer(_tableId: uint256, _seatIndex: uint256, _stack: uint256):
  assert self.tables[_tableId].config.gameAddress == msg.sender, "unauthorised"
  player: address = self.tables[_tableId].seats[_seatIndex]
  self.forceSend(player, unsafe_add(self.tables[_tableId].config.bond, _stack))
  self.playerLeaveLive(_tableId, player, _seatIndex)

@external
def deleteTable(_tableId: uint256):
  assert self.tables[_tableId].config.gameAddress == msg.sender, "unauthorised"
  self.tables[_tableId] = empty(Table)

# timeouts

@internal
@view
def validatePhase(_tableId: uint256, _phase: uint256):
  assert self.tables[_tableId].phase == _phase, "wrong phase"

@external
def prepareTimeout(_tableId: uint256, _seatIndex: uint256):
  self.validatePhase(_tableId, Phase_PREP)
  assert block.number > (self.tables[_tableId].commitBlock +
                         self.tables[_tableId].config.prepBlocks), "deadline not passed"
  assert not self.tables[_tableId].deck.hasSubmittedPrep(
    self.tables[_tableId].deckId, _seatIndex), "already submitted"
  self.failChallenge(_tableId, _seatIndex)

@external
def shuffleTimeout(_tableId: uint256, _seatIndex: uint256):
  self.validatePhase(_tableId, Phase_SHUF)
  assert block.number > (self.tables[_tableId].commitBlock +
                         self.tables[_tableId].config.shuffBlocks), "deadline not passed"
  assert self.shuffleCount(_tableId) == _seatIndex, "wrong player"
  self.failChallenge(_tableId, _seatIndex)

@external
def verificationTimeout(_tableId: uint256, _seatIndex: uint256):
  self.validatePhase(_tableId, Phase_SHUF)
  assert block.number > (self.tables[_tableId].commitBlock +
                         self.tables[_tableId].config.verifBlocks), "deadline not passed"
  assert self.shuffleCount(_tableId) == _seatIndex, "wrong player"
  assert not self.tables[_tableId].deck.challengeActive(
    self.tables[_tableId].deckId, _seatIndex), "already verified"
  self.failChallenge(_tableId, _seatIndex)

@external
def decryptTimeout(_tableId: uint256, _seatIndex: uint256, _cardIndex: uint256):
  self.validatePhase(_tableId, Phase_DEAL)
  assert block.number > (self.tables[_tableId].commitBlock +
                         self.tables[_tableId].config.dealBlocks), "deadline not passed"
  assert self.tables[_tableId].requirement[_cardIndex] != Req_DECK, "not required"
  assert self.decryptCount(_tableId, _cardIndex) == _seatIndex, "already decrypted"
  self.failChallenge(_tableId, _seatIndex)

@external
def revealTimeout(_tableId: uint256, _seatIndex: uint256, _cardIndex: uint256):
  self.validatePhase(_tableId, Phase_DEAL)
  assert block.number > (self.tables[_tableId].commitBlock +
                         self.tables[_tableId].config.dealBlocks), "deadline not passed"
  assert self.tables[_tableId].drawIndex[_cardIndex] == _seatIndex, "wrong player"
  assert self.tables[_tableId].requirement[_cardIndex] == Req_SHOW, "not required"
  assert self.tables[_tableId].deck.openedCard(
    self.tables[_tableId].deckId, _cardIndex) == 0, "already opened"
  self.failChallenge(_tableId, _seatIndex)

@internal
def failChallenge(_tableId: uint256, _challIndex: uint256):
  perPlayer: uint256 = unsafe_add(self.tables[_tableId].config.bond, self.tables[_tableId].config.buyIn)
  # burn the offender's bond + buyIn
  # refund the others' bonds and buyIns
  for seatIndex in range(MAX_SEATS):
    if seatIndex == self.tables[_tableId].config.startsWith:
      break
    player: address = self.tables[_tableId].seats[seatIndex]
    if seatIndex == _challIndex:
      self.forceSend(empty(address), perPlayer)
    else:
      self.forceSend(player, perPlayer)
    # leave the table
    self.playerLeaveLive(_tableId, player, seatIndex)
  # delete the game
  self.tables[_tableId] = empty(Table)

# deck setup

@external
def prepareDeck(_tableId: uint256, _seatIndex: uint256, _deckPrep: CP[53]):
  self.validatePhase(_tableId, Phase_PREP)
  assert self.tables[_tableId].seats[_seatIndex] == msg.sender, "unauthorised"
  self.tables[_tableId].deck.submitPrep(self.tables[_tableId].deckId, _seatIndex, _deckPrep)

@external
def finishDeckPrep(_tableId: uint256):
  self.validatePhase(_tableId, Phase_PREP)
  self.tables[_tableId].deck.finishPrep(self.tables[_tableId].deckId)
  for seatIndex in range(MAX_SEATS):
    if seatIndex == self.tables[_tableId].config.startsWith: break
    self.tables[_tableId].drawIndex[seatIndex] = seatIndex
    self.tables[_tableId].requirement[seatIndex] = Req_SHOW
  self.tables[_tableId].phase = Phase_SHUF
  self.tables[_tableId].commitBlock = block.number

# shuffle

@internal
@view
def shuffleCount(_tableId: uint256) -> uint256:
  return self.tables[_tableId].deck.shuffleCount(self.tables[_tableId].deckId)

@external
def submitShuffle(_tableId: uint256, _seatIndex: uint256,
                  _shuffle: uint256[2][53], _hash: bytes32) -> uint256:
  self.validatePhase(_tableId, Phase_SHUF)
  assert self.tables[_tableId].seats[_seatIndex] == msg.sender, "unauthorised"
  deckId: uint256 = self.tables[_tableId].deckId
  self.tables[_tableId].commitBlock = block.number
  self.tables[_tableId].deck.submitShuffle(deckId, _seatIndex, _shuffle)
  self.tables[_tableId].deck.challenge(deckId, _seatIndex, self.tables[_tableId].config.verifRounds)
  self.autoShuffle(_tableId)
  return self.tables[_tableId].deck.respondChallenge(deckId, _seatIndex, _hash)

@external
def submitVerif(_tableId: uint256, _seatIndex: uint256,
                _commitments: uint256[2][53][63],
                _scalars: uint256[63],
                _permutations: uint256[53][63]):
  self.validatePhase(_tableId, Phase_SHUF)
  assert self.tables[_tableId].seats[_seatIndex] == msg.sender, "unauthorised"
  self.tables[_tableId].shuffled |= shift(1, _seatIndex)
  for i in range(MAX_SECURITY):
    if i == self.tables[_tableId].config.verifRounds: break
    self.tables[_tableId].deck.defuseNextChallenge(
      self.tables[_tableId].deckId, _seatIndex,
      _commitments[i], _scalars[i], _permutations[i])
  self.autoVerif(_tableId)

@internal
def autoShuffle(_tableId: uint256):
  deckId: uint256 = self.tables[_tableId].deckId
  seatIndex: uint256 = self.shuffleCount(_tableId)
  for _ in range(MAX_SEATS):
    if seatIndex == self.tables[_tableId].config.startsWith:
      self.autoVerif(_tableId)
      break
    if self.tables[_tableId].present & shift(1, seatIndex) == 0:
      # just copy the shuffle: use identity permutation and secret key = 1
      # do not challenge it; external challenges can just be ignored
      self.tables[_tableId].deck.submitShuffle(
        deckId, seatIndex, self.tables[_tableId].deck.lastShuffle(deckId))
      seatIndex = unsafe_add(seatIndex, 1)
    else:
      self.tables[_tableId].commitBlock = block.number
      break

@internal
def autoVerif(_tableId: uint256):
  end: uint256 = shift(1, self.tables[_tableId].config.startsWith)
  cur: uint256 = 1
  for _ in range(MAX_SEATS):
    if cur == end:
      self.finishShuffle(_tableId)
    if self.tables[_tableId].shuffled & cur == 0:
      if self.tables[_tableId].present & cur == 0:
        self.tables[_tableId].shuffled |= cur
      else:
        self.tables[_tableId].commitBlock = block.number
        break
    cur = shift(cur, 1)

@internal
def finishShuffle(_tableId: uint256):
  self.tables[_tableId].phase = Phase_DEAL
  self.tables[_tableId].nextPhase = Phase_PLAY
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
  self.tables[_tableId].shuffled = 0
  self.tables[_tableId].phase = Phase_SHUF
  self.tables[_tableId].commitBlock = block.number

@external
def setPresence(_tableId: uint256, _seatIndex: uint256, _present: bool):
  assert self.tables[_tableId].config.gameAddress == msg.sender, "unauthorised"
  if _present:
    self.tables[_tableId].present |= shift(1, _seatIndex)
  else:
    self.tables[_tableId].present &= ~shift(1, _seatIndex)

# deal

@internal
@view
def decryptCount(_tableId: uint256, _cardIndex: uint256) -> uint256:
  return self.tables[_tableId].deck.decryptCount(self.tables[_tableId].deckId, _cardIndex)

@internal
def autoDecrypt(_tableId: uint256, _cardIndex: uint256):
  deckId: uint256 = self.tables[_tableId].deckId
  seatIndex: uint256 = self.decryptCount(_tableId, _cardIndex)
  for _ in range(MAX_SEATS):
    if seatIndex == self.tables[_tableId].config.startsWith:
      break
    if self.tables[_tableId].present & shift(1, seatIndex) == 0:
      card: uint256[2] = self.tables[_tableId].deck.lastDecrypt(deckId, _cardIndex)
      self.tables[_tableId].deck.decryptCard(deckId, seatIndex, _cardIndex, card,
        self.tables[_tableId].deck.emptyProof(card))
      seatIndex = unsafe_add(seatIndex, 1)
    else:
      break
  self.tables[_tableId].commitBlock = block.number

@external
def decryptCard(_tableId: uint256, _seatIndex: uint256, _cardIndex: uint256,
                _card: uint256[2], _proof: Proof):
  self.validatePhase(_tableId, Phase_DEAL)
  assert self.tables[_tableId].seats[_seatIndex] == msg.sender, "unauthorised"
  assert self.tables[_tableId].requirement[_cardIndex] != Req_DECK, "decrypt not allowed"
  self.tables[_tableId].deck.decryptCard(
    self.tables[_tableId].deckId, _seatIndex, _cardIndex, _card, _proof)
  self.autoDecrypt(_tableId, _cardIndex)

@external
def revealCard(_tableId: uint256, _seatIndex: uint256, _cardIndex: uint256,
               _openIndex: uint256, _proof: Proof):
  self.validatePhase(_tableId, Phase_DEAL)
  assert self.tables[_tableId].seats[_seatIndex] == msg.sender, "unauthorised"
  assert self.tables[_tableId].drawIndex[_cardIndex] == _seatIndex, "wrong player"
  assert self.tables[_tableId].requirement[_cardIndex] == Req_SHOW, "reveal not allowed"
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
        self.decryptCount(_tableId, cardIndex) <=
        self.tables[_tableId].drawIndex[cardIndex]):
      return False
  return True

@external
def endDeal(_tableId: uint256):
  self.validatePhase(_tableId, Phase_DEAL)
  assert self.checkRevelations(_tableId), "revelations missing"
  self.tables[_tableId].phase = self.tables[_tableId].nextPhase

@external
def startDeal(_tableId: uint256):
  assert self.tables[_tableId].config.gameAddress == msg.sender, "unauthorised"
  self.tables[_tableId].nextPhase = self.tables[_tableId].phase
  self.tables[_tableId].phase = Phase_DEAL
  self.tables[_tableId].commitBlock = block.number

@external
def dealTo(_tableId: uint256, _seatIndex: uint256) -> uint256:
  assert self.tables[_tableId].config.gameAddress == msg.sender, "unauthorised"
  deckIndex: uint256 = self.tables[_tableId].deckIndex
  self.tables[_tableId].drawIndex[deckIndex] = _seatIndex
  self.tables[_tableId].requirement[deckIndex] = Req_HAND
  self.tables[_tableId].deck.drawCard(
    self.tables[_tableId].deckId, _seatIndex, deckIndex)
  self.tables[_tableId].deckIndex = unsafe_add(deckIndex, 1)
  return deckIndex

@external
def showCard(_tableId: uint256, _cardIndex: uint256):
  assert self.tables[_tableId].config.gameAddress == msg.sender, "unauthorised"
  self.tables[_tableId].requirement[_cardIndex] = Req_SHOW

@external
def burnCard(_tableId: uint256):
  assert self.tables[_tableId].config.gameAddress == msg.sender, "unauthorised"
  self.tables[_tableId].deckIndex = unsafe_add(self.tables[_tableId].deckIndex, 1)

# showdown

@external
def startShow(_tableId: uint256):
  assert self.tables[_tableId].config.gameAddress == msg.sender, "unauthorised"
  self.tables[_tableId].phase = Phase_SHOW

# view info

@external
@view
def authorised(_tableId: uint256, _phase: uint256,
               _seatIndex: uint256 = empty(uint256),
               _address: address = empty(address)) -> bool:
  return (self.tables[_tableId].phase == _phase and
          (_address == empty(address) or
           _address == self.tables[_tableId].seats[_seatIndex]))

@internal
@view
def _cardAt(_tableId: uint256, _deckIndex: uint256) -> uint256:
  return self.tables[_tableId].deck.openedCard(
    self.tables[_tableId].deckId, _deckIndex)

@external
@view
def cardAt(_tableId: uint256, _deckIndex: uint256) -> uint256:
  return self._cardAt(_tableId, _deckIndex)

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
def playerAt(_tableId: uint256, _seatIndex: uint256) -> address:
  return self.tables[_tableId].seats[_seatIndex]

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
def numLevels(_tableId: uint256) -> uint256:
  return len(self.tables[_tableId].config.structure)

@external
@view
def level(_tableId: uint256, level: uint256) -> uint256:
  return self.tables[_tableId].config.structure[level]

# for off-chain viewing

@external
@view
def configParams(_tableId: uint256) -> uint256[12]:
  return [
    self.tables[_tableId].config.buyIn,
    self.tables[_tableId].config.bond,
    self.tables[_tableId].config.startsWith,
    self.tables[_tableId].config.untilLeft,
    self.tables[_tableId].config.levelBlocks,
    self.tables[_tableId].config.verifRounds,
    self.tables[_tableId].config.prepBlocks,
    self.tables[_tableId].config.shuffBlocks,
    self.tables[_tableId].config.verifBlocks,
    self.tables[_tableId].config.dealBlocks,
    self.tables[_tableId].config.actBlocks,
    self.tables[_tableId].deckId
  ]

@external
@view
def configStructure(_tableId: uint256) -> DynArray[uint256, 100]:
  return self.tables[_tableId].config.structure

@external
@view
def phaseCommit(_tableId: uint256) -> uint256[2]:
  return [self.tables[_tableId].phase,
          self.tables[_tableId].commitBlock]

@external
@view
def cardInfo(_tableId: uint256) -> uint256[26][4]:
  result: uint256[26][4] = empty(uint256[26][4])
  for cardIndex in range(26):
    result[0][cardIndex] = self.tables[_tableId].requirement[cardIndex]
    result[1][cardIndex] = self.tables[_tableId].drawIndex[cardIndex]
    result[2][cardIndex] = self.decryptCount(_tableId, cardIndex)
    result[3][cardIndex] = self._cardAt(_tableId, cardIndex)
  return result
