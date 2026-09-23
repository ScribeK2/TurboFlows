require "test_helper"

# One Step::Doors per step and one visit per edge: the walk is linear. The
# 53-step Opening Scan took 13 ms including its query with the prototype's
# costlier rule. This guards a workflow six times that size.
class StepOutlineBenchmarkTest < ActiveSupport::TestCase
  STEPS = 300

  setup do
    @user = User.create!(email: "bench-#{SecureRandom.hex(4)}@example.com", password: "password123456")
    @workflow = Workflow.create!(title: "Bench", user: @user)
    steps = (0...STEPS).map do |i|
      Steps::Question.create!(workflow: @workflow, title: "Q#{i}", position: i, answer_type: "yes_no", variable_name: "q#{i}")
    end
    done = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: STEPS)
    steps.each_with_index do |step, i|
      Transition.create!(step: step, target_step: steps[[i + 7, STEPS - 1].min], condition: "q#{i} == 'yes'", position: 0)
      Transition.create!(step: step, target_step: steps[i + 1] || done, condition: "q#{i} == 'no'", position: 1)
    end
    @workflow.update_columns(start_step_id: steps.first.id)
  end

  test "a 300-step, 600-edge outline builds in under 100ms" do
    steps = @workflow.steps.ordered.includes(transitions: :target_step).to_a
    StepOutline.call(@workflow, steps) # warm
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = StepOutline.call(@workflow, steps)
    result.ordinals
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :<, 0.1, "outline took #{(elapsed * 1000).round}ms"
  end
end
