// Putting focus somewhere deliberate after a Turbo Stream has replaced the
// thing that had it.
//
// When the focused element is removed, focus falls to <body> - a keyboard user
// is returned to the top of the page, and a screen reader loses its place.
//
// The catch is timing: `turbo:submit-end` fires before the stream that rebuilds
// the panel has rendered, so at that moment the selector still matches the OLD
// element. Focusing that one is worse than doing nothing - it is about to be
// thrown away, and whatever the browser does with focus afterwards is not a
// decision anybody made. So this waits for a node that is not the one that was
// there when it was called.
export function focusWhenReplaced(selector, { within = document, frames = 20 } = {}) {
  const before = within.querySelector(selector)

  return new Promise(resolve => {
    const attempt = left => {
      const element = within.querySelector(selector)

      if (element && element !== before) {
        element.focus()
        resolve(element)
        return
      }

      if (left <= 0) {
        // Nothing was replaced after all: the response did not rebuild this
        // part of the page. Focusing what is there beats leaving focus on
        // <body>, and it is the same element the author was already on.
        element?.focus()
        resolve(element || null)
        return
      }

      requestAnimationFrame(() => attempt(left - 1))
    }

    attempt(frames)
  })
}
