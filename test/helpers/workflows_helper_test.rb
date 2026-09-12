require "test_helper"

class WorkflowsHelperTest < ActionView::TestCase
  include WorkflowsHelper

  attr_accessor :current_user

  test "workflow_open_path sends an editor to the builder in edit" do
    editor = User.create!(
      email: "open-ed-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    workflow = Workflow.create!(title: "Open me", user: editor)
    self.current_user = editor

    assert_equal workflow_path(workflow, edit: true), workflow_open_path(workflow)
  end

  test "condition_sentence_variables puts the open question first" do
    user = User.create!(
      email: "csv-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    workflow = Workflow.create!(title: "Vars", user: user)
    Steps::Question.create!(
      workflow: workflow, position: 0, title: "Already verified?",
      question: "Already?", answer_type: "yes_no", variable_name: "already_verified"
    )
    later = Steps::Question.create!(
      workflow: workflow, position: 1, title: "Did it work?",
      question: "Work?", answer_type: "yes_no", variable_name: "verified"
    )
    Steps::Resolve.create!(
      workflow: workflow, position: 2, title: "Done", resolution_type: "success"
    )

    names = condition_sentence_variables(workflow, later).pluck(:name)
    assert_equal %w[verified already_verified], names
  end

  test "condition_sentence_variables is unchanged for a non-question step" do
    user = User.create!(
      email: "csv2-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    workflow = Workflow.create!(title: "Vars2", user: user)
    Steps::Question.create!(
      workflow: workflow, position: 0, title: "Q",
      question: "Q?", answer_type: "yes_no", variable_name: "q"
    )
    action = Steps::Action.create!(workflow: workflow, position: 1, title: "Do it")

    names = condition_sentence_variables(workflow, action).pluck(:name)
    assert_equal %w[q], names
  end

  test "step_connection_summary names targets by title and ordinal" do
    user = User.create!(
      email: "sum-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    workflow = Workflow.create!(title: "Summary", user: user)
    a = Steps::Question.create!(workflow: workflow, position: 0, title: "First", question: "A?")
    b = Steps::Resolve.create!(workflow: workflow, position: 1, title: "Done", resolution_type: "success")
    ordinals = { a.uuid => 1, b.uuid => 2 }

    assert_equal "→ Done · 2", step_connection_summary([b], ordinals)
  end

  test "step_type_label returns correct labels for known types" do
    assert_equal "Question", step_type_label("question")
    assert_equal "Action", step_type_label("action")
    assert_equal "Sub-flow", step_type_label("sub_flow")
    assert_equal "Resolve", step_type_label("resolve")
  end

  test "step_type_label falls back for unknown type" do
    assert_equal "Step", step_type_label(nil)
    assert_equal "Unknown", step_type_label("unknown")
  end

  test "step_type_svg_icon returns SVG tag for known types" do
    result = step_type_svg_icon("question")
    assert_includes result, "<svg"
    assert_includes result, "</svg>"
    assert_includes result, "icon"
  end

  test "STEP_TYPE_ICONS covers every step subclass" do
    step_types = Step.descendants.map { |klass| klass.name.demodulize.underscore }
    step_types.each do |type|
      assert WorkflowsHelper::STEP_TYPE_ICONS.key?(type),
             "Missing Heroicon mapping for step type '#{type}' in STEP_TYPE_ICONS"
    end
  end

  test "answer_type_label returns correct labels" do
    assert_equal "Yes / No", answer_type_label("yes_no")
    assert_equal "Multiple Choice", answer_type_label("multiple_choice")
    assert_equal "Text Input", answer_type_label("text")
    assert_equal "Unknown", answer_type_label(nil)
  end

  test "format_condition_for_display formats operators to human text" do
    assert_equal 'answer is "yes"', format_condition_for_display("answer == 'yes'")
    assert_equal 'score is not "low"', format_condition_for_display("score != 'low'")
    assert_equal 'count is greater than "10"', format_condition_for_display("count > '10'")
    assert_equal 'count is at least "5"', format_condition_for_display("count >= '5'")
    assert_equal 'count is less than "3"', format_condition_for_display("count < '3'")
    assert_equal 'count is at most "7"', format_condition_for_display("count <= '7'")
  end

  test "format_condition_for_display returns raw for unparseable condition" do
    assert_equal "some complex thing", format_condition_for_display("some complex thing")
    assert_equal "Not set", format_condition_for_display(nil)
    assert_equal "Not set", format_condition_for_display("")
  end

  test "step_type_badge_classes returns correct classes" do
    assert_equal "badge badge--question", step_type_badge_classes("question")
    assert_equal "badge badge--action", step_type_badge_classes("action")
    assert_equal "badge badge--form", step_type_badge_classes("form")
    assert_equal "badge badge--default", step_type_badge_classes("unknown")
  end

  test "resolve_step_reference resolves title from workflow" do
    user = User.create!(email: "wfh-#{SecureRandom.hex(4)}@example.com", password: "password123!", password_confirmation: "password123!")
    wf = Workflow.create!(title: "Helper WF", user: user)
    Steps::Action.create!(workflow: wf, position: 0, title: "My Step", uuid: "test-uuid")
    result = resolve_step_reference(wf, "test-uuid")
    assert_equal "My Step", result
  end
end
