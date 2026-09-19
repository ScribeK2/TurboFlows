require "test_helper"

# Task B1: TransitionSync learns to tell a connection the server rendered from
# one the editor minted, so a stale second panel can no longer re-create a
# connection someone else deleted. See app/services/transition_sync.rb.
class StepsControllerStalePanelSyncTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

  setup do
    @editor = User.create!(
      email: "stale-panel-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(title: "Stale Panel WF", user: @editor, graph_mode: true)
    @step = Steps::Action.create!(workflow: @workflow, position: 0, title: "Existing Step")
    sign_in @editor
  end

  # Panel A deleted this connection behind panel B's back; panel B's payload
  # still claims to have rendered it. The save must not re-create it, and the
  # editor + a flash must tell the author so - never silent.
  test "a rendered-but-deleted row heals the panel: connections re-streamed and flash shown" do
    question = Steps::Question.create!(workflow: @workflow, position: 1, title: "Light green?",
                                       answer_type: "yes_no", variable_name: "light")
    gone_uuid = SecureRandom.uuid
    transitions_json = {
      rendered: [gone_uuid], minted: [],
      rows: [{ uuid: gone_uuid, target_uuid: @step.uuid, condition: "tier == 'gold'", label: "" }]
    }.to_json

    patch workflow_step_path(@workflow, question),
          params: { step: { title: "Renamed", transitions_json: transitions_json } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_not Transition.exists?(uuid: gone_uuid)
    assert_select "turbo-stream[action='update'][target='#{dom_id(question, :connections)}']"
    assert_includes response.body, '<turbo-stream action="update" target="flash">'
    assert_includes response.body, "A connection you had open was removed elsewhere, so it wasn&#39;t saved."
  end

  test "the same PATCH in legacy known/rows shape still creates the row (pinned legacy behaviour)" do
    question = Steps::Question.create!(workflow: @workflow, position: 1, title: "Light green?",
                                       answer_type: "yes_no", variable_name: "light")
    new_uuid = SecureRandom.uuid
    transitions_json = {
      known: [new_uuid],
      rows: [{ uuid: new_uuid, target_uuid: @step.uuid, condition: "tier == 'gold'", label: "" }]
    }.to_json

    patch workflow_step_path(@workflow, question),
          params: { step: { title: "Renamed", transitions_json: transitions_json } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert Transition.exists?(uuid: new_uuid)
    assert_not_includes response.body, "A connection you had open was removed elsewhere"
  end

  test "a healed save via JSON reports the notice, without creating the gone row" do
    question = Steps::Question.create!(workflow: @workflow, position: 1, title: "Light green?",
                                       answer_type: "yes_no", variable_name: "light")
    gone_uuid = SecureRandom.uuid
    transitions_json = {
      rendered: [gone_uuid], minted: [],
      rows: [{ uuid: gone_uuid, target_uuid: @step.uuid, condition: "tier == 'gold'", label: "" }]
    }.to_json

    patch workflow_step_path(@workflow, question),
          params: { step: { transitions_json: transitions_json } },
          as: :json

    assert_response :ok
    assert_not Transition.exists?(uuid: gone_uuid)
    json = response.parsed_body
    assert_equal "A connection you had open was removed elsewhere, so it wasn't saved.", json["notice"]
  end

  test "a healed save via HTML redirects with the stale-panel notice" do
    question = Steps::Question.create!(workflow: @workflow, position: 1, title: "Light green?",
                                       answer_type: "yes_no", variable_name: "light")
    gone_uuid = SecureRandom.uuid
    transitions_json = {
      rendered: [gone_uuid], minted: [],
      rows: [{ uuid: gone_uuid, target_uuid: @step.uuid, condition: "tier == 'gold'", label: "" }]
    }.to_json

    patch workflow_step_path(@workflow, question),
          params: { step: { transitions_json: transitions_json } }

    assert_redirected_to workflow_path(@workflow, edit: true)
    assert_equal "A connection you had open was removed elsewhere, so it wasn't saved.", flash[:notice]
  end

  # #door_shape_changed? reads "shown" through #shown_and_sent_row_uuids,
  # which - independent of TransitionSync - has to read the new shape too: an
  # extra named only in `rendered` (never `known`) still counts as shown, or
  # the backward check would see it as newly-invisible-to-the-editor and force
  # the whole fragment on every save, not just the doors list. Mirrors "an
  # extra the editor already knew about streams only the doors list" below,
  # under the new shape instead of the legacy one.
  test "an extra named only in rendered still counts as shown - only the doors list streams" do
    question = Steps::Question.create!(workflow: @workflow, position: 1, title: "Light green?",
                                       answer_type: "yes_no", variable_name: "light")
    extra = Transition.create!(step: question, target_step: @step, condition: "tier == 'gold'")
    transitions_json = {
      rendered: [extra.uuid], minted: [],
      rows: [{ uuid: extra.uuid, target_uuid: @step.uuid, condition: "tier == 'gold'", label: nil }]
    }.to_json

    patch workflow_step_path(@workflow, question),
          params: { step: { answer_type: "text", transitions_json: transitions_json } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_select "turbo-stream[action='replace'][target='#{dom_id(question, :doors)}']"
    assert_select "turbo-stream[action='update'][target='#{dom_id(question, :connections)}']", false
  end
end
