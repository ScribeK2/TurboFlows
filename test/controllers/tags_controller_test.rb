require "test_helper"

class TagsControllerTest < ActionDispatch::IntegrationTest
  fixtures :tags

  setup do
    @admin = User.create!(email: "tagadmin@test.com", password: "password123!", role: "admin")
    @editor = User.create!(email: "tageditor@test.com", password: "password123!", role: "editor")
    @regular = User.create!(email: "taguser@test.com", password: "password123!")
    @workflow = Workflow.create!(title: "Tag Test Flow", user: @admin)
    @tag = tags(:urgent)
  end

  test "any logged-in user can list tags" do
    sign_in @regular
    get tags_path(format: :json)
    assert_response :success
  end

  test "admin can create a tag" do
    sign_in @admin
    assert_difference "Tag.count", 1 do
      post tags_path, params: { tag: { name: "New Tag" } }, as: :turbo_stream
    end
    assert_response :success
  end

  test "editor can create a tag" do
    sign_in @editor
    assert_difference "Tag.count", 1 do
      post tags_path, params: { tag: { name: "Editor Tag" } }, as: :turbo_stream
    end
  end

  test "regular user cannot create a tag" do
    sign_in @regular
    assert_no_difference "Tag.count" do
      post tags_path, params: { tag: { name: "Blocked" } }, as: :turbo_stream
    end
    assert_response :forbidden
  end

  test "creating duplicate tag returns existing tag" do
    sign_in @admin
    assert_no_difference "Tag.count" do
      post tags_path, params: { tag: { name: "Urgent" } }, as: :turbo_stream
    end
    assert_response :success
  end

  test "admin can destroy a tag" do
    sign_in @admin
    assert_difference "Tag.count", -1 do
      delete tag_path(@tag), as: :turbo_stream
    end
  end

  test "regular user cannot destroy a tag" do
    sign_in @regular
    assert_no_difference "Tag.count" do
      delete tag_path(@tag), as: :turbo_stream
    end
    assert_response :forbidden
  end

  test "editor can add tag to workflow" do
    sign_in @editor
    assert_difference "Tagging.count", 1 do
      post add_tag_workflow_path(@workflow), params: { tag_id: @tag.id }, as: :turbo_stream
    end
  end

  test "editor can remove tag from workflow" do
    sign_in @editor
    @workflow.tags << @tag
    assert_difference "Tagging.count", -1 do
      delete remove_tag_workflow_path(@workflow), params: { tag_id: @tag.id }, as: :turbo_stream
    end
  end

  test "regular user cannot add tag to workflow" do
    sign_in @regular
    assert_no_difference "Tagging.count" do
      post add_tag_workflow_path(@workflow), params: { tag_id: @tag.id }, as: :turbo_stream
    end
    assert_response :forbidden
  end
end
