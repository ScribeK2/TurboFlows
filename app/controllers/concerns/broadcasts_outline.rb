# Every tab open on a workflow re-renders its step list from these two
# broadcasts: the outline itself (#steps-list's children), and the candidates
# of the list-level "An existing step…" dialog (workflows/_list_target_picker),
# which sits beside #steps-list, not in it - without the second, a step grown
# or wired in another tab would never be offered there.
#
# The acting tab receives them too: nothing identifies a sender. That is fine,
# since its fragment matches the response it just rendered.
module BroadcastsOutline
  extend ActiveSupport::Concern

  private

  def broadcast_outline(workflow, steps:, outline:)
    stream = "workflow_#{workflow.id}"

    Turbo::StreamsChannel.broadcast_update_to(
      stream,
      target: "steps-list",
      partial: "workflows/steps_list_items",
      locals: { workflow: workflow, steps: steps, outline: outline }
    )
    Turbo::StreamsChannel.broadcast_replace_to(
      stream,
      target: "list-target-picker-options",
      partial: "steps/target_picker_options",
      locals: { step: nil, workflow: workflow, options_id: "list-target-picker-options", outline: outline }
    )
  end
end
