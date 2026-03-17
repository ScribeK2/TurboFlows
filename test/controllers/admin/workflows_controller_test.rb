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
      is_public: false
    )
    Steps::Question.create!(workflow: @workflow, position: 0, title: "Question 1", question: "What is your name?")
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

  test "index paginates workflows" do
    sign_in @admin
    12.times do |i|
      Workflow.create!(title: "Paginated Workflow #{i}", user: @editor)
    end

    get admin_workflows_path
    assert_response :success
    assert_select ".admin-pagination"
  end

  test "index respects per_page parameter" do
    sign_in @admin
    12.times { |i| Workflow.create!(title: "Workflow #{i}", user: @editor) }

    get admin_workflows_path(per_page: 25)
    assert_response :success
    assert_select ".admin-pagination", count: 0
  end

  test "index respects page parameter" do
    sign_in @admin
    12.times { |i| Workflow.create!(title: "Workflow #{i}", user: @editor) }

    get admin_workflows_path(page: 2)
    assert_response :success
  end

  test "admin can delete any workflow" do
    sign_in @admin
    assert_difference("Workflow.count", -1) do
      delete admin_workflow_path(@workflow)
    end
    assert_redirected_to admin_workflows_path
    assert_match(/successfully deleted/, flash[:notice])
  end

  test "non-admin cannot delete workflow via admin route" do
    sign_in @editor
    assert_no_difference("Workflow.count") do
      delete admin_workflow_path(@workflow)
    end
    assert_redirected_to root_path
  end
end
