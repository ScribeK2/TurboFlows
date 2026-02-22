require "test_helper"

# Tests for SQLite/PostgreSQL compatibility
# These tests verify behaviors that differ between databases
# Run locally with SQLite, and in CI with PostgreSQL to catch issues
class PostgresqlCompatibilityTest < ActiveSupport::TestCase
  fixtures :users, :workflows
  # ===========================================
  # Search Case-Sensitivity Tests
  # ===========================================

  test "workflow search is case-insensitive" do
    user = users(:editor_user)

    # Create workflow with mixed case title
    workflow = Workflow.create!(
      title: "TroubleShooting Guide",
      user: user,
      status: "published"
    )

    # All these searches should find the workflow
    assert_includes Workflow.search_by("troubleshooting").pluck(:id), workflow.id
    assert_includes Workflow.search_by("TROUBLESHOOTING").pluck(:id), workflow.id
    assert_includes Workflow.search_by("TroubleShoot").pluck(:id), workflow.id
  end

  test "template search is case-insensitive" do
    template = Template.create!(
      name: "Customer Support Template",
      category: "support",
      is_public: true
    )

    # All these searches should find the template
    assert_includes Template.search("customer").pluck(:id), template.id
    assert_includes Template.search("CUSTOMER").pluck(:id), template.id
    assert_includes Template.search("SUPPORT").pluck(:id), template.id
  end

  # ===========================================
  # Foreign Key Cascade Tests
  # ===========================================

  test "deleting user cascades to workflows" do
    user = User.create!(
      email: "cascade-test@example.com",
      password: "password123!",
      role: "editor"
    )

    workflow = Workflow.create!(
      title: "Test Workflow",
      user: user,
      status: "published"
    )

    workflow_id = workflow.id

    # Delete user should cascade to workflows
    user.destroy

    assert_nil Workflow.find_by(id: workflow_id), "Workflow should be deleted when user is deleted"
  end

  test "deleting workflow cascades to group_workflows" do
    user = users(:editor_user)
    group = Group.create!(name: "Test Group for Cascade")

    workflow = Workflow.create!(
      title: "Cascade Test Workflow",
      user: user,
      status: "published"
    )

    group_workflow = GroupWorkflow.create!(
      group: group,
      workflow: workflow
    )

    group_workflow_id = group_workflow.id
    workflow.destroy

    assert_nil GroupWorkflow.find_by(id: group_workflow_id), "GroupWorkflow should be deleted when workflow is deleted"
  end

  test "deleting group cascades to group_workflows" do
    user = users(:editor_user)
    group = Group.create!(name: "Deletable Group")

    workflow = Workflow.create!(
      title: "Group Cascade Test",
      user: user,
      status: "published"
    )

    GroupWorkflow.create!(group: group, workflow: workflow)

    # Should not raise foreign key violation
    assert_nothing_raised do
      group.destroy
    end

    # Workflow should still exist
    assert Workflow.exists?(workflow.id), "Workflow should not be deleted when group is deleted"
  end

  # ===========================================
  # Optimistic Locking Tests
  # ===========================================

  test "optimistic locking prevents concurrent updates" do
    user = users(:editor_user)

    workflow = Workflow.create!(
      title: "Locking Test",
      user: user,
      status: "published"
    )

    # Simulate two users loading the same record
    workflow_user1 = Workflow.find(workflow.id)
    workflow_user2 = Workflow.find(workflow.id)

    # User 1 updates successfully
    workflow_user1.update!(title: "Updated by User 1")

    # User 2's update should fail with StaleObjectError
    assert_raises ActiveRecord::StaleObjectError do
      workflow_user2.update!(title: "Updated by User 2")
    end
  end

  # ===========================================
  # Enum/CHECK Constraint Tests
  # ===========================================

  test "user role validates against allowed values" do
    user = User.new(
      email: "role-test@example.com",
      password: "password123!",
      role: "invalid_role"
    )

    assert_not user.valid?
    assert_includes user.errors[:role], "is not included in the list"
  end

  test "scenario status validates against allowed values" do
    workflow = workflows(:one)
    user = users(:regular_user)

    scenario = Scenario.new(
      workflow: workflow,
      user: user,
      status: "invalid_status"
    )

    assert_not scenario.valid?
  end

  test "valid enum values are accepted" do
    # Test all valid user roles
    %w[admin editor user].each do |role|
      user = User.new(
        email: "#{role}-valid@example.com",
        password: "password123!",
        role: role
      )

      assert_predicate user, :valid?, "Role '#{role}' should be valid"
    end

    # Test all valid scenario statuses
    %w[active completed stopped timeout error].each do |status|
      scenario = Scenario.new(
        workflow: workflows(:one),
        user: users(:regular_user),
        status: status
      )

      assert_predicate scenario, :valid?, "Status '#{status}' should be valid"
    end
  end

  # ===========================================
  # String Length Constraint Tests
  # ===========================================

  test "display_name respects length limit" do
    user = User.new(
      email: "length-test@example.com",
      password: "password123!",
      role: "user",
      display_name: "A" * 51  # Exceeds 50 char limit
    )

    assert_not user.valid?
    assert_predicate user.errors[:display_name], :any?
  end

  test "display_name accepts valid length" do
    user = User.new(
      email: "length-valid@example.com",
      password: "password123!",
      role: "user",
      display_name: "A" * 50  # Exactly at limit
    )

    assert_predicate user, :valid?, "Display name at limit should be valid"
  end

  # ===========================================
  # DateTime/Timezone Tests
  # ===========================================

  test "timestamps are stored in UTC" do
    user = users(:editor_user)

    workflow = Workflow.create!(
      title: "Timezone Test",
      user: user,
      status: "published"
    )

    # Reload to get database value
    workflow.reload

    # created_at should be in UTC
    assert_equal "UTC", workflow.created_at.zone
  end
end
