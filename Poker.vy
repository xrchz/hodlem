# @version ^0.3.7
# no-limit hold'em sit-n-go tournament contract

MAX_SEATS:  constant(uint8) =   9 # maximum seats per table
MAX_ROUNDS: constant(uint8) = 100 # maximum number of levels in tournament structure

playerAddress: public(HashMap[uint256, address])
pendingPlayerAddress: public(HashMap[uint256, address])

@external
def register(_playerId: uint256):
  assert _playerId != empty(uint256), "invalid playerId"
  assert self.playerAddress[_playerId] == empty(address), "playerId unavailable"
  self.playerAddress[_playerId] = msg.sender

@external
def changePlayerAddress(_playerId: uint256, _newAddress: address):
  assert self.playerAddress[_playerId] == msg.sender, "unauthorised"
  if _newAddress == empty(address):
    self.playerAddress[_playerId] = _newAddress
  else:
    self.pendingPlayerAddress[_playerId] = _newAddress

@external
def confirmChangePlayerAddress(_playerId: uint256):
  assert self.pendingPlayerAddress[_playerId] == msg.sender, "unauthorised"
  self.pendingPlayerAddress[_playerId] = empty(address)
  self.playerAddress[_playerId] = msg.sender

# the deck is represented by the numbers 1, ..., 52
# spades (01-13), clubs (14-26), diamonds (27-39), hearts (40-52)

@internal
@pure
def rank(card: uint8) -> uint8:
  return (card - 1) % 13

@internal
@pure
def suit(card: uint8) -> uint8:
  return (card - 1) / 13

# a permutation of the deck is an array uint8[52] of card numbers
# we hash permutations by first converting to Bytes[52] then sha256
# we assume the hash of a permutation is never empty(bytes32)

struct Proof:
  proof: Bytes[52]

struct Shuffle:
  commitments: bytes32[MAX_SEATS]    # hashed permutations from each player
  revelations: uint8[26][MAX_SEATS]  # revealed cards from the shuffle
  openCommits: bytes32[MAX_SEATS]    # unverified commitments now open to being challenged
  challIndex:  uint8                 # index of a player being actively challenged
  challBlock:  uint256               # block when challenge was issued (or empty if no challenge)
  proofs:      Proof[MAX_SEATS]      # proofs of commitments

struct Hand:
  dealer:      uint8              # seat index of current dealer
  board:       uint8[5]           # board cards
  bets:        uint256[MAX_SEATS] # current round bet of each player
  actionIndex: uint8              # seat index of currently active player
  actionBlock: uint256            # block from which action was on the active player
  pot:         uint256            # pot for the hand (from previous rounds)

struct Config:
  tableId:     uint256             # table id (can be reused after table is finished)
  buyIn:       uint256             # entry ticket price per player
  bond:        uint256             # liveness bond for each player
  minPlayers:  uint8               # game can start when this many players are seated
  maxPlayers:  uint8               # game ends when this many players are left
  structure:   uint256[MAX_ROUNDS] # small blind levels (right-padded with blanks)
  levelBlocks: uint256             # blocks between levels
  proveBlocks: uint256             # blocks allowed for responding to a challenge
  actBlocks:   uint256             # blocks to act before folding can be triggered

SELECTING_DEALER: constant(uint256) = 1

struct Table:
  config:      Config
  startBlock:  uint256              # block number when game started, or SELECTING_DEALER
  seats:       uint256[MAX_SEATS]   # playerIds in seats as at the start of the game
  stacks:      uint256[MAX_SEATS]   # stack at each seat (zero for eliminated players)
  hand:        Hand                 # current Hand
  shuffle:     Shuffle              # current Shuffle

tables: HashMap[uint256, Table]

@external
@payable
def createTable(_playerId: uint256, _seatIndex: uint8, _config: Config):
  assert self.playerAddress[_playerId] == msg.sender, "unauthorised"
  assert _config.tableId != empty(uint256), "invalid tableId"
  assert self.tables[_config.tableId].config.tableId == empty(uint256), "tableId unavailable"
  assert 1 < _config.minPlayers, "invalid minPlayers"
  assert _config.minPlayers <= MAX_SEATS, "invalid minPlayers"
  assert _config.maxPlayers < _config.minPlayers, "invalid maxPlayers"
  assert 0 < _config.maxPlayers, "invalid maxPlayers"
  assert 0 < _config.structure[0], "invalid structure"
  assert 0 < _config.buyIn, "invalid buyIn"
  assert _seatIndex < _config.minPlayers, "invalid seatIndex"
  assert msg.value == _config.bond + _config.buyIn, "incorrect bond + buyIn"
  self.tables[_config.tableId].config = _config
  self.tables[_config.tableId].seats[_seatIndex] = _playerId
  self.tables[_config.tableId].stacks[_seatIndex] = _config.buyIn

@external
@payable
def joinTable(_playerId: uint256, _tableId: uint256, _seatIndex: uint8):
  assert self.playerAddress[_playerId] == msg.sender, "unauthorised"
  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].startBlock == empty(uint256), "already started"
  assert _seatIndex < self.tables[_tableId].config.minPlayers, "invalid seatIndex"
  assert self.tables[_tableId].seats[_seatIndex] == empty(uint256), "seatIndex unavailable"
  assert msg.value == self.tables[_tableId].config.bond + self.tables[_tableId].config.buyIn, "incorrect bond + buyIn"
  self.tables[_tableId].seats[_seatIndex] = _playerId
  self.tables[_tableId].stacks[_seatIndex] = self.tables[_tableId].config.buyIn

@external
def leaveTable(_playerId: uint256, _tableId: uint256, _seatIndex: uint8):
  assert self.playerAddress[_playerId] == msg.sender, "unauthorised"
  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].startBlock == empty(uint256), "already started"
  assert _seatIndex < self.tables[_tableId].config.minPlayers, "invalid seatIndex"
  assert self.tables[_tableId].seats[_seatIndex] == _playerId, "wrong player"
  self.tables[_tableId].seats[_seatIndex] = empty(uint256)
  self.tables[_tableId].stacks[_seatIndex] = empty(uint256)
  send(msg.sender, self.tables[_tableId].config.bond + self.tables[_tableId].config.buyIn)

@external
def startGame(_tableId: uint256):
  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].startBlock == empty(uint256), "already started"
  numSeated: uint8 = 0
  for playerId in self.tables[_tableId].seats:
    if playerId != empty(uint256):
      numSeated += 1
  assert numSeated == self.tables[_tableId].config.minPlayers, "not enough players"
  self.tables[_tableId].startBlock = SELECTING_DEALER

@external
def commit(_playerId: uint256, _tableId: uint256, _seatIndex: uint8, _hashed_commitment: bytes32):
  assert self.playerAddress[_playerId] == msg.sender, "unauthorised"
  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
  assert _seatIndex < self.tables[_tableId].config.minPlayers, "invalid seatIndex"
  assert self.tables[_tableId].seats[_seatIndex] == _playerId, "wrong player"
  assert self.tables[_tableId].startBlock != empty(uint256), "not started"
  assert self.tables[_tableId].shuffle.commitments[_seatIndex] == empty(bytes32), "already committed"
  self.tables[_tableId].shuffle.commitments[_seatIndex] = _hashed_commitment

@external
def revealCard(_playerId: uint256, _tableId: uint256, _seatIndex: uint8, _cardIndex: uint8, _reveal: uint8):
  assert self.playerAddress[_playerId] == msg.sender, "unauthorised"
  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
  assert _seatIndex < self.tables[_tableId].config.minPlayers, "invalid seatIndex"
  assert self.tables[_tableId].seats[_seatIndex] == _playerId, "wrong player"
  assert _reveal != empty(uint8), "invalid reveal"
  assert self.tables[_tableId].shuffle.openCommits[_seatIndex] == empty(bytes32), "previous commitment open"
  assert self.tables[_tableId].shuffle.commitments[_seatIndex] != empty(bytes32), "not committed"
  assert _cardIndex < 26, "invalid cardIndex"
  assert self.tables[_tableId].shuffle.revelations[_seatIndex][_cardIndex] == empty(uint8), "already revealed"
  self.tables[_tableId].shuffle.revelations[_seatIndex][_cardIndex] = _reveal

@internal
@view
def revealedCard(_tableId: uint256, _cardIndex: uint8) -> uint8:
  assert _cardIndex < 26, "invalid cardIndex"
  cardIndex: uint8 = _cardIndex
  seatIndex: uint8 = 0
  for playerId in self.tables[_tableId].seats:
    if playerId != empty(uint256): # TODO: also need a non-empty stack?
      assert self.tables[_tableId].shuffle.revelations[seatIndex][cardIndex] != empty(uint8), "not revealed"
      cardIndex = self.tables[_tableId].shuffle.revelations[seatIndex][cardIndex] - 1
    seatIndex += 1
  return cardIndex + 1

@external
def selectDealer(_tableId: uint256):
  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].startBlock == SELECTING_DEALER, "wrong phase"
  highestCard: uint8 = empty(uint8)
  highestCardSeatIndex: uint8 = empty(uint8)
  seatIndex: uint8 = 0
  for playerId in self.tables[_tableId].seats:
    if playerId != empty(uint256):
      card: uint8 = self.revealedCard(_tableId, seatIndex)
      rankCard: uint8 = self.rank(card)
      rankHighestCard: uint8 = self.rank(highestCard)
      if highestCard == empty(uint8) or rankHighestCard < rankCard or (
           rankHighestCard == rankCard and self.suit(highestCard) < self.suit(card)):
        highestCard = card
        highestCardSeatIndex = seatIndex
      self.tables[_tableId].shuffle.openCommits[seatIndex] = self.tables[_tableId].shuffle.commitments[seatIndex]
      self.tables[_tableId].shuffle.commitments[seatIndex] = empty(bytes32)
    seatIndex += 1
  self.tables[_tableId].hand.dealer = highestCardSeatIndex
  self.tables[_tableId].startBlock = block.number

@internal
@view
def verify(_tableId: uint256) -> bool:
  challIndex: uint8 = self.tables[_tableId].shuffle.challIndex
  if (sha256(self.tables[_tableId].shuffle.proofs[challIndex].proof) !=
      self.tables[_tableId].shuffle.openCommits[challIndex]):
    return False
  used: uint256 = 2**52 - 1
  for i in range(52):
    card: uint8 = convert(slice(self.tables[_tableId].shuffle.proofs[challIndex].proof, i, 1), uint8)
    if (i < 26 and
        self.tables[_tableId].shuffle.revelations[challIndex][i] != empty(uint8) and
        self.tables[_tableId].shuffle.revelations[challIndex][i] != card):
      return False
    used &= ~shift(1, convert(card - 1, int128))
  return used == 0

@internal
def failChallenge(_tableId: uint256):
  challIndex: uint8 = self.tables[_tableId].shuffle.challIndex
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

@internal
def verifyChallenge(_tableId: uint256):
  challIndex: uint8 = self.tables[_tableId].shuffle.challIndex
  if self.verify(_tableId):
    self.tables[_tableId].shuffle.openCommits[challIndex] = empty(bytes32)
    self.tables[_tableId].shuffle.challBlock = empty(uint256)
  else:
    self.failChallenge(_tableId)

@external
def prove(_tableId: uint256, _playerId: uint256, _seatIndex: uint8, _proof: Bytes[52]):
  assert self.playerAddress[_playerId] == msg.sender, "unauthorised"
  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
  assert _seatIndex < self.tables[_tableId].config.minPlayers, "invalid seatIndex"
  assert self.tables[_tableId].seats[_seatIndex] == _playerId, "wrong player"
  assert self.tables[_tableId].shuffle.proofs[_seatIndex].proof == empty(Bytes[52]), "already provided"
  self.tables[_tableId].shuffle.proofs[_seatIndex] = Proof({proof: _proof})
  if self.tables[_tableId].shuffle.challIndex == _seatIndex:
    self.verifyChallenge(_tableId)

@external
def challenge(_tableId: uint256, _seatIndex: uint8):
  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
  assert _seatIndex < self.tables[_tableId].config.minPlayers, "invalid seatIndex"
  assert self.tables[_tableId].shuffle.openCommits[_seatIndex] != empty(bytes32), "no open commitment"
  assert self.tables[_tableId].shuffle.challBlock == empty(uint256), "challenge already ongoing"
  self.tables[_tableId].shuffle.challBlock = block.number
  self.tables[_tableId].shuffle.challIndex = _seatIndex
  if self.tables[_tableId].shuffle.proofs[_seatIndex].proof != empty(Bytes[52]):
    self.verifyChallenge(_tableId)

@external
def challengeTimeout(_tableId: uint256):
  assert self.tables[_tableId].config.tableId == _tableId, "invalid tableId"
  assert self.tables[_tableId].shuffle.challBlock != empty(uint256), "no ongoing challenge"
  assert block.number > (self.tables[_tableId].shuffle.challBlock +
                         self.tables[_tableId].config.proveBlocks), "deadline not passed"
  self.failChallenge(_tableId)

@external
def __init__():
  pass
