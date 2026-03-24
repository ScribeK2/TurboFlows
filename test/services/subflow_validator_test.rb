require "test_helper"

class SubflowValidatorTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "subflow-val-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
  end

  test "valid for workflow with no sub-flows" do
    wf = Workflow.create!(title: "No Subflows", user: @user)
    Steps::Action.create!(workflow: wf, position: 0, title: "Action 1")
    validator = SubflowValidator.new(wf.id)
    assert_predicate validator, :valid?
    assert_empty validator.errors
  end

  test "valid for workflow with non-circular sub-flow" do
    child_wf = Workflow.create!(title: "Child", user: @user, status: "published", is_public: true)
    Steps::Action.create!(workflow: child_wf, position: 0, title: "Child Action")
    parent_wf = Workflow.create!(title: "Parent", user: @user)
    Steps::SubFlow.create!(workflow: parent_wf, position: 0, title: "Call Child", sub_flow_workflow_id: child_wf.id)
    assert SubflowValidator.valid?(parent_wf.id)
  end

  test "detects simple circular reference A to B to A" do
    wf_a = Workflow.create!(title: "Workflow A", user: @user)
    wf_b = Workflow.create!(title: "Workflow B", user: @user)
    Steps::SubFlow.create!(workflow: wf_a, position: 0, title: "Call B", sub_flow_workflow_id: wf_b.id)
    Steps::SubFlow.create!(workflow: wf_b, position: 0, title: "Call A", sub_flow_workflow_id: wf_a.id)
    validator = SubflowValidator.new(wf_a.id)
    assert_not validator.valid?
    assert(validator.errors.any? { |e| e.include?("Circular sub-flow reference") })
  end

  test "detects chain circular reference A to B to C to A" do
    wf_a = Workflow.create!(title: "WF A", user: @user)
    wf_b = Workflow.create!(title: "WF B", user: @user)
    wf_c = Workflow.create!(title: "WF C", user: @user)
    Steps::SubFlow.create!(workflow: wf_a, position: 0, title: "Call B", sub_flow_workflow_id: wf_b.id)
    Steps::SubFlow.create!(workflow: wf_b, position: 0, title: "Call C", sub_flow_workflow_id: wf_c.id)
    Steps::SubFlow.create!(workflow: wf_c, position: 0, title: "Call A", sub_flow_workflow_id: wf_a.id)
    validator = SubflowValidator.new(wf_a.id)
    assert_not validator.valid?
    assert(validator.errors.any? { |e| e.include?("Circular sub-flow reference") })
  end

  test "reports non-existent target workflow" do
    wf = Workflow.create!(title: "Missing Target", user: @user)
    # Bypass model validations to insert a sub-flow step pointing to a non-existent workflow.
    # Must supply a UUID manually because before_validation is skipped with validate: false.
    step = Steps::SubFlow.new(workflow: wf, position: 0, title: "Call Ghost",
                              sub_flow_workflow_id: 999_999, uuid: SecureRandom.uuid)
    step.save(validate: false)
    validator = SubflowValidator.new(wf.id)
    assert_not validator.valid?
    assert(validator.errors.any? { |e| e.include?("non-existent workflow") })
  end

  test "detects exceeding MAX_DEPTH" do
    workflows = Array.new(12) { |i| Workflow.create!(title: "Depth #{i}", user: @user) }
    workflows.each_cons(2) do |parent, child|
      Steps::SubFlow.create!(workflow: parent, position: 0, title: "Call Next", sub_flow_workflow_id: child.id)
    end
    Steps::Action.create!(workflow: workflows.last, position: 0, title: "End")
    validator = SubflowValidator.new(workflows.first.id)
    assert_not validator.valid?
    assert(validator.errors.any? { |e| e.include?("maximum depth") })
  end

  test "detects self-reference" do
    wf = Workflow.create!(title: "Self Ref", user: @user, status: "published")
    step = Steps::SubFlow.new(workflow: wf, position: 0, title: "Run self",
                              sub_flow_workflow_id: wf.id, uuid: SecureRandom.uuid)
    step.save(validate: false)
    validator = SubflowValidator.new(wf.id)
    assert_not validator.valid?
    assert(validator.errors.any? { |e| e.include?("Circular") })
  end

  test "class methods valid? and errors_for work" do
    wf = Workflow.create!(title: "Class Method Test", user: @user)
    Steps::Action.create!(workflow: wf, position: 0, title: "A1")
    assert SubflowValidator.valid?(wf.id)
    assert_empty SubflowValidator.errors_for(wf.id)
  end
end
