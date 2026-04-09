require "application_system_test_case"

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
      answer_type: "yes_no"
    )
    @resolve = Steps::Resolve.create!(
      workflow: @workflow, title: "All done", position: 1
    )
    Transition.create!(step: @question, target_step: @resolve, position: 0)
    @workflow.update!(start_step: @question)

    sign_in_as @user
  end

  test "user completes a workflow through Player mode" do
    visit play_path

    # Start the workflow
    find(".player-workflow-card", text: "Player E2E Workflow").click

    # Should see the question step
    assert_selector ".player-step-card__title", text: "Do you need help?", wait: 5

    # Answer Yes
    find(".radio-card", text: "Yes").click

    # Should auto-advance or show continue — wait for resolve step
    assert_selector ".player-step-card__title", text: "All done", wait: 5

    # Complete the workflow
    click_on "Complete Workflow"

    # Should see completion screen
    assert_selector ".player-completion__title", text: "Workflow Complete", wait: 5
    assert_selector ".player-completion__stat-label", text: /steps completed/i
  end

  test "shared workflow link works without authentication" do
    # Generate a share token
    @workflow.generate_share_token!

    # Sign out (visit sign_out path) by resetting session
    Capybara.reset_sessions!

    # Visit the shared link — no login needed
    visit shared_player_path(share_token: @workflow.share_token)

    # Should see the question step without being redirected to login
    assert_selector ".player-step-card__title", text: "Do you need help?", wait: 5
  end

  test "back navigation works in Player mode" do
    # Add an intermediate step so we have 3 steps
    @action = Steps::Action.create!(
      workflow: @workflow, title: "Perform action", position: 1,
      action_type: "Instruction"
    )
    # Re-wire transitions: question -> action -> resolve
    Transition.where(step: @question).destroy_all
    Transition.create!(step: @question, target_step: @action, position: 0)
    Transition.create!(step: @action, target_step: @resolve, position: 0)

    visit play_path

    # Start the workflow
    find(".player-workflow-card", text: "Player E2E Workflow").click

    # Answer the question to advance
    assert_selector ".player-step-card__title", text: "Do you need help?", wait: 5
    find(".radio-card", text: "Yes").click

    # Should be on the action step
    assert_selector ".player-step-card__title", text: "Perform action", wait: 5

    # Click back
    click_on "Back"

    # Should return to the question step
    assert_selector ".player-step-card__title", text: "Do you need help?", wait: 5
  end
end
