require "test_helper"

class Workflows::PinsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(
      email: "pinner-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!"
    )
    @editor = User.create!(
      email: "editor-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(title: "Pinnable Flow", user: @editor, is_public: true)
    sign_in @user
  end

  test "create pins a workflow" do
    assert_difference "UserWorkflowPin.count", 1 do
      post workflow_pin_path(@workflow), as: :turbo_stream
    end
    assert_response :success
    assert @user.pinned_workflows.exists?(@workflow.id)
  end

  test "create returns turbo stream response" do
    post workflow_pin_path(@workflow), as: :turbo_stream
    assert_response :success
    assert_match "turbo-stream", response.content_type
  end

  test "create with HTML fallback redirects" do
    post workflow_pin_path(@workflow)
    assert_response :redirect
  end

  test "create prevents duplicate pins" do
    UserWorkflowPin.create!(user: @user, workflow: @workflow)
    post workflow_pin_path(@workflow)
    assert_redirected_to workflows_path
    assert_equal "User has already been taken", flash[:alert]
  end

  test "create respects pin limit" do
    UserWorkflowPin::MAX_PINS.times do |i|
      wf = Workflow.create!(title: "Flow #{i}", user: @editor, is_public: true)
      UserWorkflowPin.create!(user: @user, workflow: wf)
    end

    extra_wf = Workflow.create!(title: "Over Limit", user: @editor, is_public: true)
    assert_no_difference "UserWorkflowPin.count" do
      post workflow_pin_path(extra_wf)
    end
  end

  test "create returns 404 for invisible workflow" do
    private_wf = Workflow.create!(title: "Private", user: @editor, status: "draft")

    post workflow_pin_path(private_wf), as: :turbo_stream
    assert_response :not_found
  end

  test "destroy unpins a workflow" do
    UserWorkflowPin.create!(user: @user, workflow: @workflow)
    assert_difference "UserWorkflowPin.count", -1 do
      delete workflow_pin_path(@workflow), as: :turbo_stream
    end
    assert_response :success
    assert_not @user.pinned_workflows.exists?(@workflow.id)
  end

  test "destroy returns turbo stream response" do
    UserWorkflowPin.create!(user: @user, workflow: @workflow)
    delete workflow_pin_path(@workflow), as: :turbo_stream
    assert_response :success
    assert_match "turbo-stream", response.content_type
  end

  test "destroy with HTML fallback redirects" do
    UserWorkflowPin.create!(user: @user, workflow: @workflow)
    delete workflow_pin_path(@workflow)
    assert_response :redirect
  end

  test "destroy returns 404 when pin does not exist" do
    delete workflow_pin_path(@workflow), as: :turbo_stream
    assert_response :not_found
  end

  test "requires authentication" do
    sign_out @user
    post workflow_pin_path(@workflow)
    assert_redirected_to new_user_session_path
  end
end
