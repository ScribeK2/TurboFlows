require "test_helper"

# Which findings stop a publish (spec docs/designs/2026-09-12-editor-admin-home.md).
# Severity is not the test: no_audience and the sub-flow codes are warnings, and
# every one of them blocks. Dev data showed 8 unpublishable drafts with 0 errors.
class WorkflowHealthCheckPublishBlockersTest < ActiveSupport::TestCase
  # Where each class states its codes. GraphValidator and SubflowValidator emit
  # through add_finding(:code, ...); the health check coins its own with code: :x.
  EMITTERS = {
    "app/services/workflow_health_check.rb" => /code: :([a-z_]+)/,
    "app/services/graph_validator.rb" => /add_finding\(:([a-z_]+)/,
    "app/services/subflow_validator.rb" => /add_finding\(:([a-z_]+)/
  }.freeze

  setup do
    @user = User.create!(email: "blockers-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                         password_confirmation: "password123!", role: "editor")
  end

  # Publisher refusals are already tested per code in WorkflowPublisherTest:
  # subflow_target_required ("sub-flow has no target"), terminal_not_resolve and
  # no_terminal_nodes ("no Resolve terminal"), unreachable_step ("unreachable
  # orphan"), no_resolve_across_workflows ("no reachable Resolve anywhere"),
  # no_audience ("nobody has been chosen to see"), and no_path_to_resolve (the
  # loop test added with this file). no_outgoing_transitions is the health
  # check's stand-in for terminal_not_resolve. circular_subflow,
  # max_depth_exceeded and subflow_target_missing are save-blocking
  # (SubflowValidator::SAVE_BLOCKING_CODES), so such a workflow cannot even be
  # saved; no_steps, start_node_missing and transition_target_missing cannot
  # reach the publish path (see GRAPH_FINDING_PRESENTATION's comment).
  test "every code the health check can report is classified exactly once" do
    emitted = EMITTERS.flat_map { |path, pattern| Rails.root.join(path).read.scan(pattern).flatten }.map(&:to_sym).uniq
    blocking = WorkflowHealthCheck::PUBLISH_BLOCKING_CODES
    non_blocking = WorkflowHealthCheck::NON_BLOCKING_CODES

    unclassified = emitted - blocking - non_blocking
    classified_but_unused = (blocking + non_blocking) - emitted

    assert_empty unclassified, "classify these as blocking or not"
    assert_empty blocking & non_blocking, "a code cannot be both"
    assert_empty classified_but_unused, "classified codes that nothing emits"
  end

  test "publish_blockers counts a warning that publish refuses" do
    workflow = Workflow.create!(title: "No audience draft", user: @user, status: "draft")
    Steps::Resolve.create!(workflow:, position: 0, title: "Done", resolution_type: "success")

    result = WorkflowHealthCheck.call(workflow.reload)

    assert_equal 0, result.summary[:errors], "the point: nothing here is an error"
    assert_equal([:no_audience], result.publish_blockers.pluck(:code))
  end

  test "an unpublished sub-flow target does not block, because the set publishes together" do
    target = Workflow.create!(title: "Target draft", user: @user, status: "draft")
    Steps::Resolve.create!(workflow: target, position: 0, title: "Done", resolution_type: "success")
    workflow = file_in_global(Workflow.create!(title: "Caller", user: @user, status: "draft"))
    sub_flow = Steps::SubFlow.create!(workflow:, position: 0, title: "Call target", sub_flow_workflow_id: target.id)
    resolve = Steps::Resolve.create!(workflow:, position: 1, title: "Done", resolution_type: "success")
    Transition.create!(step: sub_flow, target_step: resolve, position: 0)
    workflow.update_column(:start_step_id, sub_flow.id)

    result = WorkflowHealthCheck.call(workflow.reload)

    assert_includes result.issues.values.flatten.pluck(:code), :subflow_target_unpublished
    assert_empty result.publish_blockers
  end
end
