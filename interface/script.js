const socket = io()

const addressElement = document.getElementById('address')
const privkeyElement = document.getElementById('privkey')
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

socket.on('wallet', (address, privkey) => {
  addressElement.value = address
  privkeyElement.value = privkey
})
