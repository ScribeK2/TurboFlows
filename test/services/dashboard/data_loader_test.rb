require "test_helper"

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
    @workflow = Workflow.create!(title: "Test Flow", user: @editor, is_public: true)
  end

  # -- CSR detection --

  test "csr? is true for regular users" do
    loader = Dashboard::DataLoader.new(@regular)
    assert loader.csr?
  end

  test "csr? is false for editors" do
    loader = Dashboard::DataLoader.new(@editor)
    assert_not loader.csr?
  end

  test "csr? is false for admins" do
    loader = Dashboard::DataLoader.new(@admin)
    assert_not loader.csr?
  end

  # -- Pinned workflows --

  test "pinned_workflows returns pinned workflows" do
    UserWorkflowPin.create!(user: @regular, workflow: @workflow)
    loader = Dashboard::DataLoader.new(@regular)
    assert_includes loader.pinned_workflows, @workflow
  end

  test "pinned_workflows is empty when no pins" do
    loader = Dashboard::DataLoader.new(@regular)
    assert_empty loader.pinned_workflows
  end

  test "pinned_workflows excludes unpublished workflows" do
    UserWorkflowPin.create!(user: @regular, workflow: @workflow)
    @workflow.update!(status: "draft")
    loader = Dashboard::DataLoader.new(@regular)
    assert_empty loader.pinned_workflows
  end

  # -- CSR stats --

  test "personal_scenario_total counts live scenarios only" do
    Scenario.create!(workflow: @workflow, user: @regular, purpose: "live", status: "completed")
    Scenario.create!(workflow: @workflow, user: @regular, purpose: "simulation", status: "completed")

    loader = Dashboard::DataLoader.new(@regular)
    assert_equal 1, loader.personal_scenario_total
  end

  test "scenarios_this_week counts only live scenarios in current week" do
    Scenario.create!(workflow: @workflow, user: @regular, purpose: "live", status: "completed")
    Scenario.create!(workflow: @workflow, user: @regular, purpose: "live", status: "active")
    Scenario.create!(workflow: @workflow, user: @regular, purpose: "simulation", status: "completed")

    loader = Dashboard::DataLoader.new(@regular)
    assert_equal 2, loader.scenarios_this_week
  end

  test "scenarios_this_week returns 0 with no scenarios" do
    loader = Dashboard::DataLoader.new(@regular)
    assert_equal 0, loader.scenarios_this_week
  end

  test "personal_completion_rate calculates from live scenarios" do
    Scenario.create!(workflow: @workflow, user: @regular, purpose: "live", status: "completed")
    Scenario.create!(workflow: @workflow, user: @regular, purpose: "live", status: "active")

    loader = Dashboard::DataLoader.new(@regular)
    assert_equal 50, loader.personal_completion_rate
  end

  test "personal_completion_rate returns 0 with no scenarios" do
    loader = Dashboard::DataLoader.new(@regular)
    assert_equal 0, loader.personal_completion_rate
  end

  test "most_used_workflow returns hash with workflow and count" do
    other_wf = Workflow.create!(title: "Other Flow", user: @editor, is_public: true)
    3.times { Scenario.create!(workflow: @workflow, user: @regular, purpose: "live", status: "completed") }
    1.times { Scenario.create!(workflow: other_wf, user: @regular, purpose: "live", status: "completed") }

    loader = Dashboard::DataLoader.new(@regular)
    result = loader.most_used_workflow
    assert_equal @workflow, result[:workflow]
    assert_equal 3, result[:count]
  end

  test "most_used_workflow returns nil with no scenarios" do
    loader = Dashboard::DataLoader.new(@regular)
    assert_nil loader.most_used_workflow
  end

  # -- SME company-wide stats --

  test "company_scenario_total counts all scenarios" do
    Scenario.create!(workflow: @workflow, user: @regular, purpose: "live", status: "completed")
    Scenario.create!(workflow: @workflow, user: @editor, purpose: "simulation", status: "active")

    loader = Dashboard::DataLoader.new(@editor)
    assert_equal 2, loader.company_scenario_total
  end

  test "company_completion_rate calculates across all users" do
    Scenario.create!(workflow: @workflow, user: @regular, purpose: "live", status: "completed")
    Scenario.create!(workflow: @workflow, user: @editor, purpose: "simulation", status: "completed")
    Scenario.create!(workflow: @workflow, user: @regular, purpose: "live", status: "active")

    loader = Dashboard::DataLoader.new(@editor)
    assert_equal 67, loader.company_completion_rate
  end

  test "company_completion_rate returns 0 with no scenarios" do
    loader = Dashboard::DataLoader.new(@editor)
    assert_equal 0, loader.company_completion_rate
  end

  test "company_scenarios_this_week counts all scenarios this week" do
    Scenario.create!(workflow: @workflow, user: @regular, purpose: "live", status: "completed")
    Scenario.create!(workflow: @workflow, user: @editor, purpose: "simulation", status: "active")

    loader = Dashboard::DataLoader.new(@editor)
    assert_equal 2, loader.company_scenarios_this_week
  end

  # -- Shared --

  test "workflow_count returns visible workflows count" do
    loader = Dashboard::DataLoader.new(@editor)
    assert loader.workflow_count >= 1, "Expected at least 1 visible workflow"
  end

  test "draft_count returns user drafts only" do
    Workflow.create!(title: "Draft Flow", user: @editor, status: "draft")
    loader = Dashboard::DataLoader.new(@editor)
    assert_equal 1, loader.draft_count
  end

  test "workflows returns recent workflows" do
    loader = Dashboard::DataLoader.new(@regular)
    assert_includes loader.workflows, @workflow
  end

  test "recent_scenarios returns user scenarios" do
    scenario = Scenario.create!(workflow: @workflow, user: @regular, purpose: "live", status: "completed")
    loader = Dashboard::DataLoader.new(@regular)
    assert_includes loader.recent_scenarios, scenario
  end
end
