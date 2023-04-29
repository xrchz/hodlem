const socket = io()
import { ethers } from "./node_modules/ethers/dist/ethers.esm.min.js"

// TODO: add option to choose multiplier for formatting amounts (e.g. gwei)
// TODO: input validation for send funds form
// TODO: buttons should be disabled based on whether a transaction is actually pending
// TODO: show next small blind value (in config)
// TODO: show/hide account balance even if wallet is hidden
// TODO: hover over seat number to see address also for Game logs
// TODO: add antes to structure
// TODO: make preset bet size buttons customisable
// TODO: test corner cases of dealers and blinds when players are eliminated
// TODO: test multiple side pots
// TODO: test split side pot
// TODO: test act timeout during showdown
// TODO: test act timeout during betting with all-in players
// TODO: test shuffle timeout with an eliminated player
// TODO: pack structs
// TODO: profile and optimise gas usage
// TODO: add configurable rake and gas refund accounting?
// TODO: add penalties (instead of full abort on failure)?
// TODO: add pause?
// TODO: use ethers for more formatting client-side?

const fragment = document.createDocumentFragment()

const errorMsg = document.getElementById('errorMsg')
const errorMsgText = errorMsg.getElementsByTagName('span')[0]
const clearErrorMsgButton = errorMsg.getElementsByTagName('input')[0]

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

const maxFeeElement = document.getElementById('maxFeePerGas')
const prioFeeElement = document.getElementById('maxPriorityFeePerGas')
const resetFeesButton = document.getElementById('resetFees')

const addressElement = document.getElementById('address')
const privkeyElement = document.getElementById('privkey')
const newAccountButton = document.getElementById('newAccount')
const hidePrivkeyButton = document.getElementById('hidePrivKey')

const walletDiv = document.getElementById('wallet')
const hideWalletButton = document.getElementById('hideWallet')

const joinDiv = document.getElementById('joinDiv')
const playDiv = document.getElementById('playDiv')

const balanceElement = document.getElementById('balance')
const sendAmountElement = document.getElementById('sendAmount')
const sendToElement = document.getElementById('sendTo')
const sendButton = document.getElementById('sendButton')

const transactionDiv = document.getElementById('transaction')
const txnInfoElement = document.getElementById('txnInfo')
const acceptTxnButton = document.getElementById('acceptTxn')
const rejectTxnButton = document.getElementById('rejectTxn')
const sendTxnsCheckbox = document.getElementById('sendTxns')

socket.on('errorMsg', msg => {
  errorMsg.classList.remove('hidden')
  errorMsgText.innerText = msg
  document.querySelectorAll('input.txnRequester').forEach(b => b.disabled = false)
})

clearErrorMsgButton.addEventListener('click', _ => {
  errorMsg.classList.add('hidden')
})

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

hideWalletButton.addEventListener('click', (e) => {
  if (wallet.classList.contains('hidden')) {
    wallet.classList.remove('hidden')
    hideWalletButton.value = 'Hide Wallet'
    if (!e.fromScript)
      socket.emit('deletePreference', 'wallet', '')
  }
  else {
    wallet.classList.add('hidden')
    hideWalletButton.value = 'Show Wallet'
    if (!e.fromScript)
      socket.emit('addPreference', 'wallet', '')
  }
})

hidePrivkeyButton.addEventListener('click', (e) => {
  if (privkeyElement.classList.contains('hidden')) {
    privkeyElement.classList.remove('hidden')
    hidePrivkeyButton.value = 'Hide'
    if (!e.fromScript)
      socket.emit('deletePreference', 'pkey', '')
  }
  else {
    privkeyElement.classList.add('hidden')
    hidePrivkeyButton.value = 'Show'
    if (!e.fromScript)
      socket.emit('addPreference', 'pkey', '')
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

sendButton.addEventListener('click', (e) => {
  if (sendToElement.checkValidity() && sendAmountElement.checkValidity()) {
    socket.emit('send', sendToElement.value, sendAmountElement.value)
    sendButton.disabled = true
  }
  else {
    sendToElement.reportValidity()
    sendAmountElement.reportValidity()
  }
})

socket.on('balance', balance => {
  balanceElement.value = balance
  sendButton.disabled = false
})

sendTxnsCheckbox.addEventListener('change', e => {
  if (!e.fromScript)
    socket.emit(sendTxnsCheckbox.checked ? 'addPreference' : 'deletePreference', 'send', '')
})

socket.on('requestTransaction', (tx, formatted) => {
  txnInfoElement.data = tx
  if (sendTxnsCheckbox.checked) {
    const e = new Event('click')
    e.fromScript = true
    acceptTxnButton.dispatchEvent(e)
  }
  else {
    if (walletDiv.classList.contains('hidden')) {
      hideWalletButton.disabled = true
      walletDiv.classList.remove('hidden')
    }
    transactionDiv.classList.remove('hidden')
    Object.entries(formatted).forEach(([key, value]) => {
      fragment.appendChild(document.createElement('dt')).innerText = key
      fragment.appendChild(document.createElement('dd')).innerText = value
    })
    txnInfoElement.replaceChildren(fragment)
  }
})

acceptTxnButton.addEventListener('click', (e) => {
  socket.emit('transaction', txnInfoElement.data)
  transactionDiv.classList.add('hidden')
  if (hideWalletButton.disabled) {
    hideWalletButton.disabled = false
    walletDiv.classList.add('hidden')
  }
})

rejectTxnButton.addEventListener('click', (e) => {
  delete txnInfoElement.data
  transactionDiv.classList.add('hidden')
  if (hideWalletButton.disabled) {
    hideWalletButton.disabled = false
    walletDiv.classList.add('hidden')
  }
  document.querySelectorAll('input.txnRequester').forEach(b => b.disabled = false)
})

const emptyAddress = '0x0000000000000000000000000000000000000000'

const rankNames = ['Deuce', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine', 'Ten', 'Jack', 'Queen', 'King', 'Ace']

function cardSpan(card) {
  const span = document.createElement('span')
  span.classList.add('card')
  if (card >= 52) span.innerText = '🂠'
  else {
    let codepoint = 0x1F000
    const suit = Math.floor(card / 13)
    codepoint += 0xA0 + 16 * suit
    const rank = card % 13
    codepoint += rank === 12 ? 1 : rank + 2 + (9 < rank)
    const suitName = ['Spades', 'Hearts', 'Diamonds', 'Clubs'][suit]
    span.classList.add(suitName)
    const rankName = rankNames[rank]
    span.title = `${rankName} of ${suitName}`
    span.innerText = String.fromCodePoint(codepoint)
  }
  return span
}

function parseHandRank(r) {
  const t = ['None', 'High Card', 'Pair', 'Two Pair', 'Set', 'Straight', 'Flush', 'Boat', 'Quads', 'Straight Flush'][r >> BigInt(5 * 8)]
  const mask = BigInt('0xff')
  const a = []
  a.push((r >> BigInt(4 * 8)) & mask)
  a.push((r >> BigInt(3 * 8)) & mask)
  a.push((r >> BigInt(2 * 8)) & mask)
  a.push((r >> BigInt(1 * 8)) & mask)
  a.push(r & mask)
  console.log(JSON.stringify(a.map(n => n.toString())))
  return `${t}: [${a.flatMap(n => n === 0n ? [] : [rankNames[n]]).join(', ')}]`
}

const logs = new Map()
const pendingGames = new Map()
const activeGames = new Map()
const addressToSeat = new Map()
const hideConfig = new Set()
const hideLog = new Set()

socket.on('preferences', (dict) => {
  sendTxnsCheckbox.checked = 'send' in dict && dict.send.length

  if ('create' in dict &&
      ((dict.create.length && hideNewGameButton.value === 'Hide') ||
       (!dict.create.length && hideNewGameButton.value === 'Show'))) {
    const e = new Event('click')
    e.fromScript = true
    hideNewGameButton.dispatchEvent(e)
  }

  if ('pkey' in dict &&
      ((dict.pkey.length && hidePrivkeyButton.value === 'Hide') ||
       (!dict.pkey.length && hidePrivkeyButton.value === 'Show'))) {
    const e = new Event('click')
    e.fromScript = true
    hidePrivkeyButton.dispatchEvent(e)
  }

  if ('wallet' in dict &&
      ((dict.wallet.length && hideWalletButton.value === 'Hide Wallet') ||
       (!dict.wallet.length && hideWalletButton.value === 'Show Wallet'))) {
    const e = new Event('click')
    e.fromScript = true
    hideWalletButton.dispatchEvent(e)
  }

  const newHideConfig = new Set(dict.config)
  hideConfig.forEach(id => {
    if (!newHideConfig.has(id)) {
      hideConfig.delete(id)
      const hideConfigButton = document.getElementById(`hideConfig${id}`)
      if (hideConfigButton && hideConfigButton.value === 'Show Config') {
        const e = new Event('click')
        e.fromScript = true
        hideConfigButton.dispatchEvent(e)
      }
    }
  })
  newHideConfig.forEach(id => {
    if (!hideConfig.has(id)) {
      hideConfig.add(id)
      const hideConfigButton = document.getElementById(`hideConfig${id}`)
      if (hideConfigButton && hideConfigButton.value === 'Hide Config') {
        const e = new Event('click')
        e.fromScript = true
        hideConfigButton.dispatchEvent(e)
      }
    }
  })

  const newHideLog = new Set(dict.log)
  hideLog.forEach(id => {
    if (!newHideLog.has(id)) {
      hideLog.delete(id)
      const hideLogButton = document.getElementById(`hideLog${id}`)
      if (hideLogButton && hideLogButton.value === 'Show Log') {
        const e = new Event('click')
        e.fromScript = true
        hideLogButton.dispatchEvent(e)
      }
    }
  })
  newHideLog.forEach(id => {
    if (!hideLog.has(id)) {
      hideLog.add(id)
      const hideLogButton = document.getElementById(`hideLog${id}`)
      if (hideLogButton && hideLogButton.value === 'Hide Log') {
        const e = new Event('click')
        e.fromScript = true
        hideLogButton.dispatchEvent(e)
      }
    }
  })
})

socket.on('logCount', (id, count) => {
  if (logs.get(id).length < count)
    socket.emit('requestLogs', id, count - logs.get(id).length)
})

socket.on('logs', (id, newLogs) => {
  logs.get(id).push(...newLogs)
  const logsList = document.getElementById(`logs${id}`)
  fragment.append(...logs.get(id).map(log => {
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
    if (log.name === 'DealRound' && typeof log.args[0] !== 'string') {
      log.args[0] = ['Hole Cards', 'Flop', 'Turn', 'River', 'Showdown'][log.args[0] - 1]
    }
    if (log.name === 'ShowHand' && log.args[1].startsWith('0x')) {
      log.args[1] = parseHandRank(BigInt(log.args[1]))
    }
    if (typeof log.args[0] === 'string' && log.args[0].startsWith('0x') &&
        log.name !== 'JoinTable') {
      const span = document.createElement('span')
      span.innerText = addressToSeat.get(id).get(log.args[0])
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
  configDiv.classList.add('hidden')
  const hideConfigButton = li.appendChild(document.createElement('input'))
  hideConfigButton.id = `hideConfig${config.id}`
  hideConfigButton.type = 'button'
  hideConfigButton.value = 'Show Config'
  hideConfigButton.classList.add('toggle')
  hideConfigButton.addEventListener('click', e => {
    if (configDiv.classList.contains('hidden')) {
      configDiv.classList.remove('hidden')
      hideConfigButton.value = 'Hide Config'
      hideConfig.delete(config.id)
      if (!e.fromScript)
        socket.emit('deletePreference', 'config', config.id)
    }
    else {
      configDiv.classList.add('hidden')
      hideConfigButton.value = 'Show Config'
      hideConfig.add(config.id)
      if (!e.fromScript)
        socket.emit('addPreference', 'config', config.id)
    }
  })
  if (!hideConfig.has(config.id)) {
    const e = new Event('click')
    e.fromScript = true
    hideConfigButton.dispatchEvent(e)
  }
}

function addLogsUl(li, tableId) {
  const logsUl = li.appendChild(document.createElement('ul'))
  logsUl.id = `logs${tableId}`
  logsUl.classList.add('logs', 'hidden')
  const hideLogButton = li.appendChild(document.createElement('input'))
  hideLogButton.id = `hideLog${tableId}`
  hideLogButton.type = 'button'
  hideLogButton.value = 'Show Log'
  hideLogButton.classList.add('toggle')
  hideLogButton.addEventListener('click', e => {
    if (logsUl.classList.contains('hidden')) {
      logsUl.classList.remove('hidden')
      hideLogButton.value = 'Hide Log'
      hideLog.delete(tableId)
      if (!e.fromScript)
        socket.emit('deletePreference', 'log', tableId)
    }
    else {
      logsUl.classList.add('hidden')
      hideLogButton.value = 'Show Log'
      hideLog.add(tableId)
      if (!e.fromScript)
        socket.emit('addPreference', 'log', tableId)
    }
  })
  if (!hideLog.has(tableId)) {
    const e = new Event('click')
    e.fromScript = true
    hideLogButton.dispatchEvent(e)
  }
}

socket.on('pendingGames', (configs, seats) => {
  const pendingIds = configs.map(({id}) => id)
  for (const k of pendingGames.keys()) {
    if (!(pendingIds.includes(k))) pendingGames.delete(k)
  }
  configs.forEach(config => {
    if (!(logs.has(config.id))) logs.set(config.id, [])
    if (!(pendingGames.has(config.id))) {
      const li = document.createElement('li')
      pendingGames.set(config.id, li)
      addGameConfig(li, config)
      addLogsUl(li, config.id)
      const ol = li.appendChild(document.createElement('ol'))
      ol.start = 0
    }
    const onTable = seats[config.id].includes(addressElement.value)
    seats[config.id].forEach((addr, seatIndex) => {
      const seatLi = fragment.appendChild(document.createElement('li'))
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
    pendingGames.get(config.id).querySelector('ol').replaceChildren(fragment)
    setTimeout(() => socket.emit('requestLogCount', config.id), 100)
  })
  joinDiv.replaceChildren(...pendingGames.values())
  createGameButton.disabled = false
})

const phases = ['NONE', 'JOIN', 'PREP', 'SHUF', 'DEAL', 'PLAY', 'SHOW']

socket.on('activeGames', (configs, data) => {
  const activeIds = configs.map(({id}) => id)
  for (const k of activeGames.keys()) {
    if (!(activeIds.includes(k))) activeGames.delete(k)
  }
  configs.forEach(config => {
    if (!(logs.has(config.id))) logs.set(config.id, [])
    if (!(activeGames.has(config.id))) {
      const li = document.createElement('li')
      activeGames.set(config.id, li)
      addGameConfig(li, config)
      addLogsUl(li, config.id)
      const ul = li.appendChild(document.createElement('ul'))
      ul.classList.add('game')
      const div = li.appendChild(document.createElement('div'))
      div.classList.add('actions')
    }
    const di = data[config.id]
    if (!(addressToSeat.has(config.id))) {
      const m = new Map()
      addressToSeat.set(config.id, m)
      di.players.forEach((addr, seatIndex) => {
        m.set(addr, seatIndex)
      })
    }
    const actionOn = new Set()
    const stacks = document.createElement('ul')
    const ul = fragment
    const div = document.createDocumentFragment()
    if (phases[di.phase] === 'PREP') {
      ul.appendChild(document.createElement('li')).innerText = `Your seat: ${di.seatIndex}`
      ul.appendChild(document.createElement('li')).innerText = `Waiting on: ${JSON.stringify(di.waitingOn)}`
      if (di.waitingOn.includes(di.seatIndex)) {
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
      const board = ul.appendChild(document.createElement('li'))
      board.appendChild(document.createElement('span')).innerText = 'Board🟩: '
      di.board.forEach(card => board.appendChild(cardSpan(card - 1)))
      const hole = ul.appendChild(document.createElement('li'))
      hole.appendChild(document.createElement('span')).innerText = 'Cards🫴: '
      di.hand.forEach(card => { if (card) hole.appendChild(cardSpan(card - 1)) })
      ul.appendChild(stacks)
      stacks.classList.add('stacks')
      ul.appendChild(document.createElement('li')).innerText = `Bet🪙: ${di.bet[di.betIndex]}`
      const pots = ul.appendChild(document.createElement('li'))
      pots.appendChild(document.createElement('span')).innerText = `Pot${di.pot.length > 1 ? 's' : ''}🍯: `
      const potsList = pots.appendChild(document.createElement('ul'))
      potsList.classList.add('pots')
      di.pot.forEach(pot => potsList.appendChild(document.createElement('li')).innerText = pot)
      potsList.appendChild(document.createElement('li')).innerText = `(with bets: ${di.lastPotWithBets})`
    }
    if (phases[di.phase] === 'SHUF') {
      if (di.shuffleCount < config.startsWith) {
        actionOn.add(di.shuffleCount)
        if (di.shuffleCount === di.seatIndex) {
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
        di.waitingOn.forEach(i => actionOn.add(i))
        if (di.waitingOn.includes(di.seatIndex)) {
          const button = div.appendChild(document.createElement('input'))
          button.type = 'button'
          button.value = 'Verify shuffle'
          button.classList.add('txnRequester')
          button.addEventListener('click', _ => {
            socket.emit('verifyShuffle', config.id)
            button.disabled = true
          })
        }
      }
    }
    if (phases[di.phase] === 'DEAL') {
      di.waitingOn.forEach(({who}) => actionOn.add(who))
      const requests = di.waitingOn.flatMap(({who, what, open}) => (who === di.seatIndex ? [[what, open]] : []))
      const decrypts = requests.filter(([, open]) => !open).map(([i]) => i)
      const opens = requests.filter(([, open]) => open).map(([i]) => i)
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
    }
    if (phases[di.phase] === 'PLAY') {
      actionOn.add(di.actionIndex)
      if (di.actionIndex == di.seatIndex) {
        const fold = div.appendChild(document.createElement('input'))
        fold.type = 'button'
        fold.value = 'Fold'
        const call = div.appendChild(document.createElement('input'))
        call.type = 'button'
        call.value = di.callBy === '0.0' ? 'Check' : `Call ${di.bet[di.betIndex]} with ${di.callBy}`
        const betDiv = div.appendChild(document.createElement('div'))
        betDiv.classList.add('bet')
        const bet = betDiv.appendChild(document.createElement('input'))
        bet.type = 'button'
        bet.value = di.callBy === '0.0' ? 'Bet ' : 'Raise with '
        const amountDiv = betDiv.appendChild(document.createElement('div'))
        amountDiv.classList.add('amount')
        const amountWei = amountDiv.appendChild(document.createElement('input'))
        const amountEther = amountDiv.appendChild(document.createElement('input'))
        const slider = amountDiv.appendChild(document.createElement('input'))
        const minRaiseByWei = ethers.utils.parseEther(di.minRaiseBy).toString()
        amountWei.type = 'number'
        amountWei.inputmode = 'numeric'
        amountWei.pattern = "^([1-9]\\d*)"
        amountWei.value = minRaiseByWei
        amountWei.min = minRaiseByWei
        amountWei.max = ethers.utils.parseEther(di.stack[di.seatIndex]).toString()
        amountWei.step = 1
        amountWei.classList.add('amountWei')
        amountEther.type = 'text'
        amountEther.inputmode = 'decimal'
        amountEther.pattern = "^([1-9]\\d*)|(\\d*\\.\\d+)$"
        amountEther.value = di.minRaiseBy
        amountEther.classList.add('amount')
        slider.type = 'range'
        slider.classList.add('amount')
        slider.min = amountWei.min
        slider.max = amountWei.max
        slider.step = amountWei.step
        const ticks = new Map()
        function addRaiseButton(value, name) {
          if (ticks.has(value)) return
          if (BigInt(value) < BigInt(amountWei.min) || BigInt(value) > BigInt(amountWei.max)) return
          const button = document.createElement('input')
          ticks.set(value, button)
          button.type = 'button'
          button.value = name
          button.classList.add('amount')
          button.classList.add('toggle')
          button.addEventListener('click', _ => {
            amountWei.value = value
            amountWei.dispatchEvent(new Event('change'))
          })
        }
        addRaiseButton(amountWei.min, 'min')
        addRaiseButton(amountWei.max, 'all-in')
        if (di.board.length) {
          const p = BigInt(ethers.utils.parseEther(di.lastPotWithBets).toString())
          addRaiseButton(p.toString(), 'pot')
          addRaiseButton((p / 2n).toString(), '½-pot')
          addRaiseButton((p * 2n / 3n).toString(), '⅔-pot')
          addRaiseButton((p * 3n / 4n).toString(), '¾-pot')
        }
        else {
          const b = BigInt(minRaiseByWei) // TODO: make the values correct
          addRaiseButton((2n * b).toString(), '1BB')
          addRaiseButton((4n * b).toString(), '2BB')
          addRaiseButton((6n * b).toString(), '3BB')
        }
        const betButtons = amountDiv.appendChild(document.createElement('div'))
        betButtons.classList.add('betButtons')
        const ticksKeys = Array.from(ticks.keys())
        ticksKeys.sort((a, b) => BigInt(a) <= BigInt(b) ? -1 : 1)
        for (const k of ticksKeys) betButtons.appendChild(ticks.get(k))
        slider.addEventListener('change', e => {
          if (!e.fromAmount) {
            amountWei.value = BigInt(slider.valueAsNumber).toString()
            const e2 = new Event('change')
            e2.fromSlider = true
            amountWei.dispatchEvent(e2)
          }
        })
        amountWei.addEventListener('change', e => {
          if (amountWei.checkValidity()) {
            const e2 = new Event('change')
            e2.fromAmount = true
            if (!e.fromSlider) {
              slider.value = amountWei.value
              slider.dispatchEvent(e2)
            }
            if (!e.fromAmountEther) {
              amountEther.value = ethers.utils.formatEther(amountWei.value)
              amountEther.dispatchEvent(e2)
            }
          }
          else {
            amountWei.reportValidity()
          }
        })
        amountEther.addEventListener('change', e => {
          if (!e.fromAmount) {
            if (amountEther.checkValidity()) {
              amountWei.value = ethers.utils.parseEther(amountEther.value).toString()
              const e2 = new Event('change')
              e2.fromAmountEther = true
              amountWei.dispatchEvent(e2)
            }
            else {
              amountEther.reportValidity()
            }
          }
        })
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
          if (amountWei.checkValidity()) {
            socket.emit('raise', config.id, di.seatIndex, amountWei.value, di.bet[di.seatIndex])
            buttons.forEach(b => b.disabled = true)
          }
          else
            amountWei.reportValidity()
        })
      }
    }
    if (phases[di.phase] === 'SHOW') {
      actionOn.add(di.actionIndex)
      if (di.actionIndex == di.seatIndex) {
        const fold = div.appendChild(document.createElement('input'))
        fold.type = 'button'
        fold.value = 'Fold'
        const call = div.appendChild(document.createElement('input'))
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
    if (phases[di.phase] !== 'PREP') {
      di.stack.forEach((s, i) => {
        const pli = stacks.appendChild(document.createElement('li'))
        const seat = pli.appendChild(document.createElement('span'))
        seat.classList.add('seat')
        seat.innerText = i.toString()
        seat.title = `Player ${i}`
        const stack = pli.appendChild(document.createElement('span'))
        stack.classList.add('stack')
        stack.innerText = s
        stack.title = `${i}'s stack`
        const bet = pli.appendChild(document.createElement('span'))
        bet.classList.add('bet')
        bet.innerText = di.bet[i]
        bet.title = `${i}'s bet`
        if (i === di.dealer) {
          pli.classList.add('dealer')
          seat.title += ' (dealer)'
        }
        if (actionOn.has(i)) pli.classList.add('action')
        if (i === di.seatIndex) {
          pli.classList.add('self')
          seat.title += ' (you)'
        }
      })
    }
    activeGames.get(config.id).querySelector('ul.game').replaceChildren(ul)
    activeGames.get(config.id).querySelector('div.actions').replaceChildren(div)
    setTimeout(() => socket.emit('requestLogCount', config.id), 100)
  })
  playDiv.replaceChildren(...activeGames.values())
})

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

hideNewGameButton.addEventListener('click', e => {
  if (createDiv.classList.contains('hidden')) {
    createDiv.classList.remove('hidden')
    hideNewGameButton.value = 'Hide'
    if (!e.fromScript)
      socket.emit('deletePreference', 'create', '')
  }
  else {
    createDiv.classList.add('hidden')
    hideNewGameButton.value = 'Show'
    if (!e.fromScript)
      socket.emit('addPreference', 'create', '')
  }
})

setTimeout(() => {
  resetFeesButton.dispatchEvent(new Event('click'))
  privkeyElement.dispatchEvent(new Event('change'))
}, 100)
