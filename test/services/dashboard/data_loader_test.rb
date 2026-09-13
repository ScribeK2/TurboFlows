require "test_helper"

# What the CSR dashboard reads. The Editor and Admin home is Dashboard::Home.
class Dashboard::DataLoaderTest < ActiveSupport::TestCase
  def setup
    @admin = User.create!(
      email: "admin-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    @editor = User.create!(
      email: "editor-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @regular = User.create!(
      email: "csr-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    @workflow = file_in_global(Workflow.create!(title: "Test Flow", user: @editor))
  end

  # -- CSR detection --

  test "csr? is true for regular users" do
    assert_predicate Dashboard::DataLoader.new(@regular), :csr?
  end

  test "csr? is false for editors" do
    assert_not Dashboard::DataLoader.new(@editor).csr?
  end

  test "csr? is false for admins" do
    assert_not Dashboard::DataLoader.new(@admin).csr?
  end

  # -- Pinned workflows --

  test "pinned_workflows returns pinned workflows" do
    UserWorkflowPin.create!(user: @regular, workflow: @workflow)
    assert_includes Dashboard::DataLoader.new(@regular).pinned_workflows, @workflow
  end

  test "pinned_workflows is empty when no pins" do
    assert_empty Dashboard::DataLoader.new(@regular).pinned_workflows
  end

  test "pinned_workflows excludes unpublished workflows" do
    UserWorkflowPin.create!(user: @regular, workflow: @workflow)
    @workflow.update!(status: "draft")
    assert_empty Dashboard::DataLoader.new(@regular).pinned_workflows
  end

  # -- Runs --

  test "recent_scenarios returns user scenarios" do
    scenario = Scenario.create!(workflow: @workflow, user: @regular, purpose: "live", status: "completed")
    assert_includes Dashboard::DataLoader.new(@regular).recent_scenarios, scenario
  end

  test "recent_scenarios stays personal, because the CSR dashboard means yours" do
    Scenario.create!(workflow: @workflow, user: @editor, purpose: "live",
                     started_at: Time.current, execution_path: [], results: {}, inputs: {})

    assert_empty Dashboard::DataLoader.new(@regular).recent_scenarios
  end

  test "recently_run lists each started workflow once, most recent first" do
    other = global_workflow("Other Flow")
    live_frame(@workflow, created_at: 2.hours.ago)
    live_frame(other, created_at: 1.hour.ago)
    live_frame(@workflow, created_at: 3.hours.ago)
    Scenario.create!(workflow: @workflow, user: @regular, purpose: "simulation", status: "completed")

    assert_equal [other, @workflow], Dashboard::DataLoader.new(@regular).recently_run.map(&:workflow)
  end

  test "recently_run leaves out workflows a call only passed through" do
    sub_flow_target = global_workflow("Sub-flow Target")
    handoff_target = global_workflow("Handoff Target")
    origin = live_frame(@workflow, status: "completed", outcome: "transferred", created_at: 1.hour.ago)
    live_frame(sub_flow_target, parent: origin, created_at: 50.minutes.ago)
    live_frame(handoff_target, handed_off_from: origin, created_at: 40.minutes.ago)

    assert_equal [@workflow], Dashboard::DataLoader.new(@regular).recently_run.map(&:workflow)
  end

  test "recently_run leaves out workflows the CSR can no longer run" do
    unpublished = global_workflow("Unpublished")
    ungrouped = Workflow.create!(title: "In no group", user: @editor)
    live_frame(unpublished)
    live_frame(ungrouped)
    live_frame(@workflow, created_at: 1.hour.ago)
    unpublished.update!(status: "draft")

    assert_equal [@workflow], Dashboard::DataLoader.new(@regular).recently_run.map(&:workflow)
  end

  test "recently_run reads how the call ended, not how its first frame did" do
    next_wf = global_workflow("Next")
    origin = live_frame(@workflow, status: "completed", outcome: "transferred", created_at: 1.hour.ago)
    live_frame(next_wf, handed_off_from: origin, status: "completed", outcome: "escalated")

    recent = Dashboard::DataLoader.new(@regular).recently_run.sole

    assert_equal origin, recent.origin
    assert_predicate recent, :finished?
    assert_equal "escalated", recent.outcome
  end

  test "recently_run says an unfinished call has not finished" do
    live_frame(@workflow, status: "active", outcome: nil)

    recent = Dashboard::DataLoader.new(@regular).recently_run.sole

    assert_not recent.finished?
    assert_nil recent.outcome
  end

  test "pinned_workflow_stats counts calls started, not the frames inside them" do
    UserWorkflowPin.create!(user: @regular, workflow: @workflow)
    origin = live_frame(@workflow, created_at: 1.hour.ago)
    live_frame(@workflow, parent: origin, created_at: 50.minutes.ago)
    live_frame(@workflow, created_at: 10.minutes.ago)

    stats = Dashboard::DataLoader.new(@regular).pinned_workflow_stats.fetch(@workflow.id)

    assert_equal 2, stats[:runs]
  end

  private

  # A live frame of @regular's. Terminal statuses get a completed_at, as
  # record_completion would give them.
  def live_frame(workflow, status: "completed", outcome: "resolved", parent: nil, handed_off_from: nil,
                 created_at: Time.current)
    Scenario.create!(workflow:, user: @regular, purpose: "live", status:, outcome:,
                     parent_scenario: parent, handed_off_from:, created_at:, started_at: created_at,
                     completed_at: (created_at if Scenario::TERMINAL_STATUSES.include?(status)),
                     execution_path: [], results: {}, inputs: {})
  end

  def global_workflow(title)
    file_in_global(Workflow.create!(title:, user: @editor))
  end
end
