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
def suit(card: uint256) -> uint256:
  return unsafe_div(unsafe_sub(card, 1), 13)

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

@external
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
