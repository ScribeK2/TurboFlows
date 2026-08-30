require "test_helper"

class StepHelperTest < ActionView::TestCase
  include StepHelper

  def setup
    @user = User.create!(
      email: "step-helper-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    @workflow = Workflow.create!(title: "Helper Test Workflow", user: @user, graph_mode: true)
  end

  # ─── step_field ─────────────────────────────────────────────────────────────

  test "step_field returns demodulized type" do
    step = Steps::Question.create!(workflow: @workflow, position: 0, title: "Q", question: "?")
    assert_equal "question", step_field(step, "type")
  end

  test "step_field returns uuid for id field" do
    step = Steps::Action.create!(workflow: @workflow, position: 0, title: "A", uuid: "test-uuid-1234")
    assert_equal "test-uuid-1234", step_field(step, "id")
  end

  test "step_field returns nil for unknown field" do
    step = Steps::Action.create!(workflow: @workflow, position: 0, title: "A")
    assert_nil step_field(step, "nonexistent_field")
  end

  # ─── render_step_content: XSS prevention ────────────────────────────────────

  test "render_step_content escapes HTML in variable values" do
    step = Steps::Message.create!(workflow: @workflow, position: 0, title: "Msg")
    step.content = "<p>Hello {{name}}</p>"
    step.save!

    result = render_step_content(step, :content, { "name" => "<script>alert('xss')</script>" })

    assert_not_includes result, "<script>"
    assert_includes result, "&lt;script&gt;"
    assert_predicate result, :html_safe?, "Result should be html_safe"
  end

  test "render_step_content preserves rich text HTML structure" do
    step = Steps::Message.create!(workflow: @workflow, position: 0, title: "Msg")
    step.content = "<p>Status: {{status}}</p>"
    step.save!

    result = render_step_content(step, :content, { "status" => "active" })

    assert_includes result, "active"
    assert_includes result, "<p>"
  end

  test "render_step_content handles missing variables gracefully" do
    step = Steps::Message.create!(workflow: @workflow, position: 0, title: "Msg")
    step.content = "<p>Hello {{name}}</p>"
    step.save!

    result = render_step_content(step, :content, { "other" => "value" })

    assert_includes result, "{{name}}"
  end

  test "render_step_content returns empty string for nil rich text" do
    step = Steps::Action.create!(workflow: @workflow, position: 0, title: "A")

    result = render_step_content(step, :instructions)

    assert_equal "", result
    assert_predicate result, :html_safe?
  end

  test "render_step_content without variables returns raw rich text" do
    step = Steps::Message.create!(workflow: @workflow, position: 0, title: "Msg")
    step.content = "<p>Hello world</p>"
    step.save!

    result = render_step_content(step, :content)

    assert_includes result, "Hello world"
    assert_predicate result, :html_safe?
  end

  # ─── workflow_display_steps ─────────────────────────────────────────────────

  test "workflow_display_steps includes transitions" do
    s1 = Steps::Question.create!(workflow: @workflow, position: 0, title: "Q1", question: "?")
    s2 = Steps::Action.create!(workflow: @workflow, position: 1, title: "A1")
    Transition.create!(step: s1, target_step: s2, position: 0)

    steps = workflow_display_steps(@workflow.reload)
    assert_equal 2, steps.length
    assert_equal 1, steps.first.transitions.length
  end

  # ─── step_summary_text ─────────────────────────────────────────────────────

  test "step_summary_text combines outcome and condition summaries" do
    q = Steps::Question.create!(workflow: @workflow, position: 0, title: "Age Check", question: "How old are you?", answer_type: "number", variable_name: "age")
    a = Steps::Action.create!(workflow: @workflow, position: 1, title: "Next")
    Transition.create!(step: q, target_step: a, condition: "age >= 18", label: "Adult", position: 0)

    result = step_summary_text(q.reload)

    assert_includes result, "Number"
    assert_includes result, "How old are you?"
    assert_includes result, "{{age}}"
    assert_includes result, "Adult -> Next"
  end

  test "step_summary_text returns empty for step with no summary" do
    a = Steps::Action.create!(workflow: @workflow, position: 0, title: "Do something")
    result = step_summary_text(a)
    assert_equal "", result
  end

  test "step_summary_text shows Terminal for resolve steps" do
    r = Steps::Resolve.create!(workflow: @workflow, position: 0, title: "Done", resolution_type: "success")
    result = step_summary_text(r)
    assert_includes result, "Success"
    assert_includes result, "Terminal"
  end

  # ─── highlight_variables ───────────────────────────────────────────────────

  test "highlight_variables wraps variables in spans" do
    result = highlight_variables("Hello {{name}}, your ID is {{user_id}}")
    assert_includes result, '<span class="variable-tag">{{name}}</span>'
    assert_includes result, '<span class="variable-tag">{{user_id}}</span>'
    assert_predicate result, :html_safe?
  end

  test "highlight_variables escapes HTML in surrounding text" do
    result = highlight_variables("Use <b>{{name}}</b> here")
    assert_includes result, "&lt;b&gt;"
    assert_includes result, '<span class="variable-tag">{{name}}</span>'
    assert_not_includes result, "<b>"
  end

  test "highlight_variables returns empty for blank input" do
    assert_equal "", highlight_variables(nil)
    assert_equal "", highlight_variables("")
  end

  # ─── outcome_summary per subclass ──────────────────────────────────────────

  test "Question#outcome_summary includes answer type and variable" do
    q = Steps::Question.create!(workflow: @workflow, position: 0, title: "Q", question: "What color?", answer_type: "multiple_choice", variable_name: "color")
    result = q.outcome_summary
    assert_includes result, "Multiple Choice"
    assert_includes result, "What color?"
    assert_includes result, "{{color}}"
  end

  test "Action#outcome_summary includes action type and instructions" do
    a = Steps::Action.create!(workflow: @workflow, position: 0, title: "A", action_type: "Verify")
    a.instructions = "Check the customer account"
    a.save!
    result = a.reload.outcome_summary
    assert_includes result, "Verify"
    assert_includes result, "Check the customer account"
  end

  test "Message#outcome_summary returns plain text content" do
    m = Steps::Message.create!(workflow: @workflow, position: 0, title: "M")
    m.content = "Welcome to the workflow"
    m.save!
    result = m.reload.outcome_summary
    assert_includes result, "Welcome to the workflow"
  end

  test "Escalate#outcome_summary shows priority and target" do
    e = Steps::Escalate.create!(workflow: @workflow, position: 0, title: "E", target_type: "supervisor", priority: "high")
    result = e.outcome_summary
    assert_includes result, "High"
    assert_includes result, "supervisor"
  end

  test "Resolve#outcome_summary shows resolution type" do
    r = Steps::Resolve.create!(workflow: @workflow, position: 0, title: "R", resolution_type: "success")
    result = r.outcome_summary
    assert_includes result, "Success"
  end

  test "SubFlow#outcome_summary shows target workflow title" do
    sf = Steps::SubFlow.create!(workflow: @workflow, position: 0, title: "SF", sub_flow_workflow_id: @workflow.id)
    result = sf.outcome_summary
    assert_includes result, "Run:"
    assert_includes result, @workflow.title
  end

  test "condition_summary shows branch info" do
    q = Steps::Question.create!(workflow: @workflow, position: 0, title: "Q", question: "?")
    a1 = Steps::Action.create!(workflow: @workflow, position: 1, title: "Yes Path")
    a2 = Steps::Action.create!(workflow: @workflow, position: 2, title: "No Path")
    Transition.create!(step: q, target_step: a1, condition: "yes", label: "Yes", position: 0)
    Transition.create!(step: q, target_step: a2, condition: "no", label: "No", position: 1)

    result = q.reload.condition_summary
    assert_includes result, "2 branches"
    assert_includes result, "Yes -> Yes Path"
    assert_includes result, "No -> No Path"
  end

  test "condition_summary returns nil for steps with no transitions" do
    a = Steps::Action.create!(workflow: @workflow, position: 0, title: "A")
    assert_nil a.condition_summary
  end
end
