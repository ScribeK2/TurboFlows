require "test_helper"

class StepImagesTest < ActionDispatch::IntegrationTest
  def setup
    @user = User.create!(
      email: "step-images-test@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
    sign_in @user
    @workflow = Workflow.create!(
      title: "Image Test Workflow",
      user: @user,
      steps: []
    )
  end

  test "workflow show view renders markdown images in step descriptions" do
    @workflow.update!(steps: [
      {
        "id" => SecureRandom.uuid,
        "type" => "action",
        "title" => "Step with image",
        "description" => "Follow this guide:\n\n![screenshot](https://example.com/guide.png)",
        "instructions" => "Click the button shown in the image:\n\n![button](https://example.com/button.png)"
      }
    ])

    get workflow_path(@workflow)
    assert_response :success
    assert_select "img.step-markdown-image", minimum: 1
  end

  test "scenario step view renders markdown images" do
    @workflow.update!(steps: [
      {
        "id" => SecureRandom.uuid,
        "type" => "message",
        "title" => "Info with image",
        "content" => "See the diagram:\n\n![diagram](https://example.com/diagram.png)"
      }
    ])

    scenario = Scenario.create!(workflow: @workflow, user: @user)
    get step_scenario_path(scenario)
    assert_response :success
    assert_select "img.step-markdown-image"
  end

  test "dangerous image sources are stripped" do
    @workflow.update!(steps: [
      {
        "id" => SecureRandom.uuid,
        "type" => "action",
        "title" => "XSS attempt",
        "description" => "![evil](javascript:alert(1))",
        "instructions" => "![data](data:text/html,<script>alert(1)</script>)"
      }
    ])

    get workflow_path(@workflow)
    assert_response :success
    assert_select "img.step-markdown-image", count: 0
  end
end
