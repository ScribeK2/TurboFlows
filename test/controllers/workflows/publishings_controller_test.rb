require "test_helper"

class Workflows::PublishingsControllerTest < ActionDispatch::IntegrationTest
  def setup
    Bullet.enable = false
    @editor = User.create!(
      email: "editor-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(title: "Publishable Flow", user: @editor)
    sign_in @editor
  end

  def teardown
    Bullet.enable = true
  end

  test "create publishes workflow with resolve step" do
    q = Steps::Question.create!(
      workflow: @workflow, uuid: SecureRandom.uuid, position: 0,
      title: "Ask", question: "What?", answer_type: "text"
    )
    r = Steps::Resolve.create!(
      workflow: @workflow, uuid: SecureRandom.uuid, position: 1,
      title: "Done", resolution_type: "success"
    )
    Transition.create!(step: q, target_step: r, position: 0)
    @workflow.update!(start_step: q)

    assert_difference "WorkflowVersion.count", 1 do
      post workflow_publishing_path(@workflow)
    end

    assert_redirected_to workflow_path(@workflow)
    assert_match(/published/i, flash[:notice])
    assert_equal "published", @workflow.reload.status
  end

  test "create without steps returns error" do
    post workflow_publishing_path(@workflow)

    assert_redirected_to workflow_path(@workflow)
    assert_match(/failed to publish/i, flash[:alert])
  end

  test "create requires authentication" do
    sign_out @editor
    post workflow_publishing_path(@workflow)

    assert_redirected_to new_user_session_path
  end
end
