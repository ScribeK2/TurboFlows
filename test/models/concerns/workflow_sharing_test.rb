require "test_helper"

class WorkflowSharingTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "sharing-#{SecureRandom.hex(4)}@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(title: "Sharing Flow", user: @user)
  end

  test "generate_share_token! creates a token" do
    assert_nil @workflow.share_token
    @workflow.generate_share_token!
    assert_predicate @workflow.reload.share_token, :present?
    assert_operator @workflow.share_token.length, :>=, 10
  end

  test "generate_share_token! changes token on each call" do
    @workflow.generate_share_token!
    first_token = @workflow.share_token
    @workflow.generate_share_token!
    second_token = @workflow.reload.share_token
    refute_equal first_token, second_token
  end

  test "revoke_share_token! clears the token" do
    @workflow.generate_share_token!
    assert_predicate @workflow.share_token, :present?

    @workflow.revoke_share_token!
    assert_nil @workflow.reload.share_token
  end

  test "shared? returns true when token is present" do
    refute_predicate @workflow, :shared?

    @workflow.generate_share_token!
    assert_predicate @workflow, :shared?
  end

  test "shared? returns false after revocation" do
    @workflow.generate_share_token!
    @workflow.revoke_share_token!
    refute_predicate @workflow, :shared?
  end

  test "embeddable? returns true when shared and embed_enabled" do
    @workflow.generate_share_token!
    @workflow.update!(embed_enabled: true)
    assert_predicate @workflow, :embeddable?
  end

  test "embeddable? returns false when shared but embed_enabled is false" do
    @workflow.generate_share_token!
    refute_predicate @workflow, :embeddable?
  end

  test "embeddable? returns false when not shared even if embed_enabled" do
    @workflow.update!(embed_enabled: true)
    refute_predicate @workflow, :embeddable?
  end

  test "embeddable? returns false when neither shared nor embed_enabled" do
    refute_predicate @workflow, :embeddable?
  end
end
