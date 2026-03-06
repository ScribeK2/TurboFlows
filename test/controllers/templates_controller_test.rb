require "test_helper"

class TemplatesControllerTest < ActionDispatch::IntegrationTest
  def setup
    # Create users with different roles (using unique emails)
    @admin = User.create!(
      email: "admin-template-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    @editor = User.create!(
      email: "editor-template-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @user = User.create!(
      email: "user-template-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )
    @template = Template.create!(
      name: "Test Template",
      description: "A test template",
      category: "post-onboarding",
      is_public: true,
      workflow_data: [{ type: "question", title: "Question 1", question: "What is your name?", answer_type: "text" }]
    )
    @private_template = Template.create!(
      name: "Private Template",
      description: "A private template",
      category: "troubleshooting",
      is_public: false,
      workflow_data: [{ type: "action", title: "Action 1", instructions: "Do something" }]
    )
    sign_in @editor
  end

  test "should get index" do
    get templates_path

    assert_response :success
  end

  test "should get show" do
    get template_path(@template)

    assert_response :success
  end

  test "should search templates" do
    Template.create!(
      name: "Post-Onboarding Checklist",
      category: "post-onboarding",
      is_public: true,
      workflow_data: []
    )
    Template.create!(
      name: "Troubleshooting Guide",
      category: "troubleshooting",
      is_public: true,
      workflow_data: []
    )

    get templates_path, params: { search: "Post-Onboarding" }

    assert_response :success
    assert_select "h3", text: /Post-Onboarding/
  end

  test "should use template to create workflow" do
    assert_difference("Workflow.count") do
      post use_template_path(@template)
    end

    workflow = Workflow.last

    assert_redirected_to edit_workflow_path(workflow)
    assert_includes workflow.title, @template.name
    # Steps may have auto-generated IDs and variable_names, so compare without them
    auto_generated_fields = %w[id variable_name]
    workflow_steps = workflow.steps.map { |s| s.except(*auto_generated_fields) }
    template_steps = @template.workflow_data.map { |s| s.is_a?(Hash) ? s.stringify_keys.except(*auto_generated_fields) : s }

    assert_equal template_steps, workflow_steps
  end

  # Authorization Tests
  test "admin should see all templates in index" do
    sign_in @admin
    get templates_path

    assert_response :success
    # Admin should see both public and private templates
    assert_select "h3", text: /Test Template/
  end

  test "non-admin should see only public templates in index" do
    sign_in @user
    get templates_path

    assert_response :success
    assert_select "h3", text: /Test Template/
    # Should not see private template
    assert_select "h3", text: /Private Template/, count: 0
  end

  test "admin should be able to view private template" do
    sign_in @admin
    get template_path(@private_template)

    assert_response :success
  end

  test "non-admin should not be able to view private template" do
    sign_in @user
    get template_path(@private_template)

    assert_redirected_to templates_path
    assert_equal "You don't have permission to view this template.", flash[:alert]
  end

  test "admin should be able to use template" do
    sign_in @admin
    assert_difference("Workflow.count") do
      post use_template_path(@template)
    end
    assert_redirected_to edit_workflow_path(Workflow.last)
  end

  test "editor should be able to use template" do
    sign_in @editor
    assert_difference("Workflow.count") do
      post use_template_path(@template)
    end
    assert_redirected_to edit_workflow_path(Workflow.last)
  end

  test "user should not be able to use template" do
    sign_in @user
    assert_no_difference("Workflow.count") do
      post use_template_path(@template)
    end
    assert_redirected_to root_path
    assert_equal "You don't have permission to perform this action.", flash[:alert]
  end

  # Visibility check for use action
  test "editor should not be able to use private template" do
    sign_in @editor
    assert_no_difference("Workflow.count") do
      post use_template_path(@private_template)
    end
    assert_redirected_to templates_path
    assert_equal "You don't have permission to use this template.", flash[:alert]
  end

  test "admin should be able to use private template" do
    sign_in @admin
    assert_difference("Workflow.count") do
      post use_template_path(@private_template)
    end
    assert_redirected_to edit_workflow_path(Workflow.last)
  end
end
