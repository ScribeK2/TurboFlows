require "test_helper"

class PlayerSharingTest < ActionDispatch::IntegrationTest
  setup do
    @admin = User.create!(
      email: "shareadmin-#{SecureRandom.hex(4)}@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    @workflow = Workflow.create!(title: "Shared Flow", user: @admin, status: "published")
    step = Steps::Resolve.create!(
      workflow: @workflow,
      title: "Done",
      uuid: SecureRandom.uuid,
      position: 0,
      resolution_type: "success"
    )
    @workflow.update!(start_step: step)
    WorkflowPublisher.publish(@workflow, @admin)
  end

  test "workflow can generate share token" do
    @workflow.generate_share_token!
    assert_predicate @workflow.share_token, :present?
    assert_equal 24, @workflow.share_token.length
  end

  test "workflow can revoke share token" do
    @workflow.generate_share_token!
    @workflow.revoke_share_token!
    assert_nil @workflow.share_token
  end

  test "shared link accessible without login" do
    @workflow.generate_share_token!
    get shared_player_path(share_token: @workflow.share_token)
    assert_response :redirect
  end

  test "invalid share token returns 404" do
    get shared_player_path(share_token: "invalid-token-here")
    assert_response :not_found
  end

  test "shared scenario step accessible without login" do
    @workflow.generate_share_token!
    get shared_player_path(share_token: @workflow.share_token)
    assert_response :redirect
    follow_redirect!
    assert_response :success
  end

  test "non-published workflow share token returns 404" do
    draft = Workflow.create!(title: "Draft Flow", user: @admin, status: "draft")
    draft.update_column(:share_token, SecureRandom.urlsafe_base64(18))
    get shared_player_path(share_token: draft.share_token)
    assert_response :not_found
  end
end
