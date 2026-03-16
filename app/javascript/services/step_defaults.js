// Shared step default field values used by both the list-mode workflow builder
// and the visual editor service. Keep this as the single source of truth —
// do not duplicate these definitions elsewhere.

export const STEP_DEFAULTS = {
  question:  { question: "", answer_type: "yes_no", variable_name: "" },
  action:    { action_type: "Instruction", instructions: "", can_resolve: false },
  sub_flow:  { target_workflow_id: "", variable_mapping: {} },
  message:   { content: "", can_resolve: false },
  escalate:  { target_type: "", target_value: "", priority: "normal", reason_required: false, notes: "" },
  resolve:   { resolution_type: "success", resolution_code: "", notes_required: false, survey_trigger: false }
}
