require "application_system_test_case"

# Characterization test for Player mode.
#
# Written against semantics — visible text, radio labels, button text and the
# scenario-step behaviour hook — not CSS classes. The previous version targeted
# `.player-workflow-card`, `.player-step-card__title` and `.player-completion__*`;
# the first of those had already been deleted when the player index moved onto
# `.list-row`, and the rest are due to change in the runner redesign.
class PlayerExecutionTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "wf-system-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )

    @workflow = Workflow.create!(title: "Player E2E Workflow", user: @user, status: "published")
    @question = Steps::Question.create!(
      workflow: @workflow, title: "Do you need help?", position: 0,
      question: "Do you need help?", answer_type: "yes_no"
    )
    @resolve = Steps::Resolve.create!(
      workflow: @workflow, title: "All done", position: 1,
      resolution_type: "success"
    )
    Transition.create!(step: @question, target_step: @resolve, position: 0)
    @workflow.update!(start_step: @question)

    sign_in_as @user
  end

  test "user completes a workflow through Player mode" do
    start_workflow

    assert_current_step "Do you need help?"
    choose_answer "Yes"

    assert_current_step "All done"
    click_on "Complete Workflow"

    assert_selector "h1", text: "Workflow Complete", wait: 5
    # Rendered uppercase by CSS, so match case-insensitively.
    assert_text(/steps completed/i)
  end

  test "shared workflow link works without authentication" do
    @workflow.generate_share_token!
    Capybara.reset_sessions!

    visit shared_player_path(share_token: @workflow.share_token)

    assert_current_step "Do you need help?"
  end

  test "back navigation works in Player mode" do
    action = Steps::Action.create!(
      workflow: @workflow, title: "Perform action", position: 1,
      action_type: "Instruction"
    )
    Transition.where(step: @question).destroy_all
    Transition.create!(step: @question, target_step: action, position: 0)
    Transition.create!(step: action, target_step: @resolve, position: 0)

    start_workflow

    assert_current_step "Do you need help?"
    choose_answer "Yes"
    assert_current_step "Perform action"

    click_on "Back"

    assert_current_step "Do you need help?"
  end

  test "cancel is hidden for an anonymous shared run" do
    @workflow.generate_share_token!
    Capybara.reset_sessions!

    visit shared_player_path(share_token: @workflow.share_token)

    # Anonymous runs have no Player index to return to, so the exit is withheld
    # rather than pointing at a page the visitor cannot reach.
    assert_current_step "Do you need help?"
    assert_no_link "Cancel"
  end

  private

  def start_workflow
    visit play_path
    click_on @workflow.title
  end
end
