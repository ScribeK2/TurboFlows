import { Controller } from "@hotwired/stimulus"

// The step list from the keyboard (QA A-004, 2026-09-23). Every step's node is
// a treeitem and a Tab stop; with focus on one:
//
//   Enter / Space   open its panel (the same click a mouse gives its row)
//   Down / Up       the next / previous VISIBLE step in reading order - a
//                   step inside a closed fold is skipped, chips never count
//   Home / End      the first / last visible step
//   Left            fold the branch this step sits in, and focus that fold
//   Right           unfold this step's own folded branches
//
// Chips, fold summaries and Remove stay ordinary Tab stops, and keys aimed at
// them are left alone: this acts only when the node ITSELF has focus. Folding
// goes through the fold's <summary> click, so outline-fold records it as the
// author's and it survives the next re-render.
//
// On the builder root, beside outline-fold: the whole #step-list element is
// replaced by several responses.
export default class extends Controller {
  connect() {
    this.boundKeydown = this.keydown.bind(this)
    this.element.addEventListener("keydown", this.boundKeydown)
  }

  disconnect() {
    this.element.removeEventListener("keydown", this.boundKeydown)
  }

  keydown(event) {
    const node = event.target
    if (!(node instanceof HTMLElement) || node.getAttribute("role") !== "treeitem") return
    if (event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return

    const action = ACTIONS[event.key]
    if (!action) return

    event.preventDefault()
    this[action](node)
  }

  open(node) {
    node.querySelector(":scope > .builder__step")?.click()
  }

  next(node) { this.move(node, +1) }
  previous(node) { this.move(node, -1) }
  first() { this.visibleNodes()[0]?.focus() }
  last() { this.visibleNodes().at(-1)?.focus() }

  move(node, step) {
    const nodes = this.visibleNodes()
    const index = nodes.indexOf(node)
    nodes[index + step]?.focus()
  }

  fold(node) {
    const branch = node.parentElement?.closest("details[data-fold-key]")
    if (!branch?.open) return

    const summary = branch.querySelector(":scope > summary")
    summary.click()
    summary.focus()
  }

  unfold(node) {
    node.querySelectorAll(":scope > .builder__outline-branch > details[data-fold-key]:not([open]) > summary")
      .forEach(summary => summary.click())
  }

  // In document order, which is reading order. A closed <details> hides its
  // content with content-visibility, so its rows still report boxes; ask the
  // DOM whether a closed fold holds the node instead.
  visibleNodes() {
    return [...this.element.querySelectorAll('#steps-list [role="treeitem"]')]
      .filter(node => !node.closest("details:not([open])"))
  }
}

const ACTIONS = {
  Enter: "open",
  " ": "open",
  ArrowDown: "next",
  ArrowUp: "previous",
  Home: "first",
  End: "last",
  ArrowLeft: "fold",
  ArrowRight: "unfold"
}
