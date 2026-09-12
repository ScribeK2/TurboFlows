require "test_helper"

# Regression: ISSUE-001 — results after a handoff showed only the last workflow
# Found by /qa on 2026-09-12
# Report: .gstack/qa-reports/qa-report-localhost-2026-09-12.md
#
# The runner thread reads a run from `run_origin`, so it showed the whole call.
# Everything reached after the run ended read one frame instead: "View results"
# linked to the frame on screen, Cancel redirected to `root_scenario` (which a
# handed-to frame is, of itself), and the results pages rendered that frame's
# path, status, duration and workflow. After Start Here -> Opening Scan -> Warm
# Transfer, the results said "Completed 5 steps in 1m 8s" and Run Again started
# Warm Transfer — a workflow the agent never opened and, for a Regular agent,
# could not.
#
# A run's results live at its origin. How it ended is read from `run_ending`.
class HandoffResultsTest < ActionDispatch::IntegrationTest
  STREAM = { "Accept" => "text/vnd.turbo-stream.html" }.freeze

  setup do
    @user = User.create!(
      email: "handoff-results-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )

    @target = Workflow.create!(title: "Warm Transfer QA", user: @user, status: "published")
    @target_q = Steps::Question.create!(workflow: @target, position: 0, title: "Did they take the call?",
                                        question: "Did they take the call?", answer_type: "yes_no",
                                        variable_name: "answered")
    @target_r = Steps::Resolve.create!(workflow: @target, position: 1, title: "Transferred to ext 256",
                                       resolution_type: "success")
    Transition.create!(step: @target_q, target_step: @target_r, position: 0)
    @target.update!(start_step: @target_q)

    @source = Workflow.create!(title: "Start Here QA", user: @user, status: "published")
    @source_q = Steps::Question.create!(workflow: @source, position: 0, title: "Is this about an account?",
                                        question: "Is this about an account?", answer_type: "yes_no",
                                        variable_name: "account_specific")
    handoff = Steps::SubFlow.create!(workflow: @source, position: 1, title: "Continue in Warm Transfer QA",
                                     sub_flow_workflow_id: @target.id, sub_flow_returns: false)
    Transition.create!(step: @source_q, target_step: handoff, position: 0)
    @source.update!(start_step: @source_q)

    # Recent, and only ever moved forward: the assertions request after the run at
    # real time, and a clock that jumped back past Devise's 30-minute timeout
    # signed the session out, which answers a GET by redirecting to itself.
    @t0 = 10.minutes.ago.change(usec: 0)
    sign_in @user
  end

  # --- driving a run ---------------------------------------------------------

  # One minute in the first workflow, four in the one it hands to. The origin
  # frame's own duration is 60s; the call is 300s.
  def run_to_the_end(next_path, start:)
    travel_to(@t0) { start.call }
    run = Scenario.order(:id).last
    travel_to(@t0 + 1.minute) { post next_path.call(run), params: { answer: "yes" }, headers: STREAM }
    head = Scenario.find_by!(handed_off_from: run)
    travel_to(@t0 + 4.minutes) { post next_path.call(head), params: { answer: "yes" }, headers: STREAM }
    travel_to(@t0 + 5.minutes) { post next_path.call(head), params: { answer: "" }, headers: STREAM }
    [run, head.reload]
  end

  def scenario_mode_run
    start = lambda do
      Scenario.create!(workflow: @source, user: @user, purpose: "simulation", status: "active",
                       started_at: Time.current, current_node_uuid: @source_q.uuid,
                       execution_path: [], results: {}, inputs: {})
    end
    run_to_the_end(->(s) { next_step_scenario_path(s) }, start: start)
  end

  def player_run
    run_to_the_end(->(s) { player_scenario_next_path(s) }, start: -> { post play_workflow_path(@source) })
  end

  def hand_off(next_path, run)
    post next_path.call(run), params: { answer: "yes" }, headers: STREAM
    Scenario.find_by!(handed_off_from: run)
  end

  # --- Scenario mode ---------------------------------------------------------

  test "precondition: the run really was handed off and finished" do
    run, head = scenario_mode_run

    assert_equal "transferred", run.reload.outcome
    assert_predicate head, :completed?
    assert_equal 60, run.duration_seconds, "the origin frame's own clock stops at the handoff"
  end

  test "the end of a handed-off run links to the whole run's results" do
    run, head = scenario_mode_run

    assert_match(/href="#{scenario_path(run)}"/, response.body)
    assert_no_match(/href="#{scenario_path(head)}"/, response.body,
                    "the frame on screen is only the last workflow the call passed through")
  end

  test "the results page shows every workflow the run went through and how it ended" do
    run, = scenario_mode_run

    get scenario_path(run)

    assert_response :success
    assert_match "Is this about an account?", response.body
    assert_match "Did they take the call?", response.body
    assert_match "Transferred to ext 256", response.body
    assert_match "Completed 3 steps in 5m 0s", response.body, "the whole call, not the minute before the handoff"
    assert_match "resolved as Success", response.body, "the ending lives in the last frame's results"
    assert_select ".scenario-status-badge", text: /Completed/
    assert_select "p.page-header-section__ident", text: @source.title
    assert_select "form[action=?]", workflow_execution_path(@source), minimum: 1
    assert_select "form[action=?]", workflow_execution_path(@target), count: 0
  end

  test "a frame after the handoff sends its results to the run's" do
    run, head = scenario_mode_run

    get scenario_path(head)

    assert_redirected_to scenario_path(run)
  end

  test "cancelling after a handoff reports the whole run as stopped" do
    travel_to(@t0) do
      run = Scenario.create!(workflow: @source, user: @user, purpose: "simulation", status: "active",
                             started_at: Time.current, current_node_uuid: @source_q.uuid,
                             execution_path: [], results: {}, inputs: {})
      head = hand_off(->(s) { next_step_scenario_path(s) }, run)

      post stop_scenario_path(head)

      assert_redirected_to scenario_path(run)
      follow_redirect!
      assert_select ".scenario-status-badge", text: /Workflow Stopped/
      assert_select ".scenario-status-badge", text: /Completed/, count: 0
    end
  end

  # --- Player ----------------------------------------------------------------

  test "the Player's end of a handed-off run links to the whole run's results" do
    run, head = player_run

    assert_match(/href="#{player_scenario_show_path(run)}"/, response.body)
    assert_no_match(/href="#{player_scenario_show_path(head)}"/, response.body)
  end

  test "the Player's completion screen counts the whole run and restarts where it began" do
    run, = player_run

    get player_scenario_show_path(run)

    assert_response :success
    assert_select "h1", text: /Workflow Complete/
    assert_select ".player-completion__stat", text: /3\s+Steps completed/
    assert_select ".player-completion__stat", text: /5 minutes\s+Duration/
    assert_select "form[action=?]", play_workflow_path(@source)
    assert_select "form[action=?]", play_workflow_path(@target), count: 0
  end

  test "the Player sends a frame after the handoff to the run's completion screen" do
    run, head = player_run

    get player_scenario_show_path(head)

    assert_redirected_to player_scenario_show_path(run)
  end

  test "the Player's Cancel after a handoff reports the whole run as stopped" do
    post play_workflow_path(@source)
    run = Scenario.order(:id).last
    head = hand_off(->(s) { player_scenario_next_path(s) }, run)

    post player_scenario_stop_path(head)

    assert_redirected_to player_scenario_show_path(run)
    follow_redirect!
    assert_select "h1", text: /Workflow Stopped/
  end

  test "an anonymous visitor's handed-off run keeps its results at the share link's run" do
    @source.update!(share_token: SecureRandom.hex(8))
    sign_out @user

    get shared_player_path(@source.share_token)
    run = Scenario.order(:id).last
    head = hand_off(->(s) { player_scenario_next_path(s) }, run)

    get player_scenario_show_path(head)

    assert_redirected_to player_scenario_show_path(run)
    follow_redirect!
    assert_response :success
  end
end
