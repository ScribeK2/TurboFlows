import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["fieldList", "choices"]
  static values = { fieldTypes: Array }

  connect() {
    this.fieldCount = this.fieldListTarget.children.length
  }

  addField() {
    this.fieldCount++
    const row = document.createElement("div")
    row.className = "form-field-row"
    row.dataset.position = this.fieldCount

    const inputs = document.createElement("div")
    inputs.className = "form-field-row__inputs"

    const nameInput = this.createInput("text", "step[options][][name]", "field_name", "Field name")
    const labelInput = this.createInput("text", "step[options][][label]", "Label", "Field label")
    const typeSelect = this.createTypeSelect()
    const requiredLabel = this.createRequiredCheckbox()
    const choicesInput = this.createChoicesInput()
    const positionInput = this.createHidden("step[options][][position]", this.fieldCount)
    const removeBtn = document.createElement("button")
    removeBtn.type = "button"
    removeBtn.className = "btn btn--plain btn--sm form-field-row__remove"
    removeBtn.title = "Remove field"
    removeBtn.dataset.action = "form-field-builder#removeField"
    removeBtn.innerHTML = '<svg class="icon icon--sm" fill="none" stroke="currentColor" viewBox="0 0 24 24" aria-hidden="true">' +
      '<path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/></svg>'

    inputs.append(nameInput, labelInput, typeSelect, requiredLabel, choicesInput, positionInput, removeBtn)
    row.appendChild(inputs)
    this.fieldListTarget.appendChild(row)
    this.scheduleSave()
  }

  removeField(event) {
    event.target.closest(".form-field-row").remove()
    this.scheduleSave()
  }

  // Adding or deleting a field is a change to `options` like any other, but
  // neither fires an input or change event, so neither reaches the autosave
  // action on the wrapper. Dispatching a bubbling change is how they join it —
  // rather than reaching for the autosave controller directly, which would tie
  // this controller to that one.
  scheduleSave() {
    this.element.dispatchEvent(new Event("change", { bubbles: true }))
  }

  // A select field is the only one with choices to author. The input stays in
  // the DOM either way — `options` posts unindexed, so a key present on some
  // rows and absent on others is how Rails' grouping goes wrong.
  toggleChoices(event) {
    const row = event.target.closest(".form-field-row")
    const choices = row?.querySelector("[data-form-field-builder-target='choices']")
    if (choices) choices.hidden = event.target.value !== "select"
  }

  createInput(type, name, placeholder, ariaLabel) {
    const input = document.createElement("input")
    input.type = type
    input.name = name
    input.placeholder = placeholder
    input.className = "form-input form-input--sm"
    input.setAttribute("aria-label", ariaLabel)
    return input
  }

  createTypeSelect() {
    const select = document.createElement("select")
    select.name = "step[options][][field_type]"
    select.className = "form-select form-select--sm"
    select.setAttribute("aria-label", "Field type")
    // The ERB version carries this; the JS one did not, so choosing "select" on
    // a freshly added row never revealed its choices box.
    select.dataset.action = "change->form-field-builder#toggleChoices"
    this.fieldTypesValue.forEach(t => {
      const opt = document.createElement("option")
      opt.value = t
      opt.textContent = t.charAt(0).toUpperCase() + t.slice(1)
      select.appendChild(opt)
    })
    return select
  }

  createChoicesInput() {
    const input = document.createElement("input")
    input.type = "text"
    input.name = "step[options][][select_options_raw]"
    input.placeholder = "Choices, comma separated"
    input.className = "form-input form-input--sm"
    input.setAttribute("aria-label", "Choices, comma separated")
    input.dataset.formFieldBuilderTarget = "choices"
    input.hidden = true
    return input
  }

  createRequiredCheckbox() {
    const label = document.createElement("label")
    label.className = "form-checkbox-label"
    const cb = document.createElement("input")
    cb.type = "checkbox"
    cb.name = "step[options][][required]"
    cb.value = "true"
    cb.className = "form-checkbox"
    label.appendChild(cb)
    const srLabel = document.createElement("span")
    srLabel.className = "sr-only"
    srLabel.textContent = "Required"
    label.appendChild(srLabel)
    return label
  }

  createHidden(name, value) {
    const input = document.createElement("input")
    input.type = "hidden"
    input.name = name
    input.value = value
    return input
  }
}
