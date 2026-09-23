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

// Deferred submits are released one at a time, each only after the one before
// it has finished. Turbo keeps one form submission in flight and stops the
// previous when a new one starts, so two grows released in the same tick
// (both waiting on the same save) sent a single POST (QA A-001, 2026-09-23).
let released = Promise.resolve()
const RESUBMIT_TIMEOUT_MS = 15000

// Call from a `submit` action. Returns false when nothing is pending, so the
// submit proceeds untouched - which is also what happens on the resubmit, since
// by then the saves have settled.
//
// What is resubmitted is what the author pressed: the form's fields are read
// NOW. There is one type picker, and opening it for a second door while this
// grow waits rewrites the very fields this one is waiting to send.
export function deferSubmitUntilPanelSaved(application, event) {
  const pending = pendingPanelSaves(application)
  if (pending.length === 0) return false

  event.preventDefault()
  const form = event.target
  const submitter = event.submitter
  const fields = [...new FormData(form, submitter)]
  const action = form.action
  const saved = Promise.all(pending.map(controller => controller.flush()))

  released = released.then(() => saved).then(() => resubmit(form, submitter, fields, action))
  return true
}

// Resolves once the submission has ended, so the next one waits for it.
function resubmit(form, submitter, fields, action) {
  // The form is usually still there. When a response in between replaced it
  // (a grow's answer re-renders the whole list, picker included), a stand-in
  // carrying the same fields is sent instead: the author's press still counts.
  const target = form.isConnected ? restore(form, fields, action) : standIn(action, fields)

  return new Promise(resolve => {
    let done = false
    const finish = () => {
      if (done) return
      done = true
      if (target !== form) target.remove()
      resolve()
    }

    target.addEventListener("turbo:submit-end", finish, { once: true })
    // The author may have typed again meanwhile: the form's own submit action
    // then defers this submit once more (preventDefault, so no submit-end
    // ever comes) and queues it behind this one - which must therefore end
    // here, or the queue would wait on itself. This listener runs after the
    // form's own action (added later) and before Turbo's (on the document).
    target.addEventListener("submit", event => { if (event.defaultPrevented) finish() }, { once: true })
    // Last resort: a submission that never reports back must not hold every
    // later grow for the rest of the page's life.
    setTimeout(finish, RESUBMIT_TIMEOUT_MS)

    target.requestSubmit(target === form && submitter?.isConnected ? submitter : undefined)
  })
}

// The target picker points one form at a different door's URL each time it
// opens, so the URL is restored along with the fields.
function restore(form, fields, action) {
  form.action = action
  for (const [name, value] of fields) {
    const input = form.querySelector(`input[type="hidden"][name="${CSS.escape(name)}"]`)
    if (input) input.value = value
  }
  return form
}

function standIn(action, fields) {
  const form = document.createElement("form")
  form.method = "post"
  form.action = action
  form.hidden = true
  form.dataset.turboStream = "true"
  for (const [name, value] of fields) {
    const input = document.createElement("input")
    input.type = "hidden"
    input.name = name
    input.value = value
    form.append(input)
  }
  document.body.append(form)
  return form
}
