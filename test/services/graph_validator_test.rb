require "test_helper"

class GraphValidatorTest < ActiveSupport::TestCase
  test "validates a simple linear graph" do
    steps = {
      'a' => { 'id' => 'a', 'title' => 'Start', 'type' => 'question', 'transitions' => [{ 'target_uuid' => 'b' }] },
      'b' => { 'id' => 'b', 'title' => 'Middle', 'type' => 'action', 'transitions' => [{ 'target_uuid' => 'c' }] },
      'c' => { 'id' => 'c', 'title' => 'End', 'type' => 'resolve', 'transitions' => [] }
    }

    validator = GraphValidator.new(steps, 'a')

    assert_predicate validator, :valid?, "Expected valid graph, got errors: #{validator.errors.join(', ')}"
    assert_empty validator.errors
  end

  test "validates a branching graph" do
    steps = {
      'a' => { 'id' => 'a', 'title' => 'Start', 'type' => 'question', 'transitions' => [
        { 'target_uuid' => 'b', 'condition' => "answer == 'yes'" },
        { 'target_uuid' => 'c', 'condition' => "answer == 'no'" }
      ] },
      'b' => { 'id' => 'b', 'title' => 'Yes Path', 'type' => 'action', 'transitions' => [{ 'target_uuid' => 'd' }] },
      'c' => { 'id' => 'c', 'title' => 'No Path', 'type' => 'action', 'transitions' => [{ 'target_uuid' => 'd' }] },
      'd' => { 'id' => 'd', 'title' => 'End', 'type' => 'resolve', 'transitions' => [] }
    }

    validator = GraphValidator.new(steps, 'a')

    assert_predicate validator, :valid?, "Expected valid graph, got errors: #{validator.errors.join(', ')}"
  end

  test "detects simple cycle" do
    steps = {
      'a' => { 'id' => 'a', 'title' => 'Start', 'type' => 'question', 'transitions' => [{ 'target_uuid' => 'b' }] },
      'b' => { 'id' => 'b', 'title' => 'Middle', 'type' => 'action', 'transitions' => [{ 'target_uuid' => 'a' }] }
    }

    validator = GraphValidator.new(steps, 'a')

    assert_not validator.valid?
    assert validator.errors.any? { |e| e.include?('Cycle') }, "Expected cycle detection error"
  end

  test "detects complex cycle" do
    steps = {
      'a' => { 'id' => 'a', 'title' => 'Start', 'type' => 'question', 'transitions' => [{ 'target_uuid' => 'b' }] },
      'b' => { 'id' => 'b', 'title' => 'Step B', 'type' => 'action', 'transitions' => [{ 'target_uuid' => 'c' }] },
      'c' => { 'id' => 'c', 'title' => 'Step C', 'type' => 'action', 'transitions' => [{ 'target_uuid' => 'd' }] },
      'd' => { 'id' => 'd', 'title' => 'Step D', 'type' => 'action', 'transitions' => [{ 'target_uuid' => 'b' }] }
    }

    validator = GraphValidator.new(steps, 'a')

    assert_not validator.valid?
    assert(validator.errors.any? { |e| e.include?('Cycle') })
  end

  test "detects invalid transition target" do
    steps = {
      'a' => { 'id' => 'a', 'title' => 'Start', 'type' => 'question', 'transitions' => [{ 'target_uuid' => 'nonexistent' }] }
    }

    validator = GraphValidator.new(steps, 'a')

    assert_not validator.valid?
    assert(validator.errors.any? { |e| e.include?('non-existent') })
  end

  test "detects unreachable nodes" do
    steps = {
      'a' => { 'id' => 'a', 'title' => 'Start', 'type' => 'question', 'transitions' => [{ 'target_uuid' => 'b' }] },
      'b' => { 'id' => 'b', 'title' => 'Middle', 'type' => 'resolve', 'transitions' => [] },
      'c' => { 'id' => 'c', 'title' => 'Unreachable', 'type' => 'resolve', 'transitions' => [] }
    }

    validator = GraphValidator.new(steps, 'a')

    assert_not validator.valid?
    assert(validator.errors.any? { |e| e.include?('not reachable') })
  end

  test "detects missing terminal nodes" do
    steps = {
      'a' => { 'id' => 'a', 'title' => 'Start', 'type' => 'question', 'transitions' => [{ 'target_uuid' => 'b' }] },
      'b' => { 'id' => 'b', 'title' => 'Middle', 'type' => 'action', 'transitions' => [{ 'target_uuid' => 'a' }] }
    }

    validator = GraphValidator.new(steps, 'a')

    assert_not validator.valid?
    assert(validator.errors.any? { |e| e.include?('terminal') || e.include?('Cycle') })
  end

  test "validates empty graph returns error" do
    validator = GraphValidator.new({}, 'a')

    assert_not validator.valid?
    assert(validator.errors.any? { |e| e.include?('no steps') })
  end

  test "validates missing start node" do
    steps = {
      'a' => { 'id' => 'a', 'title' => 'Start', 'type' => 'question', 'transitions' => [] }
    }

    validator = GraphValidator.new(steps, 'nonexistent')

    assert_not validator.valid?
    assert(validator.errors.any? { |e| e.include?('Start node') })
  end

  test "allows multiple terminal nodes" do
    steps = {
      'a' => { 'id' => 'a', 'title' => 'Start', 'type' => 'question', 'transitions' => [
        { 'target_uuid' => 'b' },
        { 'target_uuid' => 'c' }
      ] },
      'b' => { 'id' => 'b', 'title' => 'End 1', 'type' => 'resolve', 'transitions' => [] },
      'c' => { 'id' => 'c', 'title' => 'End 2', 'type' => 'resolve', 'transitions' => [] }
    }

    validator = GraphValidator.new(steps, 'a')

    assert_predicate validator, :valid?, "Expected valid graph with multiple terminals, got errors: #{validator.errors.join(', ')}"
  end

  test "rejects graph where terminal node is not a Resolve step" do
    steps = {
      'a' => { 'id' => 'a', 'title' => 'Start', 'type' => 'question', 'transitions' => [{ 'target_uuid' => 'b' }] },
      'b' => { 'id' => 'b', 'title' => 'End Action', 'type' => 'action', 'transitions' => [] }
    }

    validator = GraphValidator.new(steps, 'a')

    assert_not validator.valid?
    assert(validator.errors.any? { |e| e.include?('not a Resolve step') || e.include?('Resolve') },
           "Expected Resolve terminal error, got: #{validator.errors.join(', ')}")
  end

  test "accepts graph where terminal node is a Resolve step" do
    steps = {
      'a' => { 'id' => 'a', 'title' => 'Start', 'type' => 'question', 'transitions' => [{ 'target_uuid' => 'b' }] },
      'b' => { 'id' => 'b', 'title' => 'Done', 'type' => 'resolve', 'transitions' => [] }
    }

    validator = GraphValidator.new(steps, 'a')

    assert_predicate validator, :valid?, "Expected valid graph with Resolve terminal, got errors: #{validator.errors.join(', ')}"
  end

  test "rejects graph with mixed terminal types when one is not Resolve" do
    steps = {
      'a' => { 'id' => 'a', 'title' => 'Start', 'type' => 'question', 'transitions' => [
        { 'target_uuid' => 'b' },
        { 'target_uuid' => 'c' }
      ] },
      'b' => { 'id' => 'b', 'title' => 'Resolved', 'type' => 'resolve', 'transitions' => [] },
      'c' => { 'id' => 'c', 'title' => 'Not Resolved', 'type' => 'action', 'transitions' => [] }
    }

    validator = GraphValidator.new(steps, 'a')

    assert_not validator.valid?
    assert(validator.errors.any? { |e| e.include?('Not Resolved') })
  end

  test "validates conditional transitions" do
    steps = {
      'a' => { 'id' => 'a', 'title' => 'Question', 'type' => 'question', 'transitions' => [
        { 'target_uuid' => 'b', 'condition' => "answer == 'yes'" },
        { 'target_uuid' => 'c' } # Default transition
      ] },
      'b' => { 'id' => 'b', 'title' => 'Yes Path', 'type' => 'resolve', 'transitions' => [] },
      'c' => { 'id' => 'c', 'title' => 'Default Path', 'type' => 'resolve', 'transitions' => [] }
    }

    validator = GraphValidator.new(steps, 'a')

    assert_predicate validator, :valid?
  end

  # ---------------------------------------------------------------------------
  # Findings — the structured half. These assert the UUID each finding names,
  # which is what stops a consumer having to guess the step from the message.
  # The #errors assertions above are the other half of the contract: they prove
  # the message text is unchanged for callers that only surface sentences.
  # ---------------------------------------------------------------------------

  # Every step below deliberately shares one title, so a title lookup could not
  # tell them apart. Findings must still name the right UUID.
  def duplicate_title_steps(transitions_by_uuid)
    transitions_by_uuid.transform_values.with_index do |transitions, index|
      { 'id' => transitions_by_uuid.keys[index], 'title' => 'Same Title',
        'type' => 'question', 'transitions' => transitions }
    end
  end

  test "findings are empty for a valid graph" do
    steps = {
      'a' => { 'id' => 'a', 'title' => 'Start', 'type' => 'question', 'transitions' => [{ 'target_uuid' => 'b' }] },
      'b' => { 'id' => 'b', 'title' => 'End', 'type' => 'resolve', 'transitions' => [] }
    }
    validator = GraphValidator.new(steps, 'a')

    assert_predicate validator, :valid?
    assert_empty validator.findings
  end

  test "errors is exactly the messages of findings, in order" do
    steps = duplicate_title_steps('a' => [{ 'target_uuid' => 'b' }], 'b' => [], 'orphan' => [])
    validator = GraphValidator.new(steps, 'a')

    assert_not validator.valid?
    assert_equal validator.findings.map(&:message), validator.errors
  end

  test "terminal_not_resolve finding names the terminal step, not a same-titled sibling" do
    steps = duplicate_title_steps('a' => [{ 'target_uuid' => 'b' }], 'b' => [])
    validator = GraphValidator.new(steps, 'a')
    validator.valid?

    finding = validator.findings.find { |f| f.code == :terminal_not_resolve }

    assert finding, "Expected a terminal_not_resolve finding, got: #{validator.findings.map(&:code).inspect}"
    assert_equal 'b', finding.step_uuid
  end

  test "unreachable_step finding names the unreachable step" do
    steps = duplicate_title_steps('a' => [{ 'target_uuid' => 'b' }], 'b' => [], 'orphan' => [])
    steps['b']['type'] = 'resolve'
    steps['orphan']['type'] = 'resolve'
    validator = GraphValidator.new(steps, 'a')
    validator.valid?

    finding = validator.findings.find { |f| f.code == :unreachable_step }

    assert finding
    assert_equal 'orphan', finding.step_uuid
  end

  test "cycle_detected finding names a step in the cycle and carries the path" do
    steps = duplicate_title_steps('a' => [{ 'target_uuid' => 'b' }], 'b' => [{ 'target_uuid' => 'a' }])
    validator = GraphValidator.new(steps, 'a')
    validator.valid?

    finding = validator.findings.find { |f| f.code == :cycle_detected }

    assert finding
    assert_includes %w[a b], finding.step_uuid
    assert_includes finding.details[:cycle_uuids], 'a'
  end

  test "transition_target_missing finding names the source step and the missing target" do
    steps = duplicate_title_steps('a' => [{ 'target_uuid' => 'ghost' }])
    validator = GraphValidator.new(steps, 'a')
    validator.valid?

    finding = validator.findings.find { |f| f.code == :transition_target_missing }

    assert finding
    assert_equal 'a', finding.step_uuid
    assert_equal 'ghost', finding.details[:target_uuid]
    assert_equal 0, finding.details[:transition_index]
  end

  test "workflow-level findings carry no step_uuid" do
    empty = GraphValidator.new({}, 'a')
    empty.valid?

    assert_equal [:no_steps], empty.findings.map(&:code)
    assert_nil empty.findings.first.step_uuid

    cyclic = duplicate_title_steps('a' => [{ 'target_uuid' => 'b' }], 'b' => [{ 'target_uuid' => 'a' }])
    validator = GraphValidator.new(cyclic, 'a')
    validator.valid?
    no_terminals = validator.findings.find { |f| f.code == :no_terminal_nodes }

    assert no_terminals
    assert_nil no_terminals.step_uuid
  end
end
