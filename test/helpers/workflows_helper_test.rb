require "test_helper"

class WorkflowsHelperTest < ActionView::TestCase
  include WorkflowsHelper

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
