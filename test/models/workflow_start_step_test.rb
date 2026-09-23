require "test_helper"

# Workflow#destroy_step hands a deleted start to the step it continued into
# (QA B-005). Workflow#assign_start_step is the fallback both it and GrowStep use.
class WorkflowStartStepTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "start-step-#{SecureRandom.hex(4)}@example.com", password: "password123!", role: "editor")
    @workflow = Workflow.create!(title: "Start step", user: @user)
  end

  # "Start?" Yes → Side, No → Mid → End; Side has the lowest position after it.
  def trunk_under_no
    @start = Steps::Question.create!(workflow: @workflow, title: "Start?", position: 0, answer_type: "yes_no", variable_name: "s")
    @side = Steps::Action.create!(workflow: @workflow, title: "Side", position: 1)
    @mid = Steps::Action.create!(workflow: @workflow, title: "Mid", position: 2)
    @finish = Steps::Resolve.create!(workflow: @workflow, title: "End", position: 3)
    @yes = Transition.create!(step: @start, target_step: @side, condition: "s == 'yes'", position: 0)
    @no = Transition.create!(step: @start, target_step: @mid, condition: "s == 'no'", position: 1)
    Transition.create!(step: @side, target_step: @finish)
    Transition.create!(step: @mid, target_step: @finish)
    @workflow.update_columns(start_step_id: @start.id)
  end

  def destroy_start
    @workflow.destroy_step(@start)
    @workflow.reload.start_step
  end

  test "the start passes to its continuation, the last door's target" do
    trunk_under_no
    assert_equal @mid, destroy_start
  end

  test "a stub last door hands the start to the nearest wired door before it" do
    trunk_under_no
    @no.destroy
    @yes.update_columns(target_step_id: @finish.id) # not the lowest position
    assert_equal @finish, destroy_start
  end

  test "a last door back to the start itself is skipped for the wired door before it" do
    trunk_under_no
    @no.update_columns(target_step_id: @start.id)
    @yes.update_columns(target_step_id: @finish.id) # not the lowest position
    assert_equal @finish, destroy_start
  end

  test "every door a stub falls back to the first step by position" do
    trunk_under_no
    @yes.destroy
    @no.destroy
    assert_equal @side, destroy_start
  end

  test "a Resolve successor becomes the start" do
    only = Steps::Action.create!(workflow: @workflow, title: "Only", position: 0)
    later = Steps::Action.create!(workflow: @workflow, title: "Later", position: 1)
    finish = Steps::Resolve.create!(workflow: @workflow, title: "End", position: 2)
    Transition.create!(step: only, target_step: finish)
    @workflow.update_columns(start_step_id: only.id)
    @start = only

    assert_equal finish, destroy_start
    assert_not_equal later, @workflow.start_step
  end

  test "a start with no doors (a Resolve) falls back to the first step by position" do
    @start = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 0)
    other = Steps::Action.create!(workflow: @workflow, title: "Other", position: 1)
    @workflow.update_columns(start_step_id: @start.id)

    assert_equal other, destroy_start
  end

  test "deleting the only step leaves no start" do
    @start = Steps::Action.create!(workflow: @workflow, title: "Only", position: 0)
    @workflow.update_columns(start_step_id: @start.id)

    assert_nil destroy_start
    assert_equal 0, @workflow.steps.count
  end

  test "deleting a step that is not the start leaves the start alone" do
    trunk_under_no
    @workflow.destroy_step(@side)
    assert_equal @start, @workflow.reload.start_step
  end

  test "assign_start_step does nothing while a start is set, and takes the first by position when not" do
    trunk_under_no
    @workflow.assign_start_step(prefer: [@mid.id])
    assert_equal @start, @workflow.reload.start_step

    @workflow.update_columns(start_step_id: nil)
    @workflow.assign_start_step
    assert_equal @start, @workflow.reload.start_step
  end
end
