require "test_helper"

class Workflows::TaggingsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @editor = User.create!(
      email: "taggings-editor-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(title: "Tagged Flow", user: @editor, is_public: true)
    @tag = Tag.create!(name: "test-tag-#{SecureRandom.hex(4)}")
    sign_in @editor
  end

  test "create adds tag to workflow" do
    assert_difference "Tagging.count", 1 do
      post workflow_taggings_path(@workflow), params: { tag_id: @tag.id }, as: :turbo_stream
    end
    assert_response :success
    assert @workflow.tags.include?(@tag)
  end

  test "create prevents duplicate taggings" do
    @workflow.tags << @tag
    assert_no_difference "Tagging.count" do
      post workflow_taggings_path(@workflow), params: { tag_id: @tag.id }, as: :turbo_stream
    end
    assert_response :success
  end

  test "destroy removes tag from workflow" do
    @workflow.tags << @tag
    assert_difference "Tagging.count", -1 do
      delete workflow_tagging_path(@workflow, tag_id: @tag.id), as: :turbo_stream
    end
    assert_response :success
    assert_not @workflow.tags.include?(@tag)
  end

  test "create requires authentication" do
    sign_out @editor
    post workflow_taggings_path(@workflow), params: { tag_id: @tag.id }
    assert_redirected_to new_user_session_path
  end

  test "create forbidden for regular users" do
    regular_user = User.create!(
      email: "taggings-regular-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )
    sign_in regular_user
    post workflow_taggings_path(@workflow), params: { tag_id: @tag.id }
    assert_response :forbidden
  end
end
