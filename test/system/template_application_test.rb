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
    # Create a new workflow — POST, then the builder with "Untitled Workflow"
    visit workflows_path
    click_button "New Workflow", match: :first

    assert_selector "#builder-empty-state", wait: 5

    # Templates lead the empty state as cards. This used to say the opposite —
    # "the empty state links to [the popover] rather than duplicating it" — and
    # that ordering is what this change reverses: a template produces a correctly
    # wired graph in one click, while building by hand produced eight errors, so
    # the prominent path should be the one that works.
    find(".builder__template-card", text: "Guided Decision").click

    assert_no_selector "#builder-empty-state", wait: 5
    assert_selector ".builder__step", minimum: 3, wait: 5
  end

  # The toolbar popover still exists and still applies — it is the only way in
  # once a workflow has steps, since the empty state is gone by then.
  test "the toolbar popover still applies a template" do
    visit workflows_path
    click_button "New Workflow", match: :first

    assert_selector "#builder-empty-state", wait: 5
    click_button "Templates"
    assert_selector ".builder__template-popover-item", minimum: 1, wait: 5

    find(".builder__template-popover-item", text: "Guided Decision").click

    assert_no_selector "#builder-empty-state", wait: 5
    assert_selector ".builder__step", minimum: 3, wait: 5
  end

  test "the empty state leads with templates and offers single steps second" do
    visit workflows_path
    click_button "New Workflow", match: :first

    assert_selector "#builder-empty-state", wait: 5
    assert_selector "#builder-empty-state .list-row--prompt"

    # Templates first, blank-start second — the inversion itself, asserted by
    # document order so a later restyle cannot quietly put them back.
    cards = find("#builder-empty-state .builder__template-cards")
    quick = find("#builder-empty-state .builder__quick-starts")
    assert_operator cards.native.location.y, :<, quick.native.location.y,
                    "templates must sit above the single-step row"

    assert_selector "#builder-empty-state .builder__template-card", count: 5
    assert_button "Question"

    # The descriptions are visible, not hidden in a title tooltip: the first
    # choice an author makes was the one made blind.
    assert_text "Ask for information"

    click_button "Question"

    assert_no_selector "#builder-empty-state", wait: 5
    assert_selector ".builder__step", count: 1
  end

  test "type picker closes after adding a step, and does not cover the list" do
    workflow = Workflow.create!(title: "Picker test", user: @user)
    Steps::Resolve.create!(workflow: workflow, position: 1, title: "Done")

    visit workflow_path(workflow, edit: true)
    assert_selector ".builder__step", count: 1, wait: 5

    find(".builder__list-add").click
    assert_selector ".builder__type-option", visible: true, wait: 5

    find(".builder__type-option", text: "Action").click

    # The picker sits inside the add-step wrapper, so an outside-click handler
    # alone never closes it - choosing a type has to.
    assert_no_selector ".builder__type-option", visible: true, wait: 5
    assert_selector ".builder__step", count: 2, wait: 5
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
