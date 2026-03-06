require "test_helper"

class Admin::WorkflowsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(
      email: "admin-wf-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    @editor = User.create!(
      email: "editor-wf-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(
      title: "Test Workflow",
      description: "A test workflow",
      user: @editor,
      is_public: false,
      steps: [{ type: "question", title: "Question 1", question: "What is your name?" }]
    )
  end

  test "admin should be able to access workflow management" do
    sign_in @admin
    get admin_workflows_path

    assert_response :success
  end

  test "non-admin should not be able to access workflow management" do
    sign_in @editor
    get admin_workflows_path

    assert_redirected_to root_path
    assert_equal "You don't have permission to access this page.", flash[:alert]
  end

  test "admin should be able to view any workflow" do
    sign_in @admin
    get admin_workflow_path(@workflow)

    assert_response :success
  end
end
