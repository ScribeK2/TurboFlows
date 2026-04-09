require "test_helper"

class Workflows::FlowDiagramsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @editor = User.create!(
      email: "flow-editor-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(title: "Flow Diagram Flow", user: @editor, is_public: true)
    sign_in @editor
  end

  test "show renders flow diagram panel" do
    get workflow_flow_diagram_path(@workflow)
    assert_response :success
  end

  test "show works with steps present" do
    Steps::Resolve.create!(
      workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
      title: "Done", resolution_type: "success"
    )
    get workflow_flow_diagram_path(@workflow)
    assert_response :success
  end

  test "show requires authentication" do
    sign_out @editor
    get workflow_flow_diagram_path(@workflow)
    assert_redirected_to new_user_session_path
  end

  test "show redirects regular users to player" do
    regular_user = User.create!(
      email: "flow-regular-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )
    sign_in regular_user
    get workflow_flow_diagram_path(@workflow)
    assert_redirected_to play_path
  end
end
