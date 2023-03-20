const socket = io()

const fragment = document.createDocumentFragment()

const errorMsg = document.getElementById('errorMsg')
const errorMsgText = errorMsg.getElementsByTagName('span')[0]
const clearErrorMsgButton = errorMsg.getElementsByTagName('input')[0]

socket.on('errorMsg', msg => {
  errorMsg.classList.remove('hidden')
  errorMsgText.innerText = msg
  document.querySelectorAll('input.txnRequester').forEach(b => b.disabled = false)
})

clearErrorMsgButton.addEventListener('click', _ => {
  errorMsg.classList.add('hidden')
})

const maxFeeElement = document.getElementById('maxFeePerGas')
const prioFeeElement = document.getElementById('maxPriorityFeePerGas')
const resetFeesButton = document.getElementById('resetFees')

resetFeesButton.addEventListener('click', (e) => {
  socket.emit('resetFees')
  resetFeesButton.disabled = true
})

socket.on('maxFeePerGas', fee => {
  maxFeeElement.value = fee
})
socket.on('maxPriorityFeePerGas', fee => {
  prioFeeElement.value = fee
})

function customFees() {
  if (maxFeeElement.checkValidity() && prioFeeElement.checkValidity()) {
    socket.emit('customFees', maxFeeElement.value, prioFeeElement.value)
    resetFeesButton.disabled = false
  }
  else {
    maxFeeElement.reportValidity()
    prioFeeElement.reportValidity()
  }
}

maxFeeElement.addEventListener('change', customFees)
prioFeeElement.addEventListener('change', customFees)

const addressElement = document.getElementById('address')
const privkeyElement = document.getElementById('privkey')
const newAccountButton = document.getElementById('newAccount')
const hidePrivkeyButton = document.getElementById('hidePrivKey')

const joinDiv = document.getElementById('joinDiv')
const playDiv = document.getElementById('playDiv')

hidePrivkeyButton.addEventListener('click', (e) => {
  if (privkeyElement.classList.contains('hidden')) {
    privkeyElement.classList.remove('hidden')
    hidePrivkeyButton.value = 'Hide'
  }
  else {
    privkeyElement.classList.add('hidden')
    hidePrivkeyButton.value = 'Show'
  }
})

newAccountButton.addEventListener('click', (e) => {
  socket.emit('newAccount')
  newAccountButton.disabled = true
})

privkeyElement.addEventListener('change', (e) => {
  newAccountButton.disabled = privkeyElement.value != ''
  if (privkeyElement.value) socket.emit('privkey', privkeyElement.value)
})

socket.on('account', (address, privkey) => {
  addressElement.value = address
  privkeyElement.value = privkey
  newAccountButton.disabled = privkeyElement.value != ''
  joinDiv.replaceChildren()
  playDiv.replaceChildren()
})

const balanceElement = document.getElementById('balance')
const sendAmountElement = document.getElementById('sendAmount')
const sendToElement = document.getElementById('sendTo')
const sendButton = document.getElementById('sendButton')

sendButton.addEventListener('click', (e) => {
  if (sendToElement.checkValidity() && sendAmountElement.checkValidity()) {
    socket.emit('send', sendToElement.value, sendAmountElement.value)
  }
  else {
    sendToElement.reportValidity()
    sendAmountElement.reportValidity()
  }
})

socket.on('balance', balance => {
  balanceElement.value = balance
})

const transactionDiv = document.getElementById('transaction')
const txnInfoElement = document.getElementById('txnInfo')
const acceptTxnButton = document.getElementById('acceptTxn')
const rejectTxnButton = document.getElementById('rejectTxn')
const sendTxnsCheckbox = document.getElementById('sendTxns')

socket.on('requestTransaction', data => {
  txnInfoElement.data = data
  if (sendTxnsCheckbox.checked) {
    acceptTxnButton.dispatchEvent(new Event('click'))
  }
  else {
    transactionDiv.classList.remove('hidden')
    txnInfoElement.innerText = JSON.stringify(data)
  }
})

acceptTxnButton.addEventListener('click', (e) => {
  socket.emit('transaction', txnInfoElement.data)
  transactionDiv.classList.add('hidden')
})

rejectTxnButton.addEventListener('click', (e) => {
  delete txnInfoElement.data
  transactionDiv.classList.add('hidden')
})

const emptyAddress = '0x0000000000000000000000000000000000000000'

function cardSpan(card) {
  const span = document.createElement('span')
  span.classList.add('card')
  if (card === 53) span.innerText = '🂠'
  else {
    let codepoint = 0x1F000
    const suit = Math.floor(card / 13)
    codepoint += 0xA0 + 16 * suit
    const rank = card % 13
    codepoint += rank === 12 ? 1 : rank + 2 + (9 < rank)
    const suitName = ['Spades', 'Hearts', 'Diamonds', 'Clubs'][suit]
    span.classList.add(suitName)
    const rankName = ['Deuce', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine', 'Ten', 'Jack', 'Queen', 'King', 'Ace'][rank]
    span.title = `${rankName} of ${suitName}`
    span.innerText = String.fromCodePoint(codepoint)
  }
  return span
}

const logs = {}
const addressToSeat = {}
const hideConfig = {}

socket.on('logCount', (id, count) => {
  if (logs[id].length < count)
    socket.emit('requestLogs', id, count - logs[id].length)
})

socket.on('logs', (id, newLogs) => {
  logs[id].push(...newLogs)
  const logsList = document.getElementById(`logs${id}`)
  fragment.append(...logs[id].map(log => {
    const li = document.createElement('li')
    if (log.name === 'Show' && log.args.length < 4) {
      log.args.push(cardSpan(log.args[2] - 1))
    }
    if (log.name === 'DeckPrep' && typeof log.args[1] !== 'string') {
      log.args[1] = log.args[1] ? 'Reveal' : 'Commit'
    }
    if (log.name === 'Shuffle' && typeof log.args[1] !== 'string') {
      log.args[1] = log.args[1] ? 'Verify' : 'Submit'
    }
    if (typeof log.args[0] === 'string' && log.args[0].startsWith('0x') &&
        log.name !== 'JoinTable') {
      const span = document.createElement('span')
      span.innerText = addressToSeat[id][log.args[0]]
      span.title = log.args[0]
      log.args[0] = span
    }
    const ul = li.appendChild(document.createElement('ul'))
    ul.classList.add('log')
    const name = ul.appendChild(document.createElement('li'))
    name.classList.add('name')
    name.innerText = log.name
    log.args.forEach(arg => {
      const li = ul.appendChild(document.createElement('li'))
      if (arg instanceof Element)
        li.appendChild(arg)
      else
        li.innerText = arg
    })
    return li
  }))
  logsList.replaceChildren()
  logsList.appendChild(fragment)
  logsList.lastElementChild.scrollIntoView(false)
})

function addGameConfig(li, config) {
  const configDiv = li.appendChild(document.createElement('dl'))
  Object.entries(config).forEach(([k, v]) => {
    if (['deckId', 'id'].includes(k)) return
    configDiv.appendChild(document.createElement('dt')).innerText = k
    configDiv.appendChild(document.createElement('dd')).innerText = v
  })
  const hideConfigButton = li.appendChild(document.createElement('input'))
  hideConfigButton.type = 'button'
  hideConfigButton.value = 'Hide Config'
  hideConfigButton.addEventListener('click', _ => {
    if (configDiv.classList.contains('hidden')) {
      configDiv.classList.remove('hidden')
      hideConfigButton.value = 'Hide Config'
      delete hideConfig[config.id]
    }
    else {
      configDiv.classList.add('hidden')
      hideConfigButton.value = 'Show Config'
      hideConfig[config.id] = true
    }
  })
  if (hideConfig[config.id]) hideConfigButton.dispatchEvent(new Event('click'))
}

socket.on('pendingGames', (configs, seats) => {
  joinDiv.replaceChildren()
  configs.forEach(config => {
    if (!(config.id in logs)) logs[config.id] = []
    const li = fragment.appendChild(document.createElement('li'))
    addGameConfig(li, config)
    const logsUl = li.appendChild(document.createElement('ul'))
    logsUl.id = `logs${config.id}`
    logsUl.classList.add('logs')
    const ol = li.appendChild(document.createElement('ol'))
    ol.start = 0
    const onTable = seats[config.id].includes(addressElement.value)
    seats[config.id].forEach((addr, seatIndex) => {
      const seatLi = ol.appendChild(document.createElement('li'))
      seatLi.appendChild(document.createElement('span')).innerText = addr
      if ((!onTable && addr === emptyAddress) || addr === addressElement.value) {
        const button = seatLi.appendChild(document.createElement('input'))
        button.type = 'button'
        button.value = onTable ? 'Leave' : 'Join'
        button.classList.add('txnRequester')
        button.addEventListener('click', (e) => {
          socket.emit(`${button.value.toLowerCase()}Game`, config.id, seatIndex)
          button.disabled = true
        })
      }
    })
    setTimeout(() => socket.emit('requestLogCount', config.id), 100)
  })
  joinDiv.appendChild(fragment)
  createGameButton.disabled = false
})

const phases = ['NONE', 'JOIN', 'PREP', 'SHUF', 'DEAL', 'PLAY', 'SHOW']

socket.on('activeGames', (configs, data) => {
  playDiv.replaceChildren()
  configs.forEach(config => {
    if (!(config.id in logs)) logs[config.id] = []
    const di = data[config.id]
    if (!(config.id in addressToSeat)) {
      addressToSeat[config.id] = {}
      di.players.forEach((addr, seatIndex) => {
        addressToSeat[config.id][addr] = seatIndex
      })
    }
    const li = fragment.appendChild(document.createElement('li'))
    addGameConfig(li, config)
    const logsUl = li.appendChild(document.createElement('ul'))
    logsUl.id = `logs${config.id}`
    logsUl.classList.add('logs')
    const ul = li.appendChild(document.createElement('ul'))
    ul.classList.add('game')
    ul.appendChild(document.createElement('li')).innerText = `Your seat: ${di.seatIndex}`
    ul.appendChild(document.createElement('li')).innerText = `Game phase: ${phases[di.phase]}`
    if (phases[di.phase] === 'PREP') {
      ul.appendChild(document.createElement('li')).innerText = `Waiting on: ${JSON.stringify(di.waitingOn)}`
      if (di.waitingOn.includes(di.seatIndex)) {
        const div = li.appendChild(document.createElement('div'))
        div.classList.add('actions')
        const button = div.appendChild(document.createElement('input'))
        button.type = 'button'
        button.value = `${di.reveal ? 'Reveal' : 'Commit'} preparation`
        button.classList.add('txnRequester')
        button.addEventListener('click', _ => {
          socket.emit(`${di.reveal ? 'verify' : 'submit'}Prep`, config.id, di.seatIndex)
          button.disabled = true
        })
      }
    }
    else {
      ul.appendChild(document.createElement('li')).innerText = `Dealer: ${di.dealer}`
      ul.appendChild(document.createElement('li')).innerText = `Action on: ${di.actionIndex}`
      const board = ul.appendChild(document.createElement('li'))
      board.appendChild(document.createElement('span')).innerText = 'Board: '
      di.board.forEach(card => board.appendChild(cardSpan(card - 1)))
      const hole = ul.appendChild(document.createElement('li'))
      hole.appendChild(document.createElement('span')).innerText = 'Hole cards: '
      di.hand.forEach(card => { if (card) hole.appendChild(cardSpan(card - 1)) })
      const stacks = JSON.stringify(di.stack.map((b, i) => ({[i]: b})))
      ul.appendChild(document.createElement('li')).innerText = `Stacks: ${stacks}`
      const bets = JSON.stringify(di.bet.map((b, i) => ({[i]: b})))
      ul.appendChild(document.createElement('li')).innerText = `Bets: ${bets}`
      ul.appendChild(document.createElement('li')).innerText = `Bet: ${di.bet[di.betIndex]}`
      const pots = ul.appendChild(document.createElement('li'))
      pots.appendChild(document.createElement('span')).innerText = `Pot${di.pot.length > 1 ? 's' : ''}: `
      const potsList = pots.appendChild(document.createElement('ul'))
      potsList.classList.add('pots')
      di.pot.forEach(pot => potsList.appendChild(document.createElement('li')).innerText = pot)
      potsList.appendChild(document.createElement('li')).innerText = `(with bets: ${di.lastPotWithBets})`
    }
    if (phases[di.phase] === 'SHUF') {
      if (di.shuffleCount < config.startsWith) {
        ul.appendChild(document.createElement('li')).innerText = `Waiting on: ${di.shuffleCount}`
        if (di.shuffleCount === di.seatIndex) {
          const div = li.appendChild(document.createElement('div'))
          div.classList.add('actions')
          const button = div.appendChild(document.createElement('input'))
          button.type = 'button'
          button.value = 'Submit shuffle'
          button.classList.add('txnRequester')
          button.addEventListener('click', _ => {
            socket.emit('submitShuffle', config.id)
            button.disabled = true
          })
        }
      }
      else {
        ul.appendChild(document.createElement('li')).innerText = `Waiting on: ${JSON.stringify(di.waitingOn)}`
        if (di.waitingOn.includes(di.seatIndex)) {
          const div = li.appendChild(document.createElement('div'))
          div.classList.add('actions')
          const button = div.appendChild(document.createElement('input'))
          button.type = 'button'
          button.value = 'Verify shuffle'
          button.classList.add('txnRequester')
          button.addEventListener('click', _ => {
            socket.emit('submitVerif', config.id)
            button.disabled = true
          })
        }
      }
    }
    if (phases[di.phase] === 'DEAL') {
      ul.appendChild(document.createElement('li')).innerText = `Waiting on: ${JSON.stringify(di.waitingOn)}`
      const requests = di.waitingOn.flatMap(({who, what, open}) => (who === di.seatIndex ? [[what, open]] : []))
      const decrypts = requests.filter(([, open]) => !open).map(([i]) => i)
      const opens = requests.filter(([, open]) => open).map(([i]) => i)
      const div = ul.appendChild(document.createElement('li')).appendChild(document.createElement('div'))
      div.classList.add('actions')
      if (decrypts.length) {
        const button = div.appendChild(document.createElement('input'))
        button.type = 'button'
        button.value = `Deal card${decrypts.length > 1 ? 's' : ''} ${decrypts.join()}`
        button.classList.add('txnRequester')
        button.addEventListener('click', _ => {
          socket.emit('decryptCards', config.id, decrypts)
          button.disabled = true
        })
      }
      if (opens.length) {
        const button = div.appendChild(document.createElement('input'))
        button.type = 'button'
        button.value = `Open card${opens.length > 1 ? 's' : ''} ${opens.join()}`
        button.classList.add('txnRequester')
        button.addEventListener('click', _ => {
          socket.emit('openCards', config.id, opens)
          button.disabled = true
        })
      }
      if (!di.waitingOn.length) {
        const button = div.appendChild(document.createElement('input'))
        button.type = 'button'
        button.value = 'Finish deal'
        button.classList.add('txnRequester')
        button.addEventListener('click', _ => {
          socket.emit('endDeal', config.id)
          button.disabled = true
        })
      }
    }
    if (phases[di.phase] === 'PLAY') {
      if (di.actionIndex == di.seatIndex) {
        const div = li.appendChild(document.createElement('div'))
        div.classList.add('actions')
        const fold = div.appendChild(document.createElement('input'))
        fold.type = 'button'
        fold.value = 'Fold'
        const call = div.appendChild(document.createElement('input'))
        call.type = 'button'
        call.value = di.callBy === '0.0' ? 'Check' : `Call ${di.bet[di.betIndex]} with ${di.callBy}`
        const betDiv = div.appendChild(document.createElement('div'))
        const bet = betDiv.appendChild(document.createElement('input'))
        bet.type = 'button'
        bet.value = di.callBy === '0.0' ? 'Bet' : 'Raise with '
        const amount = betDiv.appendChild(document.createElement('input'))
        amount.inputmode = 'decimal'
        amount.pattern = "^([1-9]\\d*)|(\\d*\\.\\d+)$"
        amount.value = di.minRaiseBy
        amount.classList.add('amount')
        const buttons = [fold, call, bet]
        buttons.forEach(b => b.classList.add('txnRequester'))
        fold.addEventListener('click', _ => {
          socket.emit('fold', config.id, di.seatIndex)
          buttons.forEach(b => b.disabled = true)
        })
        call.addEventListener('click', _ => {
          socket.emit('call', config.id, di.seatIndex)
          buttons.forEach(b => b.disabled = true)
        })
        bet.addEventListener('click', _ => {
          if (amount.checkValidity()) {
            socket.emit('raise', config.id, di.seatIndex, amount.value, di.bet[di.seatIndex])
            buttons.forEach(b => b.disabled = true)
          }
          else
            amount.reportValidity()
        })
      }
    }
    if (phases[di.phase] === 'SHOW') {
      if (di.actionIndex == di.seatIndex) {
        const fold = li.appendChild(document.createElement('input'))
        fold.type = 'button'
        fold.value = 'Fold'
        const call = li.appendChild(document.createElement('input'))
        call.type = 'button'
        call.value = 'Show'
        const buttons = [fold, call]
        buttons.forEach(b => b.classList.add('txnRequester'))
        call.addEventListener('click', _ => {
          socket.emit('show', config.id, di.seatIndex)
          buttons.forEach(b => b.disabled = true)
        })
        fold.addEventListener('click', _ => {
          socket.emit('foldCards', config.id, di.seatIndex)
          buttons.forEach(b => b.disabled = true)
        })
      }
    }
    setTimeout(() => socket.emit('requestLogCount', config.id), 100)
  })
  playDiv.appendChild(fragment)
})

const buyInElement = document.getElementById('buyIn')
const bondElement = document.getElementById('bond')
const startsWithElement = document.getElementById('startsWith')
const untilLeftElement = document.getElementById('untilLeft')
const seatIndexElement = document.getElementById('seatIndex')
const structureElement = document.getElementById('structure')
const levelBlocksElement = document.getElementById('levelBlocks')
const verifRoundsElement = document.getElementById('verifRounds')
const prepBlocksElement = document.getElementById('prepBlocks')
const shuffBlocksElement = document.getElementById('shuffBlocks')
const verifBlocksElement = document.getElementById('verifBlocks')
const dealBlocksElement = document.getElementById('dealBlocks')
const actBlocksElement = document.getElementById('actBlocks')
const configElements = [
  buyInElement, bondElement, startsWithElement, untilLeftElement, seatIndexElement,
  structureElement, levelBlocksElement, verifRoundsElement,
  prepBlocksElement, shuffBlocksElement, verifBlocksElement, dealBlocksElement, actBlocksElement
]
const createDiv = document.getElementById('createDiv')
const createGameButton = document.getElementById('createGame')
const hideNewGameButton = document.getElementById('hideNewGame')

createGameButton.classList.add('txnRequester')

createGameButton.addEventListener('click', (e) => {
  seatIndexElement.max = startsWithElement.value - 1
  if (configElements.every(x => x.checkValidity())) {
    socket.emit('createGame',
      Object.fromEntries(configElements.map(x => [x.id, x.value])))
    createGameButton.disabled = true
  }
  else {
    configElements.forEach(x => x.reportValidity())
  }
})

hideNewGameButton.addEventListener('click', _ => {
  if (createDiv.classList.contains('hidden')) {
    createDiv.classList.remove('hidden')
    hideNewGameButton.value = 'Hide'
  }
  else {
    createDiv.classList.add('hidden')
    hideNewGameButton.value = 'Show'
  }
})

setTimeout(() => {
  resetFeesButton.dispatchEvent(new Event('click'))
  privkeyElement.dispatchEvent(new Event('change'))
}, 100)
