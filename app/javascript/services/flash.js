// Shows an alert in #flash the way a server flash appears, for a change the page
// made itself and the server never answered for (a drag that didn't save). It
// copies the empty alert the application layout keeps in #flash-alert-template,
// so the markup lives in shared/_flash_message alone.
export function flashAlert(message) {
  const template = document.getElementById("flash-alert-template")
  const container = document.getElementById("flash")
  if (!template || !container) return

  const flash = template.content.firstElementChild.cloneNode(true)
  flash.querySelector(".flash__text").textContent = message
  container.replaceChildren(flash)
}
