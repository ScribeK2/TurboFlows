# frozen_string_literal: true

require 'test_helper'

class ScenarioExecutionBenchmarkTest < ActiveSupport::TestCase
  include PerformanceHelper

  setup do
    Bullet.enable = false if defined?(Bullet)

    @admin = User.create!(
      email: "bench-admin-#{SecureRandom.hex(4)}@test.com",
      password: 'password123!',
      password_confirmation: 'password123!',
      role: 'admin'
    )
  end

  teardown do
    Bullet.enable = true if defined?(Bullet)
  end

  test 'scenario execution scales linearly with step count' do
    timings = {}

    [10, 50, 100, 200].each do |step_count|
      workflow = build_linear_workflow(step_count)
      scenario = Scenario.create!(
        workflow: workflow,
        user: @admin,
        purpose: 'simulation',
        current_node_uuid: workflow.start_step.uuid,
        execution_path: [],
        results: {},
        inputs: {}
      )

      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      (step_count * 2).times do
        break if scenario.complete? || scenario.stopped?

        step = scenario.current_step
        break unless step

        answer = step.step_type == 'question' ? 'yes' : nil
        scenario.process_step(answer)
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      timings[step_count] = elapsed
    end

    assert_operator timings[200], :<, 5.0,
                    "200-step scenario took #{timings[200].round(3)}s (expected < 5s)"

    if timings[10].positive?
      ratio = timings[200] / timings[10]

      assert_operator ratio, :<, 40.0,
                      "200/10 step ratio is #{ratio.round(1)}x (expected < 40x)"
    end
  end

  test 'step resolver uses constant queries per advance' do
    workflow = build_linear_workflow(20)
    scenario = Scenario.create!(
      workflow: workflow,
      user: @admin,
      purpose: 'simulation',
      current_node_uuid: workflow.start_step.uuid,
      execution_path: [],
      results: {},
      inputs: {}
    )

    # Through ScenarioSettler, because that is what the runner calls. Measuring
    # process_step directly guarded a path production stopped using when
    # traversal moved off GET, and would not have noticed the settler's own
    # per-advance cost at all.
    #
    # Warm up across three steps, not one. build_linear_workflow alternates
    # question/action, and the first advance past an action is the first thing
    # in the process to touch action_text_rich_texts — which drags in SQLite
    # schema introspection (PRAGMA table_xinfo, sqlite_master). That is a
    # one-time cost, so measuring it as though it were per-advance reported 14.
    3.times do
      step = scenario.current_step
      break unless step

      ScenarioSettler.new(scenario).settle(step.step_type == 'question' ? 'yes' : nil)
    end

    queries = count_queries do
      step = scenario.current_step
      ScenarioSettler.new(scenario).settle(step&.step_type == 'question' ? 'yes' : nil) if step
    end

    # 10, not the original 8. Two deliberate changes account for it, each one
    # query and each constant per advance — which is the property this test
    # protects, and it still holds:
    #
    #   +1  capturing an action or message body loads its Action Text record,
    #       and does so even when the step has no body to capture
    #   +1  the settler asks whether the node it landed on is one the user can
    #       answer, which is what moving traversal off GET costs
    #
    # The second is removable if it ever matters: advance_to_next_step already
    # resolves the landing Step and keeps only its uuid, so the engine knows the
    # answer and throws it away. Not worth an engine change for one query.
    assert_operator queries.size, :<=, 10,
                    "Expected <= 10 queries per advance, got #{queries.size}:\n#{queries.join("\n")}"
  end

  test 'scenario creation throughput' do
    workflow = build_linear_workflow(5)

    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    50.times do
      Scenario.create!(
        workflow: workflow,
        user: @admin,
        purpose: 'simulation',
        current_node_uuid: workflow.start_step.uuid,
        execution_path: [],
        results: {},
        inputs: {}
      )
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

    throughput = 50.0 / elapsed

    assert_operator throughput, :>, 20.0,
                    "Expected > 20 scenarios/sec, got #{throughput.round(1)}/sec"
  end

  private

  def build_linear_workflow(step_count)
    workflow = Workflow.create!(title: "Bench #{step_count} Steps", user: @admin, status: 'draft')
    steps = []

    step_count.times do |i|
      steps << if i == step_count - 1
                 Steps::Resolve.create!(
                   workflow: workflow, title: "Resolve #{i}", position: i,
                   resolution_type: 'success'
                 )
               elsif i.even?
                 Steps::Question.create!(
                   workflow: workflow, title: "Question #{i}", position: i,
                   question: "Q#{i}?", answer_type: 'yes_no', variable_name: "q#{i}"
                 )
               else
                 Steps::Action.create!(
                   workflow: workflow, title: "Action #{i}", position: i,
                   action_type: 'Instruction'
                 )
               end
    end

    steps.each_cons(2) do |from, to|
      Transition.create!(step: from, target_step: to, position: 0)
    end

    workflow.update!(start_step: steps.first)
    workflow
  end
end
