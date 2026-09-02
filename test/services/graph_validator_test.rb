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

  # Was "detects simple cycle": a bare two-step mutual cycle was refused
  # outright. Under the escapability rule a plain cycle is legal on its own —
  # what matters is whether it can reach a Resolve — so this fixture now gives
  # the cycle an exit and asserts the graph is valid. The refusal case this
  # protected (a cycle that cannot escape) is covered by the closed-loop tests
  # below.
  test "a simple two-step cycle with an exit is valid" do
    steps = {
      'a' => { 'id' => 'a', 'title' => 'Start', 'type' => 'question', 'transitions' => [
        { 'target_uuid' => 'b' },
        { 'target_uuid' => 'done' }
      ] },
      'b' => { 'id' => 'b', 'title' => 'Middle', 'type' => 'action', 'transitions' => [{ 'target_uuid' => 'a' }] },
      'done' => { 'id' => 'done', 'title' => 'End', 'type' => 'resolve', 'transitions' => [] }
    }

    validator = GraphValidator.new(steps, 'a')

    assert_predicate validator, :valid?, validator.errors.inspect
  end

  # Was "detects complex cycle": a longer cycle (b -> c -> d -> b) was refused
  # outright. Reshaped the same way as the simple-cycle test above, but with a
  # multi-node cycle, to exercise escapable_uuids' reverse BFS over more than
  # one hop back to the frontier.
  test "a longer cycle with an exit is valid" do
    steps = {
      'a' => { 'id' => 'a', 'title' => 'Start', 'type' => 'question', 'transitions' => [{ 'target_uuid' => 'b' }] },
      'b' => { 'id' => 'b', 'title' => 'Step B', 'type' => 'action', 'transitions' => [
        { 'target_uuid' => 'c' },
        { 'target_uuid' => 'done' }
      ] },
      'c' => { 'id' => 'c', 'title' => 'Step C', 'type' => 'action', 'transitions' => [{ 'target_uuid' => 'd' }] },
      'd' => { 'id' => 'd', 'title' => 'Step D', 'type' => 'action', 'transitions' => [{ 'target_uuid' => 'b' }] },
      'done' => { 'id' => 'done', 'title' => 'End', 'type' => 'resolve', 'transitions' => [] }
    }

    validator = GraphValidator.new(steps, 'a')

    assert_predicate validator, :valid?, validator.errors.inspect
  end

  test "a retry loop with an exit is valid" do
    steps = {
      'ask' => { 'id' => 'ask', 'title' => 'Fixed?', 'type' => 'question',
                 'transitions' => [{ 'target_uuid' => 'done' }, { 'target_uuid' => 'retry' }] },
      'retry' => { 'id' => 'retry', 'title' => 'Try again', 'type' => 'action',
                   'transitions' => [{ 'target_uuid' => 'ask' }] },
      'done' => { 'id' => 'done', 'title' => 'Done', 'type' => 'resolve', 'transitions' => [] }
    }

    validator = GraphValidator.new(steps, 'ask')

    assert_predicate validator, :valid?, validator.errors.inspect
  end

  test "a closed loop with no way out is refused" do
    steps = {
      'a' => { 'id' => 'a', 'title' => 'A', 'type' => 'action', 'transitions' => [{ 'target_uuid' => 'b' }] },
      'b' => { 'id' => 'b', 'title' => 'B', 'type' => 'action', 'transitions' => [{ 'target_uuid' => 'a' }] },
      'done' => { 'id' => 'done', 'title' => 'Done', 'type' => 'resolve', 'transitions' => [] }
    }

    validator = GraphValidator.new(steps, 'a')

    assert_not validator.valid?
    codes = validator.findings.map(&:code)
    assert_includes codes, :no_path_to_resolve
    assert_not_includes codes, :cycle_detected
  end

  test "a step whose only path leads into a closed loop is refused" do
    steps = {
      'start' => { 'id' => 'start', 'title' => 'Start', 'type' => 'action', 'transitions' => [{ 'target_uuid' => 'a' }] },
      'a' => { 'id' => 'a', 'title' => 'A', 'type' => 'action', 'transitions' => [{ 'target_uuid' => 'b' }] },
      'b' => { 'id' => 'b', 'title' => 'B', 'type' => 'action', 'transitions' => [{ 'target_uuid' => 'a' }] },
      'done' => { 'id' => 'done', 'title' => 'Done', 'type' => 'resolve', 'transitions' => [] }
    }

    validator = GraphValidator.new(steps, 'start')

    assert_not validator.valid?
    assert_includes validator.findings.map(&:step_uuid), 'start'
  end

  # F1 regression: find_reachable_nodes queues a transition target before
  # checking it names a real step (validate_integrity's job, not its own), so
  # a step pointing at a deleted uuid was showing up "reachable" with no step
  # behind it. validate_escapable must not report a finding against a
  # step_uuid nothing in @steps owns.
  test "no_path_to_resolve never names a step_uuid that isn't a real step" do
    steps = {
      'a' => { 'id' => 'a', 'title' => 'Start', 'type' => 'action', 'transitions' => [{ 'target_uuid' => 'ghost' }] }
    }

    validator = GraphValidator.new(steps, 'a')
    validator.valid?

    validator.findings.each do |finding|
      assert(finding.step_uuid.nil? || steps.key?(finding.step_uuid),
             "finding #{finding.code.inspect} names step_uuid #{finding.step_uuid.inspect}, which is not a key of steps")
    end
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

  # Was "cycle_detected finding names a step in the cycle and carries the
  # path": protected that a cycle finding names the right UUID even when every
  # step in it shares a title, and that it carries the cycle's path in
  # details. :cycle_detected and its details[:cycle_uuids] no longer exist —
  # a closed loop is now reported per unescapable step via
  # :no_path_to_resolve, with no path payload — so this asserts the surviving
  # half of that guarantee: every step in the loop is named individually, not
  # just "the cycle" as a whole, and duplicate titles cannot hide which one.
  test "no_path_to_resolve findings name each step in a closed loop, not just one" do
    steps = duplicate_title_steps('a' => [{ 'target_uuid' => 'b' }], 'b' => [{ 'target_uuid' => 'a' }])
    validator = GraphValidator.new(steps, 'a')
    validator.valid?

    findings = validator.findings.select { |f| f.code == :no_path_to_resolve }

    assert_equal %w[a b], findings.map(&:step_uuid).sort
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
