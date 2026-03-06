require "test_helper"

class Admin::TemplatesControllerTest < ActionDispatch::IntegrationTest
  def setup
    @admin = User.create!(
      email: "admin-tmpl-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    @editor = User.create!(
      email: "editor-tmpl-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @template = Template.create!(
      name: "Test Template",
      description: "A test template",
      category: "post-onboarding",
      is_public: true,
      workflow_data: [{ type: "question", title: "Question 1" }]
    )
  end

  test "admin should be able to access template management" do
    sign_in @admin
    get admin_templates_path

    assert_response :success
  end

  test "non-admin should not be able to access template management" do
    sign_in @editor
    get admin_templates_path

    assert_redirected_to root_path
    assert_equal "You don't have permission to access this page.", flash[:alert]
  end

  test "admin should be able to create template" do
    sign_in @admin
    get new_admin_template_path

    assert_response :success
  end

  test "admin should be able to edit template" do
    sign_in @admin
    get edit_admin_template_path(@template)

    assert_response :success
  end

  test "admin should be able to delete template" do
    sign_in @admin
    assert_difference("Template.count", -1) do
      delete admin_template_path(@template)
    end
    assert_redirected_to admin_templates_path
  end
end
