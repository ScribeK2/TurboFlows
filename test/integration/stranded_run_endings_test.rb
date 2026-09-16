require "test_helper"

# What the two endings say when a run falls through a hole in the graph.
#
# Reclassifying the outcome is not enough on its own. Both places a person looks
# after a run stops read the run's STATUS, and a stranded frame's status is
# "completed" — it genuinely is finished. So the results page put a green check
# and "Completed 1 step" on a call the agent could not finish, and the runner
# said "This run is complete." The outcome existed and nothing rendered it.
class StrandedRunEndingsTest < ActionDispatch::IntegrationTest
  STREAM = { "Accept" => "text/vnd.turbo-stream.html" }.freeze

  setup do
    @user = User.create!(
      email: "stranded-endings-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )

    # The shape a rename leaves behind: the question now writes `reason`, both
    # branches still ask about `call_reason`, and nothing refuses either.
    @workflow = Workflow.create!(title: "Renamed Variable QA", user: @user, status: "published")
    @question = Steps::Question.create!(workflow: @workflow, position: 0, title: "Why are they calling?",
                                        question: "Why are they calling?", answer_type: "choice",
                                        variable_name: "reason",
                                        options: [{ "label" => "Billing", "value" => "billing" },
                                                  { "label" => "Tech", "value" => "tech" }])
    billing = Steps::Resolve.create!(workflow: @workflow, position: 1, title: "Billing handled",
                                     resolution_type: "success")
    tech = Steps::Resolve.create!(workflow: @workflow, position: 2, title: "Tech handled",
                                  resolution_type: "success")
    Transition.create!(step: @question, target_step: billing, condition: "call_reason == 'billing'", position: 0)
    Transition.create!(step: @question, target_step: tech, condition: "call_reason == 'tech'", position: 1)
    @workflow.update!(start_step: @question)

    sign_in @user
  end

  def stranded_run
    post play_workflow_path(@workflow)
    run = Scenario.order(:id).last
    post player_scenario_next_path(run), params: { answer: "billing" }, headers: STREAM
    run.reload
  end

  test "precondition: a real run through this workflow strands" do
    run = stranded_run

    assert_predicate run, :stranded?
    assert_predicate run, :complete?, "the frame is finished — that is why the status alone misled"
    assert_equal "completed", run.status
  end

  test "the runner says the workflow has no step for that answer" do
    run = stranded_run

    get player_scenario_step_path(run)
    assert_response :success
    assert_match(/doesn&rsquo;t have a step for that answer|doesn’t have a step for that answer/, response.body)
    assert_no_match(/This run is complete/, response.body)
  end

  # The Player's completion screen: the one a CSR actually sees.
  test "the player completion screen does not say Workflow Complete" do
    run = stranded_run

    get player_scenario_show_path(run)
    assert_response :success
    assert_select ".player-completion__title", text: /No matching answer/
    assert_no_match(/Workflow Complete/, response.body)
    # A green check on a call that fell through a hole is the whole bug.
    assert_select ".player-completion__icon-wrap--success", count: 0
    assert_select ".player-completion__note", text: /doesn.t have a step for the answer you gave/
  end

  # A run that ends early is usually one step long, so the completion screen's
  # static "Steps completed" label was on screen as "1 Steps completed" more
  # often than it was ever correct.
  test "the completion screen counts one step in the singular" do
    run = stranded_run

    get player_scenario_show_path(run)
    assert_match(%r{1</span>\s*<[^>]*>Step completed}, response.body)
    assert_no_match(/1 Steps completed|>Steps completed</, response.body)
  end

  # Scenario mode's results page, which an editor sees after simulating.
  test "the scenario results page does not put a green check on it" do
    run = stranded_simulation

    get scenario_path(run)
    assert_response :success
    assert_select ".scenario-status-badge", text: /No matching answer/
    assert_select ".badge--published.scenario-status-badge", count: 0
  end

  test "the scenario results page does not claim it completed any steps" do
    run = stranded_simulation

    get scenario_path(run)
    assert_match(/Stopped after 1 step/, response.body)
    assert_no_match(/Completed 1 step/, response.body)
  end

  # The control: the same screens, for a run that really did reach a Resolve.
  test "a run that reaches a resolve still reads as completed" do
    @question.transitions.first.update!(condition: "reason == 'billing'")

    post play_workflow_path(@workflow)
    run = Scenario.order(:id).last
    post player_scenario_next_path(run), params: { answer: "billing" }, headers: STREAM
    post player_scenario_next_path(run), params: { answer: "" }, headers: STREAM
    run.reload

    assert_equal "resolved", run.outcome
    get player_scenario_show_path(run)
    assert_select ".player-completion__title", text: /Workflow Complete/
    assert_select ".player-completion__note", count: 0
    assert_select ".player-completion__stat-label", text: /^Steps completed$/,
                                                    count: 1
  end

  private

  def stranded_simulation
    run = Scenario.create!(workflow: @workflow, user: @user, purpose: "simulation", status: "active",
                           started_at: Time.current, current_node_uuid: @question.uuid,
                           execution_path: [], results: {}, inputs: {})
    post next_step_scenario_path(run), params: { answer: "billing" }, headers: STREAM
    run.reload
  end
end
