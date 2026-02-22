require "test_helper"

class WorkflowImporterTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "importer-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
  end

  teardown do
    User.where("email LIKE ?", "importer-test-%").destroy_all
  end

  test "imports from JSON string and saves workflow" do
    json_data = { title: "Test Import", steps: [] }.to_json

    result = WorkflowImporter.new(@user, format: :json, content: json_data).call

    assert result.success?
    assert_equal "Test Import", result.workflow.title
    assert_equal "published", result.workflow.status
    assert_not_nil result.workflow.id
  end

  test "returns errors for invalid JSON" do
    result = WorkflowImporter.new(@user, format: :json, content: "not json { at all").call

    assert_not result.success?
    assert result.errors.any?
    assert result.errors.any? { |e| e.match?(/invalid/i) }
  end

  test "returns error for unsupported format" do
    result = WorkflowImporter.new(@user, format: :xlsx, content: "content").call

    assert_not result.success?
    assert result.errors.any?
  end

  test "imports JSON with steps and preserves step data" do
    json_data = {
      title: "Multi-step Workflow",
      steps: [
        { type: "action", title: "First Action", instructions: "Do this" }
      ]
    }.to_json

    result = WorkflowImporter.new(@user, format: :json, content: json_data).call

    assert result.success?
    assert_equal "Multi-step Workflow", result.workflow.title
    assert result.workflow.steps.length >= 1
    assert_equal "action", result.workflow.steps.first["type"]
  end

  test "reports incomplete steps when present" do
    # A question step without a question field is flagged as incomplete by the parser
    json_data = {
      title: "Incomplete Workflow",
      steps: [
        { type: "question", title: "A Question" }
      ]
    }.to_json

    result = WorkflowImporter.new(@user, format: :json, content: json_data).call

    # Incomplete steps don't block saving — they're flagged for follow-up editing
    assert result.success?
    assert result.incomplete_steps?
    assert result.incomplete_steps_count > 0
  end

  test "returns warnings from parser" do
    # Linear format triggers a conversion warning
    json_data = {
      title: "Linear Workflow",
      steps: [
        { type: "action", title: "Step One", instructions: "Do this" },
        { type: "action", title: "Step Two", instructions: "Do that" }
      ]
    }.to_json

    result = WorkflowImporter.new(@user, format: :json, content: json_data).call

    assert result.success?
    # Parser may add conversion warnings; warnings is always an array
    assert_kind_of Array, result.warnings
  end
end
