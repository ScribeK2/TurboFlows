require "application_system_test_case"

class TemplateApplicationTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "wf-system-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    sign_in_as @user
  end

  test "user applies a template to a new workflow" do
    # Create a new workflow — goes directly to builder with "Untitled Workflow"
    visit new_workflow_path

    # Should see the empty state with template cards
    assert_selector "#builder-empty-state", wait: 5
    assert_selector ".builder__template-card", minimum: 1

    # Click the first template (Guided Decision)
    find(".builder__template-card", text: "Guided Decision").click

    # Should see steps populated (empty state gone)
    assert_no_selector "#builder-empty-state", wait: 5
    assert_selector ".builder__list-row", minimum: 3, wait: 5
  end
end
