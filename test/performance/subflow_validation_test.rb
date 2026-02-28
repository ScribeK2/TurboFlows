require "test_helper"

class SubflowValidationTest < ActiveSupport::TestCase
  include PerformanceHelper

  setup do
    @data = seed_performance_data

    # Create a chain of 10 workflows with sub-flow references
    @subflow_workflows = 10.times.map do |i|
      Workflow.create!(
        title: "Subflow Chain #{i}",
        description: "Workflow in subflow chain",
        status: "published",
        user: @data[:editors].first,
        steps: []
      )
    end

    # Wire them up: each workflow has a sub-flow step pointing to the next
    @subflow_workflows.each_with_index do |wf, i|
      next_wf = @subflow_workflows[i + 1]
      next unless next_wf

      wf.update_columns(steps: [
        { "id" => SecureRandom.uuid, "type" => "question", "title" => "Q1", "question" => "Q?" },
        { "id" => SecureRandom.uuid, "type" => "sub_flow", "title" => "Sub",
          "target_workflow_id" => next_wf.id, "_import_incomplete" => true },
        { "id" => SecureRandom.uuid, "type" => "resolve", "title" => "Done" }
      ])
    end
  end

  test "validating a 10-deep subflow chain uses bounded queries instead of N per node" do
    validator = SubflowValidator.new(@subflow_workflows.first.id)

    # BFS loads each level in one query: 1 root + up to 9 batch loads
    # Much better than the old DFS which did 2N queries (find + referenced for each node)
    assert_max_queries(12) do
      validator.valid?
    end
  end

  test "validating a workflow with no subflows uses 2 or fewer queries" do
    # Create a simple workflow with no sub-flow steps
    simple_workflow = Workflow.create!(
      title: "Simple No Subflow",
      status: "published",
      user: @data[:editors].first,
      steps: [
        { "id" => SecureRandom.uuid, "type" => "question", "title" => "Q1", "question" => "What?" },
        { "id" => SecureRandom.uuid, "type" => "resolve", "title" => "Done" }
      ]
    )

    validator = SubflowValidator.new(simple_workflow.id)

    assert_max_queries(2) do
      validator.valid?
    end
  end
end
