// Shared condition preset builder for the visual editor's connection popover.
// Used by ve_connection_controller (visual editor) and could be used by
// condition_preset_controller (list editor) in the future.

export function buildConditionPresets(step) {
  const presets = []
  const answerType = step.answer_type || "text"
  const varName = step.variable_name || "answer"

  switch (answerType) {
    case "yes_no":
      presets.push({ displayLabel: "Yes", condition: `${varName} == 'yes'`, label: "Yes" })
      presets.push({ displayLabel: "No", condition: `${varName} == 'no'`, label: "No" })
      break
    case "multiple_choice":
    case "dropdown":
      if (Array.isArray(step.options)) {
        step.options.forEach(opt => {
          const val = opt.value || opt.label || opt
          presets.push({ displayLabel: val, condition: `${varName} == '${val}'`, label: val })
        })
      }
      break
    case "number":
      presets.push({ displayLabel: "> threshold", condition: `${varName} > 0`, label: "> threshold" })
      presets.push({ displayLabel: "= threshold", condition: `${varName} == '0'`, label: "= threshold" })
      presets.push({ displayLabel: "< threshold", condition: `${varName} < 0`, label: "< threshold" })
      break
  }

  presets.push({ displayLabel: "Default (always)", condition: "", label: "Default" })
  return presets
}
