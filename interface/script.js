const socket = io()

const errorMsg = document.getElementById('errorMsg')

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

socket.on('errorMsg', msg => {
  errorMsg.innerText = msg
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

socket.on('activeGames', (configs, data) => {
  playDiv.replaceChildren()
  configs.forEach(config => {
    const li = playDiv.appendChild(document.createElement('li'))
    li.appendChild(document.createElement('p')).innerText = JSON.stringify(config)
    const ul = li.appendChild(document.createElement('ul'))
    ul.appendChild(document.createElement('li')).innerText = `Your seat: ${data[config.id].seatIndex}`
    ul.appendChild(document.createElement('li')).innerText = `Game phase: ${phases[data[config.id].phase]}`
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
