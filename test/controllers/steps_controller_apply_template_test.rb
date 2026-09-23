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
    # The list-level "An existing step…" dialog sits beside #steps-list, so its
    # candidates are re-streamed or it would offer only the replaced steps.
    assert_select "turbo-stream[action='replace'][target='list-target-picker-options']"
  end

  # A template is a worked example: applied to an empty workflow it must run.
  # Checking its shape (fields present, transitions naming real steps) passed
  # while three of five templates dead-ended every run: their Yes/No
  # questions carried custom option values (fixed/still_broken, passed/failed,
  # can_handle/needs_handoff) that a Yes/No answer never sends - the runner
  # offers "yes" and "no", and Step::Doors wires Yes/No doors on those - so
  # the connections never fired (QA D-001, 2026-09-23). So this applies each
  # template through the real endpoint and walks every answer of every
  # question with StepResolver, the runner's own routing, down to a Resolve.
  #
  # The one health issue a freshly applied template is allowed is
  # :no_audience - a new workflow has no groups yet.
  #
  # Mutation check: put `condition: fixed` back on a df-q2 transition in
  # config/templates.yml - red on diagnosis_flow.
  WorkflowTemplate.all.each_key do |key|
    test "the #{key} template runs down every answer to a Resolve and applies without warnings" do
      post apply_template_workflow_steps_path(@workflow), params: { template_key: key }, as: :turbo_stream
      assert_response :success
      @workflow.reload

      issues = WorkflowHealthCheck.call(@workflow).issues.values.flatten.pluck(:code).uniq
      assert_equal [:no_audience], issues.map(&:to_sym), "#{key} applied with health issues: #{issues.inspect}"

      walk_every_answer(@workflow.start_step, {}, [], key)
    end
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
    assert_response :unprocessable_content
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

  private

  # Depth-first over every answer a run can give. A Question branches on each
  # of its answers (its answer doors' values - what the runner sends); any
  # other step has one way on. Every path must end on a Resolve: a nil or a
  # StepResolver::NoMatch is the run stopping with "no step for that answer".
  def walk_every_answer(step, results, path, key)
    assert_operator path.size, :<, 50, "#{key}: a path never ended: #{path.join(' → ')}"
    path += [step.title]
    return if step.is_a?(Steps::Resolve)

    answers = step.is_a?(Steps::Question) ? Step::Doors.for(step).doors.select { |door| door.kind == :answer }.map(&:value) : [nil]
    answers = [nil] if answers.empty?
    answers.each do |value|
      given = value.nil? ? results : results.merge(step.variable_name.to_s => value)
      following = StepResolver.new(@workflow).resolve_next(step, given)
      assert_kind_of Step, following,
                     "#{key}: the run stops at “#{step.title}” on #{value.inspect} (path: #{path.join(' → ')})"
      walk_every_answer(following, given, path, key)
    end
  end
end
