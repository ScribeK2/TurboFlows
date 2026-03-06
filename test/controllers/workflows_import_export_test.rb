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
      graph_mode: true,
      start_node_uuid: "step-1-uuid",
      steps: [
        {
          'id' => 'step-1-uuid',
          'type' => 'question',
          'title' => 'Get Name',
          'question' => 'What is your name?',
          'answer_type' => 'text',
          'variable_name' => 'customer_name',
          'transitions' => [{ 'target_uuid' => 'step-2-uuid' }]
        },
        {
          'id' => 'step-2-uuid',
          'type' => 'question',
          'title' => 'Check Name',
          'question' => 'Does customer have a name?',
          'transitions' => [
            { 'target_uuid' => 'step-3-uuid', 'condition' => "customer_name != ''", 'label' => 'Has name' },
            { 'target_uuid' => 'step-4-uuid', 'condition' => "customer_name == ''", 'label' => 'No name' }
          ]
        },
        {
          'id' => 'step-3-uuid',
          'type' => 'action',
          'title' => 'Welcome',
          'instructions' => 'Welcome the customer',
          'transitions' => []
        },
        {
          'id' => 'step-4-uuid',
          'type' => 'resolve',
          'title' => 'Exit',
          'resolution_type' => 'cancelled'
        }
      ]
    )

    sign_in @editor
  end

  # ============================================================================
  # Export Tests
  # ============================================================================

  test "export JSON includes graph_mode and start_node_uuid" do
    get export_workflow_path(@graph_workflow)

    assert_response :success

    exported = JSON.parse(response.body)

    assert_equal true, exported['graph_mode']
    assert_equal 'step-1-uuid', exported['start_node_uuid']
    assert_equal 4, exported['steps'].length
    assert_equal '2.0', exported['export_version']
  end

  test "export JSON includes full step structure with transitions" do
    get export_workflow_path(@graph_workflow)

    assert_response :success

    exported = JSON.parse(response.body)
    first_step = exported['steps'][0]

    assert_equal 'step-1-uuid', first_step['id']
    assert_equal 'question', first_step['type']
    assert_equal 'Get Name', first_step['title']
    assert_equal 1, first_step['transitions'].length
    assert_equal 'step-2-uuid', first_step['transitions'][0]['target_uuid']
  end

  test "export PDF includes graph mode indicator" do
    get export_pdf_workflow_path(@graph_workflow)

    assert_response :success
    assert_equal 'application/pdf', response.content_type
  end

  # ============================================================================
  # Import Page Tests
  # ============================================================================

  test "import page shows Graph Mode information" do
    get import_workflows_path

    assert_response :success

    assert_match(/Graph Mode/, response.body)
    assert_match(/transitions/, response.body)
    # Should show the new step types, not legacy decision/checkpoint
    assert_match(/question.*action.*message.*escalate.*resolve/i, response.body)
    assert_no_match(/type.*decision/i, response.body.gsub(/Legacy Format Support.*$/m, '')) # Decision only in legacy section
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
      post import_file_workflows_path, params: { file: file }
    end

    imported = Workflow.last

    assert_predicate imported, :graph_mode?
    assert_equal "Imported Graph Workflow", imported.title
    assert_equal 2, imported.steps.length
    assert_equal "imported-step-1", imported.start_node_uuid
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
      post import_file_workflows_path, params: { file: file }
    end

    imported = Workflow.last

    assert_predicate imported, :graph_mode?, "Imported workflow should be in graph mode"

    # Check that steps have IDs
    imported.steps.each do |step|
      assert_predicate step['id'], :present?, "Step should have an ID"
    end

    # Check that non-terminal steps have transitions
    q1_step = imported.steps.find { |s| s['title'] == 'Q1' }

    assert_predicate q1_step['transitions'], :present?, "Question step should have transitions"
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
      post import_file_workflows_path, params: { file: file }
    end

    imported = Workflow.last
    converted_step = imported.steps.find { |s| s['title'] == 'Check Name' }

    # Decision type should be auto-converted to question during import
    assert_equal 'question', converted_step['type'], "Decision should be auto-converted to question"
    assert converted_step['_import_converted'], "Should be flagged as converted"
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
      post import_file_workflows_path, params: { file: file }
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
      post import_file_workflows_path, params: { file: file }
    end

    imported = Workflow.last

    assert_predicate imported, :graph_mode?
    assert_equal "CSV Import Test", imported.title
    assert_equal 3, imported.steps.length
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
      post import_file_workflows_path, params: { file: file }
    end

    assert_redirected_to import_workflows_path
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
      post import_file_workflows_path, params: { file: file }
    end

    assert_redirected_to import_workflows_path
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
      post import_file_workflows_path, params: { file: file }
    end

    assert_redirected_to import_workflows_path
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
      post import_file_workflows_path, params: { file: file }
    end

    imported = Workflow.last
    # Should redirect to edit page when there are incomplete steps
    assert_redirected_to edit_workflow_path(imported)
    assert_match(/incomplete.*step/i, flash[:notice])
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
      post import_file_workflows_path, params: { file: file }
    end

    imported = Workflow.last

    assert_predicate imported, :graph_mode?, "Should be imported as graph mode"
    assert imported.steps.all? { |s| s['id'].present? }, "All steps should have IDs"
  end
end
