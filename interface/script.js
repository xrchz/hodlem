const socket = io()

const errorMsg = document.getElementById('errorMsg')
const errorMsgText = errorMsg.getElementsByTagName('span')[0]
const clearErrorMsgButton = errorMsg.getElementsByTagName('input')[0]

socket.on('errorMsg', msg => {
  errorMsg.classList.remove('hidden')
  errorMsgText.innerText = msg
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

resetFeesButton.dispatchEvent(new Event('click'))

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
})

privkeyElement.addEventListener('change', (e) => {
  newAccountButton.disabled = privkeyElement.value != ''
  socket.emit('privkey', privkeyElement.value)
})

socket.on('account', (address, privkey) => {
  addressElement.value = address
  privkeyElement.value = privkey
  newAccountButton.disabled = privkeyElement.value != ''
  joinDiv.replaceChildren()
  playDiv.replaceChildren()
})

privkeyElement.dispatchEvent(new Event('change'))

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

socket.on('pendingGames', (configs, seats) => {
  joinDiv.replaceChildren()
  configs.forEach(config => {
    const li = joinDiv.appendChild(document.createElement('li'))
    li.appendChild(document.createElement('p')).innerText = JSON.stringify(config)
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
        button.addEventListener('click', (e) => {
          socket.emit(`${button.value.toLowerCase()}Game`, config.id, seatIndex)
        })
      }
    })
    if (!seats[config.id].includes(emptyAddress)) {
      const button = li.appendChild(document.createElement('input'))
      button.type = 'button'
      button.value = 'Start'
      button.addEventListener('click', (e) => {
        socket.emit('startGame', config.id)
      })
    }
  })
})

const phases = ['NONE', 'JOIN', 'PREP', 'SHUF', 'DEAL', 'PLAY', 'SHOW']

function cardChar(card) {
  let codepoint = 0x1F000
  codepoint += 0xA0 + 16 * Math.floor(card / 13)
  const rank = card % 13
  codepoint += rank === 12 ? 1 : rank + 2 + (9 < rank)
  return String.fromCodePoint(codepoint)
}

socket.on('activeGames', (configs, data) => {
  playDiv.replaceChildren()
  configs.forEach(config => {
    const di = data[config.id]
    const li = playDiv.appendChild(document.createElement('li'))
    li.appendChild(document.createElement('p')).innerText = JSON.stringify(config)
    const ul = li.appendChild(document.createElement('ul'))
    ul.appendChild(document.createElement('li')).innerText = `Your seat: ${di.seatIndex}`
    ul.appendChild(document.createElement('li')).innerText = `Game phase: ${phases[di.phase]}`
    if (phases[di.phase] === 'PREP') {
      if (di.waitingOn.length) {
        ul.appendChild(document.createElement('li')).innerText = `Waiting on: ${JSON.stringify(di.waitingOn)}`
        if (di.waitingOn.includes(di.seatIndex)) {
          const button = li.appendChild(document.createElement('input'))
          button.type = 'button'
          button.value = 'Submit preparation'
          button.addEventListener('click', _ => {
            socket.emit('submitPrep', config.id)
          })
        }
      }
      else {
        const button = li.appendChild(document.createElement('input'))
        button.type = 'button'
        button.value = 'Finish preparation'
        button.addEventListener('click', _ => {
          socket.emit('finishPrep', config.id)
        })
      }
    }
    if (phases[di.phase] === 'SHUF') {
      if (di.shuffleCount < config.startsWith) {
        ul.appendChild(document.createElement('li')).innerText = `Waiting on: ${di.shuffleCount}`
        if (di.shuffleCount === di.seatIndex) {
          const button = li.appendChild(document.createElement('input'))
          button.type = 'button'
          button.value = 'Submit shuffle'
          button.addEventListener('click', _ => {
            socket.emit('submitShuffle', config.id)
          })
        }
      }
      else {
        ul.appendChild(document.createElement('li')).innerText = `Waiting on: ${JSON.stringify(di.waitingOn)}`
        if (di.waitingOn.includes(di.seatIndex)) {
          const button = li.appendChild(document.createElement('input'))
          button.type = 'button'
          button.value = 'Verify shuffle'
          button.addEventListener('click', _ => {
            socket.emit('submitVerif', config.id)
          })
        }
      }
    }
    if (di.toDeal) {
      const button = li.appendChild(document.createElement('input'))
      button.type = 'button'
      button.value = `Deal ${di.toDeal}`
      button.addEventListener('click', _ => {
        socket.emit(`deal${di.toDeal.split(' ').map(s => s[0].toUpperCase() + s.slice(1)).join('')}`, config.id)
      })
    }
    if (phases[di.phase] === 'DEAL') {
      ul.appendChild(document.createElement('li')).innerText = `Waiting on: ${JSON.stringify(di.waitingOn)}`
      const requests = di.waitingOn.flatMap(({who, what, open}) => (who === di.seatIndex ? [[what, open]] : []))
      requests.forEach(([i, open]) => {
        const button = ul.appendChild(document.createElement('li')).appendChild(document.createElement('input'))
        button.type = 'button'
        button.value = `${open ? 'Open' : 'Deal'} card ${i}`
        button.addEventListener('click', _ => {
          socket.emit(open ? 'openCard' : 'decryptCard', config.id, i)
        })
      })
      if (!di.waitingOn.length) {
        const button = li.appendChild(document.createElement('input'))
        button.type = 'button'
        button.value = 'Finish deal'
        button.addEventListener('click', _ => {
          socket.emit('endDeal', config.id)
        })
      }
    }
    if (phases[di.phase] === 'PLAY') {
      if (di.selectDealer) {
        const drawn = di.cards.map((card, seat) => ({[seat]: cardChar(card - 1)}))
        ul.appendChild(document.createElement('li')).innerText = `Drawn cards: ${JSON.stringify(drawn)}`
        const button = li.appendChild(document.createElement('input'))
        button.type = 'button'
        button.value = 'Select dealer'
        button.addEventListener('click', _ => {
          socket.emit('selectDealer', config.id)
        })
      }
      else {
        ul.appendChild(document.createElement('li')).innerText = `Hole cards: ${di.hand.map(card => cardChar(card - 1)).join()}`
        if (di.postBlinds) {
          const button = li.appendChild(document.createElement('input'))
          button.type = 'button'
          button.value = 'Post blinds'
          button.addEventListener('click', _ => {
            socket.emit('postBlinds', config.id)
          })
        }
        ul.appendChild(document.createElement('li')).innerText = 'TODO: make moves'
      }
    }
  })
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
const createGameButton = document.getElementById('createGame')

createGameButton.addEventListener('click', (e) => {
  seatIndexElement.max = startsWithElement.value - 1
  if (configElements.every(x => x.checkValidity())) {
    socket.emit('createGame',
      Object.fromEntries(configElements.map(x => [x.id, x.value])))
  }
  else {
    configElements.forEach(x => x.reportValidity())
  }
})
