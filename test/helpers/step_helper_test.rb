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
    assert result.html_safe?, "Result should be html_safe"
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
    assert result.html_safe?
  end

  test "render_step_content without variables returns raw rich text" do
    step = Steps::Message.create!(workflow: @workflow, position: 0, title: "Msg")
    step.content = "<p>Hello world</p>"
    step.save!

    result = render_step_content(step, :content)

    assert_includes result, "Hello world"
    assert result.html_safe?
  end

  # ─── serialize_steps_for_editor ─────────────────────────────────────────────

  test "serialize_steps_for_editor returns correct shape for each step type" do
    q = Steps::Question.create!(workflow: @workflow, position: 0, title: "Q1", question: "What?", answer_type: "yes_no", variable_name: "q1_answer")
    a = Steps::Action.create!(workflow: @workflow, position: 1, title: "A1", action_type: "Instruction")
    m = Steps::Message.create!(workflow: @workflow, position: 2, title: "M1")
    e = Steps::Escalate.create!(workflow: @workflow, position: 3, title: "E1", target_type: "supervisor", priority: "high")
    r = Steps::Resolve.create!(workflow: @workflow, position: 4, title: "R1", resolution_type: "success")
    sf = Steps::SubFlow.create!(workflow: @workflow, position: 5, title: "SF1", sub_flow_workflow_id: @workflow.id)

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
    step = Steps::Action.create!(workflow: @workflow, position: 0, title: "A1", uuid: "my-custom-uuid")

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
    steps = 5.times.map do |i|
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
      query_count += 1 if payload[:sql] =~ /SELECT.*"steps"/i
    }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      serialize_steps_for_editor(@workflow)
    end

    # Should be at most 2 queries: one to load steps, one to load transitions (via includes)
    # NOT 2 + N (where N is the number of transitions)
    assert query_count <= 2, "Expected at most 2 step queries but got #{query_count} — possible N+1"
  end

  test "serialize_steps_for_editor returns empty array for workflow with no steps" do
    result = serialize_steps_for_editor(@workflow)
    assert_equal [], result
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
end
