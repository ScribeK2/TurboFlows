import { Controller } from "@hotwired/stimulus"

/**
 * Step Transitions Controller
 *
 * Manages the connections/transitions UI for graph mode workflows.
 * Each step can have multiple transitions to other steps, with optional conditions.
 */
export default class extends Controller {
  static targets = ["transitionsList", "hiddenInput", "rowTemplate", "emptyTemplate"]
  static values = {
    stepId: String,
    stepIndex: Number,
    variables: Array
  }

  connect() {
    this.refresh()

    // A collaborator's change to THIS step's connections arrives as a broadcast
    // aimed at the section this controller lives inside. Applying it is right
    // almost always - it is server truth - but it must not land on top of a row
    // this author has typed and not saved. Only the browser knows that, so the
    // decision is here.
    this.boundDeclineWhileDirty = this.declineWhileDirty.bind(this)
    document.addEventListener("turbo:before-stream-render", this.boundDeclineWhileDirty)
  }

  disconnect() {
    document.removeEventListener("turbo:before-stream-render", this.boundDeclineWhileDirty)
  }

  // Cancels a re-render of this section while the author holds a row the server
  // cannot possibly have, and says so where they are looking. Deliberately NOT
  // a flash: a flash self-dismisses in five seconds and this is durable state,
  // the panel being out of date until they reopen it. It does not stash the
  // fragment to apply later either - applying HTML rendered minutes ago is the
  // staleness this exists to cure.
  //
  // The test is the row's own content, NOT where the stream came from, and not
  // a dirty flag. Nothing here can tell another editor's broadcast from the
  // answer to this panel's own save: both land on this target. A flag said
  // "dirty" for both and cancelled the author's own doors re-render, which a
  // pre-existing grow test caught. And a flag drifts - clearing it on a
  // successful save was wrong too, because a row with no target is written
  // nowhere, so the save succeeded while this editor still held it.
  //
  // A row with no target chosen yet is exactly what TransitionSync writes
  // nowhere, so it is the one thing no incoming render can contain. Every other
  // row is saved within the debounce, which makes the incoming fragment server
  // truth and worth taking.
  declineWhileDirty(event) {
    const target = event.detail?.newStream?.getAttribute("target")
    if (!target || target !== this.sectionId()) return
    if (!this.holdsUnwritableRow()) return

    event.preventDefault()
    this.showChangedElsewhere()
  }

  holdsUnwritableRow() {
    this.syncFromDOM()
    return this.transitions.some(row => !row.target_uuid)
  }

  // The panel's Connections section, which this controller renders inside.
  sectionId() {
    return this.element.closest("[id^='connections_']")?.id ?? null
  }

  showChangedElsewhere() {
    if (this.noticeElement?.isConnected) return

    const notice = document.createElement("p")
    notice.className = "form-hint"
    notice.dataset.connectionsNotice = ""
    notice.textContent = "These connections changed elsewhere. Reopen this step to see them."
    this.element.prepend(notice)
    this.noticeElement = notice
  }

  refresh() {
    const state = this.loadState()
    this.rendered = state.rendered
    this.minted = state.minted
    this.transitions = state.rows
    this.renderTransitions()
  }

  // { rendered: [uuid], minted: [uuid], rows: [{ uuid, target_uuid, condition, label }] }
  //
  // `rendered` is every uuid the server actually put in this editor; `minted`
  // is every uuid this editor invented itself. A single list used to stand
  // for both, and the server could not tell "the author removed this row
  // here" from "someone else's save removed it while this panel sat open" -
  // a stale second panel's next save re-created a connection deleted
  // elsewhere. Splitting the list is what lets the server tell them apart:
  // see TransitionSync's class comment.
  loadState() {
    const empty = { rendered: [], minted: [], rows: [] }
    if (!this.hasHiddenInputTarget || !this.hiddenInputTarget.value) return empty

    try {
      const parsed = JSON.parse(this.hiddenInputTarget.value)
      if (Array.isArray(parsed.rendered) || Array.isArray(parsed.minted)) {
        return { rendered: parsed.rendered || [], minted: parsed.minted || [], rows: parsed.rows || [] }
      }

      // An old cached page (Turbo's bfcache preview, or a tab left open
      // across a deploy) can still hold the legacy single-list shape in its
      // hidden field even though this JS is current. Nothing was minted by
      // THIS fresh instance yet, so read it all as rendered.
      return { rendered: parsed.known || [], minted: [], rows: parsed.rows || [] }
    } catch (e) {
      console.error('[StepTransitions] Failed to parse transitions:', e)
      return empty
    }
  }

  saveTransitions() {
    if (this.hasHiddenInputTarget) {
      this.hiddenInputTarget.value = JSON.stringify({ rendered: this.rendered, minted: this.minted, rows: this.transitions })
      this.hiddenInputTarget.dispatchEvent(new Event("input", { bubbles: true }))
    }

    document.dispatchEvent(new CustomEvent("workflow:updated"))
  }

  // randomUUID exists only in a secure context; an install served over plain
  // http on an internal hostname has getRandomValues but not randomUUID.
  newUuid() {
    if (crypto.randomUUID) return crypto.randomUUID()

    const b = crypto.getRandomValues(new Uint8Array(16))
    b[6] = (b[6] & 0x0f) | 0x40
    b[8] = (b[8] & 0x3f) | 0x80
    const h = [...b].map(x => x.toString(16).padStart(2, "0")).join("")
    return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`
  }

  /**
   * Sync current DOM input values to this.transitions
   * This ensures we don't lose values when re-rendering
   */
  syncFromDOM() {
    if (!this.hasTransitionsListTarget) return

    const transitionEls = this.transitionsListTarget.querySelectorAll('[data-transition-index]')
    transitionEls.forEach((el) => {
      const index = parseInt(el.dataset.transitionIndex, 10)
      if (!this.transitions[index]) return

      // Sync all field values from DOM to this.transitions
      const targetSelect = el.querySelector('[data-transition-field="target_uuid"]')
      const conditionInput = el.querySelector('[data-transition-field="condition"]')
      const labelInput = el.querySelector('[data-transition-field="label"]')

      if (targetSelect) this.transitions[index].target_uuid = targetSelect.value
      if (conditionInput) this.transitions[index].condition = conditionInput.value
      if (labelInput) this.transitions[index].label = labelInput.value
    })
  }

  /**
   * Add a new transition
   */
  addTransition(event) {
    event.preventDefault()

    // Capture current DOM values before modifying
    this.syncFromDOM()

    // The row's key is made here, before the server has seen it, so the same
    // save sent twice writes one transition. It joins `minted` at once: a row
    // added and then removed in one sitting still has to be deleted - and
    // only `minted` (never `rendered`) makes a missing row's absence mean
    // "delete this", rather than "someone else already did".
    const uuid = this.newUuid()
    this.minted.push(uuid)
    this.transitions.push({ uuid, target_uuid: "", condition: "", label: "" })
    this.saveTransitions()
    this.renderTransitions()
  }

  /**
   * Remove a transition
   */
  removeTransition(event) {
    event.preventDefault()

    // Capture current DOM values before modifying
    this.syncFromDOM()

    const transitionEl = event.target.closest('[data-transition-index]')
    if (!transitionEl) return

    const index = parseInt(transitionEl.dataset.transitionIndex, 10)
    this.transitions.splice(index, 1)
    this.saveTransitions()
    this.renderTransitions()
  }

  /**
   * Update a transition field
   */
  updateTransition(event) {
    const transitionEl = event.target.closest('[data-transition-index]')
    if (!transitionEl) return

    const index = parseInt(transitionEl.dataset.transitionIndex, 10)
    const field = event.target.dataset.transitionField

    if (this.transitions[index] && field) {
      this.transitions[index][field] = event.target.value
      this.saveTransitions()
    }
  }

  renderTransitions() {
    if (!this.hasTransitionsListTarget) return

    const otherSteps = this.getOtherSteps()
    this.transitionsListTarget.replaceChildren()

    if (this.transitions.length === 0) {
      this.transitionsListTarget.appendChild(this.emptyTemplateTarget.content.cloneNode(true))
      return
    }

    this.transitions.forEach((transition, index) => {
      const row = this.rowTemplateTarget.content.firstElementChild.cloneNode(true)
      row.dataset.transitionIndex = index

      const targetSelect = row.querySelector('[data-transition-field="target_uuid"]')
      otherSteps.forEach(step => {
        const option = document.createElement("option")
        option.value = step.id
        option.textContent = step.title || `Step ${step.index + 1}`
        option.selected = step.id === transition.target_uuid
        targetSelect.appendChild(option)
      })

      // condition-preset connects when the row is inserted and reads its
      // values from these attributes, so set them before appending.
      const condition = row.querySelector('[data-controller~="condition-preset"]')
      condition.dataset.conditionPresetConditionValue = transition.condition || ""
      condition.dataset.conditionPresetLabelValue = transition.label || ""
      row.querySelector('[data-transition-field="condition"]').value = transition.condition || ""
      row.querySelector('[data-transition-field="label"]').value = transition.label || ""

      this.transitionsListTarget.appendChild(row)
    })
  }

  // Every builder row carries its own title in data-step-title; reading the
  // row's text picked up the "No connections" badge next to it.
  getOtherSteps() {
    const steps = []
    document.querySelectorAll('.builder__step[data-step-uuid]').forEach((row, index) => {
      const id = row.dataset.stepUuid
      if (id && id !== this.stepIdValue) {
        steps.push({ id, title: row.dataset.stepTitle || '', index })
      }
    })
    return steps
  }
}
