# @version ^0.3.7
# no-limit hold'em sit-n-go single-table tournaments

# TODO: finish frontend
# TODO: add pause?
# TODO: add rake (rewards tabs for progress txns)?
# TODO: add penalties (instead of full abort on failure)?

# copied from Deck.vy because https://github.com/vyperlang/vyper/issues/2670
MAX_PLAYERS: constant(uint256) = 127 # to distinguish from MAX_SIZE when inlining

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

# copied from Room.vy
MAX_SEATS:  constant(uint256) =   9 # maximum seats per table
MAX_LEVELS: constant(uint256) = 100 # maximum number of levels in tournament structure

struct Config:
  buyIn:       uint256             # entry ticket price per player
  bond:        uint256             # liveness bond for each player
  startsWith:  uint256             # game can start when this many players are seated
  untilLeft:   uint256             # game ends when this many players are left
  structure:   DynArray[uint256, MAX_LEVELS] # small blind levels
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

import Room as RoomManager
T: immutable(RoomManager)

@external
def __init__(roomAddress: address):
  T = RoomManager(roomAddress)

@external
@view
def roomAddress() -> address:
  return T.address

struct Game:
  startBlock:  uint256            # block number when game started
  stack:       uint256[MAX_SEATS] # stack at each seat (zero for eliminated or all-in players)
  dealer:      uint256            # seat index of current dealer
  hands:       uint256[2][MAX_SEATS] # deck indices of hole cards for each player
  board:       uint256[5]         # board cards
  bet:         uint256[MAX_SEATS] # current round bet of each player
  betIndex:    uint256            # seat index of player who introduced the current bet
  stopIndex:   uint256            # seat index of first player with no need to act this round
  minRaise:    uint256            # size of the minimum raise
  liveUntil:   uint256[MAX_SEATS] # index of first pot player is not live in
  pot:         uint256[MAX_SEATS] # pot and side pots
  numInHand:   uint256            # number of live players in this hand
  untilPot:    uint256            # 1 + index of rightmost pot
  actionIndex: uint256            # seat index of currently active player
  actionBlock: uint256            # block from which action was on the active player

games: public(HashMap[uint256, Game])

PENDING_REVEAL: constant(uint256) = 53

@external
def afterShuffle(_tableId: uint256):
  assert T.address == msg.sender, "unauthorised"
  if self.games[_tableId].startBlock == empty(uint256):
    self.dealHighCard(_tableId)
  else:
    self.dealHoleCards(_tableId)

@internal
def dealHighCard(_tableId: uint256):
  numPlayers: uint256 = T.numPlayers(_tableId)
  for seatIndex in range(MAX_SEATS):
    if seatIndex == numPlayers: break
    T.showCard(_tableId, T.dealTo(_tableId, seatIndex))
  T.startDeal(_tableId, Phase_PLAY)

event DealRound:
  table: indexed(uint256)
  street: indexed(uint256)

@internal
def dealHoleCards(_tableId: uint256):
  numPlayers: uint256 = T.numPlayers(_tableId)
  log DealRound(_tableId, 1)
  dealer: uint256 = self.games[_tableId].dealer
  seatIndex: uint256 = dealer
  for i in range(2):
    for _ in range(MAX_SEATS):
      seatIndex = self.roundNextActor(numPlayers, _tableId, seatIndex, dealer)
      self.games[_tableId].hands[seatIndex][i] = T.dealTo(_tableId, seatIndex)
      if seatIndex == dealer:
        break
  T.startDeal(_tableId, Phase_PLAY)

event SelectDealer:
  table: indexed(uint256)
  seat: indexed(uint256)

@internal
def selectDealer(_tableId: uint256):
  numPlayers: uint256 = T.numPlayers(_tableId)
  highestRank: uint256 = empty(uint256)
  highestSuit: uint256 = empty(uint256)
  highestCardSeatIndex: uint256 = empty(uint256)
  for seatIndex in range(MAX_PLAYERS):
    if seatIndex == numPlayers:
      break
    self.games[_tableId].liveUntil[seatIndex] = 1
    self.games[_tableId].stack[seatIndex] = T.buyIn(_tableId)
    card: uint256 = unsafe_sub(T.cardAt(_tableId, seatIndex), 1)
    rank: uint256 = unsafe_add(card % 13, 1)
    suit: uint256 = unsafe_div(card, 13)
    if highestRank < rank or (highestRank == rank and highestSuit < suit):
      highestRank = rank
      highestSuit = suit
      highestCardSeatIndex = seatIndex
  self.games[_tableId].untilPot = 1
  self.games[_tableId].numInHand = numPlayers
  self.games[_tableId].startBlock = block.number
  T.reshuffle(_tableId)
  self.games[_tableId].dealer = highestCardSeatIndex
  log SelectDealer(_tableId, highestCardSeatIndex)

event PostBlind:
  table: indexed(uint256)
  seat: indexed(uint256)
  bet: uint256
  placed: uint256

@internal
def postBlinds(_tableId: uint256):
  assert T.authorised(_tableId, Phase_PLAY), "unauthorised"
  assert self.games[_tableId].startBlock != empty(uint256), "not started"
  assert self.games[_tableId].board[0] == empty(uint256), "board not empty"
  assert self.games[_tableId].actionBlock == empty(uint256), "already betting"
  numPlayers: uint256 = T.numPlayers(_tableId)
  dealer: uint256 = self.games[_tableId].dealer
  seatIndex: uint256 = self.roundNextActor(numPlayers, _tableId, dealer, dealer)
  blind: uint256 = self.smallBlind(_tableId)
  placed: uint256 = self.placeBet(_tableId, seatIndex, blind)
  log PostBlind(_tableId, seatIndex, blind, placed)
  seatIndex = self.roundNextActor(numPlayers, _tableId, seatIndex, dealer)
  blind = unsafe_add(blind, blind)
  placed = self.placeBet(_tableId, seatIndex, blind)
  log PostBlind(_tableId, seatIndex, blind, placed)
  self.games[_tableId].betIndex = seatIndex
  self.games[_tableId].minRaise = blind
  self.games[_tableId].actionIndex = self.roundNextActor(numPlayers, _tableId, seatIndex, seatIndex)
  self.games[_tableId].stopIndex = self.games[_tableId].actionIndex
  self.games[_tableId].actionBlock = block.number

@internal
def validateTurn(_tableId: uint256, _seatIndex: uint256, _phase: uint256 = Phase_PLAY):
  assert T.authorised(_tableId, _phase, _seatIndex, msg.sender), "unauthorised"
  assert self.games[_tableId].actionBlock != empty(uint256), "not active"
  assert self.games[_tableId].actionIndex == _seatIndex, "wrong turn"

@internal
def removeFromPots(_tableId: uint256, _seatIndex: uint256):
  self.games[_tableId].liveUntil[_seatIndex] = 0
  assert self.games[_tableId].numInHand != 0, "TODO: internal consistency check removeFromPots"
  self.games[_tableId].numInHand = unsafe_sub(
    self.games[_tableId].numInHand, 1)

event Fold:
  table: indexed(uint256)
  seat: indexed(uint256)

@external
def fold(_tableId: uint256, _seatIndex: uint256):
  self.validateTurn(_tableId, _seatIndex)
  self.removeFromPots(_tableId, _seatIndex)
  log Fold(_tableId, _seatIndex)
  self.afterAct(_tableId, _seatIndex)

event CallBet:
  table: indexed(uint256)
  seat: indexed(uint256)
  bet: uint256
  placed: uint256

@external
def callBet(_tableId: uint256, _seatIndex: uint256):
  self.validateTurn(_tableId, _seatIndex)
  bet: uint256 = self.games[_tableId].bet[self.games[_tableId].betIndex]
  raiseBy: uint256 = unsafe_sub(bet, self.games[_tableId].bet[_seatIndex])
  placed: uint256 = 0
  if 0 < raiseBy:
    placed = self.placeBet(_tableId, _seatIndex, raiseBy)
  log CallBet(_tableId, _seatIndex, bet, placed)
  self.afterAct(_tableId, _seatIndex)

event RaiseBet:
  table: indexed(uint256)
  seat: indexed(uint256)
  bet: uint256
  placed: uint256

@external
def raiseBet(_tableId: uint256, _seatIndex: uint256, _raiseTo: uint256):
  self.validateTurn(_tableId, _seatIndex)
  bet: uint256 = self.games[_tableId].bet[self.games[_tableId].betIndex]
  assert _raiseTo > bet, "not a bet/raise"
  raiseBy: uint256 = _raiseTo - bet
  size: uint256 = _raiseTo - self.games[_tableId].bet[_seatIndex]
  assert self.placeBet(_tableId, _seatIndex, size) == size, "size exceeds stack"
  self.games[_tableId].betIndex = _seatIndex
  self.games[_tableId].stopIndex = _seatIndex
  if raiseBy >= self.games[_tableId].minRaise:
    self.games[_tableId].minRaise = raiseBy
  else: # raising all-in
    assert self.games[_tableId].stack[_seatIndex] == 0, "below minimum"
  log RaiseBet(_tableId, _seatIndex, _raiseTo, size)
  self.afterAct(_tableId, _seatIndex)

@external
def afterDeal(_tableId: uint256, _phase: uint256):
  assert T.address == msg.sender, "unauthorised"
  if _phase == Phase_PLAY:
    if self.games[_tableId].startBlock == empty(uint256):
      self.selectDealer(_tableId)
    elif self.games[_tableId].board[0] == empty(uint256):
      if self.games[_tableId].actionBlock == empty(uint256):
        self.postBlinds(_tableId)
      else:
        raise "internal consistency failure afterDeal play"
    else:
      # fill board with revealed cards
      for boardIndex in range(5):
        b: uint256 = self.games[_tableId].board[boardIndex]
        if PENDING_REVEAL <= b:
          cardIndex: uint256 = unsafe_sub(b, PENDING_REVEAL)
          self.games[_tableId].board[boardIndex] = T.cardAt(_tableId, cardIndex)
        elif b == 0: break
      if self.games[_tableId].actionBlock == empty(uint256):
          # skip to showdown when all but at most one players are all-in
          dealer: uint256 = self.games[_tableId].dealer
          self.games[_tableId].actionIndex = dealer
          self.afterAct(_tableId, dealer)
      else:
        self.games[_tableId].actionBlock = block.number
  elif _phase == Phase_SHOW:
    self.autoShow(T.numPlayers(_tableId), _tableId)
  else:
    raise "internal consistency failure afterDeal"

event Timeout:
  table: indexed(uint256)
  seat: indexed(uint256)

@external
def actTimeout(_tableId: uint256):
  assert T.authorised(_tableId, Phase_PLAY), "unauthorised"
  assert self.games[_tableId].actionBlock != empty(uint256), "not active"
  assert block.number > (self.games[_tableId].actionBlock +
                         T.actBlocks(_tableId)), "deadline not passed"
  seatIndex: uint256 = self.games[_tableId].actionIndex
  self.removeFromPots(_tableId, seatIndex)
  log Timeout(_tableId, seatIndex)
  self.afterAct(_tableId, seatIndex)

@internal
def showHand(_tableId: uint256, _seatIndex: uint256):
  T.showCard(_tableId, self.games[_tableId].hands[_seatIndex][0])
  T.showCard(_tableId, self.games[_tableId].hands[_seatIndex][1])

@external
def showCards(_tableId: uint256, _seatIndex: uint256, _data: uint256[7][2]):
  self.validateTurn(_tableId, _seatIndex, Phase_SHOW)
  self.showHand(_tableId, _seatIndex)
  T.gameRevealCards(_tableId, _seatIndex, _data)

@external
def foldCards(_tableId: uint256, _seatIndex: uint256):
  self.validateTurn(_tableId, _seatIndex, Phase_SHOW)
  self.removeFromPots(_tableId, _seatIndex)
  log Fold(_tableId, _seatIndex)
  self.autoShow(T.numPlayers(_tableId), _tableId)

event ShowHand:
  table: indexed(uint256)
  seat: indexed(uint256)
  rank: uint256

@internal
@view
def hasCard(_tableId: uint256, _seatIndex: uint256, _suit: int128, _rank: uint256) -> bool:
  for i in range(2):
    card: uint256 = T.cardAt(_tableId, self.games[_tableId].hands[_seatIndex][i])
    if self.rank(card) == _rank and self.suit(card) == _suit:
      return True
  return False

@internal
def decidePot(_numPlayers: uint256, _stopIndex: uint256,
              _untilPot: uint256, _tableId: uint256) -> uint256:
  bestHandRank: uint256 = 0
  hand: uint256[7] = [self.games[_tableId].board[0],
                      self.games[_tableId].board[1],
                      self.games[_tableId].board[2],
                      self.games[_tableId].board[3],
                      self.games[_tableId].board[4],
                      0, 0]
  winners: DynArray[uint256, MAX_SEATS] = []
  potIndex: uint256 = unsafe_sub(_untilPot, 1)
  for contestantIndex in range(MAX_SEATS):
    if contestantIndex == _numPlayers:
      break
    liveUntil: uint256 = self.games[_tableId].liveUntil[contestantIndex]
    if liveUntil != _untilPot:
      assert liveUntil < _untilPot, "TODO: internal consistency check showdown"
      continue
    self.games[_tableId].liveUntil[contestantIndex] = potIndex
    hand[5] = T.cardAt(_tableId, self.games[_tableId].hands[contestantIndex][0])
    hand[6] = T.cardAt(_tableId, self.games[_tableId].hands[contestantIndex][1])
    handRank: uint256 = self.bestHandRank(hand)
    log ShowHand(_tableId, contestantIndex, handRank)
    if bestHandRank < handRank:
      winners = [contestantIndex]
      bestHandRank = handRank
    elif bestHandRank == handRank:
      winners.append(contestantIndex)
  share: uint256 = unsafe_div(self.games[_tableId].pot[potIndex], len(winners))
  collections: uint256[MAX_SEATS] = empty(uint256[MAX_SEATS])
  for winnerIndex in winners:
    self.games[_tableId].pot[potIndex] = unsafe_sub(self.games[_tableId].pot[potIndex], share)
    self.games[_tableId].stack[winnerIndex] = unsafe_add(self.games[_tableId].stack[winnerIndex], share)
    collections[winnerIndex] = share
  # odd chip(s) distributed according to overall card rank
  if self.games[_tableId].pot[potIndex] != 0:
    done: bool = False
    for negRank in range(13):
      rank: uint256 = unsafe_sub(12, negRank)
      for negSuit in range(4):
        suit: int128 = unsafe_sub(3, negSuit)
        for winnerIndex in winners:
          if self.hasCard(_tableId, winnerIndex, suit, rank):
            self.games[_tableId].pot[potIndex] = unsafe_sub(self.games[_tableId].pot[potIndex], 1)
            self.games[_tableId].stack[winnerIndex] = unsafe_add(self.games[_tableId].stack[winnerIndex], 1)
            collections[winnerIndex] = unsafe_add(collections[winnerIndex], 1)
            done = self.games[_tableId].pot[potIndex] == 0
            if done: break
        if done: break
      if done: break
  for winnerIndex in winners:
    log CollectPot(_tableId, winnerIndex, collections[winnerIndex])
  return potIndex

@internal
def autoShow(_numPlayers: uint256, _tableId: uint256):
  seatIndex: uint256 = self.games[_tableId].actionIndex
  stopIndex: uint256 = self.games[_tableId].stopIndex
  untilPot: uint256 = self.games[_tableId].untilPot
  needDeal: bool = False
  for _ in range(MAX_SEATS * MAX_SEATS):
    seatIndex = self.nextInPot(_numPlayers, _tableId, seatIndex, stopIndex)
    if seatIndex == stopIndex:
      if not needDeal and (
           self.games[_tableId].liveUntil[stopIndex] < untilPot or
           T.cardShown(_tableId, self.games[_tableId].hands[stopIndex][0])):
        untilPot = self.decidePot(_numPlayers, stopIndex, untilPot, _tableId)
        if untilPot == 0:
          if self.playersLeft(_numPlayers, _tableId) <= T.maxPlayers(_tableId):
            self.gameOver(_numPlayers, _tableId)
          else:
            self.nextHand(_numPlayers, _tableId)
          return
        else:
          self.games[_tableId].untilPot = untilPot
          continue
    if not T.cardShown(_tableId, self.games[_tableId].hands[seatIndex][0]):
      if self.games[_tableId].stack[seatIndex] == 0:
        self.showHand(_tableId, seatIndex)
        needDeal = True
        if seatIndex == stopIndex: break
      else:
        self.games[_tableId].actionIndex = seatIndex
        self.games[_tableId].actionBlock = block.number
        break
  if needDeal:
    T.startDeal(_tableId, Phase_SHOW)

event Eliminate:
  table: indexed(uint256)
  seat: indexed(uint256)

@internal
def nextHand(_numPlayers: uint256, _tableId: uint256):
  self.games[_tableId].numInHand = 0
  for seatIndex in range(MAX_SEATS):
    if seatIndex == _numPlayers:
      break
    if self.games[_tableId].stack[seatIndex] == empty(uint256):
      T.markAbsent(_tableId, seatIndex)
      log Eliminate(_tableId, seatIndex)
    else:
      self.games[_tableId].numInHand = unsafe_add(
        self.games[_tableId].numInHand, 1)
      self.games[_tableId].liveUntil[seatIndex] = 1
  self.games[_tableId].untilPot = 1
  self.games[_tableId].board = empty(uint256[5])
  T.reshuffle(_tableId)
  dealer: uint256 = self.games[_tableId].dealer
  self.games[_tableId].dealer = self.roundNextActor(_numPlayers, _tableId, dealer, dealer)
  self.games[_tableId].actionBlock = empty(uint256)

@internal
@view
def isAllIn(_gameId: uint256, _seatIndex: uint256) -> bool:
  return (0 < self.games[_gameId].liveUntil[_seatIndex] and
          self.games[_gameId].stack[_seatIndex] == 0)

@internal
def collectPots(_numPlayers: uint256, _gameId: uint256):
  potLimit: uint256 = max_value(uint256)
  for seatIndex in range(MAX_SEATS):
    if seatIndex == _numPlayers: break
    if self.isAllIn(_gameId, seatIndex):
      potLimit = min(potLimit, self.games[_gameId].bet[seatIndex])

  potLiveUntil: uint256 = 0
  nextLiveUntil: uint256 = 1
  for potIndex in range(MAX_SEATS):
    potLiveUntil = nextLiveUntil
    nextLiveUntil = unsafe_add(nextLiveUntil, 1)
    nextPotLimit: uint256 = max_value(uint256)
    collected: bool = False
    for seatIndex in range(MAX_SEATS):
      if seatIndex == _numPlayers: break
      bet: uint256 = self.games[_gameId].bet[seatIndex]
      if 0 < bet:
        amount: uint256 = min(bet, potLimit)
        nextBet: uint256 = unsafe_sub(bet, amount)
        self.games[_gameId].bet[seatIndex] = nextBet
        self.games[_gameId].pot[potIndex] = unsafe_add(self.games[_gameId].pot[potIndex], amount)
        collected = True
        if 0 < nextBet:
          if self.games[_gameId].liveUntil[seatIndex] == potLiveUntil:
            self.games[_gameId].liveUntil[seatIndex] = nextLiveUntil
          if self.isAllIn(_gameId, seatIndex):
            nextPotLimit = min(nextPotLimit, nextBet)
    if not collected:
      return
    potLimit = nextPotLimit
  raise "collectPots"

event CollectPot:
  table: indexed(uint256)
  seat: indexed(uint256)
  pot: uint256

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
      contestantIndex: uint256 = contestant[potIndex]
      amount: uint256 = self.games[_gameId].pot[potIndex]
      self.games[_gameId].stack[contestant[potIndex]] = unsafe_add(
        self.games[_gameId].stack[contestant[potIndex]], amount)
      self.games[_gameId].pot[potIndex] = empty(uint256)
      log CollectPot(_gameId, contestantIndex, amount)
      if potIndex < self.games[_gameId].liveUntil[contestantIndex]:
        self.games[_gameId].liveUntil[contestantIndex] = potIndex
      if potIndex < self.games[_gameId].untilPot:
        self.games[_gameId].untilPot = potIndex
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

event EndGame:
  table: indexed(uint256)

@internal
def gameOver(_numPlayers: uint256, _tableId: uint256):
  # everyone gets their stack + bond
  for seatIndex in range(MAX_SEATS):
    if seatIndex == _numPlayers:
      break
    T.refundPlayer(_tableId, seatIndex, self.games[_tableId].stack[seatIndex])
  # delete the game
  self.games[_tableId] = empty(Game)
  T.deleteTable(_tableId)
  log EndGame(_tableId)

@internal
def drawNextCard(_tableId: uint256):
  self.games[_tableId].minRaise = shift(self.smallBlind(_tableId), 1)
  numPlayers: uint256 = T.numPlayers(_tableId)
  dealer: uint256 = self.games[_tableId].dealer
  self.games[_tableId].actionIndex = self.roundNextActor(
    numPlayers, _tableId, dealer, dealer)
  self.games[_tableId].actionBlock = empty(uint256)
  numInHand: uint256 = self.games[_tableId].numInHand
  allInIndices: DynArray[uint256, MAX_SEATS] = []
  for seatIndex in range(MAX_SEATS):
    if seatIndex == numPlayers: break
    if self.isAllIn(_tableId, seatIndex):
      allInIndices.append(seatIndex)
  notAtMostOneNotAllIn: bool = 1 < unsafe_sub(numInHand, len(allInIndices))
  done: bool = False
  for street in range(2, 5):
    if self.games[_tableId].board[street] == empty(uint256):
      log DealRound(_tableId, street)
      T.burnCard(_tableId)
      if street == 2:
        for drawIndex in range(3):
          self.drawToBoard(_tableId, drawIndex)
      else:
        self.drawToBoard(_tableId, street)
        if street == 4 and numInHand == len(allInIndices):
          for allInIndex in allInIndices:
            self.showHand(_tableId, allInIndex)
      done = notAtMostOneNotAllIn
    if done:
      self.games[_tableId].betIndex = self.games[_tableId].actionIndex
      self.games[_tableId].stopIndex = self.games[_tableId].actionIndex
      self.games[_tableId].actionBlock = 1 # will be set by self.afterDeal
      break
  T.startDeal(_tableId, Phase_PLAY)

@internal
def afterAct(_tableId: uint256, _seatIndex: uint256):
  numPlayers: uint256 = T.numPlayers(_tableId)
  stopIndex: uint256 = self.games[_tableId].stopIndex
  nextActor: uint256 = self.roundNextActor(numPlayers, _tableId, _seatIndex, stopIndex)
  if nextActor == stopIndex or self.games[_tableId].numInHand == 1:
    # nobody is left to act in this round
    # move bets to pots and create side pots if necessary
    self.collectPots(numPlayers, _tableId)
    # settle uncontested pots
    numContested: uint256 = self.settleUncontested(numPlayers, _tableId)
    if numContested == 0: # hand is over
      if self.playersLeft(numPlayers, _tableId) <= T.maxPlayers(_tableId):
        self.gameOver(numPlayers, _tableId)
      else:
        self.nextHand(numPlayers, _tableId)
    elif self.games[_tableId].board[4] == empty(uint256):
      self.drawNextCard(_tableId)
    else:
      # showdown to settle remaining pots
      log DealRound(_tableId, 5)
      T.startShow(_tableId)
      self.autoShow(numPlayers, _tableId)
  else:
    # a player is still left to act in this round
    # pass action to them and set new actionBlock
    self.games[_tableId].actionIndex = nextActor
    self.games[_tableId].actionBlock = block.number

@internal
def drawToBoard(_tableId: uint256, _boardIndex: uint256):
  cardIndex: uint256 = T.dealTo(_tableId, self.games[_tableId].dealer)
  T.showCard(_tableId, cardIndex)
  self.games[_tableId].board[_boardIndex] = unsafe_add(PENDING_REVEAL, cardIndex)

@internal
@view
def nextInPot(_numPlayers: uint256, _gameId: uint256, _seatIndex: uint256, _stopAt: uint256) -> uint256:
  nextIndex: uint256 = _seatIndex
  for _ in range(MAX_SEATS):
    nextIndex = uint256_addmod(nextIndex, 1, _numPlayers)
    if (nextIndex == _stopAt or
        self.games[_gameId].liveUntil[nextIndex] == self.games[_gameId].untilPot):
      return nextIndex
  raise "_stopAt not found"

@internal
@view
def roundNextActor(_numPlayers: uint256, _gameId: uint256, _seatIndex: uint256, _stopAt: uint256) -> uint256:
  nextIndex: uint256 = _seatIndex
  for _ in range(MAX_SEATS):
    nextIndex = uint256_addmod(nextIndex, 1, _numPlayers)
    if nextIndex == _stopAt or (
         self.games[_gameId].liveUntil[nextIndex] != 0 and
         self.games[_gameId].stack[nextIndex] != 0):
      return nextIndex
  raise "_stopAt not found"

@internal
@view
def smallBlind(_tableId: uint256) -> uint256:
  return T.level(_tableId,
    min(unsafe_sub(T.numLevels(_tableId), 1),
        unsafe_div(unsafe_sub(block.number, self.games[_tableId].startBlock),
                   T.levelBlocks(_tableId))))

@internal
def placeBet(_gameId: uint256, _seatIndex: uint256, _size: uint256) -> uint256:
  amount: uint256 = min(_size, self.games[_gameId].stack[_seatIndex])
  self.games[_gameId].stack[_seatIndex] = unsafe_sub(self.games[_gameId].stack[_seatIndex], amount)
  self.games[_gameId].bet[_seatIndex] = unsafe_add(self.games[_gameId].bet[_seatIndex], amount)
  return amount

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
  suits: int128[7] = empty(int128[7])
  ranks: uint256[7] = empty(uint256[7])
  for i in range(7):
    suits[i] = self.suit(cards[i])
    ranks[i] = self.rank(cards[i])
    hand[ranks[i]] |= shift(1, suits[i])
  bestRank: uint256 = 0
  for i in range(7):
    hand[ranks[i]] ^= shift(1, suits[i])
    for delta in range(7):
      j: uint256 = unsafe_add(unsafe_add(i, delta), 1)
      if j == 7: break
      hand[ranks[j]] ^= shift(1, suits[j])
      bestRank = max(bestRank, self.handRank(hand))
      hand[ranks[j]] ^= shift(1, suits[j])
    hand[ranks[i]] ^= shift(1, suits[i])
  return bestRank
