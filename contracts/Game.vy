# @version ^0.3.7
# no-limit hold'em sit-n-go single-table tournaments

# TODO: add event logs
# TODO: make a frontend
# TODO: add pause?
# TODO: add rake (rewards tabs for progress txns)?
# TODO: add penalties (instead of full abort on failure)?

# copied from Deck.vy because https://github.com/vyperlang/vyper/issues/2670
MAX_SIZE: constant(uint256) = 2000
MAX_PLAYERS: constant(uint256) = 1000 # to distinguish from MAX_SIZE when inlining
MAX_SECURITY: constant(uint256) = 256

struct Proof:
  # signature to confirm log_g(gx) = log_h(hx)
  # s is a random secret scalar
  gs:  uint256[2] # g ** s
  hs:  uint256[2] # h ** s
  scx: uint256 # s + cx (mod q), where c = hash(g, h, gx, hx, gs, hs)

struct CB:
  # g and h are random points, x is a random secret scalar
  g:   uint256[2]
  h:   uint256[2]
  gx:  uint256[2] # g ** x
  hx:  uint256[2] # h ** x
  p: Proof

struct DeckPrep:
  cards: DynArray[CB, MAX_SIZE]
# end of copy

# import Deck as DeckManager
# TODO: define the interface explicitly instead of importing
# because of https://github.com/vyperlang/titanoboa/issues/15
interface DeckManager:
    def newDeck(_size: uint256, _players: uint256) -> uint256: nonpayable
    def changeDealer(_id: uint256, _newAddress: address): nonpayable
    def changeAddress(_id: uint256, _playerIdx: uint256, _newAddress: address): nonpayable
    def submitPrep(_id: uint256, _playerIdx: uint256, _prep: DeckPrep): nonpayable
    def emptyProof(card: uint256[2]) -> Proof: pure
    def finishPrep(_id: uint256) -> uint256: nonpayable
    def resetShuffle(_id: uint256): nonpayable
    def submitShuffle(_id: uint256, _playerIdx: uint256, _shuffle: DynArray[uint256[2], 2000]): nonpayable
    def challenge(_id: uint256, _playerIdx: uint256, _rounds: uint256): nonpayable
    def respondChallenge(_id: uint256, _playerIdx: uint256, _data: DynArray[DynArray[uint256[2], 2000], 256]) -> uint256: nonpayable
    def defuseChallenge(_id: uint256, _playerIdx: uint256, _scalars: DynArray[uint256, 256], _permutations: DynArray[DynArray[uint256, 2000], 256]): nonpayable
    def drawCard(_id: uint256, _playerIdx: uint256, _cardIdx: uint256): nonpayable
    def decryptCard(_id: uint256, _playerIdx: uint256, _cardIdx: uint256, _card: uint256[2], _proof: Proof): nonpayable
    def openCard(_id: uint256, _playerIdx: uint256, _cardIdx: uint256, _openIdx: uint256, _proof: Proof): nonpayable
    def hasSubmittedPrep(_id: uint256, _playerIdx: uint256) -> bool: view
    def shuffleCount(_id: uint256) -> uint256: view
    def lastShuffle(_id: uint256) -> DynArray[uint256[2], 2000]: view
    def challengeActive(_id: uint256, _playerIdx: uint256) -> bool: view
    def decryptCount(_id: uint256, _cardIdx: uint256) -> uint256: view
    def lastDecrypt(_id: uint256, _cardIdx: uint256) -> uint256[2]: view
    def openedCard(_id: uint256, _cardIdx: uint256) -> uint256: view

# copied from Room.vy
MAX_SEATS:  constant(uint256) =   9 # maximum seats per table
MAX_LEVELS: constant(uint256) = 100 # maximum number of levels in tournament structure

struct Config:
  gameAddress: address             # address of game manager
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
  dealBlocks:  uint256             # blocks to submit card decryptions
  actBlocks:   uint256             # blocks to act before folding can be triggered

Phase_JOIN: constant(uint256) = 1 # before the game has started, taking seats
Phase_PREP: constant(uint256) = 2 # all players seated, preparing the deck
Phase_SHUF: constant(uint256) = 3 # submitting shuffles and verifications in order
Phase_DEAL: constant(uint256) = 4 # drawing and possibly opening cards as currently required
Phase_PLAY: constant(uint256) = 5 # betting; new card revelations may become required
Phase_SHOW: constant(uint256) = 6 # showdown; new card revelations may become required
# end copy

# import Room as RoomManager
# TODO: define the interface explicitly instead of importing
# because of https://github.com/vyperlang/titanoboa/issues/15
# External Interfaces
interface RoomManager:
    def register() -> uint256: nonpayable
    def changePlayerAddress(_playerId: uint256, _newAddress: address): nonpayable
    def confirmChangePlayerAddress(_playerId: uint256): nonpayable
    def createTable(_playerId: uint256, _seatIndex: uint256, _config: Config, _deckAddr: address) -> uint256: payable
    def joinTable(_playerId: uint256, _tableId: uint256, _seatIndex: uint256): payable
    def leaveTable(_tableId: uint256, _seatIndex: uint256): nonpayable
    def startGame(_tableId: uint256): nonpayable
    def refundPlayer(_tableId: uint256, _seatIndex: uint256, _stack: uint256): nonpayable
    def deleteTable(_tableId: uint256): nonpayable
    def prepareTimeout(_tableId: uint256, _seatIndex: uint256): nonpayable
    def shuffleTimeout(_tableId: uint256, _seatIndex: uint256): nonpayable
    def verificationTimeout(_tableId: uint256, _seatIndex: uint256): nonpayable
    def decryptTimeout(_tableId: uint256, _seatIndex: uint256, _cardIndex: uint256): nonpayable
    def revealTimeout(_tableId: uint256, _seatIndex: uint256, _cardIndex: uint256): nonpayable
    def prepareDeck(_tableId: uint256, _seatIndex: uint256, _deckPrep: DeckPrep): nonpayable
    def finishDeckPrep(_tableId: uint256): nonpayable
    def submitShuffle(_tableId: uint256, _seatIndex: uint256, _shuffle: DynArray[uint256[2], 2000], _commitment: DynArray[DynArray[uint256[2], 2000], 256]) -> uint256: nonpayable
    def submitVerif(_tableId: uint256, _seatIndex: uint256, _scalars: DynArray[uint256, 256], _permutations: DynArray[DynArray[uint256, 2000], 256]): nonpayable
    def reshuffle(_tableId: uint256): nonpayable
    def setPresence(_tableId: uint256, _seatIndex: uint256, _present: bool): nonpayable
    def decryptCard(_tableId: uint256, _seatIndex: uint256, _cardIndex: uint256, _card: uint256[2], _proof: Proof): nonpayable
    def revealCard(_tableId: uint256, _seatIndex: uint256, _cardIndex: uint256, _openIndex: uint256, _proof: Proof): nonpayable
    def endDeal(_tableId: uint256): nonpayable
    def startDeal(_tableId: uint256): nonpayable
    def dealTo(_tableId: uint256, _seatIndex: uint256) -> uint256: nonpayable
    def showCard(_tableId: uint256, _cardIndex: uint256): nonpayable
    def burnCard(_tableId: uint256): nonpayable
    def startShow(_tableId: uint256): nonpayable
    def authorised(_tableId: uint256, _phase: uint256, _seatIndex: uint256 = empty(uint256), _address: address = empty(address)) -> bool: view
    def gameId(_tableId: uint256) -> uint256: view
    def cardAt(_tableId: uint256, _deckIndex: uint256) -> uint256: view
    def deckIndex(_tableId: uint256) -> uint256: view
    def numPlayers(_tableId: uint256) -> uint256: view
    def maxPlayers(_tableId: uint256) -> uint256: view
    def buyIn(_tableId: uint256) -> uint256: view
    def actBlocks(_tableId: uint256) -> uint256: view
    def levelBlocks(_tableId: uint256) -> uint256: view
    def level(_tableId: uint256, level: uint256) -> uint256: view

T: immutable(RoomManager)

@external
def __init__(roomAddress: address):
  T = RoomManager(roomAddress)

struct Game:
  startBlock:  uint256            # block number when game started
  stack:       uint256[MAX_SEATS] # stack at each seat (zero for eliminated or all-in players)
  dealer:      uint256            # seat index of current dealer
  hands:       uint256[2][MAX_SEATS] # deck indices of hole cards for each player
  board:       uint256[5]         # board cards
  bet:         uint256[MAX_SEATS] # current round bet of each player
  betIndex:    uint256            # seat index of player who introduced the current bet
  minRaise:    uint256            # size of the minimum raise
  liveUntil:   uint256[MAX_SEATS] # index of first pot player is not live in
  pot:         uint256[MAX_SEATS] # pot and side pots
  potIndex:    uint256            # index of pot being decided in showdown
  actionIndex: uint256            # seat index of currently active player
  actionBlock: uint256            # block from which action was on the active player

nextGameId: uint256
games: HashMap[uint256, Game]

PENDING_REVEAL: constant(uint256) = 53

@external
def selectDealer(_tableId: uint256):
  assert T.authorised(_tableId, Phase_PLAY), "unauthorised"
  gameId: uint256 = T.gameId(_tableId)
  assert self.games[gameId].startBlock == empty(uint256), "already started"
  highestCard: uint256 = empty(uint256)
  highestCardSeatIndex: uint256 = empty(uint256)
  for seatIndex in range(MAX_PLAYERS):
    if seatIndex == T.numPlayers(_tableId):
      break
    self.games[gameId].liveUntil[seatIndex] = 1
    self.games[gameId].stack[seatIndex] = T.buyIn(_tableId)
    card: uint256 = T.cardAt(_tableId, seatIndex)
    if highestCard < card:
      highestCard = card
      highestCardSeatIndex = seatIndex
  self.games[gameId].dealer = highestCardSeatIndex
  self.games[gameId].startBlock = block.number
  T.reshuffle(_tableId)

@external
def dealHoleCards(_tableId: uint256):
  assert T.authorised(_tableId, Phase_PLAY), "unauthorised"
  gameId: uint256 = T.gameId(_tableId)
  assert self.games[gameId].startBlock != empty(uint256), "not started"
  assert T.deckIndex(_tableId) == 0, "already dealt"
  numPlayers: uint256 = T.numPlayers(_tableId)
  seatIndex: uint256 = self.games[gameId].dealer
  self.games[gameId].betIndex = seatIndex
  for i in range(2):
    for _ in range(MAX_SEATS):
      seatIndex = self.roundNextActor(numPlayers, gameId, seatIndex)
      self.games[gameId].hands[seatIndex][i] = T.dealTo(_tableId, seatIndex)
      if seatIndex == self.games[gameId].dealer:
        break
  T.startDeal(_tableId)

@external
def postBlinds(_tableId: uint256):
  assert T.authorised(_tableId, Phase_PLAY), "unauthorised"
  gameId: uint256 = T.gameId(_tableId)
  assert self.games[gameId].startBlock != empty(uint256), "not started"
  assert self.games[gameId].board[0] == empty(uint256), "board not empty"
  assert self.games[gameId].actionBlock == empty(uint256), "already betting"
  numPlayers: uint256 = T.numPlayers(_tableId)
  seatIndex: uint256 = self.roundNextActor(numPlayers, gameId, self.games[gameId].dealer)
  blind: uint256 = self.smallBlind(_tableId)
  self.placeBet(gameId, seatIndex, blind)
  seatIndex = self.roundNextActor(numPlayers, gameId, seatIndex)
  blind = unsafe_add(blind, blind)
  self.placeBet(gameId, seatIndex, blind)
  seatIndex = self.roundNextActor(numPlayers, gameId, seatIndex)
  self.games[gameId].betIndex = seatIndex
  self.games[gameId].minRaise = blind
  self.games[gameId].actionIndex = seatIndex
  self.games[gameId].actionBlock = block.number

@internal
def validateTurn(_tableId: uint256, _seatIndex: uint256, _phase: uint256 = Phase_PLAY) -> uint256:
  assert T.authorised(_tableId, _phase, _seatIndex, msg.sender), "unauthorised"
  gameId: uint256 = T.gameId(_tableId)
  assert self.games[gameId].actionBlock != empty(uint256), "not active"
  assert self.games[gameId].actionIndex == _seatIndex, "wrong turn"
  return gameId

@external
def fold(_tableId: uint256, _seatIndex: uint256):
  gameId: uint256 = self.validateTurn(_tableId, _seatIndex)
  self.games[gameId].liveUntil[_seatIndex] = 0
  self.afterAct(_tableId, gameId, _seatIndex)

@external
def check(_tableId: uint256, _seatIndex: uint256):
  gameId: uint256 = self.validateTurn(_tableId, _seatIndex)
  assert self.games[gameId].bet[self.games[gameId].betIndex] == 0, "bet required"
  self.afterAct(_tableId, gameId, _seatIndex)

@internal
def addSidePot(_numPlayers: uint256, _gameId: uint256, _nextPot: uint256):
  for seatIndex in range(MAX_SEATS):
    if seatIndex == _numPlayers:
      break
    elif self.games[_gameId].stack[seatIndex] == 0:
      continue
    elif self.games[_gameId].liveUntil[seatIndex] == _nextPot:
      self.games[_gameId].liveUntil[seatIndex] = unsafe_add(_nextPot, 1)

@external
def callBet(_tableId: uint256, _seatIndex: uint256):
  gameId: uint256 = self.validateTurn(_tableId, _seatIndex)
  bet: uint256 = self.games[gameId].bet[self.games[gameId].betIndex]
  raiseBy: uint256 = bet - self.games[gameId].bet[_seatIndex]
  assert raiseBy > 0, "nothing to call"
  self.placeBet(gameId, _seatIndex, raiseBy)
  if self.games[gameId].stack[_seatIndex] < raiseBy: # calling all-in with side-pot
    self.addSidePot(T.numPlayers(_tableId), gameId, self.games[gameId].liveUntil[_seatIndex])
  self.afterAct(_tableId, gameId, _seatIndex)

@external
def raiseBet(_tableId: uint256, _seatIndex: uint256, _raiseTo: uint256):
  gameId: uint256 = self.validateTurn(_tableId, _seatIndex)
  bet: uint256 = self.games[gameId].bet[self.games[gameId].betIndex]
  assert _raiseTo > bet, "not a bet/raise"
  raiseBy: uint256 = _raiseTo - bet
  size: uint256 = _raiseTo - self.games[gameId].bet[_seatIndex]
  assert size <= self.games[gameId].stack[_seatIndex], "size exceeds stack"
  self.placeBet(gameId, _seatIndex, size)
  self.games[gameId].betIndex = _seatIndex
  if raiseBy >= self.games[gameId].minRaise:
    self.games[gameId].minRaise = raiseBy
  else: # raising all-in
    assert self.games[gameId].stack[_seatIndex] == 0, "below minimum"
    self.addSidePot(T.numPlayers(_tableId), gameId, self.games[gameId].liveUntil[_seatIndex])
  self.afterAct(_tableId, gameId, _seatIndex)

@external
def dealNextRound(_tableId: uint256):
  assert T.authorised(_tableId, Phase_PLAY), "unauthorised"
  gameId: uint256 = T.gameId(_tableId)
  assert self.games[gameId].board[2] != empty(uint256), "board empty"
  assert self.games[gameId].actionBlock == empty(uint256), "already betting"
  # fill the board with the revealedCards
  boardIndex: uint256 = 5
  cardIndex: uint256 = T.deckIndex(_tableId)
  for _ in range(5):
    boardIndex -= 1
    if self.games[gameId].board[boardIndex] == empty(uint256):
      continue
    elif self.games[gameId].board[boardIndex] == PENDING_REVEAL:
      cardIndex -= 1
      self.games[gameId].board[boardIndex] = T.cardAt(_tableId, cardIndex)
    else:
      break
  self.games[gameId].betIndex = self.games[gameId].dealer
  self.games[gameId].actionIndex = self.roundNextActor(
    T.numPlayers(_tableId), gameId, self.games[gameId].dealer)
  if self.games[gameId].actionIndex == self.games[gameId].dealer:
    # all live players all-in this round
    self.drawNextCard(_tableId, gameId)
  else:
    self.games[gameId].minRaise = unsafe_mul(2, self.smallBlind(_tableId))
    self.games[gameId].betIndex = self.games[gameId].actionIndex
    self.games[gameId].actionBlock = block.number

@external
def actTimeout(_tableId: uint256):
  assert T.authorised(_tableId, Phase_PLAY), "unauthorised"
  gameId: uint256 = T.gameId(_tableId)
  assert self.games[gameId].actionBlock != empty(uint256), "not active"
  assert block.number > (self.games[gameId].actionBlock +
                         T.actBlocks(_tableId)), "deadline not passed"
  self.games[gameId].liveUntil[self.games[gameId].actionIndex] = 0
  self.afterAct(_tableId, gameId, self.games[gameId].actionIndex)

@external
def showCards(_tableId: uint256, _seatIndex: uint256):
  gameId: uint256 = self.validateTurn(_tableId, _seatIndex, Phase_SHOW)
  T.showCard(_tableId, self.games[gameId].hands[_seatIndex][0])
  T.showCard(_tableId, self.games[gameId].hands[_seatIndex][1])
  T.startDeal(_tableId)

@external
def foldCards(_tableId: uint256, _seatIndex: uint256):
  gameId: uint256 = self.validateTurn(_tableId, _seatIndex, Phase_SHOW)
  self.games[gameId].liveUntil[_seatIndex] = 0

@external
def endShow(_tableId: uint256):
  assert T.authorised(_tableId, Phase_SHOW)
  gameId: uint256 = T.gameId(_tableId)
  seatIndex: uint256 = self.games[gameId].actionIndex
  assert (self.games[gameId].liveUntil[seatIndex] == 0 or
    (T.cardAt(_tableId, self.games[gameId].hands[seatIndex][0]) != empty(uint256) and
     T.cardAt(_tableId, self.games[gameId].hands[seatIndex][1]) != empty(uint256))), "action required"
  numPlayers: uint256 = T.numPlayers(_tableId)
  self.games[gameId].actionIndex = self.nextInPot(numPlayers, gameId, seatIndex)
  if self.games[gameId].actionIndex == self.games[gameId].betIndex:
    bestHandRank: uint256 = 0
    hand: uint256[7] = [self.games[gameId].board[0],
                        self.games[gameId].board[1],
                        self.games[gameId].board[2],
                        self.games[gameId].board[3],
                        self.games[gameId].board[4],
                        0, 0]
    winners: DynArray[uint256, MAX_SEATS] = []
    for contestantIndex in range(MAX_SEATS):
      if contestantIndex == numPlayers:
        break
      if self.games[gameId].liveUntil[contestantIndex] <= self.games[gameId].potIndex:
        continue
      hand[5] = T.cardAt(_tableId, self.games[gameId].hands[contestantIndex][0])
      hand[6] = T.cardAt(_tableId, self.games[gameId].hands[contestantIndex][1])
      handRank: uint256 = self.bestHandRank(hand)
      if bestHandRank < handRank:
        winners = [contestantIndex]
      elif bestHandRank == handRank:
        winners.append(contestantIndex)
    potIndex: uint256 = self.games[gameId].potIndex
    share: uint256 = unsafe_div(self.games[gameId].pot[potIndex], len(winners))
    for winnerIndex in winners:
      self.games[gameId].pot[potIndex] = unsafe_sub(self.games[gameId].pot[potIndex], share)
      self.games[gameId].stack[winnerIndex] = unsafe_add(self.games[gameId].stack[winnerIndex], share)
      self.games[gameId].liveUntil[winnerIndex] = unsafe_sub(self.games[gameId].liveUntil[winnerIndex], 1)
    # odd chip(s) to be distributed according to overall card rank
    if self.games[gameId].pot[potIndex] != 0:
      for negCard in range(52):
        card: uint256 = unsafe_sub(52, negCard)
        for winnerIndex in winners:
          if (T.cardAt(_tableId, self.games[gameId].hands[winnerIndex][0]) == card or
              T.cardAt(_tableId, self.games[gameId].hands[winnerIndex][1]) == card):
            self.games[gameId].pot[potIndex] = unsafe_sub(self.games[gameId].pot[potIndex], 1)
            self.games[gameId].stack[winnerIndex] = unsafe_add(self.games[gameId].stack[winnerIndex], 1)
            if self.games[gameId].pot[potIndex] == 0:
              break
        if self.games[gameId].pot[potIndex] == 0:
          break
    if potIndex != 0:
      self.games[gameId].potIndex = unsafe_sub(potIndex, 1)
      if self.games[gameId].liveUntil[self.games[gameId].actionIndex] <= self.games[gameId].potIndex:
        self.games[gameId].actionIndex = self.nextInPot(numPlayers, gameId, self.games[gameId].actionIndex)
      self.games[gameId].actionBlock = block.number
    elif self.playersLeft(numPlayers, gameId) <= T.maxPlayers(_tableId):
      self.gameOver(numPlayers, _tableId, gameId)
    else:
      self.removeEliminated(numPlayers, _tableId, gameId)
      T.reshuffle(_tableId)
  else:
    self.games[gameId].actionBlock = block.number

@internal
def collectPots(_numPlayers: uint256, _gameId: uint256):
  maxLiveUntil: uint256 = 0
  for seatIndex in range(MAX_SEATS):
    if seatIndex == _numPlayers:
      break
    maxLiveUntil = max(maxLiveUntil, self.games[_gameId].liveUntil[seatIndex])
  for potIndex in range(MAX_SEATS):
    if potIndex == maxLiveUntil:
      break
    minBet: uint256 = max_value(uint256)
    for seatIndex in range(MAX_SEATS):
      if seatIndex == _numPlayers:
        break
      if potIndex < self.games[_gameId].liveUntil[seatIndex]:
        minBet = min(minBet, self.games[_gameId].bet[seatIndex])
    for seatIndex in range(MAX_SEATS):
      if seatIndex == _numPlayers:
        break
      if potIndex < self.games[_gameId].liveUntil[seatIndex]:
        self.games[_gameId].bet[seatIndex] = unsafe_sub(self.games[_gameId].bet[seatIndex], minBet)
        self.games[_gameId].pot[potIndex] = unsafe_add(self.games[_gameId].pot[potIndex], minBet)

@internal
def settleUncontested(_numPlayers: uint256, _gameId: uint256) -> uint256:
  numContested: uint256 = 0
  potPlayers: uint256[MAX_SEATS] = empty(uint256[MAX_SEATS])
  contestant: uint256[MAX_SEATS] = empty(uint256[MAX_SEATS])
  for seatIndex in range(MAX_SEATS):
    if seatIndex == _numPlayers:
      break
    for potIndex in range(MAX_SEATS):
      if potIndex == self.games[_gameId].liveUntil[seatIndex]:
        break
      potPlayers[potIndex] = unsafe_add(potPlayers[potIndex], 1)
      contestant[potIndex] = seatIndex
  for potIndex in range(MAX_SEATS):
    if potPlayers[potIndex] == 0:
      break
    elif potPlayers[potIndex] == 1:
      self.games[_gameId].stack[contestant[potIndex]] = unsafe_add(
        self.games[_gameId].stack[contestant[potIndex]],
        self.games[_gameId].pot[potIndex])
      self.games[_gameId].pot[potIndex] = empty(uint256)
    else:
      numContested = unsafe_add(numContested, 1)
  return numContested

@internal
def removeEliminated(_numPlayers: uint256, _tableId: uint256, _gameId: uint256):
  for seatIndex in range(MAX_SEATS):
    if seatIndex == _numPlayers:
      break
    if self.games[_gameId].stack[seatIndex] == empty(uint256):
      T.setPresence(_tableId, seatIndex, False)

@internal
@view
def playersLeft(_numPlayers: uint256, _gameId: uint256) -> uint256:
  playersLeft: uint256 = 0
  for seatIndex in range(MAX_SEATS):
    if seatIndex == _numPlayers:
      break
    if self.games[_gameId].stack[seatIndex] != empty(uint256):
      playersLeft = unsafe_add(playersLeft, 1)
  return playersLeft

@internal
def gameOver(_numPlayers: uint256, _tableId: uint256, _gameId: uint256):
  # everyone gets their stack + bond
  for seatIndex in range(MAX_SEATS):
    if seatIndex == _numPlayers:
      break
    T.refundPlayer(_tableId, seatIndex, self.games[_gameId].stack[seatIndex])
  # delete the game
  self.games[_gameId] = empty(Game)
  T.deleteTable(_tableId)

@internal
def drawNextCard(_tableId: uint256, _gameId: uint256):
  T.burnCard(_tableId)
  if self.games[_gameId].board[0] == empty(uint256): # flop
    for boardIndex in range(3):
      self.drawToBoard(_tableId, _gameId, boardIndex)
  elif self.games[_gameId].board[3] == empty(uint256): # turn
    self.drawToBoard(_tableId, _gameId, 3)
  else: # river
    self.drawToBoard(_tableId, _gameId, 4)
  T.startDeal(_tableId)

@internal
def afterAct(_tableId: uint256, _gameId: uint256, _seatIndex: uint256):
  self.games[_gameId].actionIndex = self.roundNextActor(_tableId, _gameId, _seatIndex)
  if self.games[_gameId].actionIndex == self.games[_gameId].betIndex:
    # nobody is left to act in this round
    # move bets to pots
    numPlayers: uint256 = T.numPlayers(_tableId)
    self.collectPots(numPlayers, _gameId)
    # settle uncontested pots
    numContested: uint256 = self.settleUncontested(numPlayers, _gameId)
    if numContested == 0: # hand is over
      if self.playersLeft(numPlayers, _gameId) <= T.maxPlayers(_tableId):
        self.gameOver(numPlayers, _tableId, _gameId)
      else:
        self.removeEliminated(numPlayers, _tableId, _gameId)
        T.reshuffle(_tableId)
    elif self.games[_gameId].board[4] == empty(uint256):
      self.drawNextCard(_tableId, _gameId)
    else:
      # showdown to settle remaining pots
      T.startShow(_tableId)
      # advance actionIndex till the first player in the rightmost pot
      self.games[_gameId].potIndex = self.rightmostPot(_gameId)
      if self.games[_gameId].liveUntil[self.games[_gameId].actionIndex] <= self.games[_gameId].potIndex:
        self.games[_gameId].actionIndex = self.nextInPot(numPlayers, _gameId, self.games[_gameId].actionIndex)
      self.games[_gameId].actionBlock = block.number
  else:
    # a player is still left to act in this round
    # pass action to them and set new actionBlock
    self.games[_gameId].actionBlock = block.number

@internal
@view
def rightmostPot(gameId: uint256) -> uint256:
  potIndex: uint256 = 0
  for _ in range(MAX_SEATS):
    nextPotIndex: uint256 = unsafe_add(potIndex, 1)
    if self.games[gameId].pot[nextPotIndex] == 0:
      break
    else:
      potIndex = nextPotIndex
  return potIndex

@internal
def drawToBoard(_tableId: uint256, _gameId: uint256, _boardIndex: uint256):
  cardIndex: uint256 = T.dealTo(_tableId, self.games[_gameId].betIndex)
  T.showCard(_tableId, cardIndex)
  self.games[_gameId].board[_boardIndex] = PENDING_REVEAL

@internal
@view
def nextInPot(_numPlayers: uint256, _gameId: uint256, _seatIndex: uint256) -> uint256:
  nextIndex: uint256 = _seatIndex
  for _ in range(MAX_SEATS):
    nextIndex = uint256_addmod(nextIndex, 1, _numPlayers)
    if (self.games[_gameId].potIndex < self.games[_gameId].liveUntil[nextIndex] or
        nextIndex == self.games[_gameId].betIndex):
      return nextIndex
  raise "betIndex not found"

@internal
@view
def roundNextActor(_numPlayers: uint256, _gameId: uint256, _seatIndex: uint256) -> uint256:
  nextIndex: uint256 = _seatIndex
  for _ in range(MAX_SEATS):
    nextIndex = uint256_addmod(nextIndex, 1, _numPlayers)
    if (nextIndex == self.games[_gameId].betIndex or
        self.games[_gameId].stack[nextIndex] != empty(uint256)):
      return nextIndex
  raise "betIndex not found"

@internal
@view
def smallBlind(_tableId: uint256) -> uint256:
  gameId: uint256 = T.gameId(_tableId)
  levelBlocks: uint256 = T.levelBlocks(_tableId)
  level: uint256 = empty(uint256)
  if self.games[gameId].startBlock + MAX_LEVELS * levelBlocks < block.number:
    level = ((block.number - self.games[gameId].startBlock) / levelBlocks)
  else:
    level = MAX_LEVELS - 1
  for _ in range(MAX_LEVELS):
    if T.level(_tableId, level) == empty(uint256):
      level -= 1
    else:
      break
  return T.level(_tableId, level)

@internal
def placeBet(_gameId: uint256, _seatIndex: uint256, _size: uint256):
  amount: uint256 = min(_size, self.games[_gameId].stack[_seatIndex])
  self.games[_gameId].stack[_seatIndex] = unsafe_sub(self.games[_gameId].stack[_seatIndex], amount)
  self.games[_gameId].bet[_seatIndex] = unsafe_add(self.games[_gameId].bet[_seatIndex], amount)

# hand rankings

# linear ordering on all 5-card hands
# lexicographic on uint256, higher is better
# 1 byte (8 bits) for each component of the 6-tuple, most significant first
# straight flush:  (9, rank of highest card, 0,              0,          0,          0)
# four of a kind:  (8, rank of quad,         rank of kicker, 0,          0,          0)
# full house:      (7, rank of triplet,      rank of pair,   0,          0,          0)
# flush:           (6, 1st rank,             2nd,            3rd,        4th,        5th)
# straight:        (5, rank of highest card, 0,              0,          0,          0)
# three of a kind: (4, rank of triplet,      1st kicker,     2nd kicker, 0,          0)
# two pair:        (3, rank of highest pair, 2nd pair,       kicker,     0,          0)
# pair:            (2, rank of pair,         1st kicker,     2nd kicker, 3rd kicker, 0)
# high card:       (1, 1st rank,             2nd,            3rd,        4th,        5th)

@internal
@pure
def handRank(hand: uint256[13]) -> uint256:
  straight: uint256 = self.checkStraight(hand)
  flush: uint256 = self.checkFlush(hand)
  if straight != 0 and flush != 0:
    return shift(9, 5 * 8) | shift(straight, 4 * 8)
  ranks: DynArray[uint256, 5][4] = self.getRanksByCount(hand)
  if len(ranks[3]) != 0:
    return shift(8, 5 * 8) | shift(ranks[3][0], 4 * 8) | shift(ranks[0][0], 3 * 8)
  if len(ranks[2]) != 0 and len(ranks[1]) != 0:
    return shift(7, 5 * 8) | shift(ranks[2][0], 4 * 8) | shift(ranks[1][0], 3 * 8)
  if flush != 0:
    return shift(6, 5 * 8) | (
      shift(ranks[0][4], 4 * 8) |
      shift(ranks[0][3], 3 * 8) |
      shift(ranks[0][2], 2 * 8) |
      shift(ranks[0][1], 1 * 8) |
      shift(ranks[0][0], 0 * 8))
  if straight != 0:
    return shift(5, 5 * 8) | shift(straight, 4 * 8)
  if len(ranks[2]) != 0:
    return shift(4, 5 * 8) | (
      shift(ranks[2][0], 4 * 8) |
      shift(ranks[0][1], 3 * 8) |
      shift(ranks[0][0], 2 * 8))
  if len(ranks[1]) == 2:
    return shift(3, 5 * 8) | (
      shift(ranks[1][1], 4 * 8) |
      shift(ranks[1][0], 3 * 8) |
      shift(ranks[0][0], 2 * 8))
  if len(ranks[1]) == 1:
    return shift(2, 5 * 8) | (
      shift(ranks[1][0], 4 * 8) |
      shift(ranks[0][2], 3 * 8) |
      shift(ranks[0][1], 2 * 8) |
      shift(ranks[0][0], 1 * 8))
  return shift(1, 5 * 8) | (
           shift(ranks[0][4], 4 * 8) |
           shift(ranks[0][3], 3 * 8) |
           shift(ranks[0][2], 2 * 8) |
           shift(ranks[0][1], 1 * 8) |
           shift(ranks[0][0], 0 * 8))

@internal
@pure
def getRanksByCount(hand: uint256[13]) -> DynArray[uint256, 5][4]:
  result: DynArray[uint256, 5][4] = [[], [], [], []]
  for rank in range(13):
    count: uint256 = self.suitCount(hand[rank])
    if count != 0:
      result[unsafe_sub(count, 1)].append(rank)
  return result

@internal
@pure
# return highest rank in straight, or 0
def checkStraight(hand: uint256[13]) -> uint256:
  count: uint256 = 0
  if hand[12] != 0:
    count = unsafe_add(count, 1)
  for i in range(13):
    if hand[i] != 0:
      count = unsafe_add(count, 1)
    else:
      count = 0
    if count == 5:
      return i
  return 0

@internal
@pure
# return 1 + suit of flush, or 0
def checkFlush(hand: uint256[13]) -> uint256:
  count: uint256[4] = empty(uint256[4])
  for i in range(13):
    bit: uint256 = 1
    for suit in range(4):
      if hand[i] & bit != 0:
        count[suit] = unsafe_add(count[suit], 1)
        if (count[suit] == 5):
          return unsafe_add(suit, 1)
      bit = shift(bit, 1)
  return 0

@internal
@pure
def rank(card: uint256) -> uint256:
  return unsafe_sub(card, 1) % 13

@internal
@pure
# TODO: convert to int128 because of this bug
# https://github.com/vyperlang/vyper/issues/3309
def suit(card: uint256) -> int128:
  return convert(unsafe_div(unsafe_sub(card, 1), 13), int128)

@internal
@pure
def suitCount(suits: uint256) -> uint256:
  count: uint256 = 0
  bit: uint256 = 1
  for _ in range(4):
    if suits & bit != 0:
      count = unsafe_add(count, 1)
    bit = shift(bit, 1)
  return count

@internal
@pure
def bestHandRank(cards: uint256[7]) -> uint256:
  hand: uint256[13] = empty(uint256[13])
  for i in range(7):
    hand[self.rank(cards[i])] |= shift(1, self.suit(cards[i]))
  bestRank: uint256 = 0
  for i in range(7):
    hand[self.rank(cards[i])] ^= shift(1, self.suit(cards[i]))
    for delta in range(7):
      j: uint256 = unsafe_add(unsafe_add(i, delta), 1)
      if j == 7:
        break
      hand[self.rank(cards[j])] ^= shift(1, self.suit(cards[j]))
      bestRank = max(bestRank, self.handRank(hand))
      hand[self.rank(cards[j])] ^= shift(1, self.suit(cards[j]))
    hand[self.rank(cards[i])] ^= shift(1, self.suit(cards[i]))
  return bestRank
