require "test_helper"

class WorkflowWizardFlowTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(
      email: "wizard-test@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    sign_in @user
  end

  # ==========================================================================
  # Scenario 1: Basic Linear Flow (Wizard End-to-End)
  # ==========================================================================

  test "complete wizard flow creates working workflow" do
    # Step 1: Create draft via POST /workflows/start_wizard
    # Use force_linear_mode=1 to test linear workflow creation
    # (graph mode is now the default; this test validates linear mode still works)
    post start_wizard_workflows_path(force_linear_mode: 1)

    assert_response :redirect
    follow_redirect!

    # Should redirect to step1 of a newly created draft
    assert_match(/step1/, request.path)
    draft_workflow = Workflow.drafts.last

    assert_not_nil draft_workflow
    assert_equal "draft", draft_workflow.status
    assert_equal false, draft_workflow.graph_mode, "Should be linear mode with force_linear_mode param"

    # Step 2: Complete Step 1 - Title and Description
    patch update_step1_workflow_path(draft_workflow), params: {
      workflow: {
        title: "Customer Support Flow",
        description: "Workflow for handling customer inquiries",
        graph_mode: false # Preserve linear mode
      }
    }

    assert_response :redirect
    follow_redirect!

    assert_match(/step2/, request.path)

    draft_workflow.reload

    assert_equal "Customer Support Flow", draft_workflow.title

    # Step 3: Complete Step 2 - Add Steps
    patch update_step2_workflow_path(draft_workflow), params: {
      workflow: {
        steps: [
          {
            id: SecureRandom.uuid,
            type: "question",
            title: "Customer Name",
            question: "What is your name?",
            variable_name: "customer_name",
            answer_type: "text"
          },
          {
            id: SecureRandom.uuid,
            type: "action",
            title: "Greet Customer",
            instructions: "Hello {{customer_name}}, how can I help you today?",
            action_type: "Greeting"
          }
        ]
      }
    }

    assert_response :redirect
    follow_redirect!

    assert_match(/step3/, request.path)

    draft_workflow.reload

    assert_equal 2, draft_workflow.steps.length

    # Verify variable_name is preserved
    question_step = draft_workflow.steps.find { |s| s["type"] == "question" }

    assert_equal "customer_name", question_step["variable_name"]

    # Step 4: Complete Step 3 - Publish workflow
    patch create_from_draft_workflow_path(draft_workflow)

    assert_response :redirect
    follow_redirect!

    draft_workflow.reload

    assert_equal "published", draft_workflow.status

    # Step 5: Run simulation to verify variable interpolation works
    simulation = Simulation.create!(
      workflow: draft_workflow,
      user: @user,
      status: 'active',
      current_step_index: 0,
      results: {},
      inputs: {}
    )

    # Answer question with name
    simulation.process_step("John")

    # Check that variable is stored
    assert_equal "John", simulation.results["customer_name"]

    # Process action step
    simulation.process_step

    # Workflow should complete
    assert_equal "completed", simulation.status
  end

  # ==========================================================================
  # Variable Name Persistence Tests
  # ==========================================================================

  test "variable_name persists through wizard steps" do
    # Create draft directly
    draft = Workflow.create!(
      title: "Variable Test",
      user: @user,
      status: 'draft',
      steps: [
        {
          "id" => "step-1",
          "type" => "question",
          "title" => "Question",
          "question" => "Enter value",
          "variable_name" => "my_variable"
        }
      ]
    )

    # Simulate step2 update (like the form submission)
    patch update_step2_workflow_path(draft), params: {
      workflow: {
        steps: [
          {
            id: "step-1",
            type: "question",
            title: "Question Updated",
            question: "Enter value updated"
            # NOTE: variable_name NOT included in submission (hidden field might be missing)
          }
        ]
      }
    }

    draft.reload

    # variable_name should be preserved even if not in submission
    question_step = draft.steps.find { |s| s["type"] == "question" }

    assert_equal "my_variable", question_step["variable_name"], "variable_name should be preserved when not in form submission"
  end

  # ==========================================================================
  # Draft Expiration Tests
  # ==========================================================================

  test "draft workflow has expiration date set" do
    post start_wizard_workflows_path
    follow_redirect!

    draft = Workflow.drafts.last

    assert_not_nil draft.draft_expires_at
    assert_operator draft.draft_expires_at, :>, Time.current
    assert_operator draft.draft_expires_at, :<, 8.days.from_now
  end

  test "published workflow has no expiration date" do
    # Create and publish workflow
    draft = Workflow.create!(
      title: "Publish Test",
      user: @user,
      status: 'draft',
      steps: [
        {
          "id" => "step-1",
          "type" => "action",
          "title" => "Action",
          "instructions" => "Do something"
        }
      ]
    )

    patch create_from_draft_workflow_path(draft)

    draft.reload

    assert_equal "published", draft.status
    assert_nil draft.draft_expires_at
  end

  # ==========================================================================
  # Validation Tests
  # ==========================================================================

  test "cannot publish workflow without steps" do
    draft = Workflow.create!(
      title: "Empty Workflow",
      user: @user,
      status: 'draft',
      steps: []
    )

    patch create_from_draft_workflow_path(draft)

    assert_response :unprocessable_entity

    draft.reload

    assert_equal "draft", draft.status
  end

  test "cannot publish workflow with invalid steps" do
    # Create a valid draft first
    draft = Workflow.create!(
      title: "Invalid Steps Workflow",
      user: @user,
      status: 'draft',
      steps: [
        {
          "id" => "step-1",
          "type" => "question",
          "title" => "Valid Question",
          "question" => "This is valid"
        }
      ]
    )

    # Now manually update to invalid state (bypassing validation)
    draft.update_column(:steps, [
                          {
                            "id" => "step-1",
                            "type" => "question",
                            "title" => "Question Without Text"
                            # Missing required 'question' field
                          }
                        ])

    patch create_from_draft_workflow_path(draft)

    assert_response :unprocessable_entity

    draft.reload

    assert_equal "draft", draft.status
  end

  # ==========================================================================
  # Step 1 Navigation Tests
  # ==========================================================================

  test "step1 displays title input" do
    draft = Workflow.create!(
      title: "Test Draft",
      user: @user,
      status: 'draft'
    )

    get step1_workflow_path(draft)

    assert_response :success
    assert_select "input[name='workflow[title]']"
  end

  test "update_step1 requires title" do
    draft = Workflow.create!(
      title: "Test Draft",
      user: @user,
      status: 'draft'
    )

    patch update_step1_workflow_path(draft), params: {
      workflow: {
        title: ""
      }
    }

    # Should re-render step1 with validation errors
    assert_response :unprocessable_entity
  end

  # ==========================================================================
  # Step 2 Navigation Tests
  # ==========================================================================

  test "step2 displays existing steps" do
    draft = Workflow.create!(
      title: "Test Draft",
      user: @user,
      status: 'draft',
      steps: [
        {
          "id" => "step-1",
          "type" => "question",
          "title" => "Test Question",
          "question" => "What?",
          "variable_name" => "test_var"
        }
      ]
    )

    get step2_workflow_path(draft)

    assert_response :success
  end

  # ==========================================================================
  # Step 3 Preview Tests
  # ==========================================================================

  test "step3 displays workflow summary" do
    draft = Workflow.create!(
      title: "Preview Test",
      user: @user,
      status: 'draft',
      steps: [
        {
          "id" => "step-1",
          "type" => "question",
          "title" => "Name",
          "question" => "Your name?",
          "variable_name" => "name"
        },
        {
          "id" => "step-2",
          "type" => "action",
          "title" => "Greet",
          "instructions" => "Hello {{name}}!"
        }
      ]
    )

    get step3_workflow_path(draft)

    assert_response :success
  end

  # ==========================================================================
  # Group Assignment Tests
  # ==========================================================================

  test "step1 allows group assignment" do
    group = Group.create!(name: "Test Group")
    draft = Workflow.create!(
      title: "Test Draft",
      user: @user,
      status: 'draft'
    )

    patch update_step1_workflow_path(draft), params: {
      workflow: {
        title: "With Group",
        group_ids: [group.id]
      }
    }

    assert_response :redirect

    draft.reload

    assert_includes draft.group_ids, group.id
  end

  # ==========================================================================
  # Complete Integration Test - Variable Interpolation Flow
  # ==========================================================================

  test "wizard creates workflow with working variable interpolation" do
    # Create draft with question + action using interpolation
    draft = Workflow.create!(
      title: "Interpolation Test",
      user: @user,
      status: 'draft',
      steps: [
        {
          "id" => "step-1",
          "type" => "question",
          "title" => "Get Customer Name",
          "question" => "What is your name?",
          "variable_name" => "customer_name",
          "answer_type" => "text"
        },
        {
          "id" => "step-2",
          "type" => "question",
          "title" => "Get Issue",
          "question" => "Hello {{customer_name}}, what is your issue?",
          "variable_name" => "issue",
          "answer_type" => "text"
        },
        {
          "id" => "step-3",
          "type" => "action",
          "title" => "Summary",
          "instructions" => "Customer {{customer_name}} reported: {{issue}}"
        }
      ]
    )

    # Publish
    patch create_from_draft_workflow_path(draft)
    draft.reload

    assert_equal "published", draft.status

    # Run simulation
    simulation = Simulation.create!(
      workflow: draft,
      user: @user,
      status: 'active',
      current_step_index: 0,
      results: {},
      inputs: {}
    )

    # Answer first question
    simulation.process_step("Alice")

    assert_equal "Alice", simulation.results["customer_name"]

    # Answer second question (which should show interpolated text when viewed)
    simulation.process_step("Login problem")

    assert_equal "Login problem", simulation.results["issue"]

    # Process action and complete
    simulation.process_step

    assert_equal "completed", simulation.status

    # Verify all results are stored
    assert_equal "Alice", simulation.results["customer_name"]
    assert_equal "Login problem", simulation.results["issue"]
  end
end
