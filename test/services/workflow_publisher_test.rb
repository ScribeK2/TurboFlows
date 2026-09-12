require "test_helper"

class WorkflowPublisherTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(
      email: "publisher-test@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    @workflow = Workflow.create!(
      title: "Publishable Workflow",
      description: "A workflow to publish",
      user: @user,
      graph_mode: true
    )
    @q_step = Steps::Question.create!(
      workflow: @workflow, position: 0, title: "Q1", question: "What?", variable_name: "q1"
    )
    @r_step = Steps::Resolve.create!(
      workflow: @workflow, position: 1, title: "Done", resolution_type: "success"
    )
    Transition.create!(step: @q_step, target_step: @r_step, position: 0)
    @workflow.update_column(:start_step_id, @q_step.id)
    file_in_global(@workflow)
  end

  # Nothing pinned this until 2026-09-10, and it is the only thing between an
  # untargeted Sub-Flow and a live workflow once saves stop refusing it.
  test "refuses to publish a workflow whose sub-flow has no target" do
    sub_flow = Steps::SubFlow.create!(workflow: @workflow, position: 2, title: "Hand to billing")
    Transition.find_by(step: @q_step, target_step: @r_step).update!(position: 1)
    Transition.create!(step: @q_step, target_step: sub_flow, position: 0)
    Transition.create!(step: sub_flow, target_step: @r_step, position: 0)

    result = nil
    assert_no_difference "WorkflowVersion.count" do
      result = WorkflowPublisher.publish(@workflow.reload, @user)
    end

    assert_not result.success?
    assert_includes result.error, "requires a target workflow"
  end

  test "the publish signal ends with the publish" do
    assert_predicate WorkflowPublisher.publish(@workflow, @user), :success?
    assert_not @workflow.publishing?
  end

  test "publishes a workflow and creates a version" do
    result = WorkflowPublisher.publish(@workflow, @user)

    assert_predicate result, :success?, result.error
    version = result.version
    assert_equal 1, version.version_number
    assert_equal "Q1", version.steps_snapshot.first["title"]
    assert_equal @user, version.published_by
    assert_not_nil version.published_at
  end

  test "snapshots metadata correctly" do
    result = WorkflowPublisher.publish(@workflow, @user)

    metadata = result.version.metadata_snapshot
    assert_equal "Publishable Workflow", metadata["title"]
    assert metadata["graph_mode"]
    assert_equal @q_step.uuid, metadata["start_node_uuid"]
  end

  test "sets published_version_id on workflow" do
    result = WorkflowPublisher.publish(@workflow, @user)

    @workflow.reload
    assert_equal result.version, @workflow.published_version
  end

  test "increments version_number when the content actually changed" do
    WorkflowPublisher.publish(@workflow, @user)
    @q_step.update!(question: "What, precisely?")
    result = WorkflowPublisher.publish(@workflow, @user, changelog: "Updated steps")

    assert_equal 2, result.version.version_number
  end

  # An identical republish is not a new version: the previous row already records
  # that exact content, so a byte-identical ~9.5KB snapshot beside it records
  # nothing further. Skipping the write destroys nothing, unlike releasing one.
  test "republishing unchanged content reuses the existing version" do
    first = WorkflowPublisher.publish(@workflow, @user).version

    assert_no_difference "WorkflowVersion.count" do
      again = WorkflowPublisher.publish(@workflow, @user)
      assert_equal first.id, again.version.id
    end
    assert_equal first, @workflow.reload.published_version
    assert_predicate @workflow, :published?
  end

  test "a title change alone is a new version" do
    WorkflowPublisher.publish(@workflow, @user)
    @workflow.update!(title: "Renamed Workflow")

    assert_difference "WorkflowVersion.count", 1 do
      result = WorkflowPublisher.publish(@workflow, @user)
      assert_equal 2, result.version.version_number
    end
  end

  test "stores changelog" do
    result = WorkflowPublisher.publish(@workflow, @user, changelog: "Initial release")

    assert_equal "Initial release", result.version.changelog
  end

  test "fails if workflow has no steps" do
    empty_workflow = Workflow.create!(title: "Empty", user: @user, graph_mode: true)

    result = WorkflowPublisher.publish(empty_workflow, @user)

    assert_not result.success?
    assert_match(/no steps/i, result.error)
  end

  test "fails if workflow has validation errors in graph mode" do
    # Create a step with a transition to a nonexistent target
    r_step = Steps::Resolve.create!(workflow: @workflow, position: 1, title: "End")
    # Create transition to non-existent step to trigger graph validation failure
    Transition.create!(step: @q_step, target_step: r_step, position: 0)
    # Add an orphaned step with no incoming transitions and no outgoing
    Steps::Action.create!(workflow: @workflow, position: 2, title: "Orphan")

    result = WorkflowPublisher.publish(@workflow, @user)

    assert_not result.success?
    assert_predicate result.error, :present?
  end

  test "does not create version on failure" do
    empty_workflow = Workflow.create!(title: "Empty", user: @user, graph_mode: true)

    assert_no_difference "WorkflowVersion.count" do
      WorkflowPublisher.publish(empty_workflow, @user)
    end
  end

  test "rejects workflow with no Resolve terminal" do
    # Create a workflow with only non-Resolve steps
    no_resolve_wf = Workflow.create!(title: "No Resolve", user: @user, graph_mode: true, status: "draft")
    a = Steps::Action.create!(workflow: no_resolve_wf, position: 0, title: "Only Action")
    no_resolve_wf.update_column(:start_step_id, a.id)

    result = WorkflowPublisher.publish(no_resolve_wf, @user)

    assert_not result.success?
    assert_match(/Resolve/i, result.error)
  end

  test "rejects workflow with unreachable orphan step" do
    orphan_wf = Workflow.create!(title: "Orphan WF", user: @user, graph_mode: true, status: "draft")
    q = Steps::Question.create!(workflow: orphan_wf, position: 0, title: "Q", question: "What?")
    r = Steps::Resolve.create!(workflow: orphan_wf, position: 1, title: "Done", resolution_type: "success")
    Steps::Action.create!(workflow: orphan_wf, position: 2, title: "Orphan")
    Transition.create!(step: q, target_step: r, position: 0)
    orphan_wf.update_column(:start_step_id, q.id)

    result = WorkflowPublisher.publish(orphan_wf, @user)

    assert_not result.success?
    assert_match(/reachable/i, result.error)
  end

  test "publishes valid workflow with Resolve terminal and all reachable" do
    valid_wf = Workflow.create!(title: "Valid", user: @user, graph_mode: true, status: "draft")
    q = Steps::Question.create!(workflow: valid_wf, position: 0, title: "Q1", question: "What?", variable_name: "answer")
    r = Steps::Resolve.create!(workflow: valid_wf, position: 1, title: "Done", resolution_type: "success")
    Transition.create!(step: q, target_step: r, position: 0)
    valid_wf.update_column(:start_step_id, q.id)
    file_in_global(valid_wf)

    result = WorkflowPublisher.publish(valid_wf, @user)

    assert_predicate result, :success?, "Expected success, got: #{result.error}"
    assert_equal 1, result.version.version_number
  end

  test "published_version points to latest version" do
    WorkflowPublisher.publish(@workflow, @user)

    # Add a new step between Q1 and Done, rewire transitions for v2
    new_step = Steps::Action.create!(workflow: @workflow, position: 1, title: "New Step")
    @r_step.update!(position: 2)
    # Remove old Q1->Done transition and add Q1->New->Done
    @q_step.transitions.destroy_all
    Transition.create!(step: @q_step, target_step: new_step, position: 0)
    Transition.create!(step: new_step, target_step: @r_step, position: 0)
    WorkflowPublisher.publish(@workflow, @user, changelog: "v2")

    @workflow.reload
    assert_equal 2, @workflow.published_version.version_number
    assert_equal "New Step", @workflow.published_version.steps_snapshot[1]["title"]
  end

  test "refuses to publish a workflow with no reachable Resolve anywhere" do
    wf_a = Workflow.create!(title: "Pub A", user: @user, status: "draft")
    wf_b = Workflow.create!(title: "Pub B", user: @user, status: "draft")
    Steps::SubFlow.create!(workflow: wf_a, position: 0, title: "Hand to B",
                           sub_flow_workflow_id: wf_b.id, sub_flow_returns: false)
    Steps::SubFlow.create!(workflow: wf_b, position: 0, title: "Hand to A",
                           sub_flow_workflow_id: wf_a.id, sub_flow_returns: false)
    result = WorkflowPublisher.publish(wf_a.reload, @user)
    assert_not result.success?
    # Anchored: GraphValidator's own message is "Step 'X' has no path to a
    # Resolve step.", which differs from this one only by capitalisation.
    # Unanchored, a reworded message on either side could make this pass for
    # the wrong validator.
    assert_match(/\ANo path to a Resolve step/, result.error)
    assert_equal "draft", wf_a.reload.status
  end

  # Spec Q44. New workflows start with no groups (Q45), so a forgotten choice
  # would otherwise publish something only its owner and admins can see.
  test "refuses to publish a workflow nobody has been chosen to see" do
    @workflow.group_workflows.delete_all

    result = WorkflowPublisher.publish(@workflow, @user)

    assert_not result.success?
    assert_equal WorkflowPublisher::NO_AUDIENCE, result.error
    assert_empty @workflow.versions
  end

  # no_path_to_resolve is a publish blocker (PUBLISH_BLOCKING_CODES), and the
  # other refusals above each had a test; this one had none.
  test "refuses a workflow whose only path leads into a loop with no way out" do
    loop_wf = Workflow.create!(title: "Loop", user: @user, graph_mode: true, status: "draft")
    start = Steps::Action.create!(workflow: loop_wf, position: 0, title: "Start")
    a = Steps::Action.create!(workflow: loop_wf, position: 1, title: "A")
    b = Steps::Action.create!(workflow: loop_wf, position: 2, title: "B")
    Steps::Resolve.create!(workflow: loop_wf, position: 3, title: "Done", resolution_type: "success")
    Transition.create!(step: start, target_step: a, position: 0)
    Transition.create!(step: a, target_step: b, position: 0)
    Transition.create!(step: b, target_step: a, position: 0)
    loop_wf.update_column(:start_step_id, start.id)
    file_in_global(loop_wf)

    result = WorkflowPublisher.publish(loop_wf.reload, @user)

    assert_not result.success?
    assert_match(/no path to a Resolve step/i, result.error)
    assert_equal "draft", loop_wf.reload.status
  end
end
