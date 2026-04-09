require "test_helper"

class Workflows::SharesControllerTest < ActionDispatch::IntegrationTest
  def setup
    Bullet.enable = false
    @editor = User.create!(
      email: "editor-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(title: "Shareable Flow", user: @editor)
    sign_in @editor
  end

  def teardown
    Bullet.enable = true
  end

  test "create generates share token" do
    assert_nil @workflow.share_token

    post workflow_share_path(@workflow)

    assert_redirected_to workflow_path(@workflow)
    assert_match(/share link generated/i, flash[:notice])
    assert @workflow.reload.share_token.present?
  end

  test "destroy revokes share token" do
    @workflow.generate_share_token!
    assert @workflow.share_token.present?

    delete workflow_share_path(@workflow)

    assert_redirected_to workflow_path(@workflow)
    assert_match(/share link revoked/i, flash[:notice])
    assert_nil @workflow.reload.share_token
  end

  test "create requires authentication" do
    sign_out @editor
    post workflow_share_path(@workflow)

    assert_redirected_to new_user_session_path
  end
end
