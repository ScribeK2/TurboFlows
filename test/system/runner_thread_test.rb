require "application_system_test_case"

# The runner thread in a real browser.
#
# The point of streaming is that answering a step does not reload the page, and
# that is exactly what a request test cannot see — it can confirm the response
# is a turbo-stream, but not that the browser applied it in place. These tests
# stamp a value on `window` and assert it survives the answer: a full navigation
# would wipe it.
class RunnerThreadSystemTest < ApplicationSystemTestCase
  setup do
    @user = User.create!(
      email: "wf-system-test-stacked-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    @workflow = Workflow.create!(title: "Stacked System WF", user: @user, status: "published")
    @q1 = Steps::Question.create!(
      workflow: @workflow, title: "Is the account verified", position: 0,
      variable_name: "verified", question: "Is the account verified?", answer_type: "yes_no"
    )
    @q2 = Steps::Question.create!(
      workflow: @workflow, title: "Did the email arrive", position: 1,
      variable_name: "emailed", question: "Did the email arrive?", answer_type: "yes_no"
    )
    Steps::Resolve.create!(workflow: @workflow, title: "Close the call", position: 2, resolution_type: "success")
    Transition.create!(step: @q1, target_step: @q2, position: 0)
    Transition.create!(step: @q2, target_step: @workflow.steps.find_by(title: "Close the call"), position: 0)
    @workflow.update!(start_step: @q1)
  end

  def start_scenario(purpose: "simulation")
    Scenario.create!(
      workflow: @workflow, user: @user, purpose: purpose, started_at: Time.current,
      current_node_uuid: @q1.uuid, execution_path: [], results: {}, inputs: {}
    )
  end

  # Stamps an expando property on the first answered row's DOM node.
  #
  # Not a `window` flag: classic answers with a redirect, and Turbo Drive
  # handles a redirect as a visit that swaps the body while keeping the same JS
  # context — so `window` survives both paths and proves nothing. A node does
  # not: streaming leaves the rows above the tail untouched, while a Drive visit
  # rebuilds them, so identity of the node is the honest discriminator.
  def mark_first_row
    page.execute_script("document.querySelector('.runner-thread__card').dataset.marked = 'yes'; " \
                        "document.querySelector('.runner-thread__card').__survived = true")
  end

  def first_row_survived?
    page.evaluate_script("!!(document.querySelector('.runner-thread__card') || {}).__survived")
  end

  test "answering leaves the transcript above it untouched" do
    scenario = start_scenario
    sign_in_as(@user)
    visit step_scenario_path(scenario)

    choose_answer "Yes"
    assert_current_step "Did the email arrive"
    mark_first_row

    choose_answer "Yes"
    assert_current_step "Close the call"

    assert_predicate self, :first_row_survived?,
                     "the rows above the answer were rebuilt — the page repainted instead of streaming"
    assert_selector ".runner-thread__card", count: 2
  end

  test "the answered step stays on screen as a row" do
    scenario = start_scenario
    sign_in_as(@user)
    visit step_scenario_path(scenario)

    choose_answer "Yes"
    assert_current_step "Did the email arrive"

    assert_selector ".runner-thread__card", text: "Is the account verified"
    assert_selector ".runner-thread__card .runner-thread__card-answer", text: "yes"
  end

  test "auto-advance submits once" do
    scenario = start_scenario
    sign_in_as(@user)
    visit step_scenario_path(scenario)

    choose_answer "Yes"
    assert_current_step "Did the email arrive"

    assert_selector ".runner-thread__card", count: 1,
                                            wait: 3
  end

  test "refreshing mid-run restores the same thread" do
    scenario = start_scenario
    sign_in_as(@user)
    visit step_scenario_path(scenario)
    choose_answer "Yes"
    assert_current_step "Did the email arrive"
    cards_before = all(".runner-thread__card").size

    visit step_scenario_path(scenario)

    assert_current_step "Did the email arrive"
    assert_equal cards_before, all(".runner-thread__card").size,
                 "a streamed thread and a reloaded one must not disagree"
  end

  # Keydown is scoped to the card rather than the document now, so focus landing
  # inside it is what makes the shortcut work at all. A free-text question,
  # because a radio auto-advances on selection and would pass this test without
  # Enter ever being involved.
  test "Enter submits the open card" do
    wf = Workflow.create!(title: "Typed WF", user: @user, status: "published")
    q = Steps::Question.create!(
      workflow: wf, title: "What is the account number", position: 0,
      variable_name: "acct", question: "What is the account number?", answer_type: "text"
    )
    nxt = Steps::Question.create!(
      workflow: wf, title: "Anything else", position: 1,
      variable_name: "more", question: "Anything else?", answer_type: "text"
    )
    done = Steps::Resolve.create!(workflow: wf, title: "Close", position: 2, resolution_type: "success")
    Transition.create!(step: q, target_step: nxt, position: 0)
    Transition.create!(step: nxt, target_step: done, position: 0)
    wf.update!(start_step: q)

    scenario = Scenario.create!(
      workflow: wf, user: @user, purpose: "simulation", started_at: Time.current,
      current_node_uuid: q.uuid, execution_path: [], results: {}, inputs: {}
    )
    sign_in_as(@user)
    visit step_scenario_path(scenario)
    assert_current_step "What is the account number"

    field = find("#{RUNNER_STEP_CARD} input[type='text']")
    field.send_keys("12345", :enter)

    assert_current_step "Anything else"
    assert_selector ".runner-thread__card .runner-thread__card-answer", text: "12345"
  end

  test "the Player streams too" do
    scenario = start_scenario(purpose: "live")
    sign_in_as(@user)
    visit player_scenario_step_path(scenario)
    assert_current_step "Is the account verified"

    choose_answer "Yes"
    assert_current_step "Did the email arrive"
    mark_first_row

    choose_answer "Yes"
    assert_current_step "Close the call"

    assert_predicate self, :first_row_survived?, "the Player repainted — both shells must stream"
    assert_selector ".runner-thread__card", text: "Is the account verified"
  end
  test "an anonymous shared run streams like any other" do
    @workflow.update!(share_token: SecureRandom.hex(8))

    visit shared_player_path(@workflow.share_token)
    assert_current_step "Is the account verified"

    choose_answer "Yes"
    assert_current_step "Did the email arrive"
    mark_first_row

    choose_answer "Yes"
    assert_current_step "Close the call"

    assert_predicate self, :first_row_survived?,
                     "share links are the surface least able to report what they saw — " \
                     "they must not silently fall back to reloading"
  end
end
