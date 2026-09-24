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

  test "imported workflows still never expire after being edited" do
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

    result.workflow.update!(title: "Edited")

    travel_to(8.days.from_now) do
      assert_nil result.workflow.reload.draft_expires_at
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

  # The step panel's Guidance note (help_text) and Reference link
  # (reference_url) could only arrive through JSON or YAML; the CSV and
  # Markdown parsers read neither, and the lenient path drops what it does not
  # name, so a guidance column vanished without a word.
  {
    csv: "workflow_title,type,title,question,variable_name,options,guidance,reference_link,transitions\n" \
         "Guide,question,Check plan,Which plan?,plan,Basic,Do not quote a price.,https://kb.example.com/plans,Done\n" \
         "Guide,resolve,Done,,,,Log the call.,tel:+15551234567,\n",
    markdown: "# Guide\n\n## Step 1: Check plan\nType: question\nQuestion: Which plan?\nVariable: plan\n" \
              "Options: Basic\nGuidance: Do not quote a price.\n" \
              "Reference Link: https://kb.example.com/plans\nTransitions: Step 2\n\n" \
              "## Step 2: Done\nType: resolve\n**Guidance**: Log the call.\n" \
              "**Reference Link**: tel:+15551234567\n"
  }.each do |format, content|
    test "#{format} import carries each step's guidance note and reference link" do
      result = WorkflowImporter.new(@user, format: format, content: content).call

      assert_predicate result, :success?, "import failed: #{result.errors.inspect}"
      question = result.workflow.steps.find { |step| step.step_type == "question" }
      resolve = result.workflow.steps.find { |step| step.step_type == "resolve" }
      assert_equal "Do not quote a price.", question.help_text
      assert_equal "https://kb.example.com/plans", question.reference_url
      assert_equal "Log the call.", resolve.help_text
      assert_equal "tel:+15551234567", resolve.reference_url
    end
  end

  test "csv import accepts the help_text and reference_url column names too" do
    content = "workflow_title,type,title,help_text,reference_url\n" \
              "Guide,resolve,Done,Log the call.,https://kb.example.com/close\n"
    result = WorkflowImporter.new(@user, format: :csv, content:).call

    assert_predicate result, :success?, "import failed: #{result.errors.inspect}"
    step = result.workflow.steps.first
    assert_equal "Log the call.", step.help_text
    assert_equal "https://kb.example.com/close", step.reference_url
  end

  # A Guidance line is a field now, not description text; the rest of the
  # step's prose must still land where it did.
  test "a markdown guidance line does not swallow the description around it" do
    content = "# Guide\n\n## Step 1: Done\nType: resolve\nClose the ticket politely.\n" \
              "Guidance: Log the call.\n"
    result = WorkflowImporter.new(@user, format: :markdown, content:).call

    assert_predicate result, :success?, "import failed: #{result.errors.inspect}"
    step = result.workflow.steps.first
    assert_equal "Log the call.", step.help_text
    assert_includes step.description.to_plain_text, "Close the ticket politely."
    assert_not_includes step.description.to_plain_text, "Log the call."
  end

  # Every other Markdown field label is case-insensitive; these match it.
  test "markdown guidance and reference link labels ignore case" do
    content = "# Guide\n\n## Step 1: Done\nType: resolve\nguidance note: Log the call.\n" \
              "**REFERENCE LINK**: https://kb.example.com/close\n"
    result = WorkflowImporter.new(@user, format: :markdown, content:).call

    assert_predicate result, :success?, "import failed: #{result.errors.inspect}"
    step = result.workflow.steps.first
    assert_equal "Log the call.", step.help_text
    assert_equal "https://kb.example.com/close", step.reference_url
  end

  test "a reference link the builder would refuse fails the import and writes nothing" do
    content = "workflow_title,type,title,reference_link\n" \
              "Bad Link,resolve,Done,javascript:alert(1)\n"

    assert_no_difference -> { Workflow.count } do
      result = WorkflowImporter.new(@user, format: :csv, content:).call
      assert_not result.success?
      assert_match(/reference url/i, result.errors.join(" "))
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

  test "an import places the workflow in a nested group named by itself" do
    child = Group.create!(name: "Importer Group Nested #{SecureRandom.hex(2)}", parent: @group)
    json_data = {
      title: "Nested Placement",
      groups: [child.name],
      steps: [{ id: "z", type: "resolve", title: "Done", resolution_type: "success" }]
    }.to_json

    result = WorkflowImporter.new(@user, format: :json, content: json_data).call

    assert_predicate result, :success?
    assert_equal [child.id], result.workflow.groups.map(&:id)
  end

  test "a lenient import naming Uncategorized arrives with no group and says so" do
    json_data = {
      title: "Old Lenient Export",
      groups: ["Uncategorized"],
      steps: [{ id: "z", type: "resolve", title: "Done", resolution_type: "success" }]
    }.to_json

    result = WorkflowImporter.new(@user, format: :json, content: json_data).call

    assert_predicate result, :success?
    assert_empty result.workflow.groups
    assert_match(/Uncategorized/, result.warnings.join("\n"))
  end

  # Two unknown groups, and a linear-format step list (which the parser
  # always flags with a "Converted from linear format to Graph Mode"
  # warning), are the probe: the pre-build `resolve` returns one distinct
  # error entry per bad group AND passes `parser.warnings` through, while a
  # wrong implementation that let `workflow.save` proceed and only discovered
  # the bad placement via `apply!` raising inside the transaction would be
  # caught by `call`'s blanket `rescue StandardError`, which collapses to a
  # single `[e.message]` (both group errors joined into one string by
  # `InvalidPlacement`'s constructor) and drops `warnings` entirely (the
  # rescue's `failure([e.message])` call doesn't pass `warnings:`). Either
  # symptom alone would catch a resolve-after-build regression; asserting
  # both makes the test fail loudly instead of by a fragile count.
  test "an unknown group fails the import and writes nothing" do
    json_data = {
      title: "Misplaced Workflow",
      groups: ["No Such Group At All", "Also Not A Real Group"],
      steps: [
        { type: "action", title: "Step One", instructions: "Do this" },
        { type: "resolve", title: "Done", resolution_type: "success" }
      ]
    }.to_json

    assert_no_difference -> { Workflow.count } do
      result = WorkflowImporter.new(@user, format: :json, content: json_data).call

      assert_not result.success?
      assert_match(/No group exists at path/, result.errors.join(" "))
      assert_equal 2, result.errors.size,
                   "expected one distinct error per bad group, got: #{result.errors.inspect}"
      assert(result.errors.any? { |e| e.include?("No Such Group At All") })
      assert(result.errors.any? { |e| e.include?("Also Not A Real Group") })
      assert(result.warnings.any? { |w| w.include?("Graph Mode") },
             "expected parser warnings to survive the early return, got: #{result.warnings.inspect}")
    end
  end

  test "a group the importing user cannot see fails the import" do
    hidden = Group.create!(name: "Importer Group #{SecureRandom.hex(2)} Hidden")
    json_data = {
      title: "Forbidden Placement",
      groups: [hidden.name],
      steps: [
        { type: "action", title: "Step One", instructions: "Do this" },
        { type: "resolve", title: "Done", resolution_type: "success" }
      ]
    }.to_json

    assert_no_difference -> { Workflow.count } do
      result = WorkflowImporter.new(@user, format: :json, content: json_data).call

      assert_not result.success?
      assert_match(/do not have access/, result.errors.join(" "))
      assert(result.warnings.any? { |w| w.include?("Graph Mode") },
             "expected parser warnings to survive the early return, got: #{result.warnings.inspect}")
    end
  end
  test "a validated strict report imports without re-parsing" do
    content = {
      schema_version: "1",
      workflows: [{
        title: "Strict Import",
        groups: [@group.name],
        tags: ["billing"],
        steps: [
          { id: "hello", type: "message", title: "Greet", content: "<p>Hello</p>",
            transitions: [{ target_id: "done" }] },
          { id: "done", type: "resolve", title: "Done", resolution_type: "success" }
        ]
      }]
    }.to_json

    report = StrictImportValidator.new(user: @user, content:).validate
    assert_predicate report, :valid?, report.errors.inspect

    result = WorkflowImporter.new(@user, format: :json, content:, strict_report: report).call

    assert_predicate result, :success?
    assert_equal "Strict Import", result.workflow.title
    assert_equal "draft", result.workflow.status
    assert_nil result.workflow.draft_expires_at
    assert_equal [@group.id], result.workflow.groups.map(&:id)
    assert_equal ["billing"], result.workflow.tags.map(&:name)
    assert_equal %w[done hello], result.workflow.steps.map(&:uuid).sort
  end
end
