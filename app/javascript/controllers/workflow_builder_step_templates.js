// Client-side HTML template builders for workflow_builder_controller.js.
//
// Functions that require controller-instance methods (getAllStepTitles,
// buildDropdownOptions, getWorkflowIdFromPage, getTemplatesFromPage) accept
// `context` — the controller instance — as their first argument.
//
// This module is auto-pinned via the pin_all_from directive in importmap.rb.

// ── Utility ──────────────────────────────────────────────────────────────────

export function escapeHtml(text) {
  const div = document.createElement("div")
  div.textContent = text
  return div.innerHTML
}

export function getWorkflowIdFromForm(form) {
  if (!form) return null
  const action = form.action || ""
  const match = action.match(/\/workflows\/(\d+)/)
  return match ? match[1] : null
}

export function getPreviewHtml(_stepType, _stepData) {
  return `
    <div class="preview-pane bg-gray-50 border rounded-lg p-4">
      <h4 class="text-sm font-semibold text-gray-700 mb-2">Live Preview</h4>
      <p class="text-sm text-gray-500">Start filling in the form to see preview</p>
    </div>
  `
}

// ── Step shell ────────────────────────────────────────────────────────────────

export function buildStepHtml(context, stepType, index, stepData = {}) {
  const stepTitles = context.getAllStepTitles(index)
  const truePathOptions = context.buildDropdownOptions(stepTitles, stepData.true_path || "")
  const falsePathOptions = context.buildDropdownOptions(stepTitles, stepData.false_path || "")

  const form = context.element.closest("form")
  const workflowId = form?.dataset?.workflowId || getWorkflowIdFromForm(form)
  const previewUrl = workflowId ? `/workflows/${workflowId}/preview` : ""

  return `
    <div class="step-item border rounded p-4 mb-4"
         data-step-index="${index}"
         data-controller="step-form"
         data-step-form-step-type-value="${stepType}"
         data-step-form-step-index-value="${index}">
      <div class="flex items-center justify-between mb-2">
        <span class="drag-handle cursor-move text-gray-500">☰</span>
        <button type="button" data-action="click->workflow-builder#removeStep" class="text-red-500 hover:text-red-700">Remove</button>
      </div>
      <input type="hidden" name="workflow[steps][][index]" value="${index}">
      <input type="hidden" name="workflow[steps][][type]" value="${stepType}">

      <div class="grid grid-cols-1 md:grid-cols-2 gap-4"
           ${previewUrl ? `data-controller="preview-updater" data-preview-updater-url-value="${previewUrl}" data-preview-updater-index-value="${index}"` : ""}>
        <div class="space-y-2 min-w-0">
          <div class="field-container">
            <input type="text"
                   name="workflow[steps][][title]"
                   value="${escapeHtml(stepData.title || "")}"
                   placeholder="Step title"
                   class="w-full border rounded px-3 py-2"
                   required
                   data-step-form-target="field">
          </div>
          <div class="field-container">
            <textarea name="workflow[steps][][description]"
                      placeholder="Step description"
                      class="w-full border rounded px-3 py-2"
                      rows="2"
                      data-step-form-target="field">${escapeHtml(stepData.description || "")}</textarea>
          </div>
          ${getStepTypeSpecificFields(context, stepType, stepData, truePathOptions, falsePathOptions)}
        </div>

        ${previewUrl ? `
          <div class="min-w-0">
            <turbo-frame id="step_preview_${index}" data-preview-updater-target="previewFrame">
              ${getPreviewHtml(stepType, stepData)}
            </turbo-frame>
          </div>
        ` : `
          <div class="preview-pane bg-gray-50 border rounded-lg p-4">
            <h4 class="text-sm font-semibold text-gray-700 mb-2">Live Preview</h4>
            <p class="text-sm text-gray-500 text-center py-4">Save workflow to enable live preview</p>
          </div>
        `}
      </div>
    </div>
  `
}

// ── Step type dispatcher ──────────────────────────────────────────────────────

export function getStepTypeSpecificFields(context, stepType, stepData = {}, truePathOptions = "", falsePathOptions = "") {
  const templateSelector = getTemplateSelectorHtml(context, stepType)
  switch (stepType) {
    case "question":
      return getQuestionFieldsHtml(stepData)
    case "action":
      return getActionFieldsHtml(stepData)
    case "sub_flow":
      return getSubflowFieldsHtml(context, stepData)
    case "message":
      return getMessageFieldsHtml(stepData)
    case "escalate":
      return getEscalateFieldsHtml(stepData)
    case "resolve":
      return getResolveFieldsHtml(stepData)
    default:
      return ""
  }
}

// ── Type-specific field builders ──────────────────────────────────────────────

export function getActionFieldsHtml(stepData = {}) {
  const attachments = stepData.attachments || []
  const attachmentsJson = JSON.stringify(attachments)

  let attachmentsHtml = ""
  if (attachments.length > 0) {
    attachmentsHtml = attachments.map(signedId => {
      return `
        <div class="flex items-center justify-between p-2 bg-gray-50 rounded border" data-attachment-id="${escapeHtml(signedId)}">
          <div class="flex items-center gap-2">
            <span class="text-sm text-gray-700">File</span>
          </div>
          <button type="button"
                  class="text-red-500 hover:text-red-700 text-sm"
                  data-action="click->file-attachment#removeAttachment"
                  data-attachment-id="${escapeHtml(signedId)}">
            Remove
          </button>
        </div>
      `
    }).join('')
  }

  return `
    <div class="field-container">
      <label class="block text-sm font-medium text-gray-700 mb-1">Instructions</label>
      <textarea name="workflow[steps][][instructions]"
                placeholder="Detailed instructions for this action..."
                class="w-full border rounded px-3 py-2"
                rows="3"
                data-step-form-target="field">${escapeHtml(stepData.instructions || "")}</textarea>
    </div>

    <div class="field-container"
         data-controller="file-attachment"
         data-file-attachment-step-index-value="">
      <label class="block text-sm font-medium text-gray-700 mb-1">Attachments</label>

      <input type="hidden"
             name="workflow[steps][][attachments]"
             value="${escapeHtml(attachmentsJson)}"
             data-file-attachment-target="attachmentsInput"
             data-step-form-target="field">

      <div class="mt-2">
        <input type="file"
               class="block w-full text-sm text-gray-500
                      file:mr-4 file:py-2 file:px-4
                      file:rounded-full file:border-0
                      file:text-sm file:font-semibold
                      file:bg-blue-50 file:text-blue-700
                      hover:file:bg-blue-100
                      cursor-pointer"
               data-file-attachment-target="fileInput"
               data-action="change->file-attachment#handleFileSelect"
               multiple
               accept="image/*,.pdf,.doc,.docx,.txt,.csv">
        <p class="mt-1 text-xs text-gray-500">Upload files (images, PDFs, documents). Multiple files allowed.</p>
      </div>

      <div data-file-attachment-target="attachmentsList" class="mt-3 space-y-2">
        ${attachmentsHtml}
      </div>
    </div>
  `
}

export function getCheckpointFieldsHtml(stepData = {}) {
  return `
    <div class="field-container">
      <label class="block text-sm font-medium text-gray-700 mb-1">Checkpoint Message</label>
      <textarea name="workflow[steps][][checkpoint_message]"
                placeholder="Message to display at checkpoint..."
                class="w-full border rounded px-3 py-2"
                rows="2"
                data-step-form-target="field">${escapeHtml(stepData.checkpoint_message || "")}</textarea>
      <p class="mt-1 text-xs text-gray-500">This message will be shown when the simulation reaches this checkpoint.</p>
    </div>
  `
}

export function getMessageFieldsHtml(stepData = {}) {
  return `
    <div class="field-container">
      <div class="bg-cyan-50 border border-cyan-200 rounded-lg p-3 mb-4">
        <div class="flex items-start">
          <svg class="w-5 h-5 text-cyan-600 mr-2 mt-0.5 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
          </svg>
          <p class="text-sm text-cyan-800">
            <strong>Message Step:</strong> Display information to the CSR. Auto-advances without user input.
          </p>
        </div>
      </div>

      <label class="block text-sm font-medium text-gray-700 mb-1">Message Content</label>
      <textarea name="workflow[steps][][content]"
                placeholder="Enter the message to display..."
                class="w-full border rounded px-3 py-2"
                rows="4"
                data-step-form-target="field">${escapeHtml(stepData.content || "")}</textarea>
      <p class="mt-1 text-xs text-gray-500">Supports variable interpolation with {{variable_name}} syntax.</p>
    </div>
  `
}

export function getEscalateFieldsHtml(stepData = {}) {
  const targetTypes = ['department', 'supervisor', 'channel', 'ticket']
  const priorities = ['low', 'medium', 'high', 'critical']

  return `
    <div class="field-container">
      <div class="bg-orange-50 border border-orange-200 rounded-lg p-3 mb-4">
        <div class="flex items-start">
          <svg class="w-5 h-5 text-orange-600 mr-2 mt-0.5 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M7 11l5-5m0 0l5 5m-5-5v12" />
          </svg>
          <p class="text-sm text-orange-800">
            <strong>Escalate Step:</strong> Transfer to another team, queue, or supervisor.
          </p>
        </div>
      </div>

      <div class="mb-4">
        <label class="block text-sm font-medium text-gray-700 mb-1">Target Type</label>
        <select name="workflow[steps][][target_type]"
                class="w-full border rounded px-3 py-2"
                data-step-form-target="field">
          <option value="">-- Select target type --</option>
          ${targetTypes.map(t => `<option value="${t}" ${stepData.target_type === t ? 'selected' : ''}>${t.charAt(0).toUpperCase() + t.slice(1)}</option>`).join('')}
        </select>
      </div>

      <div class="mb-4">
        <label class="block text-sm font-medium text-gray-700 mb-1">Target Name/ID</label>
        <input type="text"
               name="workflow[steps][][target_value]"
               value="${escapeHtml(stepData.target_value || "")}"
               placeholder="e.g., Billing Team, Supervisor Queue"
               class="w-full border rounded px-3 py-2"
               data-step-form-target="field">
      </div>

      <div class="mb-4">
        <label class="block text-sm font-medium text-gray-700 mb-1">Priority</label>
        <select name="workflow[steps][][priority]"
                class="w-full border rounded px-3 py-2"
                data-step-form-target="field">
          ${priorities.map(p => `<option value="${p}" ${(stepData.priority || 'medium') === p ? 'selected' : ''}>${p.charAt(0).toUpperCase() + p.slice(1)}</option>`).join('')}
        </select>
      </div>

      <div class="mb-4">
        <label class="flex items-center cursor-pointer">
          <input type="hidden" name="workflow[steps][][reason_required]" value="false">
          <input type="checkbox"
                 name="workflow[steps][][reason_required]"
                 value="true"
                 ${stepData.reason_required ? 'checked' : ''}
                 class="h-4 w-4 text-orange-600 border-gray-300 rounded"
                 data-step-form-target="field">
          <span class="ml-2 text-sm text-gray-700">Require reason for escalation</span>
        </label>
      </div>

      <div class="mb-4">
        <label class="block text-sm font-medium text-gray-700 mb-1">Notes (optional)</label>
        <textarea name="workflow[steps][][notes]"
                  placeholder="Additional context for the escalation..."
                  class="w-full border rounded px-3 py-2"
                  rows="2"
                  data-step-form-target="field">${escapeHtml(stepData.notes || "")}</textarea>
      </div>
    </div>
  `
}

export function getResolveFieldsHtml(stepData = {}) {
  const resolutionTypes = [
    { value: 'success', label: 'Success' },
    { value: 'transfer', label: 'Transfer' },
    { value: 'ticket', label: 'Ticket' },
    { value: 'manager_escalation', label: 'Manager Escalation' }
  ]

  return `
    <div class="field-container">
      <div class="bg-green-50 border border-green-200 rounded-lg p-3 mb-4">
        <div class="flex items-start">
          <svg class="w-5 h-5 text-green-600 mr-2 mt-0.5 flex-shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
          </svg>
          <p class="text-sm text-green-800">
            <strong>Resolve Step:</strong> Terminal step that completes the workflow. Cannot have outgoing connections.
          </p>
        </div>
      </div>

      <div class="mb-4">
        <label class="block text-sm font-medium text-gray-700 mb-1">Resolution Type</label>
        <select name="workflow[steps][][resolution_type]"
                class="w-full border rounded px-3 py-2"
                data-step-form-target="field">
          ${resolutionTypes.map(t => `<option value="${t.value}" ${(stepData.resolution_type || 'success') === t.value ? 'selected' : ''}>${t.label}</option>`).join('')}
        </select>
      </div>
    </div>
  `
}

export function getSubflowFieldsHtml(context, stepData = {}) {
  const workflowId = context.getWorkflowIdFromPage()

  return `
    <div class="field-container" data-controller="subflow-selector" data-subflow-selector-current-workflow-id-value="${workflowId || ''}">
      <label class="block text-sm font-medium text-gray-700 mb-1">Target Workflow</label>
      <input type="hidden"
             name="workflow[steps][][target_workflow_id]"
             value="${escapeHtml(stepData.target_workflow_id || "")}"
             data-subflow-selector-target="hiddenInput"
             data-step-form-target="field">
      <select data-subflow-selector-target="select"
              data-action="change->subflow-selector#selectWorkflow"
              class="w-full border rounded px-3 py-2 focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:border-indigo-500">
        <option value="">-- Select a workflow --</option>
      </select>
      <p class="mt-1 text-xs text-gray-500">Select a published workflow to run as a sub-routine. Variables will be inherited.</p>
    </div>

    <div class="field-container mt-3">
      <label class="block text-sm font-medium text-gray-700 mb-1">Variable Mapping (Optional)</label>
      <div class="bg-gray-50 rounded p-3 border border-gray-200">
        <p class="text-xs text-gray-500 mb-2">
          Map parent workflow variables to child workflow variables. Child workflow results will be merged back.
        </p>
        <input type="hidden"
               name="workflow[steps][][variable_mapping]"
               value="${escapeHtml(JSON.stringify(stepData.variable_mapping || {}))}"
               data-step-form-target="field">
        <div class="text-xs text-gray-400 italic">
          Variable mapping editor coming soon. Currently, all parent variables are automatically passed to sub-flows.
        </div>
      </div>
    </div>
  `
}

export function getTemplateSelectorHtml(context, stepType) {
  const templatesData = context.getTemplatesFromPage()
  const templates = templatesData[stepType] || []

  if (templates.length === 0) return ""

  const optionsHtml = templates.map(t =>
    `<option value="${escapeHtml(t.key)}">${escapeHtml(t.name)}</option>`
  ).join('')

  const escapedTemplatesJson = JSON.stringify(templates)
    .replace(/&/g, '&amp;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')

  return `
    <div class="field-container mb-3"
         data-controller="step-template"
         data-step-template-step-type-value="${stepType}"
         data-step-template-templates-data="${escapedTemplatesJson}">
      <label class="block text-sm font-medium text-gray-700 mb-1">Apply Template</label>
      <select data-step-template-target="select"
              data-action="change->step-template#applyTemplate"
              class="w-full border rounded px-3 py-2 text-sm">
        <option value="">-- Select a template --</option>
        ${optionsHtml}
      </select>
      <p class="mt-1 text-xs text-gray-500">Quickly fill form fields with a predefined template</p>
    </div>
  `
}

export function getQuestionFieldsHtml(stepData = {}) {
  const answerTypes = [
    { value: 'text', label: 'Text' },
    { value: 'yes_no', label: 'Yes/No' },
    { value: 'multiple_choice', label: 'Multiple Choice' },
    { value: 'dropdown', label: 'Dropdown' },
    { value: 'date', label: 'Date' },
    { value: 'number', label: 'Number' },
    { value: 'file', label: 'File Upload' }
  ]

  const currentAnswerType = stepData.answer_type || ""
  const showOptions = currentAnswerType === 'multiple_choice' || currentAnswerType === 'dropdown'

  const answerTypeRadios = answerTypes.map(type => {
    const checked = currentAnswerType === type.value ? 'checked' : ''
    const selectedClass = checked ? 'bg-blue-50 border-blue-500' : ''
    return `
      <label class="flex items-center gap-2 p-2 border rounded cursor-pointer hover:bg-gray-50 ${selectedClass}">
        <input type="radio"
               name="workflow[steps][][answer_type]"
               value="${type.value}"
               ${checked}
               data-question-form-target="answerType"
               data-action="change->question-form#handleAnswerTypeChange"
               data-step-form-target="field"
               class="cursor-pointer">
        <span class="text-sm">${type.label}</span>
      </label>
    `
  }).join('')

  let optionsHtml = ""
  if (stepData.options && Array.isArray(stepData.options) && stepData.options.length > 0) {
    optionsHtml = stepData.options.map(option => {
      const label = option.label || option.value || option || ""
      const value = option.value || option.label || option || ""
      return `
        <div class="flex gap-2 items-center option-item">
          <span class="drag-handle cursor-move text-gray-500 text-lg" title="Drag to reorder">☰</span>
          <input type="text"
                 name="workflow[steps][][options][][label]"
                 value="${escapeHtml(label)}"
                 placeholder="Option label"
                 class="flex-1 border rounded px-2 py-1 text-sm"
                 data-step-form-target="field">
          <input type="text"
                 name="workflow[steps][][options][][value]"
                 value="${escapeHtml(value)}"
                 placeholder="Option value"
                 class="flex-1 border rounded px-2 py-1 text-sm"
                 data-step-form-target="field">
          <button type="button"
                  class="text-red-500 hover:text-red-700 text-sm px-2"
                  data-action="click->question-form#removeOption">
            Remove
          </button>
        </div>
      `
    }).join('')
  }

  return `
    <div class="field-container">
      <input type="text"
             name="workflow[steps][][question]"
             value="${escapeHtml(stepData.question || "")}"
             placeholder="Question text"
             class="w-full border rounded px-3 py-2"
             data-step-form-target="field"
             data-required="true">
    </div>

    <div class="field-container" data-controller="question-form">
      <label class="block text-sm font-medium text-gray-700 mb-2">Answer Type</label>
      <div class="grid grid-cols-2 gap-2" data-question-form-target="answerTypeContainer">
        ${answerTypeRadios}
      </div>
      <input type="hidden" name="workflow[steps][][answer_type]" value="${escapeHtml(currentAnswerType)}" data-question-form-target="hiddenAnswerType">

      <div class="mt-4 ${showOptions ? '' : 'hidden'}"
           data-question-form-target="optionsContainer">
        <label class="block text-sm font-medium text-gray-700 mb-2">Options</label>
        <div data-question-form-target="optionsList" class="space-y-2">
          ${optionsHtml}
        </div>
        <button type="button"
                class="mt-2 text-sm text-blue-600 hover:text-blue-800"
                data-action="click->question-form#addOption">
          + Add Option
        </button>
      </div>
    </div>

    <div class="field-container">
      <label class="block text-sm font-medium text-gray-700 mb-1">Variable Name</label>
      <input type="text"
             name="workflow[steps][][variable_name]"
             value="${escapeHtml(stepData.variable_name || "")}"
             placeholder="e.g., user_name, age, etc."
             class="w-full border rounded px-3 py-2"
             data-step-form-target="field">
      <p class="mt-1 text-xs text-gray-500">Optional: Name this answer for use in transition conditions</p>
    </div>
  `
}

export function getDecisionFieldsHtml(context, stepData = {}, truePathOptions = "", falsePathOptions = "") {
  const workflowId = getWorkflowIdFromForm(context.element.closest("form"))
  const variablesUrl = workflowId ? `/workflows/${workflowId}/variables` : ""

  const branches = stepData.branches || []
  const branchesHtml = branches.map((branch, index) => {
    return getBranchHtml(index, branch.condition || "", branch.path || "", workflowId, variablesUrl)
  }).join('')

  return `
    <div class="field-container"
         data-controller="multi-branch"
         ${workflowId ? `data-multi-branch-workflow-id-value="${workflowId}"` : ""}
         ${variablesUrl ? `data-multi-branch-variables-url-value="${variablesUrl}"` : ""}>

      <div class="flex items-center justify-between mb-3">
        <label class="block text-sm font-medium text-gray-700">Decision Branches</label>
        <button type="button"
                class="text-sm text-blue-600 hover:text-blue-800"
                data-action="click->multi-branch#addBranch">
          + Add Branch
        </button>
      </div>

      <div data-multi-branch-target="branchesContainer" class="space-y-2">
        ${branchesHtml}
      </div>

      <div class="mt-4" data-multi-branch-target="elsePathContainer">
        <label class="block text-sm font-medium text-gray-700">Else (default), go to:</label>
        <div class="field-container mt-1 relative">
          <div data-controller="step-selector"
               data-step-selector-selected-value-value="${stepData.else_path || ""}"
               data-step-selector-placeholder-value="-- Select step --">
            <input type="hidden"
                   name="workflow[steps][][else_path]"
                   value="${stepData.else_path || ""}"
                   data-step-selector-target="hiddenInput"
                   data-step-form-target="field">
            <button type="button"
                    class="w-full text-left border rounded px-3 py-2 bg-white hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
                    data-step-selector-target="button"
                    data-action="click->step-selector#toggle">
              ${stepData.else_path ? `<span class="font-medium">${escapeHtml(stepData.else_path)}</span>` : '<span class="text-gray-500">-- Select step --</span>'}
            </button>
            <div class="hidden absolute z-50 w-full mt-1 bg-white border border-gray-300 rounded-lg shadow-lg max-h-64 overflow-hidden"
                 data-step-selector-target="dropdown">
              <div class="p-2 border-b border-gray-200">
                <input type="text"
                       placeholder="Search steps..."
                       class="w-full px-3 py-2 text-sm border border-gray-300 rounded focus:outline-none focus:ring-2 focus:ring-blue-500"
                       data-step-selector-target="search"
                       data-action="input->step-selector#search">
              </div>
              <div class="overflow-y-auto max-h-56" data-step-selector-target="options">
                <!-- Options will be rendered here -->
              </div>
            </div>
          </div>
        </div>
        <p class="mt-1 text-xs text-gray-500">Optional: Path to take when no branch conditions match</p>
      </div>

      <input type="hidden" name="workflow[steps][][true_path]" value="${stepData.true_path || ""}">
      <input type="hidden" name="workflow[steps][][false_path]" value="${stepData.false_path || ""}">

      <p class="mt-2 text-xs text-gray-500">Available variables come from question steps with variable names</p>
    </div>
  `
}

export function getBranchHtml(index, condition, path, workflowId, variablesUrl) {
  let variable = "", operator = "", value = ""
  if (condition) {
    const patterns = [
      /^(\w+)\s*(==|!=)\s*['"]([^'"]*)['"]$/,
      /^(\w+)\s*(>|>=|<|<=)\s*(\d+)$/
    ]

    for (const pattern of patterns) {
      const match = condition.match(pattern)
      if (match) {
        variable = match[1]
        operator = match[2]
        value = match[3] || ""
        break
      }
    }
  }

  const operatorOptions = [
    { value: "==", label: "Equals (==)", selected: operator === "==" },
    { value: "!=", label: "Not Equals (!=)", selected: operator === "!=" },
    { value: ">", label: "Greater Than (>)", selected: operator === ">" && operator !== ">=" },
    { value: ">=", label: "Greater or Equal (>=)", selected: operator === ">=" },
    { value: "<", label: "Less Than (<)", selected: operator === "<" && operator !== "<=" },
    { value: "<=", label: "Less or Equal (<=)", selected: operator === "<=" }
  ]

  return `
    <div class="branch-item border rounded p-3 mb-3 bg-gray-50" data-branch-index="${index}">
      <div class="flex items-center justify-between mb-2">
        <span class="text-sm font-medium text-gray-700">Branch ${index + 1}</span>
        <button type="button"
                class="text-red-500 hover:text-red-700 text-sm"
                data-action="click->multi-branch#removeBranch"
                data-branch-index="${index}">
          Remove
        </button>
      </div>

      <div class="grid grid-cols-1 gap-3">
        <div data-controller="rule-builder"
             ${workflowId ? `data-rule-builder-workflow-id-value="${workflowId}"` : ""}
             ${variablesUrl ? `data-rule-builder-variables-url-value="${variablesUrl}"` : ""}>
          <div class="flex items-center justify-between mb-2">
            <label class="block text-xs font-medium text-gray-700">Condition</label>
            <div class="flex gap-1" data-rule-builder-target="presetButtons">
              <button type="button"
                      class="px-2 py-1 text-xs bg-blue-50 text-blue-700 rounded hover:bg-blue-100 border border-blue-200"
                      data-preset="equals"
                      data-action="click->rule-builder#applyPreset"
                      title="Equals">
                ==
              </button>
              <button type="button"
                      class="px-2 py-1 text-xs bg-blue-50 text-blue-700 rounded hover:bg-blue-100 border border-blue-200"
                      data-preset="not_equals"
                      data-action="click->rule-builder#applyPreset"
                      title="Not Equals">
                !=
              </button>
              <button type="button"
                      class="px-2 py-1 text-xs bg-blue-50 text-blue-700 rounded hover:bg-blue-100 border border-blue-200"
                      data-preset="is_empty"
                      data-action="click->rule-builder#applyPreset"
                      title="Is Empty">
                Empty
              </button>
            </div>
          </div>

          <input type="hidden"
                 name="workflow[steps][][branches][][condition]"
                 value="${escapeHtml(condition)}"
                 data-rule-builder-target="conditionInput"
                 data-step-form-target="field">

          <div class="grid grid-cols-3 gap-2 items-end">
            <div>
              <label class="block text-xs text-gray-600 mb-1">Variable</label>
              <select data-rule-builder-target="variableSelect"
                      class="w-full border rounded px-2 py-1 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
                      data-action="change->rule-builder#buildCondition">
                <option value="">-- Select variable --</option>
              </select>
            </div>

            <div>
              <label class="block text-xs text-gray-600 mb-1">Operator</label>
              <select data-rule-builder-target="operatorSelect"
                      class="w-full border rounded px-2 py-1 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
                      data-action="change->rule-builder#buildCondition">
                <option value="">-- Select --</option>
                ${operatorOptions.map(opt =>
                  `<option value="${opt.value}" ${opt.selected ? 'selected' : ''}>${opt.label}</option>`
                ).join('')}
              </select>
            </div>

            <div>
              <label class="block text-xs text-gray-600 mb-1">Value</label>
              <div class="relative">
                <input type="text"
                       data-rule-builder-target="valueInput"
                       value="${escapeHtml(value)}"
                       placeholder="Value"
                       class="w-full border rounded px-2 py-1 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
                       data-action="input->rule-builder#buildCondition"
                       list="value-suggestions-${index}">
                <datalist id="value-suggestions-${index}" data-rule-builder-target="valueSuggestions">
                  <!-- Options will be populated dynamically -->
                </datalist>
              </div>
            </div>
          </div>

          <div class="mt-2 p-2 bg-gray-50 rounded border border-gray-200">
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-2">
                <span class="text-xs text-gray-500">Condition:</span>
                <span data-rule-builder-target="conditionDisplay" class="text-xs font-mono text-gray-900">${condition || "Not set"}</span>
              </div>
            </div>
            <div data-rule-builder-target="validationMessage" class="hidden"></div>
            <div data-rule-builder-target="helpText" class="mt-1 text-xs text-gray-500">
              <span class="font-medium">Tip:</span> Select a variable first, then choose an operator and enter a value.
            </div>
          </div>
        </div>

        <div>
          <label class="block text-xs text-gray-600 mb-1">Go to:</label>
          <div data-controller="step-selector"
               data-step-selector-selected-value-value="${path}"
               data-step-selector-placeholder-value="-- Select step --"
               class="relative">
            <input type="hidden"
                   name="workflow[steps][][branches][][path]"
                   value="${escapeHtml(path)}"
                   data-step-selector-target="hiddenInput"
                   data-step-form-target="field"
                   data-multi-branch-target="branchPathSelect">
            <button type="button"
                    class="w-full text-left border rounded px-3 py-2 text-sm bg-white hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
                    data-step-selector-target="button"
                    data-action="click->step-selector#toggle">
              ${path ? `<span class="font-medium">${escapeHtml(path)}</span>` : '<span class="text-gray-500">-- Select step --</span>'}
            </button>
            <div class="hidden absolute z-50 w-full mt-1 bg-white border border-gray-300 rounded-lg shadow-lg max-h-64 overflow-hidden"
                 data-step-selector-target="dropdown">
              <div class="p-2 border-b border-gray-200">
                <input type="text"
                       placeholder="Search steps..."
                       class="w-full px-3 py-2 text-sm border border-gray-300 rounded focus:outline-none focus:ring-2 focus:ring-blue-500"
                       data-step-selector-target="search"
                       data-action="input->step-selector#search">
              </div>
              <div class="overflow-y-auto max-h-56" data-step-selector-target="options">
                <!-- Options will be rendered here -->
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  `
}
