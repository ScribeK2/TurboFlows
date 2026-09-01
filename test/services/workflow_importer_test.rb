require "test_helper"

class WorkflowImporterTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "importer-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @group = Group.create!(name: "Importer Group #{SecureRandom.hex(2)}")
    UserGroup.create!(user: @user, group: @group)
  end

  teardown do
    User.where("email LIKE ?", "importer-test-%").destroy_all
    Group.where("name LIKE ?", "Importer Group %").destroy_all
  end

  test "imports from JSON string and saves workflow" do
    json_data = { title: "Test Import", steps: [] }.to_json

    result = WorkflowImporter.new(@user, format: :json, content: json_data).call

    assert_predicate result, :success?
    assert_equal "Test Import", result.workflow.title
    assert_equal "draft", result.workflow.status
    assert_not_nil result.workflow.id
  end

  test "imports land as drafts, not published" do
    json_data = {
      title: "Draft Landing",
      steps: [
        { id: "a", type: "action", title: "First", instructions: "Do a thing",
          transitions: [{ target_uuid: "z" }] },
        { id: "z", type: "resolve", title: "Done", resolution_type: "success" }
      ]
    }.to_json

    result = WorkflowImporter.new(@user, format: :json, content: json_data).call

    assert_predicate result, :success?
    assert_equal "draft", result.workflow.status
    assert_nil result.workflow.published_version_id
    assert_equal 0, result.workflow.versions.count
  end

  test "imported workflows never expire on their own" do
    json_data = {
      title: "Never Expires",
      steps: [
        { id: "a", type: "action", title: "First", instructions: "Do a thing",
          transitions: [{ target_uuid: "z" }] },
        { id: "z", type: "resolve", title: "Done", resolution_type: "success" }
      ]
    }.to_json

    result = WorkflowImporter.new(@user, format: :json, content: json_data).call

    assert_predicate result, :success?
    assert_nil result.workflow.draft_expires_at

    travel_to(8.days.from_now) do
      assert_not_includes Workflow.expired_drafts, result.workflow
    end
  end

  # An escalate step with no priority is the documented default shape, and it
  # failed the entire import: "Validation failed: Priority is not included in
  # the list". Not the step — the workflow. Every format is covered because the
  # `normal` default was written in four places and they all funnel through
  # StepNormalizer.
  {
    json: '{"title":"Esc","steps":[' \
          '{"id":"s1","type":"escalate","title":"Hand off","target_type":"supervisor",' \
          '"transitions":[{"target_uuid":"s2"}]},' \
          '{"id":"s2","type":"resolve","title":"Done","resolution_type":"success"}]}',
    yaml: "title: Esc\nsteps:\n  - id: s1\n    type: escalate\n    title: Hand off\n    " \
          "target_type: supervisor\n    transitions:\n      - target_uuid: s2\n  " \
          "- id: s2\n    type: resolve\n    title: Done\n    resolution_type: success\n",
    csv: "workflow_title,step_number,type,title,target_type,transitions\n" \
         "Esc,1,escalate,Hand off,supervisor,2\n" \
         "Esc,2,resolve,Done,,\n",
    markdown: "# Esc\n\n## Step 1: Hand off\nType: escalate\nTarget Type: supervisor\n" \
              "Transitions: Step 2\n\n## Step 2: Done\nType: resolve\nResolution Type: success\n"
  }.each do |format, content|
    test "#{format} import of an escalate with no priority succeeds" do
      result = WorkflowImporter.new(@user, format: format, content: content).call

      assert_predicate result, :success?,
                       "import failed: #{result.errors.inspect}"
      escalate = result.workflow.steps.find { |step| step.step_type == "escalate" }
      assert escalate, "precondition: the escalate step was imported"
      assert_includes Steps::Escalate::VALID_PRIORITIES, escalate.priority
    end
  end

  test "returns errors for invalid JSON" do
    result = WorkflowImporter.new(@user, format: :json, content: "not json { at all").call

    assert_not result.success?
    assert_predicate result.errors, :any?
    assert(result.errors.any? { |e| e.match?(/invalid/i) })
  end

  test "returns error for unsupported format" do
    result = WorkflowImporter.new(@user, format: :xlsx, content: "content").call

    assert_not result.success?
    assert_predicate result.errors, :any?
  end

  test "a failed import leaves no workflow behind" do
    json_data = {
      title: "Orphan Probe",
      steps: [
        { id: "a", type: "action", title: "First", instructions: "Do a thing" },
        { id: "a", type: "message", title: "Duplicate id", content: "Boom" },
        { id: "z", type: "resolve", title: "Done", resolution_type: "success" }
      ]
    }.to_json

    assert_no_difference -> { Workflow.count } do
      assert_no_difference -> { Step.count } do
        result = WorkflowImporter.new(@user, format: :json, content: json_data).call

        assert_not result.success?
        assert_match(/uuid/i, result.errors.join(" "))
      end
    end
  end

  test "imports JSON with steps and preserves step data" do
    json_data = {
      title: "Multi-step Workflow",
      steps: [
        { type: "action", title: "First Action", instructions: "Do this" }
      ]
    }.to_json

    result = WorkflowImporter.new(@user, format: :json, content: json_data).call

    assert_predicate result, :success?
    assert_equal "Multi-step Workflow", result.workflow.title
    assert_operator result.workflow.steps.count, :>=, 1
    assert_equal "Steps::Action", result.workflow.steps.first.type
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
    assert_predicate result, :success?
    assert_predicate result, :incomplete_steps?
    assert_predicate result.incomplete_steps_count, :positive?
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

    assert_predicate result, :success?
    # Parser may add conversion warnings; warnings is always an array
    assert_kind_of Array, result.warnings
  end

  test "an import places the workflow in its named group and tags it" do
    json_data = {
      title: "Placed Workflow",
      groups: [@group.name],
      tags: %w[billing tier-2],
      steps: [{ id: "z", type: "resolve", title: "Done", resolution_type: "success" }]
    }.to_json

    result = WorkflowImporter.new(@user, format: :json, content: json_data).call

    assert_predicate result, :success?
    assert_equal [@group.id], result.workflow.groups.map(&:id)
    assert_equal %w[billing tier-2], result.workflow.tags.map(&:name).sort
  end

  test "an unknown group fails the import and writes nothing" do
    json_data = {
      title: "Misplaced Workflow",
      groups: ["No Such Group At All"],
      steps: [{ id: "z", type: "resolve", title: "Done", resolution_type: "success" }]
    }.to_json

    assert_no_difference -> { Workflow.count } do
      result = WorkflowImporter.new(@user, format: :json, content: json_data).call

      assert_not result.success?
      assert_match(/No group exists at path/, result.errors.join(" "))
    end
  end

  test "a group the importing user cannot see fails the import" do
    hidden = Group.create!(name: "Importer Group #{SecureRandom.hex(2)} Hidden")
    json_data = {
      title: "Forbidden Placement",
      groups: [hidden.name],
      steps: [{ id: "z", type: "resolve", title: "Done", resolution_type: "success" }]
    }.to_json

    assert_no_difference -> { Workflow.count } do
      result = WorkflowImporter.new(@user, format: :json, content: json_data).call

      assert_not result.success?
      assert_match(/do not have access/, result.errors.join(" "))
    end
  end
end
