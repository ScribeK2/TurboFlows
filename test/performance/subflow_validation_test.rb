require "test_helper"

class SubflowValidationTest < ActiveSupport::TestCase
  include PerformanceHelper

  setup do
    @data = seed_performance_data

    # Create a chain of 10 workflows with sub-flow references
    @subflow_workflows = Array.new(10) do |i|
      Workflow.create!(
        title: "Subflow Chain #{i}",
        status: "published",
        user: @data[:editors].first
      )
    end

    # Wire them up: each workflow has a sub-flow step pointing to the next
    @subflow_workflows.each_with_index do |wf, i|
      next_wf = @subflow_workflows[i + 1]

      q_step = Steps::Question.create!(
        workflow: wf, uuid: SecureRandom.uuid, position: 0,
        title: "Q1", question: "Q?"
      )

      if next_wf
        Steps::SubFlow.create!(
          workflow: wf, uuid: SecureRandom.uuid, position: 1,
          title: "Sub", sub_flow_workflow_id: next_wf.id
        )
      end

      Steps::Resolve.create!(
        workflow: wf, uuid: SecureRandom.uuid, position: 2,
        title: "Done", resolution_type: "success"
      )

      wf.update_column(:start_step_id, q_step.id)
    end
  end

  test "validating a 10-deep subflow chain uses bounded queries" do
    validator = SubflowValidator.new(@subflow_workflows.first.id)

    # With AR steps, extract_subflow_target_ids queries each workflow individually.
    # preload_reachable_workflows: 1 root find + 10 extract queries + batch loads
    # validate_no_circular_subflows: up to 10 more extract queries
    # validate_max_depth: up to 10 more extract queries
    # Total: ~40 queries for 10 workflows (bounded, not exponential)
    assert_max_queries(45) do
      validator.valid?
    end
  end

  test "validating a workflow with no subflows uses few queries" do
    # Create a simple workflow with no sub-flow steps
    simple_workflow = Workflow.create!(
      title: "Simple No Subflow",
      status: "published",
      user: @data[:editors].first
    )

    q_step = Steps::Question.create!(
      workflow: simple_workflow, uuid: SecureRandom.uuid, position: 0,
      title: "Q1", question: "What?"
    )
    Steps::Resolve.create!(
      workflow: simple_workflow, uuid: SecureRandom.uuid, position: 1,
      title: "Done", resolution_type: "success"
    )
    simple_workflow.update_column(:start_step_id, q_step.id)

    validator = SubflowValidator.new(simple_workflow.id)

    # 1 find root + 1 extract subflow IDs + depth calculation
    assert_max_queries(5) do
      validator.valid?
    end
  end
end
