require "test_helper"

class NavHelperTest < ActionView::TestCase
  include NavHelper

  # nav_section reads controller_path, which ActionView::TestCase does not set
  # for us. Each test declares the page it is standing on.
  attr_accessor :controller_path

  # --- the three controllers that used to light nothing ---
  #
  # Before the section map these fell through `start_with?("workflows")` and
  # left the bar completely inert: you could be running a scenario from the
  # builder with no item highlighted anywhere.

  test "a scenario run lights Workflows" do
    self.controller_path = "scenarios"
    assert_equal :workflows, nav_section
  end

  test "a step edit lights Workflows" do
    self.controller_path = "steps"
    assert_equal :workflows, nav_section
  end

  test "version history lights Workflows" do
    self.controller_path = "workflow_versions"
    assert_equal :workflows, nav_section
  end

  # --- sections ---

  test "the workflows index lights Workflows" do
    self.controller_path = "workflows"
    assert_equal :workflows, nav_section
  end

  test "every Workflows:: namespace controller lights Workflows" do
    %w[workflows/exports workflows/imports workflows/healths
       workflows/executions workflows/publishings].each do |path|
      self.controller_path = path
      assert_equal :workflows, nav_section, "#{path} should light Workflows"
    end
  end

  test "the player lights Play" do
    self.controller_path = "player"
    assert_equal :play, nav_section
  end

  test "every admin page lights Admin" do
    %w[admin/dashboard admin/users admin/workflows admin/groups
       admin/data_health admin/smtp_settings].each do |path|
      self.controller_path = path
      assert_equal :admin, nav_section, "#{path} should light Admin"
    end
  end

  test "analytics and its drill-downs light Analytics" do
    %w[analytics analytics/agents analytics/runs].each do |path|
      self.controller_path = path
      assert_equal :analytics, nav_section, "#{path} should light Analytics"
    end
  end

  test "the dashboard lights the brand" do
    self.controller_path = "dashboard"
    assert_equal :home, nav_section
  end

  # admin/dashboard must not be mistaken for the top-level dashboard: the
  # admin/ prefix is checked before the map is consulted.
  test "the admin dashboard lights Admin, not the brand" do
    self.controller_path = "admin/dashboard"
    assert_equal :admin, nav_section
  end

  # --- deliberate non-members ---

  test "pages reached from inside a section light nothing" do
    %w[profiles tags folders first_runs sessions
       users/registrations users/sessions].each do |path|
      self.controller_path = path
      assert_nil nav_section, "#{path} should light no nav item"
    end
  end

  # "workflow_versions" must not be swept up by a sloppy prefix match on
  # "workflows" — and equally must not be missed, which is why it is in the map.
  test "a controller merely starting with 'workflow' is not assumed" do
    self.controller_path = "workflowish"
    assert_nil nav_section
  end

  # --- nav_current ---

  test "nav_current returns page for the matching section and nil otherwise" do
    self.controller_path = "player"
    assert_equal "page", nav_current(:play)
    assert_nil nav_current(:workflows)
    assert_nil nav_current(:admin)
    assert_nil nav_current(:home)
  end
end
