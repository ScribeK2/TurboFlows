# Single source of truth for step type icon mappings.
# Used by WorkflowsHelper (views) and Workflow model.
module StepTypeIcons
  ICONS = {
    'question' => '?',
    'action' => '!',
    'sub_flow' => '~',
    'message' => 'm',
    'escalate' => '^',
    'resolve' => 'r',
    'form' => 'f'
  }.freeze

  DEFAULT_ICON = '#'

  def step_type_icon(type)
    ICONS.fetch(type, DEFAULT_ICON)
  end
end
