require "test_helper"

# Three times a control shipped in the step panel with no autosave action: the
# Form step's field inputs (2026-09-05), the media file input, and the Question
# step's answer type (both 2026-09-15). Each one saved only if something else
# on the panel changed afterwards. This renders the panel for every step type
# and refuses any control that neither carries the action itself nor sits
# under an element that does.
class StepPanelAutosaveCoverageTest < ActionDispatch::IntegrationTest
  AUTOSAVE = "inline-autosave#schedule".freeze
  CONTROLS = "input:not([type=hidden]):not([type=submit]):not([type=button]), select, textarea".freeze

  setup do
    @editor = User.create!(email: "coverage-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                           password_confirmation: "password123!", role: "editor")
    @workflow = Workflow.create!(title: "Coverage", user: @editor)
    @published = Workflow.create!(title: "Target", user: @editor).tap { |w| w.update_columns(status: "published") }
    sign_in @editor
  end

  test "every control in every step type's panel autosaves" do
    uncovered = steps.flat_map do |step|
      get panel_edit_workflow_step_path(@workflow, step)
      assert_response :success

      form = response.parsed_body.at_css("form[data-controller~='inline-autosave']")
      assert form, "#{step.step_type}: no autosave form"

      form.css(CONTROLS).reject { |control| covered?(control) }.map do |control|
        "#{step.step_type}: #{control.name}[name=#{control['name'].inspect}]"
      end
    end

    assert_empty uncovered, "controls that never autosave:\n  #{uncovered.join("\n  ")}"
  end

  private

  def steps
    [
      Steps::Question.create!(workflow: @workflow, position: 0, title: "Q", question: "Q?", answer_type: "multiple_choice",
                              options: [{ "label" => "A", "value" => "a" }]),
      Steps::Action.create!(workflow: @workflow, position: 1, title: "A"),
      Steps::Message.create!(workflow: @workflow, position: 2, title: "M"),
      Steps::Escalate.create!(workflow: @workflow, position: 3, title: "E"),
      Steps::Resolve.create!(workflow: @workflow, position: 4, title: "R"),
      Steps::SubFlow.create!(workflow: @workflow, position: 5, title: "S", sub_flow_workflow_id: @published.id),
      Steps::Form.create!(workflow: @workflow, position: 6, title: "F",
                          options: [{ "name" => "plan", "label" => "Plan", "field_type" => "select", "required" => false,
                                      "position" => 0, "select_options" => [{ "label" => "Basic", "value" => "basic" }] }])
    ]
  end

  # A control is covered by its own action, by an ancestor's (Form rows, Question
  # options), or by the transition editor, whose controls write into a hidden
  # input that carries the action. Anything inside a <template> is inert.
  def covered?(control)
    return true if control.ancestors("template").any?

    control.ancestors.push(control).any? do |node|
      node["data-action"].to_s.include?(AUTOSAVE) ||
        node["data-controller"].to_s.split.include?("step-transitions")
    end
  end
end
