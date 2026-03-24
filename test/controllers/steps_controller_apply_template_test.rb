require "test_helper"

class StepsControllerApplyTemplateTest < ActionDispatch::IntegrationTest
  setup do
    @editor = User.create!(
      email: "apply-template-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(title: "Apply Template Test WF", user: @editor)
    sign_in @editor
  end

  test "apply_template creates steps from template on empty workflow" do
    assert_difference("Step.count", 5) do
      post apply_template_workflow_steps_path(@workflow),
           params: { template_key: "guided_decision" },
           as: :turbo_stream
    end
    assert_response :success

    @workflow.reload
    assert_equal 5, @workflow.steps.count
    assert(@workflow.steps.any?(Steps::Question))
    assert(@workflow.steps.any?(Steps::Resolve))
    assert_predicate @workflow.start_step_id, :present?
  end

  test "apply_template creates transitions between steps" do
    post apply_template_workflow_steps_path(@workflow),
         params: { template_key: "guided_decision" },
         as: :turbo_stream

    @workflow.reload
    transitions = Transition.where(step: @workflow.steps)
    assert_equal 4, transitions.count
  end

  test "apply_template replaces existing steps when workflow has steps" do
    Steps::Question.create!(
      workflow: @workflow,
      title: "Old step",
      position: 1,
      uuid: SecureRandom.uuid
    )

    # Net change is +4: 1 old step destroyed, 5 new steps created
    assert_difference("Step.count", 4) do
      post apply_template_workflow_steps_path(@workflow),
           params: { template_key: "guided_decision" },
           as: :turbo_stream
    end
    assert_response :success

    @workflow.reload
    assert_equal 5, @workflow.steps.count
    assert_not(@workflow.steps.any? { |s| s.title == "Old step" })
  end

  test "apply_template with invalid key returns unprocessable entity" do
    assert_no_difference("Step.count") do
      post apply_template_workflow_steps_path(@workflow),
           params: { template_key: "nonexistent" },
           as: :turbo_stream
    end
    assert_response :unprocessable_entity
  end

  test "apply_template requires edit permission" do
    other_user = User.create!(
      email: "viewer-apply-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )
    sign_in other_user

    post apply_template_workflow_steps_path(@workflow),
         params: { template_key: "guided_decision" },
         as: :turbo_stream
    assert_response :redirect
  end

  test "apply_template returns turbo stream updating step list" do
    post apply_template_workflow_steps_path(@workflow),
         params: { template_key: "guided_decision" },
         as: :turbo_stream
    assert_response :success
    assert_includes response.body, "turbo-stream"
  end

  test "apply_template sets graph_mode to true on the workflow" do
    @workflow.update_column(:graph_mode, false)
    assert_not @workflow.reload.graph_mode

    post apply_template_workflow_steps_path(@workflow),
         params: { template_key: "guided_decision" },
         as: :turbo_stream
    assert_response :success

    @workflow.reload
    assert @workflow.graph_mode
  end
end
