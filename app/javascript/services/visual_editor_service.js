// VisualEditorService: In-memory step state management for the visual workflow editor.
// Manages step CRUD, transitions, start node, serialization, and orphan detection.

import { STEP_DEFAULTS } from "services/step_defaults"

export class VisualEditorService {
  static STEP_DEFAULTS = STEP_DEFAULTS

  constructor(steps = [], options = {}) {
    this.steps = structuredClone(steps)
    this.startNodeUuid = options.startNodeUuid || this.detectStartNode()
    this.onChange = options.onChange || (() => {})
    this.dirty = false
  }

  // --- Step CRUD ---

  addStep(type, data = {}) {
    const step = {
      id: crypto.randomUUID(),
      type,
      title: data.title || this.capitalize(type.replace('_', ' ')),
      description: data.description || "",
      transitions: [],
      ...this.defaultFieldsForType(type),
      ...data
    }

    this.steps.push(step)

    // Auto-set start node if this is the first step
    if (this.steps.length === 1) {
      this.startNodeUuid = step.id
    }

    this.markDirty()
    return step
  }

  removeStep(stepId) {
    this.steps = this.steps.filter(s => s.id !== stepId)

    // Remove all transitions referencing this step
    this.steps.forEach(s => {
      if (Array.isArray(s.transitions)) {
        s.transitions = s.transitions.filter(t => t.target_uuid !== stepId)
      }
    })

    // Update start node if removed
    if (this.startNodeUuid === stepId) {
      this.startNodeUuid = this.steps.length > 0 ? this.steps[0].id : null
    }

    this.markDirty()
  }

  updateStep(stepId, data) {
    const step = this.findStep(stepId)
    if (!step) return null

    Object.assign(step, data)
    this.markDirty()
    return step
  }

  findStep(stepId) {
    return this.steps.find(s => s.id === stepId) || null
  }

  // --- Transition CRUD ---

  addTransition(fromStepId, toStepId, condition = "", label = "") {
    const step = this.findStep(fromStepId)
    if (!step) return null

    if (!Array.isArray(step.transitions)) {
      step.transitions = []
    }

    // Prevent duplicate transitions
    const exists = step.transitions.some(
      t => t.target_uuid === toStepId && t.condition === condition
    )
    if (exists) return null

    const transition = { target_uuid: toStepId, condition, label }
    step.transitions.push(transition)
    this.markDirty()
    return transition
  }

  removeTransition(fromStepId, index) {
    const step = this.findStep(fromStepId)
    if (!step || !Array.isArray(step.transitions)) return

    step.transitions.splice(index, 1)
    this.markDirty()
  }

  updateTransition(fromStepId, index, data) {
    const step = this.findStep(fromStepId)
    if (!step || !Array.isArray(step.transitions) || !step.transitions[index]) return null

    Object.assign(step.transitions[index], data)
    this.markDirty()
    return step.transitions[index]
  }

  // --- Start Node ---

  setStartNode(stepId) {
    if (this.findStep(stepId)) {
      this.startNodeUuid = stepId
      this.markDirty()
    }
  }

  // --- Serialization ---

  stepsForRenderer() {
    return this.steps.map((step, index) => ({
      ...step,
      index,
      isStartNode: step.id === this.startNodeUuid
    }))
  }

  toJSON() {
    return JSON.stringify(this.steps)
  }

  toFormData() {
    return {
      steps: this.steps,
      start_node_uuid: this.startNodeUuid,
      graph_mode: true
    }
  }

  // --- Orphan Detection ---

  getOrphanStepIds() {
    if (this.steps.length === 0) return []

    const startStep = this.findStep(this.startNodeUuid)
    if (!startStep) return this.steps.map(s => s.id)

    const visited = new Set()
    const queue = [this.startNodeUuid]

    while (queue.length > 0) {
      const currentId = queue.shift()
      if (visited.has(currentId)) continue
      visited.add(currentId)

      const step = this.findStep(currentId)
      if (!step || !Array.isArray(step.transitions)) continue

      step.transitions.forEach(t => {
        if (t.target_uuid && !visited.has(t.target_uuid)) {
          queue.push(t.target_uuid)
        }
      })
    }

    return this.steps
      .filter(s => !visited.has(s.id))
      .map(s => s.id)
  }

  // --- Private ---

  markDirty() {
    this.dirty = true
    this.onChange()
  }

  detectStartNode() {
    return this.steps.length > 0 ? this.steps[0].id : null
  }

  capitalize(str) {
    if (!str) return ''
    return str.charAt(0).toUpperCase() + str.slice(1)
  }

  defaultFieldsForType(type) {
    return structuredClone(VisualEditorService.STEP_DEFAULTS[type] || {})
  }
}

export default VisualEditorService
