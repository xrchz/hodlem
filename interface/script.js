const socket = io()

const addressElement = document.getElementById('address')
const privkeyElement = document.getElementById('privkey')
const newAccountButton = addressElement.parentElement.previousElementSibling
const hidePrivkeyButton = privkeyElement.previousElementSibling

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
const refreshBalanceButton = document.getElementById('refreshBalance')
const sendAmountElement = document.getElementById('sendAmount')
const sendToElement = document.getElementById('sendTo')
const sendButton = document.getElementById('sendButton')

refreshBalanceButton.addEventListener('click', (e) => {
  socket.emit('refreshBalance')
})

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

socket.on('waiting', tableId => {
  joinDiv.appendChild(document.createElement('p')).innerText = `Waiting in ${tableId}`
})

socket.on('playing', tableId => {
  playDiv.appendChild(document.createElement('p')).innerText = `Playing in ${tableId}`
})

socket.on('sendError', msg => {
  sendToElement.value = msg
})
