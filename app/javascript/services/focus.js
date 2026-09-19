// Putting focus somewhere deliberate after a Turbo Stream has replaced the
// thing that had it.
//
// When the focused element is removed, focus falls to <body> - a keyboard user
// is returned to the top of the page, and a screen reader loses its place. The
// element to move to usually does not exist yet at the moment we learn the
// request succeeded (`turbo:submit-end` can arrive before the stream that
// rebuilds the panel has rendered), so this waits a few frames for it.
export function focusWhenPresent(selector, { within = document, frames = 20 } = {}) {
  return new Promise(resolve => {
    const attempt = left => {
      const element = within.querySelector(selector)
      if (element) {
        element.focus()
        resolve(element)
        return
      }
      if (left <= 0) {
        resolve(null)
        return
      }
      requestAnimationFrame(() => attempt(left - 1))
    }

    attempt(frames)
  })
}
