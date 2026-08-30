require "test_helper"

# A sub-flow whose first step is a notes-required Resolve.
#
# The settler walks past a child's Resolve on purpose: a resolve inside a child
# is the sub-flow finishing, not the run finishing, and the agent should not be
# asked to acknowledge it. But a Resolve with `notes_required` will refuse — and
# refusing a step nobody was shown left the run in a state with no way out.
#
# What it used to do: the run parked with "This run is paused… Resume", and
# Resume answered "This run has already finished." while the scenario stayed
# awaiting_subflow. Both messages were wrong and it repeated forever. Before
# that, when the shells still redirected, it was a browser redirect loop.
class SubflowNotesRequiredTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(
      email: "subflow-notes-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    sign_in @user

    @child = Workflow.create!(title: "Child", user: @user)
    @child_resolve = Steps::Resolve.create!(
      workflow: @child, position: 0, title: "Child Done",
      resolution_type: "success", notes_required: true
    )
    @child.update!(start_step: @child_resolve)

    @parent = Workflow.create!(title: "Parent", user: @user)
    @q = Steps::Question.create!(workflow: @parent, position: 0, title: "Q",
                                 question: "Q?", variable_name: "qv")
    sf = Steps::SubFlow.create!(workflow: @parent, position: 1, title: "SF",
                                sub_flow_workflow_id: @child.id)
    pr = Steps::Resolve.create!(workflow: @parent, position: 2, title: "Parent Done",
                                resolution_type: "success")
    Transition.create!(step: @q, target_step: sf, position: 0)
    Transition.create!(step: sf, target_step: pr, position: 0)
    @parent.update!(start_step: @q)

    @scenario = Scenario.create!(
      workflow: @parent, user: @user, purpose: "simulation", status: "active",
      started_at: Time.current, current_node_uuid: @q.uuid,
      execution_path: [], results: {}, inputs: {}
    )
  end

  def answer_into_the_subflow
    post next_step_scenario_path(@scenario), params: { answer: "yes" },
                                             headers: { "Accept" => "text/vnd.turbo-stream.html" }
  end

  test "the child's notes-required Resolve is shown instead of being walked past" do
    answer_into_the_subflow

    assert_response :success, "opening the sub-flow is not a refusal"
    assert_match(/Child Done/, response.body,
                 "the step asking for notes has to be on screen for anyone to answer it")
    assert_no_match(/This run is paused/, response.body,
                    "a step waiting for input is not a parked run")
  end

  test "the run is not parked, because it is waiting on a person" do
    answer_into_the_subflow
    child = @scenario.reload.active_child_scenario

    assert_not_predicate child, :parked?,
                         "parked means nobody can act; here the agent can type notes"
    assert_not ScenarioSettler.auto_processable?(child, @child_resolve),
               "a resolve that will refuse is not one the settler can walk past"
  end

  test "supplying the notes completes the sub-flow and returns to the parent" do
    answer_into_the_subflow
    child = @scenario.reload.active_child_scenario

    post next_step_scenario_path(child), params: { resolution_notes: "Verified by phone" },
                                         headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_predicate child.reload, :completed?, "the notes were accepted"
    assert_not_predicate @scenario.reload, :awaiting_subflow?,
                         "the parent resumes once the child is done"
  end

  # The regression this whole entry was about: the run must never reach a state
  # where the only control on screen does nothing.
  test "the run never reaches a dead end that Resume cannot leave" do
    answer_into_the_subflow

    3.times do
      body = response.body
      assert_no_match(/already finished/i, body,
                      "a run waiting on a sub-flow has not finished")
      break unless body.include?("This run is paused")

      post next_step_scenario_path(@scenario.reload),
           headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_no_match(/This run is paused/, response.body,
                    "the run must end up on a step someone can act on")
  end
end
