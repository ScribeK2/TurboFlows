require "application_system_test_case"

# Answer-type edge cases in the runner.
#
# Both cases here were caught by /review, not by the characterization suite,
# which only exercised yes_no. Auto-advance used to be computed twice — once on
# the shell for the Stimulus controller, once in the question partial for
# whether Continue renders — and the two expressions disagreed.
class RunnerAnswerTypesTest < ApplicationSystemTestCase
  test "a question with options but a non-standard answer_type can still be answered" do
    u = User.create!(email: "wf-system-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor")
    wf = Workflow.create!(title: "Deadend Probe", user: u, status: "published")
    # answer_type outside %w[yes_no multiple_choice], but options present.
    q = Steps::Question.create!(workflow: wf, title: "Pick a tier", position: 0,
                                question: "Pick a tier", answer_type: "text",
                                options: [{ "label" => "Gold", "value" => "gold" },
                                          { "label" => "Silver", "value" => "silver" }])
    r = Steps::Resolve.create!(workflow: wf, title: "Done", position: 1, resolution_type: "success")
    Transition.create!(step: q, target_step: r, position: 0)
    wf.update!(start_step: q)
    sign_in_as u
    visit new_workflow_execution_path(wf)
    click_on "Start Workflow"
    assert_current_step "Pick a tier"

    choose_answer "Gold"

    # Either auto-advance fires, or a Continue button exists to press.
    # If neither, the user is stuck on this step forever.
    if page.has_button?("Continue", wait: 2)
      click_on "Continue"
    end
    assert_current_step "Done"
  end

  test "a multiple_choice question with no options does not submit mid-typing" do
    u = User.create!(email: "wf-system-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor")
    wf = Workflow.create!(title: "Typing Probe", user: u, status: "published")
    # Authored as multiple_choice but with no options, so it falls through to a
    # free-text field. The old shell auto-advanced on answer_type alone, so the
    # field submitted 300ms after the first keystroke and captured one character.
    q = Steps::Question.create!(workflow: wf, title: "Describe the issue", position: 0,
                                question: "Describe the issue", answer_type: "multiple_choice",
                                options: [])
    r = Steps::Resolve.create!(workflow: wf, title: "Done", position: 1, resolution_type: "success")
    Transition.create!(step: q, target_step: r, position: 0)
    wf.update!(start_step: q)
    sign_in_as u
    visit new_workflow_execution_path(wf)
    click_on "Start Workflow"
    assert_current_step "Describe the issue"

    fill_in "answer", with: "disk full on the web node"

    # The auto-advance timer is 300ms; assert AFTER it would have fired, or the
    # assertion passes simply by running first and proves nothing.
    sleep 1
    assert_current_step "Describe the issue"

    click_on "Continue"
    assert_current_step "Done"
    assert_equal "disk full on the web node",
                 Scenario.where(workflow: wf).last.execution_path.first["answer"]
  end
end
