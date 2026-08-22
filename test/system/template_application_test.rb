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

    assert_selector "#builder-empty-state", wait: 5

    # Templates live in the toolbar popover, which is the only place that
    # action exists — the empty state links to it rather than duplicating it.
    click_button "Browse templates"
    assert_selector ".builder__template-popover-item", minimum: 1, wait: 5

    find(".builder__template-popover-item", text: "Guided Decision").click

    # Should see steps populated (empty state gone)
    assert_no_selector "#builder-empty-state", wait: 5
    assert_selector ".builder__step", minimum: 3, wait: 5
  end

  test "empty state offers quick starts without duplicating the template grid" do
    visit new_workflow_path

    assert_selector "#builder-empty-state", wait: 5
    assert_selector "#builder-empty-state .list-row--prompt"
    assert_button "Question"
    assert_no_selector "#builder-empty-state .builder__template-popover-item"

    click_button "Question"

    assert_no_selector "#builder-empty-state", wait: 5
    assert_selector ".builder__step", count: 1
  end

  test "opening a step marks its row as selected" do
    workflow = Workflow.create!(title: "Selection test", user: @user)
    Steps::Resolve.create!(workflow: workflow, position: 1, title: "Done")

    visit workflow_path(workflow, edit: true)

    assert_selector ".builder__step", count: 1, wait: 5
    assert_no_selector ".builder__step--selected"

    find(".builder__step").click

    assert_selector ".builder__step--selected", wait: 5
  end
end
