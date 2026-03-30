require "test_helper"

class ScenarioExecutionTimingTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "timing-#{SecureRandom.hex(4)}@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    @workflow = Workflow.create!(title: "Timing Flow", user: @user)
    @resolve_step = Steps::Resolve.create!(
      workflow: @workflow,
      title: "Done",
      uuid: SecureRandom.uuid,
      position: 0,
      resolution_type: "success"
    )
    @workflow.update!(start_step: @resolve_step)
    WorkflowPublisher.publish(@workflow, @user)
  end

  test "record_step_started stores pending timestamp" do
    scenario = Scenario.create!(workflow: @workflow, user: @user, purpose: "simulation")
    assert_nil scenario.step_started_at_pending

    scenario.record_step_started
    assert scenario.step_started_at_pending.present?
    assert_nothing_raised { Time.parse(scenario.step_started_at_pending) }
  end

  test "build_path_entry consumes pending started_at" do
    scenario = Scenario.create!(workflow: @workflow, user: @user, purpose: "simulation")
    scenario.record_step_started
    pending_ts = scenario.step_started_at_pending

    entry = scenario.send(:build_path_entry, @resolve_step)

    assert_equal pending_ts, entry[:started_at]
    assert_nil scenario.step_started_at_pending, "pending timestamp should be consumed"
  end

  test "build_path_entry uses current time when no pending timestamp" do
    scenario = Scenario.create!(workflow: @workflow, user: @user, purpose: "simulation")

    freeze_time do
      entry = scenario.send(:build_path_entry, @resolve_step)
      assert_equal Time.current.iso8601(3), entry[:started_at]
    end
  end

  test "record_step_ended stamps last path entry with ended_at and duration" do
    scenario = Scenario.create!(workflow: @workflow, user: @user, purpose: "simulation")
    started = Time.current.iso8601(3)
    scenario.execution_path = [{ "step_uuid" => @resolve_step.uuid, "started_at" => started }]
    scenario.save!

    travel 5.seconds do
      scenario.record_step_ended
    end

    last_entry = scenario.reload.execution_path.last
    assert last_entry["ended_at"].present?
    assert last_entry["duration_seconds"].present?
    assert last_entry["duration_seconds"] >= 4.5, "duration should be ~5 seconds"
  end

  test "record_step_ended is a no-op when execution_path is blank" do
    scenario = Scenario.create!(workflow: @workflow, user: @user, purpose: "simulation")
    scenario.execution_path = []
    scenario.save!

    assert_nothing_raised { scenario.record_step_ended }
  end

  test "record_step_ended is a no-op when last entry has no started_at" do
    scenario = Scenario.create!(workflow: @workflow, user: @user, purpose: "simulation")
    scenario.execution_path = [{ "step_uuid" => @resolve_step.uuid }]
    scenario.save!

    assert_nothing_raised { scenario.record_step_ended }
    assert_nil scenario.execution_path.last["ended_at"]
  end

  test "execution path entries include started_at after processing" do
    scenario = Scenario.create!(
      workflow: @workflow,
      user: @user,
      purpose: "simulation",
      current_node_uuid: @resolve_step.uuid,
      execution_path: [],
      results: {},
      inputs: {}
    )
    scenario.record_step_started

    scenario.process_step(nil)

    assert scenario.execution_path.present?
    entry = scenario.execution_path.last
    assert entry["started_at"].present?, "path entry should include started_at"
  end
end
