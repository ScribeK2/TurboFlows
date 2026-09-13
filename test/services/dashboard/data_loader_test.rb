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

  # -- Resume --

  test "resume offers a call active 59 minutes ago" do
    frame = live_frame(@workflow, status: "active", outcome: nil)
    age!(frame, 59.minutes.ago)

    resume = Dashboard::DataLoader.new(@regular).resume

    assert_equal frame, resume.frame
    assert_equal @workflow, resume.workflow
  end

  test "resume offers nothing once a call has been idle 61 minutes" do
    frame = live_frame(@workflow, status: "active", outcome: nil)
    age!(frame, 61.minutes.ago)

    assert_nil Dashboard::DataLoader.new(@regular).resume
  end

  test "resume offers nothing for a call that finished" do
    live_frame(@workflow, status: "completed", outcome: "resolved")

    assert_nil Dashboard::DataLoader.new(@regular).resume
  end

  test "resume offers nothing for someone else's call" do
    Scenario.create!(workflow: @workflow, user: @editor, purpose: "live", status: "active",
                     execution_path: [], results: {}, inputs: {})

    assert_nil Dashboard::DataLoader.new(@regular).resume
  end

  test "resume reads the whole call's clock, so a parent parked on a live sub-flow is not idle" do
    sub_flow = global_workflow("Sub-flow")
    parent = live_frame(@workflow, status: "awaiting_subflow", outcome: nil)
    age!(parent, 3.hours.ago)
    child = live_frame(sub_flow, status: "active", outcome: nil, parent:)

    resume = Dashboard::DataLoader.new(@regular).resume

    assert_equal child, resume.frame, "Resume opens the frame the CSR was last on"
    assert_equal @workflow, resume.workflow, "and names the workflow the call started in"
  end

  test "resume follows a handoff to the frame the call moved to" do
    next_wf = global_workflow("Next")
    origin = live_frame(@workflow, status: "completed", outcome: "transferred")
    handed_to = live_frame(next_wf, status: "active", outcome: nil, handed_off_from: origin)

    resume = Dashboard::DataLoader.new(@regular).resume

    assert_equal handed_to, resume.frame
    assert_equal @workflow, resume.workflow
  end

  test "resume picks the call with the latest activity" do
    other = global_workflow("Other")
    older = live_frame(@workflow, status: "active", outcome: nil)
    age!(older, 30.minutes.ago)
    newer = live_frame(other, status: "active", outcome: nil)
    age!(newer, 5.minutes.ago)

    assert_equal newer, Dashboard::DataLoader.new(@regular).resume.frame
  end

  test "resume names the step open on its frame" do
    question = Steps::Question.create!(workflow: @workflow, title: "Verify account", position: 0,
                                       question: "Is the account verified?", answer_type: "yes_no")
    frame = live_frame(@workflow, status: "active", outcome: nil)
    frame.update!(current_node_uuid: question.uuid)

    assert_equal "Verify account", Dashboard::DataLoader.new(@regular).resume.step_title
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

  def age!(scenario, ago)
    Scenario.where(id: scenario.id).update_all(updated_at: ago)
  end
end
