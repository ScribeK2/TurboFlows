require "test_helper"
require "turbo/broadcastable/test_helper"

# Which panel saves re-render the whole outline for every tab, and which send
# only their own row (StepsController::OUTLINE_FIELDS and
# TransitionSync::Result#changed; docs/agents/builder.md § The list is an
# outline, "Which saves re-render the whole list").
class StepsControllerOutlineBroadcastsTest < ActionDispatch::IntegrationTest
  include Turbo::Broadcastable::TestHelper

  setup do
    @editor = User.create!(email: "editor-outline-bc-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                           password_confirmation: "password123!", role: "editor")
    @workflow = Workflow.create!(title: "Outline broadcasts WF", user: @editor, graph_mode: true)
    sign_in @editor
  end

  # In the outline a step's title is on every jump chip, fold summary and
  # ways-in tooltip naming it; its doors are its answer type, options and
  # connections. A lone row replace leaves all of those stale.
  #
  # But the panel's hidden step[transitions_json] field rides along on EVERY
  # autosave, unchanged, whether or not the author touched a connection (see
  # docs/agents/builder.md: "the panel submits the whole step on every
  # change"). So these three tests use the field's REAL rendered value, from
  # a live panel_edit render, rather than a hand-built payload that could
  # happen to omit transitions_json (proving nothing about the request the
  # browser actually sends) or invent a shape that looks "changed" when the
  # real field never would be.
  test "an autosave whose transitions payload is unchanged broadcasts only its row" do
    question, transitions_json = wired_question_with_rendered_transitions_json

    assert_turbo_stream_broadcasts("workflow_#{@workflow.id}", count: 1) do
      patch workflow_step_path(@workflow, question),
            params: { step: { help_text: "note", dirty_fields: ["help_text"], rendered: { help_text: "" },
                              transitions_json: transitions_json } },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end
  end

  test "a title save broadcasts the whole list, with the real unchanged connections payload riding along" do
    question, transitions_json = wired_question_with_rendered_transitions_json

    # Row + list + the list dialog's candidates: the list broadcast replaces
    # only #steps-list's children, so broadcast_step_list carries
    # #list-target-picker-options beside it.
    assert_turbo_stream_broadcasts("workflow_#{@workflow.id}", count: 3) do
      patch workflow_step_path(@workflow, question),
            params: { step: { title: "Renamed", dirty_fields: ["title"], rendered: { title: question.title },
                              transitions_json: transitions_json } },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end
  end

  test "a connections-only save that retargets a row broadcasts the whole list" do
    question, transitions_json = wired_question_with_rendered_transitions_json
    other_target = Steps::Resolve.create!(workflow: @workflow, position: 9, title: "Elsewhere",
                                          resolution_type: "success")
    payload = JSON.parse(transitions_json)
    payload["rows"].first["target_uuid"] = other_target.uuid

    # Row + list + the list dialog's candidates (broadcast_step_list carries
    # #list-target-picker-options with the list).
    assert_turbo_stream_broadcasts("workflow_#{@workflow.id}", count: 3) do
      patch workflow_step_path(@workflow, question),
            params: { step: { dirty_fields: [""], transitions_json: payload.to_json } },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end
  end

  # A rename rewrites the step's own conditions inside @step.update, before
  # TransitionSync takes its before-signature, so the sync sees no change; the
  # extras' chips and ways-in tooltips quote those conditions, so the list
  # must go out anyway (OUTLINE_FIELDS includes variable_name).
  test "a variable rename broadcasts the whole list, with the extras reading the new name" do
    question, = wired_question_with_rendered_transitions_json
    Transition.find_by!(step: question, condition: "count > 5").update!(condition: "q == 'maybe'")
    get panel_edit_workflow_step_path(@workflow, question)
    transitions_json = css_select("input[name='step[transitions_json]']").first["value"]

    broadcasts = capture_turbo_stream_broadcasts("workflow_#{@workflow.id}") do
      patch workflow_step_path(@workflow, question),
            params: { step: { variable_name: "light", dirty_fields: ["variable_name"], rendered: { variable_name: "q" },
                              transitions_json: transitions_json } },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :ok
    list = broadcasts.find { |stream| stream["target"] == "steps-list" }
    assert list, "a rename must broadcast the list"
    assert_includes list.to_html, "light is"
    assert_not_includes list.to_html, "q is"
  end

  private

  # A Question with a wired Yes door PLUS one extra connection ("Other
  # connections" - a numeric range no door describes), and the exact
  # step[transitions_json] the panel's own hidden field renders for it - not a
  # hand-built payload, since what that field actually contains
  # (rendered/minted/known, all naming this one row) is exactly what the guard
  # under test must be right about. The editor's `rows` hold only #extras
  # (Step::Doors), never a door's own transition, so the retarget test below
  # needs the extra row, not the Yes door, to have anything to change.
  def wired_question_with_rendered_transitions_json
    target = Steps::Resolve.create!(workflow: @workflow, position: 1, title: "Done", resolution_type: "success")
    extra_target = Steps::Resolve.create!(workflow: @workflow, position: 2, title: "Extra target",
                                          resolution_type: "success")
    question = Steps::Question.create!(workflow: @workflow, position: 3, title: "Q", question: "Q?",
                                       answer_type: "yes_no", variable_name: "q")
    Transition.create!(step: question, target_step: target, condition: "q == 'yes'", label: "Yes", position: 0)
    Transition.create!(step: question, target_step: extra_target, condition: "count > 5", position: 1)

    get panel_edit_workflow_step_path(@workflow, question)
    [question, css_select("input[name='step[transitions_json]']").first["value"]]
  end
end
