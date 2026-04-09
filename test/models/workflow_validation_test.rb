require "test_helper"

class WorkflowValidationTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "wf-validation-#{SecureRandom.hex(4)}@example.com", password: "password123456")
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def create_workflow(title, status: "published", **attrs)
    Workflow.create!(title: title, user: @user, status: status, **attrs)
  end

  def add_question(workflow, title, position:, variable_name: nil)
    Steps::Question.create!(
      workflow: workflow,
      title: title,
      position: position,
      question: "#{title}?",
      variable_name: variable_name || title.parameterize(separator: "_")
    )
  end

  def add_resolve(workflow, title, position:)
    Steps::Resolve.create!(workflow: workflow, title: title, position: position, resolution_type: "success")
  end

  def add_subflow(workflow, title, position:, target_workflow:)
    Steps::SubFlow.create!(
      workflow: workflow,
      title: title,
      position: position,
      sub_flow_workflow_id: target_workflow.id
    )
  end

  def link(from_step, to_step, condition: nil, position: 0)
    Transition.create!(step: from_step, target_step: to_step, condition: condition, position: position)
  end

  # ---------------------------------------------------------------------------
  # Basic validations
  # ---------------------------------------------------------------------------

  test "requires title" do
    wf = Workflow.new(user: @user, status: "published")
    assert_not wf.valid?
    assert_includes wf.errors[:title], "can't be blank"
  end

  test "requires user" do
    wf = Workflow.new(title: "No user", status: "published")
    assert_not wf.valid?
    assert_includes wf.errors[:user], "must exist"
  end

  test "title length max 255" do
    wf = Workflow.new(title: "x" * 256, user: @user, status: "published")
    assert_not wf.valid?
    assert(wf.errors[:title].any? { |e| e.include?("too long") })
  end

  # ---------------------------------------------------------------------------
  # Draft mode allows incomplete workflow
  # ---------------------------------------------------------------------------

  test "draft with no steps is valid" do
    wf = Workflow.new(title: "Empty Draft", user: @user, status: "draft")
    assert_predicate wf, :valid?, "Draft with no steps should be valid: #{wf.errors.full_messages.join(', ')}"
  end

  test "draft skips graph structure validation" do
    wf = create_workflow("Draft WF", status: "draft")
    # Add a question step with no transitions (orphan) — no resolve either
    add_question(wf, "Floating Q", position: 0)

    # Re-save — should not error because draft skips graph validation
    wf.reload
    assert_predicate wf, :valid?, "Draft should skip graph validation: #{wf.errors.full_messages.join(', ')}"
  end

  # ---------------------------------------------------------------------------
  # Optimistic locking
  # ---------------------------------------------------------------------------

  test "stale lock_version raises StaleObjectError" do
    wf = create_workflow("Lockable")

    # Simulate concurrent edit
    stale = Workflow.find(wf.id)
    wf.update!(title: "Updated by first editor")

    assert_raises ActiveRecord::StaleObjectError do
      stale.update!(title: "Updated by second editor")
    end
  end

  # ---------------------------------------------------------------------------
  # Graph validation on publish
  # ---------------------------------------------------------------------------

  test "published workflow with disconnected steps is invalid" do
    wf = create_workflow("Graph Validation", status: "draft")
    q = add_question(wf, "Start", position: 0)
    add_resolve(wf, "End", position: 1)
    # No transition linking q -> r — they are disconnected
    wf.update!(start_step: q)

    # Force graph validation via validate_graph_now!
    wf.validate_graph_now!
    assert_not wf.valid?, "Disconnected graph should be invalid"
    assert_predicate wf.errors[:steps], :any?, "Should have step errors for disconnected graph"
  end

  test "published workflow with connected graph is valid" do
    wf = create_workflow("Valid Graph")
    q = add_question(wf, "Start", position: 0)
    r = add_resolve(wf, "End", position: 1)
    link(q, r)
    wf.update!(start_step: q)

    wf.reload
    assert_predicate wf, :valid?, "Connected graph should be valid: #{wf.errors.full_messages.join(', ')}"
  end

  test "validate_graph_now! forces validation on draft" do
    wf = create_workflow("Force Validate Draft", status: "draft")
    q = add_question(wf, "Orphan", position: 0)
    add_resolve(wf, "End", position: 1)
    wf.update_column(:start_step_id, q.id)

    wf.reload
    wf.validate_graph_now!
    assert_not wf.valid?, "validate_graph_now! should force graph validation on draft"
  end

  # ---------------------------------------------------------------------------
  # SubFlow validations
  # ---------------------------------------------------------------------------

  test "subflow step pointing to nonexistent workflow is invalid" do
    wf = create_workflow("SubFlow Missing Target")
    Steps::SubFlow.create!(
      workflow: wf,
      title: "Bad SubFlow",
      position: 0,
      sub_flow_workflow_id: 999_999
    )

    wf.reload
    assert_not wf.valid?
    assert wf.errors[:steps].any? { |e| e.include?("does not exist") },
           "Should report missing target workflow: #{wf.errors[:steps].inspect}"
  end

  test "subflow step cannot reference itself" do
    wf = create_workflow("Self-referencing")
    Steps::SubFlow.create!(
      workflow: wf,
      title: "Self Ref",
      position: 0,
      sub_flow_workflow_id: wf.id
    )

    wf.reload
    assert_not wf.valid?
    assert wf.errors[:steps].any? { |e| e.include?("cannot reference itself") },
           "Should detect self-referencing subflow: #{wf.errors[:steps].inspect}"
  end

  test "circular subflow references are detected" do
    wf_a = create_workflow("WF A")
    wf_b = create_workflow("WF B")

    # A has subflow -> B
    r_a = add_resolve(wf_a, "Resolve A", position: 1)
    sf_a = add_subflow(wf_a, "Call B", position: 0, target_workflow: wf_b)
    link(sf_a, r_a)

    # B has subflow -> A (creating circular reference)
    r_b = add_resolve(wf_b, "Resolve B", position: 1)
    sf_b = add_subflow(wf_b, "Call A", position: 0, target_workflow: wf_a)
    link(sf_b, r_b)

    wf_a.reload
    assert_not wf_a.valid?, "Circular subflow should be invalid"
    assert wf_a.errors[:steps].any? { |e| e.include?("Circular") },
           "Should detect circular subflow: #{wf_a.errors[:steps].inspect}"
  end

  # ---------------------------------------------------------------------------
  # Status enum
  # ---------------------------------------------------------------------------

  test "status defaults to published" do
    wf = Workflow.new(title: "Default Status", user: @user)
    assert_equal "published", wf.status
  end

  test "draft sets expiration" do
    wf = create_workflow("Expiring Draft", status: "draft")
    assert_not_nil wf.draft_expires_at
    assert_operator wf.draft_expires_at, :>, Time.current
  end
end
