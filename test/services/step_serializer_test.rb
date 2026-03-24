require "test_helper"

class StepSerializerTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "step-serializer-test@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    @workflow = Workflow.create!(
      title: "Serializer Test Workflow",
      user: @user,
      graph_mode: true
    )
  end

  test "serializes question step with all fields" do
    Steps::Question.create!(
      workflow: @workflow, uuid: "q-uuid", position: 0, title: "Ask name",
      question: "What is your name?", answer_type: "text", variable_name: "name"
    )

    result = StepSerializer.call(@workflow)

    assert_equal 1, result.length
    data = result.first
    assert_equal "q-uuid", data["id"]
    assert_equal "question", data["type"]
    assert_equal "Ask name", data["title"]
    assert_equal "What is your name?", data["question"]
    assert_equal "text", data["answer_type"]
    assert_equal "name", data["variable_name"]
  end

  test "serializes transitions" do
    q = Steps::Question.create!(workflow: @workflow, uuid: "q1", position: 0, title: "Q1", question: "Ask?")
    a = Steps::Action.create!(workflow: @workflow, uuid: "a1", position: 1, title: "A1")
    Transition.create!(step: q, target_step: a, condition: "yes", label: "Yes path", position: 0)

    result = StepSerializer.call(@workflow)
    q_data = result.find { |s| s["id"] == "q1" }

    assert_equal 1, q_data["transitions"].length
    t = q_data["transitions"].first
    assert_equal "a1", t["target_uuid"]
    assert_equal "yes", t["condition"]
    assert_equal "Yes path", t["label"]
  end

  test "all six STI types serialize correctly" do
    Steps::Question.create!(workflow: @workflow, uuid: "u0", position: 0, title: "S0", question: "Ask?")
    Steps::Action.create!(workflow: @workflow, uuid: "u1", position: 1, title: "S1")
    Steps::Message.create!(workflow: @workflow, uuid: "u2", position: 2, title: "S2")
    Steps::Escalate.create!(workflow: @workflow, uuid: "u3", position: 3, title: "S3", target_type: "supervisor")
    Steps::Resolve.create!(workflow: @workflow, uuid: "u4", position: 4, title: "S4")
    Steps::SubFlow.create!(workflow: @workflow, uuid: "u5", position: 5, title: "S5", sub_flow_workflow_id: @workflow.id)

    result = StepSerializer.call(@workflow)

    assert_equal 6, result.length
    types = result.pluck("type")
    assert_includes types, "question"
    assert_includes types, "action"
    assert_includes types, "message"
    assert_includes types, "escalate"
    assert_includes types, "resolve"
    assert_includes types, "sub_flow"
  end

  test "empty workflow returns empty array" do
    result = StepSerializer.call(@workflow)
    assert_equal [], result
  end
end
