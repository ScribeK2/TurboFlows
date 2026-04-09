# frozen_string_literal: true

require 'test_helper'

class WorkflowNormalizationTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "norm-#{SecureRandom.hex(4)}@test.com",
      password: 'password123!',
      password_confirmation: 'password123!',
      role: 'editor'
    )
    @workflow = Workflow.create!(title: 'Normalization WF', user: @user)
  end

  test 'generate_variable_name converts title to snake_case' do
    assert_equal 'customer_name', @workflow.generate_variable_name('Customer Name')
  end

  test 'generate_variable_name strips punctuation' do
    assert_equal 'what_is_your_issue', @workflow.generate_variable_name('What is your issue?')
  end

  test 'generate_variable_name handles exclamation marks and colons' do
    assert_equal 'hello_world', @workflow.generate_variable_name('Hello! World:')
  end

  test 'generate_variable_name collapses multiple underscores' do
    result = @workflow.generate_variable_name('Too   many   spaces')

    assert_no_match(/__/, result)
  end

  test 'generate_variable_name removes leading and trailing underscores' do
    result = @workflow.generate_variable_name('  Leading and trailing  ')

    assert_no_match(/^_/, result)
    assert_no_match(/_$/, result)
  end

  test 'generate_variable_name truncates to 30 chars' do
    long_title = 'This is a very long title that should be truncated to fit within limits'
    result = @workflow.generate_variable_name(long_title)

    assert_operator result.length, :<=, 30
  end

  test 'generate_variable_name does not leave trailing underscore after truncation' do
    result = @workflow.generate_variable_name("#{'a' * 30}_extra_stuff")

    assert_no_match(/_$/, result)
  end

  test 'generate_variable_name returns nil for blank input' do
    assert_nil @workflow.generate_variable_name('')
    assert_nil @workflow.generate_variable_name(nil)
    assert_nil @workflow.generate_variable_name('   ')
  end

  test 'variables extracts variable names from question steps' do
    Steps::Question.create!(
      workflow: @workflow, title: 'Name?', position: 0,
      answer_type: 'text', variable_name: 'customer_name'
    )
    Steps::Question.create!(
      workflow: @workflow, title: 'Age?', position: 1,
      answer_type: 'number', variable_name: 'customer_age'
    )

    vars = @workflow.variables

    assert_includes vars, 'customer_name'
    assert_includes vars, 'customer_age'
  end

  test 'variables extracts variable names from action step output_fields' do
    Steps::Action.create!(
      workflow: @workflow, title: 'Lookup', position: 0,
      action_type: 'Instruction',
      output_fields: [{ 'name' => 'lookup_result', 'value' => 'found' }]
    )

    vars = @workflow.variables

    assert_includes vars, 'lookup_result'
  end

  test 'variables returns unique names' do
    Steps::Question.create!(
      workflow: @workflow, title: 'Q1', position: 0,
      answer_type: 'text', variable_name: 'shared_var'
    )
    Steps::Action.create!(
      workflow: @workflow, title: 'A1', position: 1,
      action_type: 'Instruction',
      output_fields: [{ 'name' => 'shared_var', 'value' => 'val' }]
    )

    vars = @workflow.variables

    assert_equal 1, vars.count('shared_var')
  end

  test 'variables skips question steps without variable_name' do
    # Question auto-generates variable_name from title via before_validation,
    # so use update_column to force-clear it after creation
    q = Steps::Question.create!(
      workflow: @workflow, title: 'Q1', position: 0,
      answer_type: 'text', variable_name: 'q1'
    )
    q.update_column(:variable_name, nil)

    assert_empty @workflow.reload.variables
  end
end
