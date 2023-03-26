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

import Deck as DeckManager

D: immutable(DeckManager)

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

interface GameManager:
  def afterShuffle(_tableId: uint256): nonpayable
  def afterDeal(_tableId: uint256, _phase: uint256): nonpayable

struct Config:
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
  game:        GameManager          # game contract
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
def __init__(_deckAddr: address):
  D = DeckManager(_deckAddr)
  self.nextTableId = 1

@external
@view
def deckAddress() -> address:
  return D.address

@internal
def forceSend(_to: address, _amount: uint256) -> bool:
  return raw_call(_to, b"", value=_amount, gas=0, revert_on_failure=False)

# lobby

event JoinTable:
  table: indexed(uint256)
  player: indexed(address)
  seat: indexed(uint256)

event LeaveTable:
  table: indexed(uint256)
  player: indexed(address)

event StartGame:
  table: indexed(uint256)

event EndGame:
  table: indexed(uint256)

@internal
def playerJoinWaiting(_tableId: uint256, _seatIndex: uint256):
  if self.numWaiting[_tableId] == empty(uint256):
    self.nextWaitingTable[_tableId] = self.nextWaitingTable[0]
    self.nextWaitingTable[0] = _tableId
    self.prevWaitingTable[_tableId] = 0
    self.prevWaitingTable[self.nextWaitingTable[_tableId]] = _tableId
  self.numWaiting[_tableId] = unsafe_add(self.numWaiting[_tableId], 1)
  log JoinTable(_tableId, msg.sender, _seatIndex)

@internal
def playerLeaveWaiting(_tableId: uint256, _num: uint256):
  self.numWaiting[_tableId] = unsafe_sub(self.numWaiting[_tableId], _num)
  if self.numWaiting[_tableId] == empty(uint256):
    self.nextWaitingTable[self.prevWaitingTable[_tableId]] = self.nextWaitingTable[_tableId]
    self.prevWaitingTable[self.nextWaitingTable[_tableId]] = self.prevWaitingTable[_tableId]

@internal
def playerLeaveLive(_tableId: uint256, _player: address):
  self.nextLiveTable[_player][self.prevLiveTable[_player][_tableId]] = self.nextLiveTable[_player][_tableId]
  self.prevLiveTable[_player][self.nextLiveTable[_player][_tableId]] = self.prevLiveTable[_player][_tableId]
  log LeaveTable(_tableId, _player)

@internal
@pure
def ascending(_a: DynArray[uint256, 100]) -> bool:
  x: uint256 = 0
  for y in _a:
    if y <= x:
      return False
    x = y
  return True

@internal
@view
def validatePhase(_tableId: uint256, _phase: uint256):
  assert self.tables[_tableId].phase == _phase, "wrong phase"

@internal
@view
def gameAuth(_tableId: uint256):
  assert self.tables[_tableId].game.address == msg.sender, "unauthorised"

@internal
@view
def checkAuth(_tableId: uint256, _seatIndex: uint256):
  assert self.tables[_tableId].seats[_seatIndex] == msg.sender, "unauthorised"

@external
@payable
def createTable(_seatIndex: uint256, _config: Config, _gameAddr: address) -> uint256:
  assert 1 < _config.startsWith and _config.startsWith <= MAX_SEATS, "invalid startsWith"
  assert 0 < _config.untilLeft and _config.untilLeft < _config.startsWith, "invalid untilLeft"
  assert 0 < len(_config.structure) and self.ascending(_config.structure), "invalid structure"
  assert 0 < _config.buyIn, "invalid buyIn"
  assert _seatIndex < _config.startsWith, "invalid seatIndex"
  assert _config.startsWith * (_config.bond + _config.buyIn) <= max_value(uint256), "amounts too large"
  assert msg.value == unsafe_add(_config.bond, _config.buyIn), "incorrect bond + buyIn"
  tableId: uint256 = self.nextTableId
  self.tables[tableId].game = GameManager(_gameAddr)
  self.tables[tableId].deckId = D.newDeck(_config.startsWith)
  self.tables[tableId].phase = Phase_JOIN
  self.tables[tableId].config = _config
  self.tables[tableId].seats[_seatIndex] = msg.sender
  self.nextTableId = unsafe_add(tableId, 1)
  self.playerJoinWaiting(tableId, _seatIndex)
  self.tables[tableId].present = 1
  return tableId

@external
@payable
def joinTable(_tableId: uint256, _seatIndex: uint256):
  self.validatePhase(_tableId, Phase_JOIN)
  numPlayers: uint256 = self.tables[_tableId].config.startsWith
  assert _seatIndex < numPlayers, "invalid seatIndex"
  assert self.tables[_tableId].seats[_seatIndex] == empty(address), "seatIndex unavailable"
  for seatIndex in range(MAX_SEATS):
    if seatIndex == numPlayers: break
    assert self.tables[_tableId].seats[seatIndex] != msg.sender, "already joined"
  assert msg.value == unsafe_add(
    self.tables[_tableId].config.bond, self.tables[_tableId].config.buyIn), "incorrect bond + buyIn"
  self.tables[_tableId].seats[_seatIndex] = msg.sender
  self.playerJoinWaiting(_tableId, _seatIndex)
  numJoined: uint256 = unsafe_add(self.tables[_tableId].present, 1)
  self.tables[_tableId].present = numJoined
  if numJoined == numPlayers:
    self.tables[_tableId].present = 0
    for seatIndex in range(MAX_SEATS):
      if seatIndex == numPlayers: break
      player: address = self.tables[_tableId].seats[seatIndex]
      self.tables[_tableId].present |= shift(1, convert(seatIndex, int128)) # TODO: https://github.com/vyperlang/vyper/issues/3309
      self.nextLiveTable[player][_tableId] = self.nextLiveTable[player][0]
      self.nextLiveTable[player][0] = _tableId
      self.prevLiveTable[player][_tableId] = 0
      self.prevLiveTable[player][self.nextLiveTable[player][_tableId]] = _tableId
    self.playerLeaveWaiting(_tableId, numPlayers)
    self.tables[_tableId].phase = Phase_PREP
    self.tables[_tableId].commitBlock = block.number
    log StartGame(_tableId)

@external
def leaveTable(_tableId: uint256, _seatIndex: uint256):
  self.validatePhase(_tableId, Phase_JOIN)
  self.checkAuth(_tableId, _seatIndex)
  self.tables[_tableId].seats[_seatIndex] = empty(address)
  self.forceSend(msg.sender, unsafe_add(self.tables[_tableId].config.bond, self.tables[_tableId].config.buyIn))
  self.playerLeaveWaiting(_tableId, 1)
  self.tables[_tableId].present = unsafe_sub(self.tables[_tableId].present, 1)
  log LeaveTable(_tableId, msg.sender)

@external
def refundPlayer(_tableId: uint256, _seatIndex: uint256, _stack: uint256):
  self.gameAuth(_tableId)
  player: address = self.tables[_tableId].seats[_seatIndex]
  self.forceSend(player, unsafe_add(self.tables[_tableId].config.bond, _stack))
  self.playerLeaveLive(_tableId, player)

@external
def deleteTable(_tableId: uint256):
  self.gameAuth(_tableId)
  self.tables[_tableId] = empty(Table)
  log EndGame(_tableId)

# timeouts

event Challenge:
  table: indexed(uint256)
  player: indexed(address)
  sender: indexed(address)
  type: uint256

@internal
@view
def checkDeadline(_tableId: uint256, _blocks: uint256):
  assert block.number > (self.tables[_tableId].commitBlock + _blocks), "deadline not passed"

@external
def submitPrepTimeout(_tableId: uint256, _seatIndex: uint256):
  self.validatePhase(_tableId, Phase_PREP)
  self.checkDeadline(_tableId, self.tables[_tableId].config.prepBlocks)
  assert not D.hasSubmittedPrep(self.tables[_tableId].deckId, _seatIndex), "already submitted"
  self.failChallenge(_tableId, _seatIndex, 0)

@external
def verifyPrepTimeout(_tableId: uint256, _seatIndex: uint256):
  self.validatePhase(_tableId, Phase_PREP)
  self.checkDeadline(_tableId, self.tables[_tableId].config.prepBlocks)
  deckId: uint256 = self.tables[_tableId].deckId
  assert D.allSubmittedPrep(deckId), "not submitted"
  assert not D.hasVerifiedPrep(deckId, _seatIndex), "already verified"
  self.failChallenge(_tableId, _seatIndex, 1)

@external
def submitShuffleTimeout(_tableId: uint256, _seatIndex: uint256):
  self.validatePhase(_tableId, Phase_SHUF)
  self.checkDeadline(_tableId, self.tables[_tableId].config.shuffBlocks)
  assert self.shuffleCount(_tableId) == _seatIndex, "wrong player"
  self.failChallenge(_tableId, _seatIndex, 2)

@external
def verifyShuffleTimeout(_tableId: uint256, _seatIndex: uint256):
  self.validatePhase(_tableId, Phase_SHUF)
  self.checkDeadline(_tableId, self.tables[_tableId].config.verifBlocks)
  assert self.shuffleCount(_tableId) == _seatIndex, "wrong player"
  assert not D.challengeActive(self.tables[_tableId].deckId, _seatIndex), "already verified"
  self.failChallenge(_tableId, _seatIndex, 3)

@external
def decryptTimeout(_tableId: uint256, _seatIndex: uint256, _cardIndex: uint256):
  self.validatePhase(_tableId, Phase_DEAL)
  self.checkDeadline(_tableId, self.tables[_tableId].config.dealBlocks)
  assert self.tables[_tableId].requirement[_cardIndex] != Req_DECK, "not required"
  assert self.decryptCount(_tableId, _cardIndex) == _seatIndex, "already decrypted"
  self.failChallenge(_tableId, _seatIndex, 4)

@external
def revealTimeout(_tableId: uint256, _seatIndex: uint256, _cardIndex: uint256):
  self.validatePhase(_tableId, Phase_DEAL)
  self.checkDeadline(_tableId, self.tables[_tableId].config.dealBlocks)
  assert self.tables[_tableId].drawIndex[_cardIndex] == _seatIndex, "wrong player"
  assert self.tables[_tableId].requirement[_cardIndex] == Req_SHOW, "not required"
  assert D.openedCard(self.tables[_tableId].deckId, _cardIndex) == 0, "already opened"
  self.failChallenge(_tableId, _seatIndex, 5)

@internal
def failChallenge(_tableId: uint256, _challIndex: uint256, _type: uint256):
  numPlayers: uint256 = self.tables[_tableId].config.startsWith
  perPlayer: uint256 = unsafe_add(self.tables[_tableId].config.bond, self.tables[_tableId].config.buyIn)
  # burn the offender's bond + buyIn
  # refund the others' bonds and buyIns
  for seatIndex in range(MAX_SEATS):
    if seatIndex == numPlayers:
      break
    player: address = self.tables[_tableId].seats[seatIndex]
    if seatIndex == _challIndex:
      self.forceSend(empty(address), perPlayer)
      log Challenge(_tableId, player, msg.sender, _type)
    else:
      self.forceSend(player, perPlayer)
    # leave the table
    self.playerLeaveLive(_tableId, player)
  # delete the game
  self.tables[_tableId] = empty(Table)
  log EndGame(_tableId)

# deck setup

event DeckPrep:
  table: indexed(uint256)
  player: indexed(address)
  step: indexed(uint256)

@external
def submitPrep(_tableId: uint256, _seatIndex: uint256, _hash: bytes32):
  self.validatePhase(_tableId, Phase_PREP)
  self.checkAuth(_tableId, _seatIndex)
  deckId: uint256 = self.tables[_tableId].deckId
  D.submitPrep(deckId, _seatIndex, _hash)
  log DeckPrep(_tableId, msg.sender, 0)
  numSubmitted: uint256 = unsafe_add(self.tables[_tableId].deckIndex, 1)
  self.tables[_tableId].deckIndex = numSubmitted
  if numSubmitted == self.tables[_tableId].config.startsWith:
    D.finishSubmit(deckId)
    self.tables[_tableId].deckIndex = 0
  self.tables[_tableId].commitBlock = block.number

@external
def verifyPrep(_tableId: uint256, _seatIndex: uint256, _prep: CP[53]):
  self.validatePhase(_tableId, Phase_PREP)
  self.checkAuth(_tableId, _seatIndex)
  deckId: uint256 = self.tables[_tableId].deckId
  D.verifyPrep(deckId, _seatIndex, _prep)
  log DeckPrep(_tableId, msg.sender, 1)
  numVerified: uint256 = unsafe_add(self.tables[_tableId].deckIndex, 1)
  self.tables[_tableId].deckIndex = numVerified
  if numVerified == self.tables[_tableId].config.startsWith:
    D.finishPrep(deckId)
    for seatIndex in range(MAX_SEATS):
      if seatIndex == numVerified: break
      self.tables[_tableId].drawIndex[seatIndex] = seatIndex
      self.tables[_tableId].requirement[seatIndex] = Req_SHOW
    self.tables[_tableId].deckIndex = 0
    self.tables[_tableId].phase = Phase_SHUF
    self.tables[_tableId].nextPhase = Phase_PLAY
  self.tables[_tableId].commitBlock = block.number

# shuffle

event Shuffle:
  table: indexed(uint256)
  player: indexed(address)
  step: indexed(uint256)

@internal
@view
def shuffleCount(_tableId: uint256) -> uint256:
  return D.shuffleCount(self.tables[_tableId].deckId)

@external
def submitShuffle(_tableId: uint256, _seatIndex: uint256,
                  _shuffle: uint256[2][53], _hash: bytes32) -> uint256:
  self.validatePhase(_tableId, Phase_SHUF)
  self.checkAuth(_tableId, _seatIndex)
  deckId: uint256 = self.tables[_tableId].deckId
  self.tables[_tableId].commitBlock = block.number
  D.submitShuffle(deckId, _seatIndex, _shuffle)
  D.challenge(deckId, _seatIndex, self.tables[_tableId].config.verifRounds)
  log Shuffle(_tableId, msg.sender, 0)
  self.autoShuffle(_tableId)
  return D.respondChallenge(deckId, _seatIndex, _hash)

@external
def verifyShuffle(_tableId: uint256, _seatIndex: uint256,
                  _commitments: uint256[2][53][63],
                  _scalars: uint256[63],
                  _permutations: uint256[53][63]):
  self.validatePhase(_tableId, Phase_SHUF)
  self.checkAuth(_tableId, _seatIndex)
  bit: uint256 = shift(1, convert(_seatIndex, int128)) # TODO: https://github.com/vyperlang/vyper/issues/3309
  assert self.tables[_tableId].shuffled & bit == 0, "already verified"
  self.tables[_tableId].shuffled ^= bit
  for i in range(MAX_SECURITY):
    if i == self.tables[_tableId].config.verifRounds: break
    D.defuseNextChallenge(
      self.tables[_tableId].deckId, _seatIndex,
      _commitments[i], _scalars[i], _permutations[i])
  log Shuffle(_tableId, msg.sender, 1)
  self.autoVerif(_tableId)

@internal
def autoShuffle(_tableId: uint256):
  deckId: uint256 = self.tables[_tableId].deckId
  seatIndex: uint256 = self.shuffleCount(_tableId)
  for _ in range(MAX_SEATS):
    if seatIndex == self.tables[_tableId].config.startsWith:
      self.autoVerif(_tableId)
      break
    if self.tables[_tableId].present & shift(1, convert(seatIndex, int128)) == 0: # TODO: https://github.com/vyperlang/vyper/issues/3309
      # just copy the shuffle: use identity permutation and secret key = 1
      # do not challenge it; external challenges can just be ignored
      D.submitShuffle(deckId, seatIndex, D.lastShuffle(deckId))
      seatIndex = unsafe_add(seatIndex, 1)
    else:
      self.tables[_tableId].commitBlock = block.number
      break

@internal
def autoVerif(_tableId: uint256):
  end: uint256 = shift(1, convert(self.tables[_tableId].config.startsWith, int128)) # TODO: https://github.com/vyperlang/vyper/issues/3309
  cur: uint256 = 1
  for _ in range(MAX_SEATS):
    if cur == end:
      self.tables[_tableId].shuffled |= cur
      self.tables[_tableId].game.afterShuffle(_tableId)
      return
    if self.tables[_tableId].shuffled & cur == 0:
      if self.tables[_tableId].present & cur == 0:
        self.tables[_tableId].shuffled |= cur
      else:
        self.tables[_tableId].commitBlock = block.number
        return
    cur = shift(cur, 1)
  raise "autoVerif"

@external
def reshuffle(_tableId: uint256):
  self.gameAuth(_tableId)
  D.resetShuffle(self.tables[_tableId].deckId)
  self.tables[_tableId].shuffled = 0
  self.tables[_tableId].requirement = empty(uint256[26])
  self.tables[_tableId].deckIndex = 0
  self.tables[_tableId].phase = Phase_SHUF
  self.tables[_tableId].commitBlock = block.number

@external
def markAbsent(_tableId: uint256, _seatIndex: uint256):
  self.gameAuth(_tableId)
  self.tables[_tableId].present &= ~shift(1, convert(_seatIndex, int128)) # TODO: https://github.com/vyperlang/vyper/issues/3309

# deal

event Deal:
  table: indexed(uint256)
  player: indexed(address)
  card: indexed(uint256)

event Show:
  table: indexed(uint256)
  player: indexed(address)
  card: indexed(uint256)
  show: uint256

@internal
@view
def decryptCount(_tableId: uint256, _cardIndex: uint256) -> uint256:
  return D.decryptCount(self.tables[_tableId].deckId, _cardIndex)

@internal
def autoDecrypt(_tableId: uint256, _cardIndex: uint256):
  deckId: uint256 = self.tables[_tableId].deckId
  seatIndex: uint256 = self.decryptCount(_tableId, _cardIndex)
  for _ in range(MAX_SEATS):
    if seatIndex == self.tables[_tableId].config.startsWith:
      break
    if self.tables[_tableId].present & shift(1, convert(seatIndex, int128)) == 0: # TODO: https://github.com/vyperlang/vyper/issues/3309
      card: uint256[2] = D.lastDecrypt(deckId, _cardIndex)
      D.decryptCard(deckId, seatIndex, _cardIndex, card, D.emptyProof(card))
      seatIndex = unsafe_add(seatIndex, 1)
    else:
      break
  self.tables[_tableId].commitBlock = block.number

@external
def decryptCards(_tableId: uint256, _seatIndex: uint256, _data: DynArray[uint256[8], 26], _end: bool):
  self.validatePhase(_tableId, Phase_DEAL)
  self.checkAuth(_tableId, _seatIndex)
  for data in _data:
    cardIndex: uint256 = data[0]
    assert self.tables[_tableId].requirement[cardIndex] != Req_DECK, "decrypt not allowed"
    D.decryptCard(
      self.tables[_tableId].deckId, _seatIndex, cardIndex, [data[1], data[2]],
      Proof({gs: [data[3], data[4]], hs: [data[5], data[6]], scx: data[7]}))
    self.autoDecrypt(_tableId, cardIndex)
    log Deal(_tableId, msg.sender, cardIndex)
  if _end:
    self.endDeal(_tableId)

@external
def gameRevealCards(_tableId: uint256, _seatIndex: uint256, _data: uint256[7][2]):
  self.gameAuth(_tableId)
  deckId: uint256 = self.tables[_tableId].deckId
  sender: address = self.tables[_tableId].seats[_seatIndex]
  for i in range(2):
    self._revealCard(deckId, _seatIndex, _tableId, sender, _data[i])
  self.tables[_tableId].game.afterDeal(_tableId, Phase_SHOW)

@internal
def _revealCard(_deckId: uint256, _seatIndex: uint256,
                _tableId: uint256, _sender: address, _data: uint256[7]) -> uint256:
  cardIndex: uint256 = _data[0]
  D.openCard(
    _deckId, _seatIndex, cardIndex, _data[1],
    Proof({gs: [_data[2], _data[3]], hs: [_data[4], _data[5]], scx: _data[6]}))
  log Show(_tableId, _sender, cardIndex, _data[1])
  return cardIndex

@external
def revealCards(_tableId: uint256, _seatIndex: uint256, _data: DynArray[uint256[7], 26], _end: bool):
  self.validatePhase(_tableId, Phase_DEAL)
  self.checkAuth(_tableId, _seatIndex)
  deckId: uint256 = self.tables[_tableId].deckId
  for data in _data:
    cardIndex: uint256 = self._revealCard(deckId, _seatIndex, _tableId, msg.sender, data)
    assert self.tables[_tableId].drawIndex[cardIndex] == _seatIndex, "wrong player"
    assert self.tables[_tableId].requirement[cardIndex] == Req_SHOW, "reveal not allowed"
  if _end:
    self.endDeal(_tableId)

@internal
@view
def checkRevelations(_tableId: uint256) -> bool:
  for cardIndex in range(26):
    if (self.tables[_tableId].requirement[cardIndex] == Req_SHOW and
        D.openedCard(self.tables[_tableId].deckId, cardIndex) == 0):
      return False
    if (self.tables[_tableId].requirement[cardIndex] != Req_DECK and
        self.decryptCount(_tableId, cardIndex) <=
        self.tables[_tableId].drawIndex[cardIndex]):
      return False
  return True

@internal
def endDeal(_tableId: uint256):
  assert self.checkRevelations(_tableId), "revelations missing"
  nextPhase: uint256 = self.tables[_tableId].nextPhase
  self.tables[_tableId].phase = nextPhase
  self.tables[_tableId].game.afterDeal(_tableId, nextPhase)

@external
def startDeal(_tableId: uint256, _nextPhase: uint256):
  self.gameAuth(_tableId)
  self.tables[_tableId].phase = Phase_DEAL
  self.tables[_tableId].nextPhase = _nextPhase
  self.tables[_tableId].commitBlock = block.number

@external
def dealTo(_tableId: uint256, _seatIndex: uint256) -> uint256:
  self.gameAuth(_tableId)
  deckIndex: uint256 = self.tables[_tableId].deckIndex
  self.tables[_tableId].drawIndex[deckIndex] = _seatIndex
  self.tables[_tableId].requirement[deckIndex] = Req_HAND
  D.drawCard(self.tables[_tableId].deckId, _seatIndex, deckIndex)
  self.tables[_tableId].deckIndex = unsafe_add(deckIndex, 1)
  return deckIndex

@external
def showCard(_tableId: uint256, _cardIndex: uint256):
  self.gameAuth(_tableId)
  self.tables[_tableId].requirement[_cardIndex] = Req_SHOW

@external
def burnCard(_tableId: uint256):
  self.gameAuth(_tableId)
  self.tables[_tableId].deckIndex = unsafe_add(self.tables[_tableId].deckIndex, 1)

# showdown

@external
def startShow(_tableId: uint256):
  self.gameAuth(_tableId)
  self.tables[_tableId].phase = Phase_SHOW

# view info

@external
@view
def cardShown(_tableId: uint256, _cardIndex: uint256) -> bool:
  return self.tables[_tableId].requirement[_cardIndex] == Req_SHOW

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
  return D.openedCard(self.tables[_tableId].deckId, _deckIndex)

@external
@view
def cardAt(_tableId: uint256, _deckIndex: uint256) -> uint256:
  return unsafe_sub(self._cardAt(_tableId, _deckIndex), 1)

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

@external
@view
def shuffled(_tableId: uint256) -> uint256:
  return self.tables[_tableId].shuffled

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
