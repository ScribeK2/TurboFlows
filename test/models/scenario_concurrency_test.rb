# frozen_string_literal: true

require 'test_helper'

class ScenarioConcurrencyTest < ActiveSupport::TestCase
  def setup
    @user = User.create!(
      email: "concurrency-scenario-#{SecureRandom.hex(4)}@test.com",
      password: 'password123!',
      password_confirmation: 'password123!',
      role: 'editor'
    )
    @workflow = Workflow.create!(title: 'Concurrency Test', user: @user)
    @question = Steps::Question.create!(
      workflow: @workflow,
      uuid: SecureRandom.uuid,
      position: 0,
      title: 'Q1',
      question: 'What?',
      answer_type: 'text',
      variable_name: 'v1'
    )
    @resolve = Steps::Resolve.create!(
      workflow: @workflow,
      uuid: SecureRandom.uuid,
      position: 1,
      title: 'Done',
      resolution_type: 'success'
    )
    Transition.create!(step: @question, target_step: @resolve, position: 0)
    @workflow.update!(start_step: @question)
  end

  def teardown
    Scenario.where(user: @user).delete_all
    @workflow.destroy
    @user.destroy
  end

  test 'lock_version increments on scenario save' do
    scenario = create_scenario
    initial = scenario.lock_version

    scenario.update!(stopped_at_step_index: 42)

    assert_equal initial + 1, scenario.lock_version
  end

  test 'StaleObjectError raised on direct save with stale lock_version' do
    scenario = create_scenario
    stale = Scenario.find(scenario.id)

    scenario.update!(stopped_at_step_index: 42)

    stale.stopped_at_step_index = 99
    assert_raises(ActiveRecord::StaleObjectError) do
      stale.save!
    end
  end

  test 'StaleObjectError on stale process_step returns false' do
    scenario = create_scenario
    stale = Scenario.find(scenario.id)

    # First instance advances successfully
    assert scenario.process_step('answer1')

    # Stale instance should return false (not raise)
    result = stale.process_step('answer2')

    assert_not result
  end

  test 'StaleObjectError on stale process_subflow_completion returns false' do
    scenario = create_scenario
    scenario.update!(status: 'awaiting_subflow')

    stale = Scenario.find(scenario.id)

    # Advance the real instance to bump lock_version
    scenario.update!(stopped_at_step_index: 42)

    # Stale instance should handle gracefully
    result = stale.process_subflow_completion

    assert_not result
  end

  test 'StaleObjectError on stale record_step_ended is handled gracefully' do
    scenario = create_scenario
    # Simulate a step entry with timing data
    scenario.execution_path = [{ 'step_title' => 'Q1', 'step_type' => 'question', 'started_at' => Time.current.iso8601(3) }]
    scenario.save!

    stale = Scenario.find(scenario.id)

    # Advance real instance to bump lock_version
    scenario.update!(stopped_at_step_index: 42)

    # Stale record_step_ended should not raise
    assert_nothing_raised do
      stale.record_step_ended
    end
  end

  test 'reload resets lock_version for retry after StaleObjectError' do
    scenario = create_scenario
    stale = Scenario.find(scenario.id)

    scenario.update!(stopped_at_step_index: 42)

    stale.stopped_at_step_index = 99
    assert_raises(ActiveRecord::StaleObjectError) do
      stale.save!
    end

    stale.reload

    assert_equal scenario.lock_version, stale.lock_version

    stale.update!(status: 'stopped')

    assert_equal 'stopped', stale.reload.status
  end

  private

  def create_scenario
    Scenario.create!(
      workflow: @workflow,
      user: @user,
      purpose: 'simulation',
      current_node_uuid: @workflow.start_step.uuid,
      execution_path: [],
      results: {},
      inputs: {}
    )
  end
end
