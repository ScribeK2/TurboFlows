# One validation failure, reported structurally rather than as a sentence.
#
# Emitted by GraphValidator and SubflowValidator. Consumers that need to know
# *which* step or workflow failed switch on +code+ and read +step_uuid+ or
# +details+ — they must never parse +message+ back into a step, because step
# titles are not unique and a title lookup can attach an issue, and its Fix
# button, to the wrong step.
#
# +message+ stays the single source of the human-readable text, so a validator's
# #errors is just a projection of its findings.
#
# +step_uuid+ is nil for findings that belong to no single step (a workflow with
# no steps, a missing start node, sub-flow recursion).
ValidationFinding = Data.define(:code, :step_uuid, :message, :details) do
  def initialize(code:, message:, step_uuid: nil, details: {})
    super
  end
end
