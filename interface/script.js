const socket = io()

const addressElement = document.getElementById('address')
const privkeyElement = document.getElementById('privkey')
const newAccountButton = addressElement.parentElement.previousElementSibling
const hidePrivkeyButton = privkeyElement.previousElementSibling

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
})

privkeyElement.dispatchEvent(new Event('change'))

const balanceElement = document.getElementById('balance')

socket.on('balance', balance => {
  balanceElement.value = balance
})
