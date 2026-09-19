import { Controller } from "@hotwired/stimulus"

// The step panel's header names the step being edited, and it named the step as
// it was when the panel OPENED - so renaming one left the header reading
// "Untitled Question" above a field that plainly said otherwise. The step's ROW
// in the list updates on save (the update stream replaces it); only the header
// two inches above the field was stale.
//
// It follows the field as you type rather than waiting for the save. That means
// the header can show text that is not stored yet, which would have been
// ambiguous before - but the save indicator sits beside it and says exactly
// that ("Unsaved changes" until it lands), so the two together are honest in a
// way either alone is not.
export default class extends Controller {
  static targets = ["heading", "field"]
  static values = { fallback: { type: String, default: "Untitled" } }

  update() {
    if (!this.hasHeadingTarget || !this.hasFieldTarget) return

    this.headingTarget.textContent = this.fieldTarget.value.trim() || this.fallbackValue
  }
}
