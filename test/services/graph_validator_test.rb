require "test_helper"

class GraphValidatorTest < ActiveSupport::TestCase
  test "validates a simple linear graph" do
    steps = {
      'a' => { 'id' => 'a', 'title' => 'Start', 'type' => 'question', 'transitions' => [{ 'target_uuid' => 'b' }] },
      'b' => { 'id' => 'b', 'title' => 'Middle', 'type' => 'action', 'transitions' => [{ 'target_uuid' => 'c' }] },
      'c' => { 'id' => 'c', 'title' => 'End', 'type' => 'action', 'transitions' => [] }
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
      'd' => { 'id' => 'd', 'title' => 'End', 'type' => 'action', 'transitions' => [] }
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
      'b' => { 'id' => 'b', 'title' => 'Middle', 'type' => 'action', 'transitions' => [] },
      'c' => { 'id' => 'c', 'title' => 'Unreachable', 'type' => 'action', 'transitions' => [] }
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
      'b' => { 'id' => 'b', 'title' => 'End 1', 'type' => 'action', 'transitions' => [] },
      'c' => { 'id' => 'c', 'title' => 'End 2', 'type' => 'action', 'transitions' => [] }
    }

    validator = GraphValidator.new(steps, 'a')

    assert_predicate validator, :valid?, "Expected valid graph with multiple terminals, got errors: #{validator.errors.join(', ')}"
  end

  test "validates conditional transitions" do
    steps = {
      'a' => { 'id' => 'a', 'title' => 'Question', 'type' => 'question', 'transitions' => [
        { 'target_uuid' => 'b', 'condition' => "answer == 'yes'" },
        { 'target_uuid' => 'c' } # Default transition
      ] },
      'b' => { 'id' => 'b', 'title' => 'Yes Path', 'type' => 'action', 'transitions' => [] },
      'c' => { 'id' => 'c', 'title' => 'Default Path', 'type' => 'action', 'transitions' => [] }
    }

    validator = GraphValidator.new(steps, 'a')

    assert_predicate validator, :valid?
  end
end
