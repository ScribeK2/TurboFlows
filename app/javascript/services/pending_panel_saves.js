// Anything that acts on what the SERVER believes about the open step has to let
// the step panel's pending autosave land first.
//
// The panel holds an edit for up to two seconds, and its doors are rendered by
// the server - so inside that window they show the step as it WAS. A request
// sent from one of them arrives before the save and is answered against the old
// step: a Text question's single blank "Next" connection, written on what is
// about to be a Yes/No question, catches both answers.
//
// Waiting is only half of it. The click still names the door it saw, so the
// server refuses one the step no longer has (GrowStep::GONE_DOOR) - see
// AGENTS.md § Growing a workflow.

// The inline-autosave controllers inside the panel with something outstanding:
// dirty (a debounce still running) or in flight (a save already sent).
export function pendingPanelSaves(application) {
  return [...document.querySelectorAll('#builder-panel [data-controller~="inline-autosave"]')]
    .map(element => application.getControllerForElementAndIdentifier(element, "inline-autosave"))
    .filter(controller => controller && (controller.dirty || controller.inFlight))
}

// Call from a `submit` action. Returns false when nothing is pending, so the
// submit proceeds untouched - which is also what happens on the resubmit, since
// by then the saves have settled.
export function deferSubmitUntilPanelSaved(application, event) {
  const pending = pendingPanelSaves(application)
  if (pending.length === 0) return false

  event.preventDefault()
  const form = event.target
  const submitter = event.submitter

  Promise.all(pending.map(controller => controller.flush())).then(() => {
    // The save's own response may have replaced either: a form that is gone
    // has nothing left to send, and requestSubmit refuses a submitter that is
    // no longer inside the form.
    if (form.isConnected) form.requestSubmit(submitter?.isConnected ? submitter : undefined)
  })

  return true
}
