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

  test "recently_run_workflows lists each live-run workflow once, most recent first" do
    other = file_in_global(Workflow.create!(title: "Other Flow", user: @editor))
    Scenario.create!(workflow: @workflow, user: @regular, purpose: "live", status: "completed", created_at: 2.hours.ago)
    Scenario.create!(workflow: other, user: @regular, purpose: "live", status: "completed", created_at: 1.hour.ago)
    Scenario.create!(workflow: @workflow, user: @regular, purpose: "simulation", status: "completed")

    assert_equal [other, @workflow], Dashboard::DataLoader.new(@regular).recently_run_workflows.map(&:workflow)
  end
end
