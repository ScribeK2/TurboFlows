require "test_helper"

class ScenarioCleanupTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(
      email: "cleanup-test@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    @workflow = Workflow.create!(
      title: "Cleanup Test Workflow",
      user: @user
    )
  end

  # Helper to create a scenario with specific attributes
  def create_scenario(purpose: "simulation", status: "completed", completed_at: Time.current, updated_at: nil)
    scenario = Scenario.create!(
      workflow: @workflow,
      user: @user,
      purpose: purpose,
      status: "active"
    )
    # Use update_columns to bypass enum and set exact DB values + timestamps
    attrs = { status: status, completed_at: completed_at }
    attrs[:updated_at] = updated_at if updated_at
    scenario.update_columns(attrs)
    scenario
  end

  # --- terminal scope ---

  test "terminal scope includes completed, stopped, timeout, and error statuses" do
    completed = create_scenario(status: "completed")
    stopped = create_scenario(status: "stopped")
    timed_out = create_scenario(status: "timeout")
    errored = create_scenario(status: "error")
    active = create_scenario(status: "active")
    awaiting = create_scenario(status: "awaiting_subflow")

    terminal_ids = Scenario.terminal.pluck(:id)

    assert_includes terminal_ids, completed.id
    assert_includes terminal_ids, stopped.id
    assert_includes terminal_ids, timed_out.id
    assert_includes terminal_ids, errored.id
    assert_not_includes terminal_ids, active.id
    assert_not_includes terminal_ids, awaiting.id
  end

  # --- stale_simulations scope ---

  test "stale_simulations includes old completed simulation scenarios" do
    stale = create_scenario(purpose: "simulation", status: "completed", completed_at: 8.days.ago)
    fresh = create_scenario(purpose: "simulation", status: "completed", completed_at: 1.day.ago)

    stale_ids = Scenario.stale_simulations.pluck(:id)

    assert_includes stale_ids, stale.id
    assert_not_includes stale_ids, fresh.id
  end

  test "stale_simulations excludes live scenarios" do
    old_live = create_scenario(purpose: "live", status: "completed", completed_at: 8.days.ago)

    stale_ids = Scenario.stale_simulations.pluck(:id)

    assert_not_includes stale_ids, old_live.id
  end

  # --- stale_live scope ---

  test "stale_live includes old completed live scenarios" do
    stale = create_scenario(purpose: "live", status: "completed", completed_at: 91.days.ago)
    fresh = create_scenario(purpose: "live", status: "completed", completed_at: 30.days.ago)

    stale_ids = Scenario.stale_live.pluck(:id)

    assert_includes stale_ids, stale.id
    assert_not_includes stale_ids, fresh.id
  end

  test "stale_live excludes simulation scenarios" do
    old_sim = create_scenario(purpose: "simulation", status: "completed", completed_at: 91.days.ago)

    stale_ids = Scenario.stale_live.pluck(:id)

    assert_not_includes stale_ids, old_sim.id
  end

  # --- Boundary tests ---

  test "simulation at exactly 7 days is not stale" do
    travel_to Time.zone.local(2026, 3, 18, 12, 0, 0) do
      boundary = create_scenario(
        purpose: "simulation",
        status: "completed",
        completed_at: 7.days.ago
      )

      assert_not_includes Scenario.stale_simulations.pluck(:id), boundary.id
    end
  end

  test "simulation at 8 days is stale" do
    travel_to Time.zone.local(2026, 3, 18, 12, 0, 0) do
      past_boundary = create_scenario(
        purpose: "simulation",
        status: "completed",
        completed_at: 8.days.ago
      )

      assert_includes Scenario.stale_simulations.pluck(:id), past_boundary.id
    end
  end

  test "live at exactly 90 days is not stale" do
    travel_to Time.zone.local(2026, 3, 18, 12, 0, 0) do
      boundary = create_scenario(
        purpose: "live",
        status: "completed",
        completed_at: 90.days.ago
      )

      assert_not_includes Scenario.stale_live.pluck(:id), boundary.id
    end
  end

  test "live at 91 days is stale" do
    travel_to Time.zone.local(2026, 3, 18, 12, 0, 0) do
      past_boundary = create_scenario(
        purpose: "live",
        status: "completed",
        completed_at: 91.days.ago
      )

      assert_includes Scenario.stale_live.pluck(:id), past_boundary.id
    end
  end

  # --- Active scenarios protected ---

  test "active scenarios are never eligible for cleanup regardless of age" do
    old_active = create_scenario(status: "active", completed_at: nil)
    old_active.update_columns(created_at: 1.year.ago, updated_at: 1.year.ago)

    assert_not_includes Scenario.stale_simulations.pluck(:id), old_active.id
    assert_not_includes Scenario.stale_live.pluck(:id), old_active.id
  end

  test "awaiting_subflow scenarios are never eligible for cleanup" do
    awaiting = create_scenario(status: "awaiting_subflow", completed_at: nil)
    awaiting.update_columns(created_at: 1.year.ago, updated_at: 1.year.ago)

    assert_not_includes Scenario.stale_simulations.pluck(:id), awaiting.id
    assert_not_includes Scenario.stale_live.pluck(:id), awaiting.id
  end

  # --- NULL completed_at (post-backfill behavior) ---

  test "terminal scenario with NULL completed_at is excluded from stale scopes" do
    # After backfill migration, terminal scenarios always have completed_at.
    # If one somehow has NULL, it should be excluded (not cleaned up prematurely).
    scenario = create_scenario(status: "error", completed_at: nil)
    scenario.update_columns(completed_at: nil, updated_at: 8.days.ago)

    assert_not_includes Scenario.stale_simulations.pluck(:id), scenario.id
  end

  # --- FK cascade (step_responses) ---

  test "delete_all on scenarios cascades to step_responses via FK" do
    scenario = create_scenario(purpose: "simulation", status: "completed", completed_at: 8.days.ago)
    step = @workflow.steps.first || Steps::Action.create!(
      workflow: @workflow, title: "Test Step", uuid: SecureRandom.uuid
    )
    StepResponse.create!(scenario: scenario, step: step, submitted_at: Time.current)

    assert_equal 1, StepResponse.where(scenario_id: scenario.id).count
    Scenario.where(id: scenario.id).delete_all
    assert_equal 0, StepResponse.where(scenario_id: scenario.id).count
  end

  test "cleanup_stale cascades step_response deletion" do
    scenario = create_scenario(purpose: "simulation", status: "completed", completed_at: 8.days.ago)
    step = @workflow.steps.first || Steps::Action.create!(
      workflow: @workflow, title: "Test Step", uuid: SecureRandom.uuid
    )
    StepResponse.create!(scenario: scenario, step: step, submitted_at: Time.current)

    Scenario.cleanup_stale

    assert_not Scenario.exists?(scenario.id)
    assert_equal 0, StepResponse.where(scenario_id: scenario.id).count
  end

  # --- cleanup_stale class method ---

  test "cleanup_stale deletes stale scenarios and returns total count" do
    stale_sim = create_scenario(purpose: "simulation", status: "completed", completed_at: 8.days.ago)
    stale_live = create_scenario(purpose: "live", status: "completed", completed_at: 91.days.ago)
    fresh = create_scenario(purpose: "simulation", status: "completed", completed_at: 1.day.ago)

    count = Scenario.cleanup_stale

    assert_equal 2, count
    assert_not Scenario.exists?(stale_sim.id)
    assert_not Scenario.exists?(stale_live.id)
    assert Scenario.exists?(fresh.id)
  end

  test "cleanup_stale returns 0 when no stale scenarios exist" do
    create_scenario(purpose: "simulation", status: "completed", completed_at: 1.day.ago)

    assert_equal 0, Scenario.cleanup_stale
  end

  # --- Child scenario cleanup ---

  test "cleanup_stale deletes child scenarios of stale parents" do
    parent = create_scenario(purpose: "simulation", status: "completed", completed_at: 8.days.ago)

    child = Scenario.create!(
      workflow: @workflow,
      user: @user,
      parent_scenario: parent,
      purpose: "simulation",
      status: "active"
    )
    child.update_columns(status: "completed", completed_at: 1.day.ago)

    Scenario.cleanup_stale

    assert_not Scenario.exists?(parent.id)
    assert_not Scenario.exists?(child.id)
  end

  test "orphaned stale child scenarios are cleaned up independently" do
    # Child whose parent was already deleted — child is stale on its own
    orphan = create_scenario(purpose: "simulation", status: "completed", completed_at: 8.days.ago)

    Scenario.cleanup_stale

    assert_not Scenario.exists?(orphan.id)
  end

  # --- Custom ENV retention ---

  test "custom ENV overrides simulation retention period" do
    # Scenario is 4 days old — stale with 3-day retention, fresh with default 7-day
    scenario = create_scenario(purpose: "simulation", status: "completed", completed_at: 4.days.ago)

    # With default 7-day retention, should NOT be stale
    assert_not_includes Scenario.stale_simulations.pluck(:id), scenario.id

    # Override to 3 days
    ENV["SCENARIO_RETENTION_SIMULATION_DAYS"] = "3"
    assert_includes Scenario.stale_simulations.pluck(:id), scenario.id
  ensure
    ENV.delete("SCENARIO_RETENTION_SIMULATION_DAYS")
  end

  test "custom ENV overrides live retention period" do
    # Scenario is 31 days old — stale with 30-day retention, fresh with default 90-day
    scenario = create_scenario(purpose: "live", status: "completed", completed_at: 31.days.ago)

    # With default 90-day retention, should NOT be stale
    assert_not_includes Scenario.stale_live.pluck(:id), scenario.id

    # Override to 30 days
    ENV["SCENARIO_RETENTION_LIVE_DAYS"] = "30"
    assert_includes Scenario.stale_live.pluck(:id), scenario.id
  ensure
    ENV.delete("SCENARIO_RETENTION_LIVE_DAYS")
  end
end
