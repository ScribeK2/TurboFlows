# frozen_string_literal: true

# Shared subflow orchestration logic for PlayerController and ScenariosController.
# Uses a template method pattern — each including controller must define
# #subflow_step_path and #subflow_completion_path.
module SubflowOrchestration
  extend ActiveSupport::Concern

  private

  # Template methods — each including controller MUST define these.

  def subflow_step_path(scenario)
    raise NotImplementedError, "#{self.class} must implement #subflow_step_path"
  end

  def subflow_completion_path(scenario)
    raise NotImplementedError, "#{self.class} must implement #subflow_completion_path"
  end

  # Shared subflow logic

  # When a scenario is awaiting_subflow, either redirect to the active child
  # or process the completed subflow and continue.
  def handle_awaiting_subflow(scenario)
    active_child = scenario.active_child_scenario
    if active_child && !active_child.complete?
      redirect_to subflow_step_path(active_child)
    else
      scenario.process_subflow_completion
      redirect_to scenario.complete? ? subflow_completion_path(scenario) : subflow_step_path(scenario)
    end
  end

  # When a child scenario completes, process the parent's subflow completion
  # and redirect appropriately.
  def handle_child_completion(scenario)
    if scenario.parent_scenario.present?
      parent = scenario.parent_scenario
      parent.process_subflow_completion
      redirect_to parent.complete? ? subflow_completion_path(parent) : subflow_step_path(parent)
    else
      redirect_to subflow_completion_path(scenario)
    end
  end

  # After processing a step, redirect to the active child if awaiting subflow,
  # or return false so the caller can handle the non-subflow case.
  def redirect_to_subflow_if_awaiting(scenario)
    return false unless scenario.awaiting_subflow?

    active_child = scenario.active_child_scenario
    redirect_to subflow_step_path(active_child || scenario)
    true
  end
end
