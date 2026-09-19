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

  # steps_controller_test.rb's "a save that turns an editor row into a door
  # streams the whole connections fragment" and its contrast ("...streams
  # only the doors list") both predate the rendered/minted split and send a
  # brand-new row's uuid as `known`. In real traffic a brand-new row is always
  # `minted`, never `rendered` - TransitionSync#sync_row's creation gate treats
  # the two differently (minted/legacy -> create; rendered-only -> skip and
  # heal) - so this is the shape those two tests would send today, and the
  # first proof that #door_shape_changed? reads a MINTED new row as "shown" at
  # all, not just a rendered one.
  test "a minted row that becomes a door streams the whole connections fragment, with no stale-panel notice" do
    question = Steps::Question.create!(workflow: @workflow, position: 1, title: "Light green?",
                                       answer_type: "yes_no", variable_name: "light")
    new_uuid = SecureRandom.uuid
    transitions_json = {
      rendered: [], minted: [new_uuid],
      rows: [{ uuid: new_uuid, target_uuid: @step.uuid, condition: "light == 'no'", label: "No" }]
    }.to_json

    patch workflow_step_path(@workflow, question),
          params: { step: { transitions_json: transitions_json } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    transition = question.transitions.reload.sole
    assert_equal transition, Step::Doors.for(question.reload).door_for("light == 'no'").transition

    assert_select "turbo-stream[action='update'][target='#{dom_id(question, :connections)}']"
    assert_select "turbo-stream[action='replace'][target='#{dom_id(question, :doors)}']", false
    assert_not_includes response.body, "A connection you had open was removed elsewhere"
  end

  # The contrast case: the same minted-new-row shape, but the sent row's
  # condition names a variable no door of this step reads at all, so it stays
  # an extra and only the doors list needs replacing - not the notice, which
  # never fires for a row this editor minted and TransitionSync went on to
  # create.
  test "a minted row that stays an extra streams only the doors list, with no stale-panel notice" do
    question = Steps::Question.create!(workflow: @workflow, position: 1, title: "Light green?",
                                       answer_type: "yes_no", variable_name: "light")
    new_uuid = SecureRandom.uuid
    transitions_json = {
      rendered: [], minted: [new_uuid],
      rows: [{ uuid: new_uuid, target_uuid: @step.uuid, condition: "tier == 'gold'", label: nil }]
    }.to_json

    patch workflow_step_path(@workflow, question),
          params: { step: { transitions_json: transitions_json } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    transition = question.transitions.reload.sole
    assert_includes Step::Doors.for(question.reload).extras, transition

    assert_select "turbo-stream[action='replace'][target='#{dom_id(question, :doors)}']"
    assert_select "turbo-stream[action='update'][target='#{dom_id(question, :connections)}']", false
    assert_not_includes response.body, "A connection you had open was removed elsewhere"
  end

  # A tab open ACROSS A DEPLOY keeps running the pre-2026-09-19
  # step_transitions_controller.js (javascript_importmap_tags carries no
  # data-turbo-track, and nothing about opening or saving the panel is a
  # Turbo visit, so the module is never refetched). That old JS's loadState
  # reads only `known`, never `rendered`/`minted`, and never mutates it on
  # removal - so it needs the field to carry a real, usable `known` list, not
  # merely be present-but-empty, or a removal sends an empty delete set and
  # the "removed" row snaps right back (#door_shape_changed?'s backward
  # check re-streams the whole fragment on the very same save). This
  # reproduces exactly what that old JS would send: read the field the
  # server rendered, take its `known` (the TRANSITIONAL duplicate of
  # `rendered` in _transitions_editor.html.erb), and PATCH the shape the old
  # removeTransition/saveTransitions pair would produce - `rows` with the
  # extra spliced out, `known` untouched.
  test "a tab still running the pre-deploy controller can still remove a connection" do
    question = Steps::Question.create!(workflow: @workflow, position: 1, title: "Light green?",
                                       answer_type: "yes_no", variable_name: "light")
    extra = Transition.create!(step: question, target_step: @step, condition: "tier == 'gold'")

    get panel_edit_workflow_step_path(@workflow, question)
    rendered_payload = JSON.parse(css_select("input[name='step[transitions_json]']").first["value"])
    old_js_payload = { known: rendered_payload["known"], rows: [] }.to_json

    patch workflow_step_path(@workflow, question),
          params: { step: { transitions_json: old_js_payload } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_not Transition.exists?(uuid: extra.uuid)
  end
end
