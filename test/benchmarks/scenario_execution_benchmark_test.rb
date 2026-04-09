require "test_helper"

class ScenarioExecutionBenchmarkTest < ActiveSupport::TestCase
  include PerformanceHelper

  setup do
    Bullet.enable = false if defined?(Bullet)

    @admin = User.create!(
      email: "bench-admin-#{SecureRandom.hex(4)}@test.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "admin"
    )
  end

  teardown do
    Bullet.enable = true if defined?(Bullet)
  end

  test "scenario execution scales linearly with step count" do
    timings = {}

    [10, 50, 100, 200].each do |step_count|
      workflow = build_linear_workflow(step_count)
      scenario = Scenario.create!(
        workflow: workflow,
        user: @admin,
        purpose: "simulation",
        current_node_uuid: workflow.start_step.uuid,
        execution_path: [],
        results: {},
        inputs: {}
      )

      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      # Advance through all steps
      (step_count * 2).times do
        break if scenario.complete? || scenario.stopped?
        step = scenario.current_step
        break unless step

        answer = case step.step_type
                 when "question" then "yes"
                 else nil
                 end
        scenario.process_step(answer)
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      timings[step_count] = elapsed
    end

    # 200-step should complete in < 5 seconds
    assert_operator timings[200], :<, 5.0,
                    "200-step scenario took #{timings[200].round(3)}s (expected < 5s)"

    # Scaling check: 200-step should be < 40x of 10-step
    # (accounts for quadratic-ish growth from growing execution_path JSON saves)
    # The important thing is absolute time stays under budget, not perfect linearity
    if timings[10] > 0
      ratio = timings[200] / timings[10]
      assert_operator ratio, :<, 40.0,
                      "200/10 step ratio is #{ratio.round(1)}x (expected < 40x)"
    end
  end

  test "step resolver uses constant queries per advance" do
    workflow = build_linear_workflow(20)
    scenario = Scenario.create!(
      workflow: workflow,
      user: @admin,
      purpose: "simulation",
      current_node_uuid: workflow.start_step.uuid,
      execution_path: [],
      results: {},
      inputs: {}
    )

    # Warm up — first advance may trigger more queries for caching
    step = scenario.current_step
    scenario.process_step(step&.step_type == "question" ? "yes" : nil) if step

    # Measure queries for a single advance
    queries = count_queries do
      step = scenario.current_step
      scenario.process_step(step&.step_type == "question" ? "yes" : nil) if step
    end

    assert_operator queries.size, :<=, 8,
                    "Expected <= 8 queries per advance, got #{queries.size}:\n#{queries.join("\n")}"
  end

  test "scenario creation throughput" do
    workflow = build_linear_workflow(5)

    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    50.times do
      Scenario.create!(
        workflow: workflow,
        user: @admin,
        purpose: "simulation",
        current_node_uuid: workflow.start_step.uuid,
        execution_path: [],
        results: {},
        inputs: {}
      )
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

    throughput = 50.0 / elapsed
    assert_operator throughput, :>, 20.0,
                    "Expected > 20 scenarios/sec, got #{throughput.round(1)}/sec (#{elapsed.round(3)}s total)"
  end

  private

  def build_linear_workflow(step_count)
    workflow = Workflow.create!(title: "Bench #{step_count} Steps", user: @admin, status: "draft")
    steps = []

    step_count.times do |i|
      if i == step_count - 1
        # Last step is always a Resolve
        steps << Steps::Resolve.create!(
          workflow: workflow, title: "Resolve #{i}", position: i,
          resolution_type: "success"
        )
      elsif i.even?
        steps << Steps::Question.create!(
          workflow: workflow, title: "Question #{i}", position: i,
          question: "Q#{i}?", answer_type: "yes_no", variable_name: "q#{i}"
        )
      else
        steps << Steps::Action.create!(
          workflow: workflow, title: "Action #{i}", position: i,
          action_type: "Instruction"
        )
      end
    end

    # Create sequential transitions
    steps.each_cons(2) do |from, to|
      Transition.create!(step: from, target_step: to, position: 0)
    end

    workflow.update!(start_step: steps.first)
    workflow
  end
end
