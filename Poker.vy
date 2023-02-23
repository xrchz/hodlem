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

struct Hand:
  startBlock:  uint256            # block number when game started
  stack:       uint256[MAX_SEATS] # stack at each seat (zero for eliminated or all-in players)
  dealer:      uint256            # seat index of current dealer
  board:       uint256[5]         # board cards
  bet:         uint256[MAX_SEATS] # current round bet of each player
  lastBet:     uint256            # size of last bet or raise
  live:        bool[MAX_SEATS]    # whether this player has a live hand
  betIndex:    uint256            # seat index of player who introduced the current bet
  actionIndex: uint256            # seat index of currently active player
  actionBlock: uint256            # block from which action was on the active player
  pot:         uint256            # pot for the hand (from previous rounds)

nextHandId: uint256
hands: HashMap[uint256, Hand]

PENDING_REVEAL: constant(uint256) = 53

@external
def selectDealer(_tableId: uint256):
  assert T.authorised(_tableId, Phase_PLAY), "unauthorised"
  handId: uint256 = T.handId(_tableId)
  assert self.hands[handId].startBlock == empty(uint256), "already started"
  highestCard: uint256 = empty(uint256)
  highestCardSeatIndex: uint256 = empty(uint256)
  for seatIndex in range(MAX_PLAYERS):
    if seatIndex == T.numPlayers(_tableId):
      break
    self.hands[handId].live[seatIndex] = True
    self.hands[handId].stack[seatIndex] = T.buyIn(_tableId)
    card: uint256 = T.cardAt(_tableId, seatIndex)
    if highestCard < card:
      highestCard = card
      highestCardSeatIndex = seatIndex
  self.hands[handId].dealer = highestCardSeatIndex
  self.hands[handId].startBlock = block.number
  T.reshuffle(_tableId)

@external
def dealHoleCards(_tableId: uint256):
  assert T.authorised(_tableId, Phase_PLAY), "unauthorised"
  handId: uint256 = T.handId(_tableId)
  assert self.hands[handId].startBlock != empty(uint256), "not started"
  assert T.deckIndex(_tableId) == 0, "already dealt"
  seatIndex: uint256 = self.hands[handId].dealer
  self.hands[handId].betIndex = seatIndex
  for __ in range(2):
    for _ in range(MAX_SEATS):
      seatIndex = self.roundNextActor(_tableId, seatIndex)
      T.dealTo(_tableId, seatIndex)
      if seatIndex == self.hands[handId].dealer:
        break
  T.startDeal(_tableId)

@external
def postBlinds(_tableId: uint256):
  assert T.authorised(_tableId, Phase_PLAY), "unauthorised"
  handId: uint256 = T.handId(_tableId)
  assert self.hands[handId].startBlock != empty(uint256), "not started"
  assert self.hands[handId].board[0] == empty(uint256), "board not empty"
  assert self.hands[handId].actionBlock == empty(uint256), "already betting"
  seatIndex: uint256 = self.roundNextActor(_tableId, self.hands[handId].dealer)
  blind: uint256 = self.smallBlind(_tableId)
  self.placeBet(handId, seatIndex, blind)
  seatIndex = self.roundNextActor(_tableId, seatIndex)
  blind = unsafe_add(blind, blind)
  self.placeBet(handId, seatIndex, blind)
  seatIndex = self.roundNextActor(_tableId, seatIndex)
  self.hands[handId].betIndex = seatIndex
  self.hands[handId].lastBet = blind
  self.hands[handId].actionIndex = seatIndex
  self.hands[handId].actionBlock = block.number

@internal
def validateTurn(_tableId: uint256, _seatIndex: uint256) -> uint256:
  assert T.authorised(_tableId, Phase_PLAY, _seatIndex, msg.sender), "unauthorised"
  handId: uint256 = T.handId(_tableId)
  assert self.hands[handId].actionBlock != empty(uint256), "not active"
  assert self.hands[handId].actionIndex == _seatIndex, "wrong turn"
  return handId

@external
def fold(_tableId: uint256, _seatIndex: uint256):
  handId: uint256 = self.validateTurn(_tableId, _seatIndex)
  self.hands[handId].live[_seatIndex] = False
  self.afterAct(_tableId, _seatIndex)

@external
def check(_tableId: uint256, _seatIndex: uint256):
  handId: uint256 = self.validateTurn(_tableId, _seatIndex)
  assert self.hands[handId].bet[self.hands[handId].betIndex] == 0, "bet required"
  self.afterAct(_tableId, _seatIndex)

@external
def callBet(_tableId: uint256, _seatIndex: uint256):
  handId: uint256 = self.validateTurn(_tableId, _seatIndex)
  assert self.hands[handId].bet[self.hands[handId].betIndex] > 0, "no bet"
  # TODO: handle calling all-in (if side pot needed?)
  self.placeBet(handId, _seatIndex, self.hands[handId].bet[self.hands[handId].betIndex])
  self.afterAct(_tableId, _seatIndex)

@external
def bet(_tableId: uint256, _seatIndex: uint256, _size: uint256):
  handId: uint256 = self.validateTurn(_tableId, _seatIndex)
  assert self.hands[handId].bet[self.hands[handId].betIndex] == 0, "call/raise required"
  assert _size <= self.hands[handId].stack[_seatIndex], "size exceeds stack"
  # TODO: handle betting all-in (if side pot needed?)
  self.placeBet(handId, _seatIndex, _size)
  self.hands[handId].betIndex = _seatIndex
  self.hands[handId].lastBet = _size
  self.afterAct(_tableId, _seatIndex)

@external
def raiseBet(_tableId: uint256, _seatIndex: uint256, _raiseBy: uint256):
  handId: uint256 = self.validateTurn(_tableId, _seatIndex)
  assert self.hands[handId].bet[self.hands[handId].betIndex] > 0, "no bet"
  assert _raiseBy <= self.hands[handId].stack[_seatIndex], "size exceeds stack"
  # TODO: allow below minimum if raising all in; handle side pot, adjust lastBet
  assert _raiseBy >= self.hands[handId].lastBet, "size below minimum"
  self.placeBet(handId, _seatIndex, _raiseBy)
  self.hands[handId].betIndex = _seatIndex
  self.hands[handId].lastBet = _raiseBy
  self.afterAct(_tableId, _seatIndex)

@external
def dealNextRound(_tableId: uint256):
  assert T.authorised(_tableId, Phase_PLAY), "unauthorised"
  handId: uint256 = T.handId(_tableId)
  assert self.hands[handId].board[2] != empty(uint256), "board empty"
  assert self.hands[handId].actionBlock == empty(uint256), "already betting"
  # fill the board with the revealedCards
  boardIndex: uint256 = 5
  cardIndex: uint256 = T.deckIndex(_tableId)
  for _ in range(5):
    boardIndex -= 1
    if self.hands[handId].board[boardIndex] == empty(uint256):
      continue
    elif self.hands[handId].board[boardIndex] == PENDING_REVEAL:
      cardIndex -= 1
      self.hands[handId].board[boardIndex] = T.cardAt(_tableId, cardIndex)
    else:
      break
  self.hands[handId].betIndex = self.hands[handId].dealer
  self.hands[handId].actionIndex = self.roundNextActor(_tableId, self.hands[handId].dealer)
  self.hands[handId].betIndex = self.hands[handId].actionIndex
  self.hands[handId].actionBlock = block.number

@external
def actTimeout(_tableId: uint256):
  assert T.authorised(_tableId, Phase_PLAY), "unauthorised"
  handId: uint256 = T.handId(_tableId)
  assert self.hands[handId].actionBlock != empty(uint256), "not active"
  assert block.number > (self.hands[handId].actionBlock +
                         T.actBlocks(_tableId)), "deadline not passed"
  self.hands[handId].live[self.hands[handId].actionIndex] = False
  self.afterAct(_tableId, self.hands[handId].actionIndex)

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

@internal
def afterAct(_tableId: uint256, _seatIndex: uint256):
  # TODO: implement
  # check if a player is still left to act in this round:
  # pass action to them and set new actionBlock
  #
  # if nobody is left to act in this round:
  # if only one player is left standing, they win the pot
  # elif there are board cards to come, deal the next round
  # else move into showdown phase
  #   each remaining player shows cards or mucks (+ folds) in turn
  #   all remaining players compete for best hands
  #   best hands split the pot
  #   TODO: handle side pots
  pass

#@internal
#def actNext(_tableId: uint256, _seatIndex: uint256):
#  self.tables[_tableId].hand.actionIndex = self.nextPlayer(_tableId, _seatIndex)
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
def roundNextActor(_tableId: uint256, _seatIndex: uint256) -> uint256:
  handId: uint256 = T.handId(_tableId)
  numPlayers: uint256 = T.numPlayers(_tableId)
  nextIndex: uint256 = _seatIndex
  for _ in range(MAX_SEATS):
    nextIndex = uint256_addmod(nextIndex, 1, numPlayers)
    if (nextIndex == self.hands[handId].betIndex or
        self.hands[handId].stack[nextIndex] != empty(uint256)):
      return nextIndex
  raise "betIndex not found"

@internal
@view
def smallBlind(_tableId: uint256) -> uint256:
  handId: uint256 = T.handId(_tableId)
  levelBlocks: uint256 = T.levelBlocks(_tableId)
  level: uint256 = empty(uint256)
  if self.hands[handId].startBlock + MAX_LEVELS * levelBlocks < block.number:
    level = ((block.number - self.hands[handId].startBlock) / levelBlocks)
  else:
    level = MAX_LEVELS - 1
  for _ in range(MAX_LEVELS):
    if T.level(_tableId, level) == empty(uint256):
      level -= 1
    else:
      break
  return T.level(_tableId, level)

@internal
def placeBet(_handId: uint256, _seatIndex: uint256, _size: uint256):
  amount: uint256 = min(_size, self.hands[_handId].stack[_seatIndex])
  self.hands[_handId].stack[_seatIndex] -= amount
  self.hands[_handId].bet[_seatIndex] += amount
