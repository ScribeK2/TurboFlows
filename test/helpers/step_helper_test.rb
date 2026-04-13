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

  # ─── serialize_steps_for_editor ─────────────────────────────────────────────

  test "serialize_steps_for_editor returns correct shape for each step type" do
    Steps::Question.create!(workflow: @workflow, position: 0, title: "Q1", question: "What?", answer_type: "yes_no", variable_name: "q1_answer")
    Steps::Action.create!(workflow: @workflow, position: 1, title: "A1", action_type: "Instruction")
    Steps::Message.create!(workflow: @workflow, position: 2, title: "M1")
    Steps::Escalate.create!(workflow: @workflow, position: 3, title: "E1", target_type: "supervisor", priority: "high")
    Steps::Resolve.create!(workflow: @workflow, position: 4, title: "R1", resolution_type: "success")
    Steps::SubFlow.create!(workflow: @workflow, position: 5, title: "SF1", sub_flow_workflow_id: @workflow.id)

    result = serialize_steps_for_editor(@workflow.reload)

    assert_equal 6, result.length

    # Question
    assert_equal "question", result[0]["type"]
    assert_equal "What?", result[0]["question"]
    assert_equal "yes_no", result[0]["answer_type"]
    assert_equal "q1_answer", result[0]["variable_name"]

    # Action
    assert_equal "action", result[1]["type"]
    assert_equal "Instruction", result[1]["action_type"]

    # Message
    assert_equal "message", result[2]["type"]

    # Escalate
    assert_equal "escalate", result[3]["type"]
    assert_equal "supervisor", result[3]["target_type"]
    assert_equal "high", result[3]["priority"]

    # Resolve
    assert_equal "resolve", result[4]["type"]
    assert_equal "success", result[4]["resolution_type"]

    # SubFlow
    assert_equal "sub_flow", result[5]["type"]
    assert_equal @workflow.id, result[5]["target_workflow_id"]
  end

  test "serialize_steps_for_editor uses uuid not AR id" do
    Steps::Action.create!(workflow: @workflow, position: 0, title: "A1", uuid: "my-custom-uuid")

    result = serialize_steps_for_editor(@workflow.reload)

    assert_equal "my-custom-uuid", result[0]["id"]
  end

  test "serialize_steps_for_editor resolves transitions to target uuids" do
    s1 = Steps::Question.create!(workflow: @workflow, position: 0, title: "Q1", question: "?", answer_type: "yes_no", uuid: "step-uuid-1")
    s2 = Steps::Action.create!(workflow: @workflow, position: 1, title: "A1", uuid: "step-uuid-2")
    s3 = Steps::Message.create!(workflow: @workflow, position: 2, title: "M1", uuid: "step-uuid-3")

    Transition.create!(step: s1, target_step: s2, condition: "answer == 'yes'", label: "Yes", position: 0)
    Transition.create!(step: s1, target_step: s3, condition: "answer == 'no'", label: "No", position: 1)

    result = serialize_steps_for_editor(@workflow.reload)

    transitions = result[0]["transitions"]
    assert_equal 2, transitions.length
    assert_equal "step-uuid-2", transitions[0]["target_uuid"]
    assert_equal "answer == 'yes'", transitions[0]["condition"]
    assert_equal "Yes", transitions[0]["label"]
    assert_equal "step-uuid-3", transitions[1]["target_uuid"]
    assert_equal "answer == 'no'", transitions[1]["condition"]
  end

  test "serialize_steps_for_editor excludes transitions with missing targets" do
    s1 = Steps::Question.create!(workflow: @workflow, position: 0, title: "Q1", question: "?", uuid: "step-uuid-1")
    s2 = Steps::Action.create!(workflow: @workflow, position: 1, title: "A1", uuid: "step-uuid-2")

    Transition.create!(step: s1, target_step: s2, position: 0)

    # Delete s2 so the transition now points to a missing step
    s2.destroy!

    result = serialize_steps_for_editor(@workflow.reload)

    # The transition should be filtered out since the target no longer exists
    assert_equal 0, result[0]["transitions"].length
  end

  test "serialize_steps_for_editor avoids N+1 queries" do
    steps = Array.new(5) do |i|
      Steps::Action.create!(workflow: @workflow, position: i, title: "Step #{i}", uuid: "nplus1-#{i}")
    end

    # Create transitions between sequential steps
    steps.each_cons(2) do |from, to|
      Transition.create!(step: from, target_step: to, position: 0)
    end

    @workflow.reload

    # Count queries during serialization
    query_count = 0
    counter = lambda { |_name, _start, _finish, _id, payload|
      query_count += 1 if /SELECT.*"steps"/i.match?(payload[:sql])
    }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      serialize_steps_for_editor(@workflow)
    end

    # Should be at most 2 queries: one to load steps, one to load transitions (via includes)
    # NOT 2 + N (where N is the number of transitions)
    assert_operator query_count, :<=, 2, "Expected at most 2 step queries but got #{query_count} — possible N+1"
  end

  test "serialize_steps_for_editor returns empty array for workflow with no steps" do
    result = serialize_steps_for_editor(@workflow)
    assert_equal [], result
  end

  test "serialize_steps_for_editor includes position_x and position_y" do
    Steps::Action.create!(workflow: @workflow, position: 0, title: "A1", position_x: 120, position_y: 240)
    Steps::Action.create!(workflow: @workflow, position: 1, title: "A2")

    result = serialize_steps_for_editor(@workflow.reload)

    assert_equal 120, result[0]["position_x"]
    assert_equal 240, result[0]["position_y"]
    assert_nil result[1]["position_x"]
    assert_nil result[1]["position_y"]
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
