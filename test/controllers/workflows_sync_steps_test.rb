require "test_helper"

class WorkflowsSyncStepsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @user = User.create!(
      email: "sync-test-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    sign_in @user
    @workflow = Workflow.create!(
      title: "Sync Test Workflow",
      user: @user,
      graph_mode: true,
      status: "draft"
    )
  end

  test "sync_steps creates new steps" do
    steps_json = [
      {
        id: "uuid-1",
        type: "question",
        title: "First Question",
        question: "What is your name?",
        answer_type: "free_text",
        position: 0,
        transitions: []
      },
      {
        id: "uuid-2",
        type: "action",
        title: "Record Name",
        position: 1,
        transitions: []
      }
    ]

    patch sync_steps_workflow_path(@workflow), params: {
      steps: steps_json,
      start_node_uuid: "uuid-1",
      lock_version: @workflow.lock_version
    }, as: :json

    assert_response :success
    @workflow.reload
    assert_equal 2, @workflow.workflow_steps.count
    assert_equal "uuid-1", @workflow.start_step.uuid
  end

  test "sync_steps updates existing steps" do
    step = Steps::Question.create!(
      workflow: @workflow,
      uuid: "uuid-1",
      title: "Old Title",
      question: "Old?",
      answer_type: "yes_no",
      position: 0
    )
    @workflow.update_column(:start_step_id, step.id)

    steps_json = [
      {
        id: "uuid-1",
        type: "question",
        title: "New Title",
        question: "New?",
        answer_type: "free_text",
        position: 0,
        transitions: []
      }
    ]

    patch sync_steps_workflow_path(@workflow), params: {
      steps: steps_json,
      start_node_uuid: "uuid-1",
      lock_version: @workflow.lock_version
    }, as: :json

    assert_response :success
    step.reload
    assert_equal "New Title", step.title
    assert_equal "New?", step.question
  end

  test "sync_steps deletes removed steps" do
    step1 = Steps::Question.create!(
      workflow: @workflow, uuid: "uuid-1", title: "Keep",
      question: "Q?", answer_type: "yes_no", position: 0
    )
    step2 = Steps::Action.create!(
      workflow: @workflow, uuid: "uuid-2", title: "Remove", position: 1
    )
    @workflow.update_column(:start_step_id, step1.id)

    steps_json = [
      { id: "uuid-1", type: "question", title: "Keep", question: "Q?",
        answer_type: "yes_no", position: 0, transitions: [] }
    ]

    patch sync_steps_workflow_path(@workflow), params: {
      steps: steps_json,
      start_node_uuid: "uuid-1",
      lock_version: @workflow.lock_version
    }, as: :json

    assert_response :success
    assert_equal 1, @workflow.workflow_steps.reload.count
    assert_nil Step.find_by(id: step2.id)
  end

  test "sync_steps reconciles transitions" do
    step1 = Steps::Question.create!(
      workflow: @workflow, uuid: "uuid-1", title: "Q1",
      question: "Yes or no?", answer_type: "yes_no", position: 0
    )
    step2 = Steps::Action.create!(
      workflow: @workflow, uuid: "uuid-2", title: "A1", position: 1
    )
    @workflow.update_column(:start_step_id, step1.id)

    steps_json = [
      {
        id: "uuid-1", type: "question", title: "Q1",
        question: "Yes or no?", answer_type: "yes_no", position: 0,
        transitions: [
          { target_uuid: "uuid-2", condition: "yes", label: "Yes" }
        ]
      },
      { id: "uuid-2", type: "action", title: "A1", position: 1, transitions: [] }
    ]

    patch sync_steps_workflow_path(@workflow), params: {
      steps: steps_json,
      start_node_uuid: "uuid-1",
      lock_version: @workflow.lock_version
    }, as: :json

    assert_response :success
    assert_equal 1, Transition.where(step_id: step1.id).count
    t = Transition.find_by(step_id: step1.id)
    assert_equal step2.id, t.target_step_id
    assert_equal "yes", t.condition
  end

  test "sync_steps rejects stale lock_version" do
    steps_json = [
      { id: "uuid-1", type: "action", title: "A", position: 0, transitions: [] }
    ]

    # Send a lock_version that doesn't match the current one
    stale_version = @workflow.lock_version + 99

    patch sync_steps_workflow_path(@workflow), params: {
      steps: steps_json,
      start_node_uuid: "uuid-1",
      lock_version: stale_version
    }, as: :json

    assert_response :conflict
    assert_equal 0, @workflow.workflow_steps.reload.count
  end

  test "sync_steps handles empty steps array" do
    Steps::Action.create!(
      workflow: @workflow, uuid: "uuid-1", title: "Existing", position: 0
    )

    patch sync_steps_workflow_path(@workflow), params: {
      steps: [],
      start_node_uuid: nil,
      lock_version: @workflow.lock_version
    }, as: :json

    assert_response :success
    assert_equal 0, @workflow.workflow_steps.reload.count
    assert_nil @workflow.reload.start_step_id
  end

  test "sync_steps returns validation errors" do
    steps_json = [
      { id: "uuid-1", type: "question", title: "No question field",
        answer_type: "yes_no", position: 0, transitions: [] }
    ]

    patch sync_steps_workflow_path(@workflow), params: {
      steps: steps_json,
      start_node_uuid: "uuid-1",
      lock_version: @workflow.lock_version
    }, as: :json

    assert_response :unprocessable_entity
  end

  test "sync_steps requires authentication" do
    sign_out @user

    patch sync_steps_workflow_path(@workflow), params: {
      steps: [], lock_version: 0
    }, as: :json

    assert_response :unauthorized
  end

  test "sync_steps creates steps with transitions in one call" do
    steps_json = [
      {
        id: "start-uuid",
        type: "question",
        title: "Start",
        question: "Continue?",
        answer_type: "yes_no",
        position: 0,
        transitions: [
          { target_uuid: "yes-uuid", condition: "yes", label: "Yes" },
          { target_uuid: "no-uuid", condition: "no", label: "No" }
        ]
      },
      {
        id: "yes-uuid",
        type: "message",
        title: "Yes Path",
        content: "<p>Great!</p>",
        position: 1,
        transitions: []
      },
      {
        id: "no-uuid",
        type: "resolve",
        title: "End",
        resolution_type: "success",
        position: 2,
        transitions: []
      }
    ]

    patch sync_steps_workflow_path(@workflow), params: {
      steps: steps_json,
      start_node_uuid: "start-uuid",
      lock_version: @workflow.lock_version
    }, as: :json

    assert_response :success
    @workflow.reload
    assert_equal 3, @workflow.workflow_steps.count
    start = @workflow.start_step
    assert_equal "Start", start.title
    assert_equal 2, start.transitions.count
  end

  test "sync_steps handles multiple transitions to same target with different conditions" do
    steps_json = [
      {
        id: "q-uuid",
        type: "question",
        title: "Contact Method",
        question: "How?",
        answer_type: "multiple_choice",
        position: 0,
        transitions: [
          { target_uuid: "voice-uuid", condition: "inbound", label: "Inbound" },
          { target_uuid: "voice-uuid", condition: "callback", label: "Callback" }
        ]
      },
      {
        id: "voice-uuid",
        type: "action",
        title: "Voice Instructions",
        position: 1,
        transitions: []
      }
    ]

    patch sync_steps_workflow_path(@workflow), params: {
      steps: steps_json,
      start_node_uuid: "q-uuid",
      lock_version: @workflow.lock_version
    }, as: :json

    assert_response :success
    q_step = Step.find_by(uuid: "q-uuid", workflow_id: @workflow.id)
    assert_equal 2, q_step.transitions.count
  end
end
