require "test_helper"

# Finding 2c: workflows/_step_row's door-stub button repeats "→ add step" (or
# "No → add step") on every row with a door of its own kind unwired, with only
# a sibling span for context - not enough to tell a screen-reader user which
# Question a stub belongs to. Split out from WorkflowsControllerTest, which
# was already at Metrics/ClassLength's limit.
class StepRowAccessibleNamesTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

  setup do
    @editor = User.create!(email: "editor-rowaria-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                           password_confirmation: "password123!", role: "editor")
    @workflow = Workflow.create!(title: "Row Aria WF", user: @editor, graph_mode: true)
    sign_in @editor
  end

  test "a stubbed row names which step and which door in its accessible name" do
    question = Steps::Question.create!(workflow: @workflow, position: 0, title: "Light green?",
                                       answer_type: "yes_no", variable_name: "light")

    get workflow_path(@workflow, edit: true)

    assert_select "##{dom_id(question)} .builder__door-stub[aria-label='“Light green?” — Yes: add step']",
                  text: "Yes → add step"
    assert_select "##{dom_id(question)} .builder__door-stub[aria-label='“Light green?” — No: add step']",
                  text: "No → add step"
  end

  # The single, unlabelled Next door's stub reads "→ add step" visibly, and
  # its accessible name is built from the same fact data-grow-context already
  # carries, phrased as an action.
  test "a lone unlabelled stub names the step it follows" do
    action = Steps::Action.create!(workflow: @workflow, position: 0, title: "Power cycle the modem")

    get workflow_path(@workflow, edit: true)

    assert_select "##{dom_id(action)} .builder__door-stub[aria-label='Add a step after “Power cycle the modem”']",
                  text: "→ add step"
  end
end
