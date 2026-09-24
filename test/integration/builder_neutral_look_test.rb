require "test_helper"

# The outline's look (2026-09-24, chosen from three prototypes): colour means
# a problem and nothing else. A step's type is a grey icon, on its row, in the
# type picker and on a jump chip naming its target; numbers are neutral; no
# type dots; a continuation reads as a quiet connector, and a plain "Next" -
# whose step is the very next row - draws nothing at all.
class BuilderNeutralLookTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

  setup do
    @user = User.create!(email: "neutral-look-#{SecureRandom.hex(4)}@example.com",
                         password: "password123!", password_confirmation: "password123!", role: "editor")
    @workflow = Workflow.create!(title: "Modem light", user: @user, status: "draft")
    sign_in @user
  end

  # Mutation check: render the wired continuation chip for a :next door
  # again in _step_node - red.
  test "a wired Next draws nothing, since its step is the next row" do
    check = Steps::Action.create!(workflow: @workflow, title: "Power cycle", position: 0)
    done = Steps::Resolve.create!(workflow: @workflow, title: "Fixed", position: 1)
    Transition.create!(step: check, target_step: done)
    @workflow.update!(start_step: check)

    get workflow_path(@workflow, edit: true)

    assert_select "##{dom_id(check, :node)} > .builder__outline-door", count: 0
    assert_select "##{dom_id(done)}"
  end

  test "an unwired Next keeps its add-step stub" do
    check = Steps::Action.create!(workflow: @workflow, title: "Power cycle", position: 0)
    @workflow.update!(start_step: check)

    get workflow_path(@workflow, edit: true)

    assert_select "##{dom_id(check, :node)} .builder__door-stub", text: /add step/
  end

  # Mutation check: give the connector back its pill class - red.
  test "a labelled continuation is a quiet connector, not a pill" do
    question = Steps::Question.create!(workflow: @workflow, title: "Light green?", position: 0,
                                       answer_type: "yes_no", variable_name: "light")
    working = Steps::Resolve.create!(workflow: @workflow, title: "Working", position: 1)
    cycle = Steps::Action.create!(workflow: @workflow, title: "Power cycle", position: 2)
    Transition.create!(step: question, target_step: working, condition: "light == 'yes'", position: 0)
    Transition.create!(step: question, target_step: cycle, condition: "light == 'no'", position: 1)
    @workflow.update!(start_step: question)

    get workflow_path(@workflow, edit: true)

    assert_select "##{dom_id(question, :node)} > .builder__outline-door--connector", text: /No/ do |connector|
      assert_select connector, ".builder__outline-chip", count: 0
    end
  end

  # Mutation check: put a builder__type-dot back in the type picker - red.
  test "no type dots anywhere in the builder" do
    question = Steps::Question.create!(workflow: @workflow, title: "Light green?", position: 0,
                                       answer_type: "yes_no", variable_name: "light")
    working = Steps::Resolve.create!(workflow: @workflow, title: "Working", position: 1)
    cycle = Steps::Action.create!(workflow: @workflow, title: "Power cycle", position: 2)
    Transition.create!(step: question, target_step: working, condition: "light == 'yes'", position: 0)
    Transition.create!(step: question, target_step: cycle, condition: "light == 'no'", position: 1)
    Transition.create!(step: cycle, target_step: working)
    @workflow.update!(start_step: question)

    get workflow_path(@workflow, edit: true)

    assert_select ".builder__type-dot", count: 0
  end

  test "a step's type is an icon on its row, in the picker and on a jump chip" do
    question = Steps::Question.create!(workflow: @workflow, title: "Light green?", position: 0,
                                       answer_type: "yes_no", variable_name: "light")
    working = Steps::Resolve.create!(workflow: @workflow, title: "Working", position: 1)
    cycle = Steps::Action.create!(workflow: @workflow, title: "Power cycle", position: 2)
    Transition.create!(step: question, target_step: working, condition: "light == 'yes'", position: 0)
    Transition.create!(step: question, target_step: cycle, condition: "light == 'no'", position: 1)
    Transition.create!(step: cycle, target_step: working)
    @workflow.update!(start_step: question)

    get workflow_path(@workflow, edit: true)

    assert_select "##{dom_id(cycle)} .builder__step-type-icon[title=?] svg", "Action"
    assert_select "##{dom_id(working)} .builder__step-type-icon[title=?] svg", "Resolve"
    assert_select ".builder__type-option .builder__step-type-icon svg", count: WorkflowsHelper::STEP_TYPE_ICONS.size
    assert_select ".builder__outline-jump > svg.builder__step-type-icon"
  end

  test "Escalate's type icon is not the warning icon" do
    assert_not_equal "exclamation-triangle", WorkflowsHelper::STEP_TYPE_ICONS.fetch("escalate"),
                     "the row's type icon and its health warning would be the same glyph"
  end
end
