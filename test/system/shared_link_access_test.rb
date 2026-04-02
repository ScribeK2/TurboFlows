require "application_system_test_case"

class SharedLinkAccessTest < ApplicationSystemTestCase
  setup do
    @owner = User.create!(
      email: "wf-system-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )

    @workflow = Workflow.create!(
      title: "Shared Workflow", user: @owner, status: "published",
      share_token: SecureRandom.hex(16)
    )
    @question = Steps::Question.create!(
      workflow: @workflow, title: "What is your issue?", position: 0,
      answer_type: "text"
    )
    @resolve = Steps::Resolve.create!(
      workflow: @workflow, title: "Issue resolved", position: 1
    )
    Transition.create!(step: @question, target_step: @resolve, position: 0)
    @workflow.update!(start_step: @question)
  end

  test "anonymous user can execute a shared workflow" do
    # Visit the shared link — no login
    visit shared_player_path(share_token: @workflow.share_token)

    # Should land on the step page (redirected from show_shared)
    assert_selector ".player-step-card__title", text: "What is your issue?", wait: 5

    # No cancel or exit buttons for anonymous users
    assert_no_selector ".scenario-btn-cancel"

    # Answer the question
    fill_in "answer", with: "My printer is broken"
    click_on "Continue"

    # Should see resolve step
    assert_selector ".player-step-card__title", text: "Issue resolved", wait: 5

    # Complete
    click_on "Complete Workflow"

    # Completion screen
    assert_selector ".player-completion__title", text: "Workflow Complete", wait: 5
  end
end
