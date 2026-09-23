// Bringing a builder row into view inside the step list's own scroller.
//
// Not element.scrollIntoView(): that scrolls every scrollable ancestor,
// including the page, and at phone width the page scrolls too. This moves
// .builder__list-scroll alone, and only when the row is not already fully
// visible, so a row the author can see never jumps.
//
// The panel opening narrows the list over 250ms (see builder.css), which
// re-wraps rows and can push the one just revealed back out of view, so this
// looks again once that has settled - finding the row afresh by its step id,
// since the acting tab's own list broadcast has usually replaced it by then.
// It never touches focus.
const PANEL_SETTLE_MS = 300

export function revealRowInList(row, { block = "nearest" } = {}) {
  scrollRow(row, block)
  const stepId = row.dataset.stepId
  setTimeout(() => {
    const current = row.isConnected ? row : document.querySelector(`.builder__step[data-step-id="${CSS.escape(stepId)}"]`)
    if (current) scrollRow(current, block)
  }, PANEL_SETTLE_MS)
}

function scrollRow(row, block) {
  const scroller = row?.closest(".builder__list-scroll")
  if (!scroller) return
  // A row inside a closed fold has nowhere to scroll to. Ask the DOM, not the
  // box: Chrome hides a closed <details>' content with content-visibility, so
  // the row still reports a full-size rect (43px measured on Chrome 152) that
  // points at nothing on screen.
  if (row.closest("details:not([open])")) return

  const box = scroller.getBoundingClientRect()
  const rect = row.getBoundingClientRect()
  if (rect.top >= box.top && rect.bottom <= box.bottom) return

  if (block === "center") {
    scroller.scrollTop += rect.top - box.top - (box.height - rect.height) / 2
  } else if (rect.top < box.top || rect.height > box.height) {
    scroller.scrollTop += rect.top - box.top
  } else {
    scroller.scrollTop += rect.bottom - box.bottom
  }
}
