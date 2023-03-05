const socket = io()

socket.on('hello', () => {
  document.getElementsByTagName('p')[0].innerHTML += ' Hello from the server!'
})
