import { Controller } from "@hotwired/stimulus"

// The runner thread: the answered steps, and whatever the run is waiting on.
//
// Owns only what belongs to the list as a whole — bringing a newly streamed
// card into view and easing it in. Focus, the page title and the live-region
// announcement stay on scenario-step, which owns the card itself: they are
// properties of the step being answered, not of the list around it.
//
// Usage:
//   <ol data-controller="thread">
//     <li data-thread-target="current"> ... </li>
export default class extends Controller {
  static targets = ["current"]

  // Fires for the card present on load and for every card streamed in after an
  // answer. Not gated on the first one deliberately: landing on the open step
  // is the right place to be after a refresh of a long run, and if the thread
  // already fits on screen scrollIntoView does nothing.
  currentTargetConnected(element) {
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches

    element.scrollIntoView({ block: "center", behavior: reduced ? "auto" : "smooth" })

    if (reduced) return

    element.animate(
      [
        { opacity: 0, transform: "translateY(0.5rem)" },
        { opacity: 1, transform: "translateY(0)" }
      ],
      { duration: 240, easing: "ease-out" }
    )
  }
}
