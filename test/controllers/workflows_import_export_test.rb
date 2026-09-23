require "test_helper"

class WorkflowsImportExportTest < ActionDispatch::IntegrationTest
  def setup
    @editor = User.create!(
      email: "editor-import-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )

    @graph_workflow = Workflow.create!(
      title: "Graph Mode Workflow",
      description: "A workflow in graph mode",
      user: @editor,
      graph_mode: true
    )

    step1 = Steps::Question.create!(
      workflow: @graph_workflow, uuid: "step-1-uuid", position: 0,
      title: "Get Name", question: "What is your name?",
      answer_type: "text", variable_name: "customer_name"
    )
    step2 = Steps::Question.create!(
      workflow: @graph_workflow, uuid: "step-2-uuid", position: 1,
      title: "Check Name", question: "Does customer have a name?"
    )
    step3 = Steps::Action.create!(
      workflow: @graph_workflow, uuid: "step-3-uuid", position: 2,
      title: "Welcome"
    )
    step3.update!(instructions: "Welcome the customer")
    step4 = Steps::Resolve.create!(
      workflow: @graph_workflow, uuid: "step-4-uuid", position: 3,
      title: "Exit", resolution_type: "cancelled"
    )

    Transition.create!(step: step1, target_step: step2, position: 0)
    Transition.create!(step: step2, target_step: step3, condition: "customer_name != ''", label: "Has name", position: 0)
    Transition.create!(step: step2, target_step: step4, condition: "customer_name == ''", label: "No name", position: 1)

    @graph_workflow.update_column(:start_step_id, step1.id)

    sign_in @editor
  end

  # ============================================================================
  # Export Tests
  # ============================================================================

  test "export JSON carries the strict envelope and the start step" do
    get workflow_export_path(@graph_workflow)

    assert_response :success

    exported = response.parsed_body

    assert_equal ImportSchemaGenerator::SCHEMA_VERSION, exported['schema_version']
    assert_equal 1, exported['workflows'].length

    workflow = exported['workflows'].first
    assert_equal 'step-1-uuid', workflow['start_step_id']
    assert_equal 4, workflow['steps'].length
  end

  test "export JSON includes full step structure with transitions" do
    get workflow_export_path(@graph_workflow)

    assert_response :success

    first_step = response.parsed_body['workflows'].first['steps'][0]

    assert_equal 'step-1-uuid', first_step['id']
    assert_equal 'question', first_step['type']
    assert_equal 'Get Name', first_step['title']
    assert_equal 1, first_step['transitions'].length
    # The wire name is target_id: an agent told "uuid" reaches for SecureRandom
    # rather than another step's id.
    assert_equal 'step-2-uuid', first_step['transitions'][0]['target_id']
  end

  test "export PDF includes graph mode indicator" do
    get pdf_workflow_export_path(@graph_workflow)

    assert_response :success
    assert_equal 'application/pdf', response.content_type
  end

  # ============================================================================
  # Import Page Tests
  # ============================================================================

  # This used to assert the page said "Graph Mode", against a section headed
  # "Graph Mode Workflows". There is no other mode — every workflow is a graph —
  # so that section was telling the reader about a distinction the app does not
  # have, and it went. What is asserted instead is what the page must not get
  # wrong: it names every step type the app accepts, and it teaches the strict
  # envelope rather than only the lenient one.
  #
  # The step types come from the generated prompt, not from copy in the view, so
  # this passes for the same reason it cannot drift: adding a step type to
  # Workflow::VALID_STEP_TYPES puts it on the page. `form` and `sub_flow` were
  # both missing from the hand-written reference this replaced.
  test "import page documents every step type the app accepts" do
    get new_workflow_import_path

    assert_response :success

    Workflow::VALID_STEP_TYPES.each do |type|
      assert_match(/\b#{Regexp.escape(type)}\b/, response.body, "#{type} is not documented on the import page")
    end

    assert_match(/transitions/, response.body)
    assert_no_match(/\bcheckpoint\b/i, response.body)
  end

  test "import page teaches the strict dialect, not only the lenient one" do
    get new_workflow_import_path

    assert_response :success

    assert_match(/schema_version/, response.body)
    assert_match(ImportSchemaGenerator::SCHEMA_URL, response.body)
    assert_match(ImportSchemaGenerator::MAX_WORKFLOWS_PER_FILE.to_s, response.body)
    # The copyable agent prompt itself, not a description of it.
    assert_match(/Writing a TurboFlows workflow file/, response.body)
    assert_match(/\[\[&quot;Support&quot;, &quot;Tier 2&quot;\]\]/, response.body)
  end

  # Every example on the page is claimed to import cleanly. That claim is the
  # kind that rots silently, so it is checked rather than trusted: the four that
  # used to be here all transitioned to steps that were not in the file, and
  # anyone who copied one got a workflow they could not publish.
  test "the lenient examples on the import page import with no warnings" do
    get new_workflow_import_path

    assert_response :success

    blocks = response.body.scan(%r{<pre class="code-block"><code>(.*?)</code></pre>}m).flatten
    assert_equal 3, blocks.size, "expected the YAML, CSV and Markdown examples"

    formats = %i[yaml csv markdown]
    blocks.zip(formats).each do |raw, format|
      content = CGI.unescapeHTML(raw)
      result = WorkflowImporter.new(@editor, format: format, content: content).call

      assert_predicate result, :success?, "#{format} example failed: #{result.errors.inspect}"
      assert_empty result.warnings, "#{format} example imported with warnings"
      assert_not result.incomplete_steps?, "#{format} example has incomplete steps"
    end
  end

  # ============================================================================
  # JSON Import Tests
  # ============================================================================

  test "import JSON with graph mode structure" do
    json_content = {
      title: "Imported Graph Workflow",
      description: "A workflow with transitions",
      graph_mode: true,
      start_node_uuid: "imported-step-1",
      steps: [
        {
          id: "imported-step-1",
          type: "question",
          title: "Question 1",
          question: "What is your name?",
          transitions: [{ target_uuid: "imported-step-2" }]
        },
        {
          id: "imported-step-2",
          type: "resolve",
          title: "Complete",
          resolution_type: "success"
        }
      ]
    }.to_json

    file = Rack::Test::UploadedFile.new(
      StringIO.new(json_content),
      'application/json',
      original_filename: 'test_workflow.json'
    )

    assert_difference("Workflow.count") do
      post workflow_import_path, params: { file: file }
    end

    imported = Workflow.last

    assert_predicate imported, :graph_mode?
    assert_equal "Imported Graph Workflow", imported.title
    assert_equal 2, imported.steps.count
    assert_equal "imported-step-1", imported.start_step&.uuid
  end

  test "import JSON without graph mode converts to graph mode" do
    json_content = {
      title: "Legacy Linear Workflow",
      steps: [
        { type: "question", title: "Q1", question: "Name?" },
        { type: "action", title: "A1", instructions: "Do something" }
      ]
    }.to_json

    file = Rack::Test::UploadedFile.new(
      StringIO.new(json_content),
      'application/json',
      original_filename: 'legacy.json'
    )

    assert_difference("Workflow.count") do
      post workflow_import_path, params: { file: file }
    end

    imported = Workflow.last

    assert_predicate imported, :graph_mode?, "Imported workflow should be in graph mode"

    # Check that steps have UUIDs
    imported.steps.each do |step|
      assert_predicate step.uuid, :present?, "Step should have a UUID"
    end

    # Check that non-terminal steps have transitions
    q1_step = imported.steps.find_by(title: 'Q1')

    assert_predicate q1_step.transitions, :present?, "Question step should have transitions"
  end

  test "import JSON with legacy branches converts to transitions" do
    json_content = {
      title: "Legacy Decision Workflow",
      steps: [
        {
          type: "question",
          title: "Get Name",
          question: "Name?",
          variable_name: "name"
        },
        {
          type: "decision",
          title: "Check Name",
          branches: [
            { condition: "name != ''", path: "Welcome" }
          ],
          else_path: "Retry"
        },
        { type: "action", title: "Welcome", instructions: "Hello!" },
        { type: "action", title: "Retry", instructions: "Try again" }
      ]
    }.to_json

    file = Rack::Test::UploadedFile.new(
      StringIO.new(json_content),
      'application/json',
      original_filename: 'legacy_decision.json'
    )

    assert_difference("Workflow.count") do
      post workflow_import_path, params: { file: file }
    end

    imported = Workflow.last
    converted_step = imported.steps.find_by(title: 'Check Name')

    # Decision type should be auto-converted to question during import
    assert_instance_of Steps::Question, converted_step, "Decision should be auto-converted to question"
  end

  # ============================================================================
  # YAML Import Tests
  # ============================================================================

  test "import YAML with graph mode structure" do
    yaml_content = <<~YAML
      title: "YAML Graph Workflow"
      graph_mode: true
      steps:
        - id: "yaml-step-1"
          type: question
          title: "Question"
          question: "What?"
          transitions:
            - target_uuid: "yaml-step-2"
        - id: "yaml-step-2"
          type: resolve
          title: "Done"
          resolution_type: success
    YAML

    file = Rack::Test::UploadedFile.new(
      StringIO.new(yaml_content),
      'text/yaml',
      original_filename: 'test.yaml'
    )

    assert_difference("Workflow.count") do
      post workflow_import_path, params: { file: file }
    end

    imported = Workflow.last

    assert_predicate imported, :graph_mode?
    assert_equal "YAML Graph Workflow", imported.title
  end

  # ============================================================================
  # CSV Import Tests
  # ============================================================================

  test "import CSV with transitions column" do
    csv_content = <<~CSV
      workflow_title,id,type,title,question,instructions,transitions,resolution_type
      CSV Import Test,csv-step-1,question,Get Name,What is your name?,,csv-step-2,
      ,csv-step-2,action,Process,,Process the data,csv-step-3,
      ,csv-step-3,resolve,Complete,,,,success
    CSV

    file = Rack::Test::UploadedFile.new(
      StringIO.new(csv_content),
      'text/csv',
      original_filename: 'test.csv'
    )

    assert_difference("Workflow.count") do
      post workflow_import_path, params: { file: file }
    end

    imported = Workflow.last

    assert_predicate imported, :graph_mode?
    assert_equal "CSV Import Test", imported.title
    assert_equal 3, imported.steps.reload.count
  end

  # ============================================================================
  # Error Handling Tests
  # ============================================================================

  test "import rejects file without title" do
    json_content = { steps: [{ type: "action", title: "Step 1" }] }.to_json

    file = Rack::Test::UploadedFile.new(
      StringIO.new(json_content),
      'application/json',
      original_filename: 'no_title.json'
    )

    assert_no_difference("Workflow.count") do
      post workflow_import_path, params: { file: file }
    end

    assert_redirected_to new_workflow_import_path
    # Either "title is required" or "failed to parse" is acceptable
    assert_predicate flash[:alert], :present?
  end

  test "import rejects oversized file" do
    # Create a file larger than 10MB
    large_content = "a" * (11 * 1024 * 1024)

    file = Rack::Test::UploadedFile.new(
      StringIO.new(large_content),
      'application/json',
      original_filename: 'huge.json'
    )

    assert_no_difference("Workflow.count") do
      post workflow_import_path, params: { file: file }
    end

    assert_redirected_to new_workflow_import_path
    assert_match(/too large/i, flash[:alert])
  end

  test "import handles invalid JSON gracefully" do
    invalid_json = "{ this is not valid json"

    file = Rack::Test::UploadedFile.new(
      StringIO.new(invalid_json),
      'application/json',
      original_filename: 'invalid.json'
    )

    assert_no_difference("Workflow.count") do
      post workflow_import_path, params: { file: file }
    end

    assert_redirected_to new_workflow_import_path
    assert_match(/invalid json/i, flash[:alert].downcase)
  end

  test "import with incomplete steps redirects to edit" do
    json_content = {
      title: "Incomplete Workflow",
      steps: [
        { type: "question", title: "Missing Question Text" }, # No question field
        { type: "action", title: "Complete Action", instructions: "Do this" }
      ]
    }.to_json

    file = Rack::Test::UploadedFile.new(
      StringIO.new(json_content),
      'application/json',
      original_filename: 'incomplete.json'
    )

    assert_difference("Workflow.count") do
      post workflow_import_path, params: { file: file }
    end

    imported = Workflow.last
    # Should redirect to edit page when there are incomplete steps
    assert_redirected_to edit_workflow_path(imported, health: true)
    assert_match(/Review issues in the Health panel/i, flash[:notice])
  end

  # ============================================================================
  # Graph Validation Tests
  # ============================================================================

  test "import validates graph structure and reports warnings" do
    # This workflow is valid but has a warning about conversion
    json_content = {
      title: "Simple Workflow",
      steps: [
        {
          type: "question",
          title: "Q1",
          question: "Name?"
        },
        {
          type: "action",
          title: "Process",
          instructions: "Process data"
        },
        {
          type: "resolve",
          title: "End",
          resolution_type: "success"
        }
      ]
    }.to_json

    file = Rack::Test::UploadedFile.new(
      StringIO.new(json_content),
      'application/json',
      original_filename: 'linear_workflow.json'
    )

    # Should import and convert to graph mode with warnings
    assert_difference("Workflow.count") do
      post workflow_import_path, params: { file: file }
    end

    imported = Workflow.last

    assert_predicate imported, :graph_mode?, "Should be imported as graph mode"
    assert imported.steps.all? { |s| s.uuid.present? }, "All steps should have UUIDs"
  end

  # ============================================================================
  # PDF Export Ordering
  # ============================================================================

  module RecordPdfText
    def text(string, options = {})
      (Thread.current[:recorded_pdf_text] ||= []) << string
      super
    end
  end
  Prawn::Document.prepend(RecordPdfText) unless Prawn::Document <= RecordPdfText

  # Mutation check: restore `@workflow.steps.includes(:transitions).each_with_index`
  # in export_pdf_ar_steps - red.
  test "the PDF numbers steps as the builder's outline does" do
    workflow = Workflow.create!(title: "PDF order", user: @editor)
    q = Steps::Question.create!(workflow: workflow, title: "Power light green?", position: 0,
                                answer_type: "yes_no", variable_name: "light")
    trunk = Steps::Resolve.create!(workflow: workflow, title: "Trunk done", position: 1)
    exit_step = Steps::Resolve.create!(workflow: workflow, title: "Exit done", position: 2)
    Transition.create!(step: q, target_step: exit_step, condition: "light == 'yes'", position: 0)
    Transition.create!(step: q, target_step: trunk, condition: "light == 'no'", position: 1)
    workflow.update_columns(start_step_id: q.id)

    Thread.current[:recorded_pdf_text] = []
    get pdf_workflow_export_path(workflow)
    assert_response :success

    headings = Thread.current[:recorded_pdf_text].grep(/\A\d+\. /)
    assert_equal(["1. Power light green? [Question]", "2. Exit done [Resolve]", "3. Trunk done [Resolve]"], headings)
  ensure
    Thread.current[:recorded_pdf_text] = nil
  end
end
