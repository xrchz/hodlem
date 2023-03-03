# @version ^0.3.8
# lobby implementation

# copied storage from Table.vy

# copied from Deck.vy because https://github.com/vyperlang/vyper/issues/2670
MAX_SIZE: constant(uint256) = 2000
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
# end of copy
import Deck as DeckManager

playerAddress: HashMap[uint256, address]
pendingPlayerAddress: HashMap[uint256, address]
nextPlayerId: uint256

MAX_SEATS:  constant(uint256) =   9 # maximum seats per table
MAX_LEVELS: constant(uint256) = 100 # maximum number of levels in tournament structure

# not using Vyper enum because of this bug
# https://github.com/vyperlang/vyper/pull/3196/files#r1062141796
Phase_JOIN:    constant(uint256) = 0 # before the game has started, taking seats
Phase_PREP:    constant(uint256) = 1 # all players seated, preparing the deck
Phase_SHUFFLE: constant(uint256) = 2 # submitting shuffles and verifications in order
Phase_DEAL:    constant(uint256) = 3 # drawing and possibly opening cards as currently required
Phase_PLAY:    constant(uint256) = 4 # betting; new card revelations may become required
Phase_SHOW:    constant(uint256) = 5 # showdown; new card revelations may become required

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
  nextPhase:   uint256              # phase to enter after deal
  present:     bool[9]              # whether each player contributes to the current shuffle
  gameId:      uint256              # id of game in game contract
  commitBlock: uint256              # block from which new commitments were required
  deckIndex:   uint256              # index of next card in deck
  drawIndex:   uint256[26]          # player the card is drawn to
  requirement: uint256[26]          # revelation requirement level

tables: HashMap[uint256, Table]
nextTableId: uint256

# end copy

@external
@payable
def new(_playerId: uint256, _tableId: uint256, _seatIndex: uint256, _config: Config, _deckAddr: address):
  assert self.playerAddress[_playerId] == msg.sender, "unauthorised"
  assert 1 < _config.startsWith, "invalid startsWith"
  assert _config.startsWith <= MAX_SEATS, "invalid startsWith"
  assert _config.untilLeft < _config.startsWith, "invalid untilLeft"
  assert 0 < _config.untilLeft, "invalid untilLeft"
  assert 0 < _config.structure[0], "invalid structure"
  assert 0 < _config.buyIn, "invalid buyIn"
  assert _seatIndex < _config.startsWith, "invalid seatIndex"
  assert msg.value == _config.bond + _config.buyIn, "incorrect bond + buyIn"
  self.tables[_tableId].tableId = _tableId
  self.tables[_tableId].deck = DeckManager(_deckAddr)
  self.tables[_tableId].deckId = self.tables[_tableId].deck.newDeck(52, _config.startsWith)
  self.tables[_tableId].phase = Phase_JOIN
  self.tables[_tableId].config = _config
  self.tables[_tableId].seats[_seatIndex] = _playerId
  self.nextTableId = unsafe_add(_tableId, 1)

@external
@payable
def join(_playerId: uint256, _tableId: uint256, _seatIndex: uint256):
  assert self.playerAddress[_playerId] == msg.sender, "unauthorised"
  assert self.tables[_tableId].tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].phase == Phase_JOIN, "wrong phase"
  assert _seatIndex < self.tables[_tableId].config.startsWith, "invalid seatIndex"
  assert self.tables[_tableId].seats[_seatIndex] == empty(uint256), "seatIndex unavailable"
  assert msg.value == self.tables[_tableId].config.bond + self.tables[_tableId].config.buyIn, "incorrect bond + buyIn"
  self.tables[_tableId].seats[_seatIndex] = _playerId

@external
def leave(_tableId: uint256, _seatIndex: uint256):
  assert self.tables[_tableId].tableId == _tableId, "invalid tableId"
  assert self.playerAddress[self.tables[_tableId].seats[_seatIndex]] == msg.sender, "unauthorised"
  assert self.tables[_tableId].phase == Phase_JOIN, "wrong phase"
  self.tables[_tableId].seats[_seatIndex] = empty(uint256)
  send(msg.sender, self.tables[_tableId].config.bond + self.tables[_tableId].config.buyIn)

@external
def start(_tableId: uint256):
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
def refund(_tableId: uint256, _seatIndex: uint256, _stack: uint256):
  assert self.tables[_tableId].config.gameAddress == msg.sender, "unauthorised"
  send(self.playerAddress[self.tables[_tableId].seats[_seatIndex]],
       unsafe_add(self.tables[_tableId].config.bond, _stack))

@external
def delete(_tableId: uint256):
  assert self.tables[_tableId].config.gameAddress == msg.sender, "unauthorised"
  self.tables[_tableId] = empty(Table)
