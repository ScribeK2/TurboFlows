require "test_helper"

class StepParamsFormTest < ActiveSupport::TestCase
  test "parses step params from raw controller params" do
    raw = ActionController::Parameters.new(
      title: "Question 1",
      type: "question",
      transitions_json: '[{"target_step_id": "abc-123", "position": 0}]'
    )

    form = StepParamsForm.new(raw)
    assert_equal "Question 1", form.title
    assert_equal "question", form.type
    assert_kind_of Array, form.transitions
    assert_equal "abc-123", form.transitions.first["target_step_id"]
  end

  test "handles invalid JSON gracefully" do
    raw = ActionController::Parameters.new(
      title: "Q1",
      type: "question",
      transitions_json: "not json"
    )

    form = StepParamsForm.new(raw)
    assert_equal [], form.transitions
  end

  test "returns empty array when transitions_json is blank" do
    raw = ActionController::Parameters.new(title: "Step", type: "action")

    form = StepParamsForm.new(raw)
    assert_equal [], form.transitions
  end

  test "passes through an already-parsed array for output_fields" do
    raw = ActionController::Parameters.new(
      title: "Action Step",
      type: "action",
      output_fields: [{ "name" => "ticket_id", "value" => "T-999" }]
    )

    form = StepParamsForm.new(raw)
    assert_equal 1, form.output_fields.length
    assert_equal "ticket_id", form.output_fields.first["name"]
  end

  test "parses output_fields from JSON string" do
    raw = ActionController::Parameters.new(
      title: "Action Step",
      type: "action",
      output_fields: '[{"name": "order_id", "value": ""}]'
    )

    form = StepParamsForm.new(raw)
    assert_equal "order_id", form.output_fields.first["name"]
  end

  test "parses attachments from JSON string" do
    raw = ActionController::Parameters.new(
      title: "Action Step",
      type: "action",
      attachments: '[{"url": "https://example.com/doc.pdf", "label": "Guide"}]'
    )

    form = StepParamsForm.new(raw)
    assert_equal 1, form.attachments.length
    assert_equal "https://example.com/doc.pdf", form.attachments.first["url"]
  end

  test "handles malformed output_fields JSON gracefully" do
    raw = ActionController::Parameters.new(
      type: "action",
      output_fields: "{ broken"
    )

    form = StepParamsForm.new(raw)
    assert_equal [], form.output_fields
  end

  test "handles malformed attachments JSON gracefully" do
    raw = ActionController::Parameters.new(
      type: "action",
      attachments: "not-an-array"
    )

    form = StepParamsForm.new(raw)
    assert_equal [], form.attachments
  end

  test "returns empty arrays when JSON value is an object instead of array" do
    raw = ActionController::Parameters.new(
      type: "question",
      transitions_json: '{"key": "value"}'
    )

    form = StepParamsForm.new(raw)
    assert_equal [], form.transitions
  end

  test "to_step_params merges parsed arrays and removes transitions_json key" do
    raw = ActionController::Parameters.new(
      title: "Q1",
      type: "question",
      transitions_json: '[{"target_step_id": "uuid-1", "position": 0}]'
    )

    form   = StepParamsForm.new(raw)
    result = form.to_step_params

    assert_equal "Q1", result[:title]
    assert_not result.key?(:transitions_json), "transitions_json should not be present in to_step_params output"
    assert_kind_of Array, result[:transitions]
    assert_equal "uuid-1", result[:transitions].first["target_step_id"]
  end
end
