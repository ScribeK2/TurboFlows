require "test_helper"
require "turbo/broadcastable/test_helper"

# What StepsController answers with when it refuses something that has a saved
# change behind it, or a stale control in front of it. A refusal that only
# flashed left the page as wrong as it was before the author pressed anything.
class StepsControllerRefusalsTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier
  include Turbo::Broadcastable::TestHelper

  setup do
    @editor = User.create!(
      email: "editor-refusals-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(title: "Refusals Test WF", user: @editor, graph_mode: true)
    @step = Steps::Action.create!(workflow: @workflow, position: 0, title: "Existing Step")
    sign_in @editor
  end

  # The rename is committed by the time the connections are refused, and the
  # callback has already rewritten the step's own conditions to the new name.
  # The editor's snapshot still names the OLD one, and the panel sends the
  # whole step on every change - so unless the refusal re-renders the editor,
  # its next autosave, of any field, writes the stale condition straight back.
  test "a rename whose connections are refused still rebuilds the editor, so the next autosave keeps the rename" do
    question = Steps::Question.create!(workflow: @workflow, position: 1, title: "Light?", question: "Light?",
                                       answer_type: "yes_no", variable_name: "light")
    extra = Transition.create!(step: question, target_step: @step, condition: "light == 'blinking'")
    foreign = Transition.create!(step: @step, target_step: question)
    stale_rows = [{ uuid: extra.uuid, target_uuid: @step.uuid, condition: "light == 'blinking'", label: "" }]

    # A uuid that belongs to another step's connection, claimed as minted here:
    # Transition's own uniqueness validation refuses it, rolling back the sync.
    patch workflow_step_path(@workflow, question),
          params: { step: { variable_name: "lamp", transitions_json: {
            rendered: [extra.uuid], minted: [foreign.uuid],
            rows: stale_rows + [{ uuid: foreign.uuid, target_uuid: @step.uuid, condition: "", label: "" }]
          }.to_json } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :unprocessable_content
    assert_includes response.body, "its connections were not"
    assert_equal "lamp == 'blinking'", extra.reload.condition
    assert_select "turbo-stream[action='update'][target='#{dom_id(question, :connections)}']"

    rebuilt = css_select("input[name='step[transitions_json]']").first
    assert_not_nil rebuilt, "the refusal did not re-render the connections editor"

    patch workflow_step_path(@workflow, question),
          params: { step: { title: "Any later autosave", transitions_json: rebuilt["value"] } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "lamp == 'blinking'", extra.reload.condition
  end

  # A save refused by a model validation used to answer with
  # turbo_stream.replace(dom_id(step, :form)) - a target the builder does not
  # render, so the stream replaced nothing and the author saw no error at all.
  # Whatever this branch answers with has to name an element that is on the
  # page while the panel is open.
  test "a save refused by a validation answers into an element the builder renders" do
    patch workflow_step_path(@workflow, @step),
          params: { step: { reference_url: "javascript:alert(1)" } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :unprocessable_content
    assert_select "turbo-stream[target='#{dom_id(@step, :form)}']", false,
                  "answered into a target the builder does not render"
    assert_includes response.body, "must use http, https, tel, or mailto protocol"
    assert_nil @step.reload.reference_url
  end

  # The step's own fields DID save, so the row that shows them - here and in
  # every other editor's list - has to follow, whatever happened to the
  # connections.
  # Deleting a step leaves every parent that pointed at it with a stale
  # Connections section. destroy_streams answers the editor who deleted; without
  # a broadcast, another editor's open panel went on naming a step that no
  # longer exists.
  #
  # Asserted here rather than in a browser: the unique fact is what the SERVER
  # sends. Whether a panel applies or declines it is shared with the
  # Steps::TransitionsController path and covered by builder_collaboration_test.
  test "destroying a step broadcasts each parent's connections" do
    parent = Steps::Question.create!(workflow: @workflow, position: 1, title: "Which?",
                                     question: "Which?", variable_name: "which", answer_type: "text")
    doomed = Steps::Resolve.create!(workflow: @workflow, position: 2, title: "Gone soon",
                                    resolution_type: "success")
    Transition.create!(step: parent, target_step: doomed, position: 0)

    broadcasts = capture_turbo_stream_broadcasts("workflow_#{@workflow.id}") do
      delete workflow_step_path(@workflow, doomed), headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_includes broadcasts.pluck("target"), dom_id(parent, :connections),
                    "a parent of the deleted step must have its Connections section broadcast"
  end

  test "a refused connections save still re-renders and broadcasts the step's row" do
    broadcasts = capture_turbo_stream_broadcasts("workflow_#{@workflow.id}") do
      patch workflow_step_path(@workflow, @step),
            params: { step: { title: "Saved beside bad json", transitions_json: "[]" } },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_equal [dom_id(@step)], broadcasts.pluck("target")

    assert_response :unprocessable_content
    assert_select "turbo-stream[action='replace'][target='#{dom_id(@step)}']"
    assert_includes response.body, "Saved beside bad json"
    assert_select "turbo-stream[action='update'][target='flash']"
  end

  # The stub the author pressed is the stale thing, so a refusal that only
  # flashed would leave it there to be pressed again.
  test "a grow refused because the door is already wired re-renders the list and that step's doors" do
    child = Steps::Action.create!(workflow: @workflow, position: 1, title: "Already there")
    Transition.create!(step: @step, target_step: child)

    assert_no_difference -> { @workflow.steps.count } do
      post workflow_steps_path(@workflow),
           params: { step: { type: "action" }, from_step_id: @step.id },
           headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :unprocessable_content
    assert_includes response.body, "already leads to"
    assert_select "turbo-stream[action='replace'][target='step-list']"
    assert_select "turbo-stream[action='update'][target='#{dom_id(@step, :connections)}']"
    assert_select "turbo-stream[action='update'][target='flash']"
  end
end
