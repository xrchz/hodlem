# @version ^0.3.8
# no-limit hold'em sit-n-go single-table tournaments

# copied from Deck.vy because https://github.com/vyperlang/vyper/issues/2670
MAX_SIZE: constant(uint256) = 9000
MAX_PLAYERS: constant(uint256) = 8000 # to distinguish from MAX_SIZE when inlining
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
import Deck as DeckManager

# copied from Table.vy
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

Phase_JOIN:    constant(uint256) = 0 # before the game has started, taking seats
Phase_PREP:    constant(uint256) = 1 # all players seated, preparing the deck
Phase_SHUFFLE: constant(uint256) = 2 # submitting shuffles and verifications in order
Phase_DEAL:    constant(uint256) = 3 # drawing and possibly opening cards as currently required
Phase_PLAY:    constant(uint256) = 4 # betting; new card revelations may become required
Phase_SHOW:    constant(uint256) = 5 # showdown TODO
# end copy
import Table as TableManager

T: immutable(TableManager)

@external
def __init__(tableAddress: address):
  T = TableManager(tableAddress)

# TODO: add rake (rewards tabs for progress txns)?
# TODO: add penalties (instead of full abort on failure)?

struct Game:
  startBlock:  uint256            # block number when game started
  stack:       uint256[MAX_SEATS] # stack at each seat (zero for eliminated or all-in players)
  dealer:      uint256            # seat index of current dealer
  board:       uint256[5]         # board cards
  bet:         uint256[MAX_SEATS] # current round bet of each player
  betIndex:    uint256            # seat index of player who introduced the current bet
  minRaise:    uint256            # size of the minimum raise
  liveUntil:   uint256[MAX_SEATS] # index of first pot player is not live in
  pot:         uint256[MAX_SEATS] # pot and side pots
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
  for __ in range(2):
    for _ in range(MAX_SEATS):
      seatIndex = self.roundNextActor(numPlayers, gameId, seatIndex)
      T.dealTo(_tableId, seatIndex)
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
def validateTurn(_tableId: uint256, _seatIndex: uint256) -> uint256:
  assert T.authorised(_tableId, Phase_PLAY, _seatIndex, msg.sender), "unauthorised"
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
    # TODO: set next cards to reveal (similar to afterAct)
    pass
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
def afterAct(_tableId: uint256, _gameId: uint256, _seatIndex: uint256):
  self.games[_gameId].actionIndex = self.roundNextActor(_tableId, _gameId, _seatIndex)
  if self.games[_gameId].actionIndex == self.games[_gameId].betIndex:
    # nobody is left to act in this round
    # move bets to pots
    numPlayers: uint256 = T.numPlayers(_tableId)
    self.collectPots(numPlayers, _gameId)
    # settle uncontested pots
    numContested: uint256 = self.settleUncontested(numPlayers, _gameId)
    if numContested == 0:
      # round is over
      if self.playersLeft(numPlayers, _gameId) <= T.maxPlayers(_tableId):
        # game is over
        # everyone gets their stack
        # and refund all bonds
        for seatIndex in range(MAX_SEATS):
          if seatIndex == numPlayers:
            break
          T.refundPlayer(_tableId, seatIndex, self.games[_gameId].stack[seatIndex])
        # delete the game
        self.games[_gameId] = empty(Game)
        T.deleteTable(_tableId)
      else:
        pass
        # prepare new shuffle for next hand
    elif self.games[_gameId].board[4] == empty(uint256):
      pass
      # there are board cards to come
      # prepare another round of betting to settle remaining pots
    else:
      pass
      # showdown to settle remaining pots
      # each remaining player shows cards or mucks (+ folds) in turn
      # all remaining players compete for best hands
      # best hands split the pot
  else:
    # a player is still left to act in this round
    # pass action to them and set new actionBlock
    self.games[_gameId].actionBlock = block.number

# @internal
# def drawToBoard(_tableId: uint256, _boardIndex: uint256):
#   self.tables[_tableId].drawIndex[
#     self.tables[_tableId].hand.deckIndex] = self.tables[_tableId].hand.betIndex
#   self.tables[_tableId].requirement[
#     self.tables[_tableId].hand.deckIndex] = Req_SHOW
#   self.tables[_tableId].deck.drawCard(
#     self.tables[_tableId].deckId,
#     self.tables[_tableId].hand.betIndex,
#     self.tables[_tableId].hand.deckIndex)
#   self.autoDecrypt(_tableId, self.tables[_tableId].hand.deckIndex)
#   self.tables[_tableId].hand.board[_boardIndex] = PENDING_REVEAL
#   self.tables[_tableId].hand.deckIndex = unsafe_add(self.tables[_tableId].hand.deckIndex, 1)

#@internal
#def actNext(_tableId: uint256, _seatIndex: uint256):
#  # check if the round is complete
#  if self.tables[_tableId].hand.actionIndex == self.tables[_tableId].hand.betIndex:
#    # collect pot
#    for seatIndex in range(MAX_SEATS):
#      if seatIndex == self.tables[_tableId].config.startsWith:
#        break
#      self.tables[_tableId].hand.pot += self.tables[_tableId].hand.bet[seatIndex]
#      self.tables[_tableId].hand.bet[seatIndex] = 0
#    if self.tables[_tableId].hand.board[4] != empty(uint256):
#      # check if
#    else:
#      # burn card
#      self.tables[_tableId].hand.deckIndex = unsafe_add(self.tables[_tableId].hand.deckIndex, 1)
#      # reveal next round's card(s)
#      if self.tables[_tableId].hand.board[0] == empty(uint256): # flop
#        for boardIndex in range(3): self.drawToBoard(_tableId, boardIndex)
#      elif self.tables[_tableId].hand.board[3] == empty(uint256): # turn
#        self.drawToBoard(_tableId, 3)
#      else: # river
#        self.drawToBoard(_tableId, 4)
#      self.tables[_tableId].hand.actionBlock = empty(uint256)
#      self.tables[_tableId].phase = Phase_DEAL
#      self.tables[_tableId].commitBlock = block.number
#  else:
#    # TODO: handle next player being all-in
#    self.tables[_tableId].hand.actionBlock = block.number
#
#@internal
#def foldNext(_tableId: uint256, _seatIndex: uint256):
#  self.tables[_tableId].hand.actionIndex = self.nextPlayer(_tableId, _seatIndex, False)
#  self.tables[_tableId].hand.live[_seatIndex] = False
#  if self.tables[_tableId].hand.actionIndex == self.tables[_tableId]
#       _tableId, self.tables[_tableId].hand.actionIndex):
#    # actionIndex wins the round as last player standing
#    # give the winner the pot
#    self.tables[_tableId].stacks[
#      self.tables[_tableId].hand.actionIndex] += self.tables[_tableId].hand.pot
#    self.tables[_tableId].hand.pot = 0
#    # (eliminate any all-in players -- impossible as only winner left standing)
#    # (check if untilLeft is reached -- impossible as nobody was eliminated)
#    # progress the dealer
#    for seatIndex in range(MAX_SEATS):
#      if seatIndex == self.tables[_tableId].config.startsWith:
#        break
#      self.tables[_tableId].hand.live[seatIndex] = self.tables[_tableId].stacks[seatIndex] > 0
#    self.tables[_tableId].hand.dealer = self.nextPlayer(
#      _tableId, self.tables[_tableId].hand.dealer)
#    # clear board and reshuffle
#    self.tables[_tableId].hand.actionBlock = empty(uint256)
#    self.tables[_tableId].hand.board = empty(uint256[5])
#    self.tables[_tableId].requirement = empty(uint256[26])
#    self.tables[_tableId].hand.deckIndex = 0
#    self.tables[_tableId].deck.resetShuffle(self.tables[_tableId].deckId)
#    self.tables[_tableId].phase = Phase_SHUFFLE
#    self.autoShuffle(_tableId)
#  else:
#    self.tables[_tableId].hand.actionBlock = block.number

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
