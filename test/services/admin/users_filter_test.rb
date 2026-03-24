require "test_helper"

module Admin
  class UsersFilterTest < ActiveSupport::TestCase
    def setup
      @admin = User.create!(email: "filter-admin@test.com", password: "password123!", password_confirmation: "password123!", role: "admin")
      @editor = User.create!(email: "filter-editor@test.com", password: "password123!", password_confirmation: "password123!", role: "editor")
      @regular = User.create!(email: "filter-regular@test.com", password: "password123!", password_confirmation: "password123!", role: "regular")
      @group = Group.create!(name: "Filter Test Group")
      UserGroup.create!(user: @editor, group: @group)
    end

    test "returns all users when no filters" do
      filter = Admin::UsersFilter.new(params: {}).call
      assert_operator filter.total_count, :>=, 3
    end

    test "filters by search query" do
      filter = Admin::UsersFilter.new(params: { q: "filter-admin" }).call
      assert_includes filter.users.map(&:id), @admin.id
      assert_not_includes filter.users.map(&:id), @editor.id
    end

    test "filters by role" do
      filter = Admin::UsersFilter.new(params: { role: "editor" }).call
      assert_includes filter.users.map(&:id), @editor.id
      assert_not_includes filter.users.map(&:id), @admin.id
    end

    test "filters by group" do
      filter = Admin::UsersFilter.new(params: { group: @group.id.to_s }).call
      assert_includes filter.users.map(&:id), @editor.id
      assert_not_includes filter.users.map(&:id), @admin.id
    end

    test "combines filters with AND logic" do
      filter = Admin::UsersFilter.new(params: { role: "editor", group: @group.id.to_s }).call
      assert_includes filter.users.map(&:id), @editor.id
      assert_equal 1, filter.users.where(id: @editor.id).count
    end

    test "paginates with default 25 per page" do
      filter = Admin::UsersFilter.new(params: {}).call
      assert_equal 25, filter.per_page_size
      assert_equal 1, filter.current_page
    end

    test "respects per_page param" do
      filter = Admin::UsersFilter.new(params: { per_page: "50" }).call
      assert_equal 50, filter.per_page_size
    end

    test "invalid per_page defaults to 25" do
      filter = Admin::UsersFilter.new(params: { per_page: "999" }).call
      assert_equal 25, filter.per_page_size
    end

    test "negative page defaults to 1" do
      filter = Admin::UsersFilter.new(params: { page: "-5" }).call
      assert_equal 1, filter.current_page
    end

    test "page beyond total_pages clamps to last page" do
      filter = Admin::UsersFilter.new(params: { page: "9999" }).call
      assert_equal filter.total_pages, filter.current_page
    end

    test "total_pages is at least 1" do
      filter = Admin::UsersFilter.new(params: { q: "xyznotfound9999" }).call
      assert_equal 1, filter.total_pages
    end

    test "sorts by email ascending" do
      filter = Admin::UsersFilter.new(params: { sort: "email_asc" }).call
      emails = filter.users.map(&:email)
      assert_equal emails, emails.sort
    end
  end
end
