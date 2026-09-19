require "test_helper"

class StepResolverTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "test-resolver@example.com", password: "password123456")
    @workflow = Workflow.create!(title: "Resolver Test", user: @user, status: "draft")
  end

  def create_step(type_class, title, position, **attrs)
    type_class.create!(workflow: @workflow, title: title, position: position, **attrs)
  end

  def link(from_step, to_step, condition: nil, label: nil, position: 0)
    Transition.create!(step: from_step, target_step: to_step, condition: condition, label: label, position: position)
  end

  test "resolves unconditional transition to target step" do
    q = create_step(Steps::Question, "Q1", 0)
    a = create_step(Steps::Action, "A1", 1)
    link(q, a)
    resolver = StepResolver.new(@workflow)
    assert_equal a, resolver.resolve_next(q, {})
  end

  test "returns nil for step with no transitions (terminal)" do
    r = create_step(Steps::Resolve, "Done", 0)
    resolver = StepResolver.new(@workflow)
    assert_nil resolver.resolve_next(r, {})
  end

  test "returns default transition when no conditions match" do
    q = create_step(Steps::Question, "Q1", 0, variable_name: "answer")
    a = create_step(Steps::Action, "A1", 1)
    r = create_step(Steps::Resolve, "Done", 2)
    link(q, a, condition: "yes", position: 0)
    link(q, r, position: 1)
    resolver = StepResolver.new(@workflow)
    result = resolver.resolve_next(q, { "answer" => "no" })
    assert_equal r, result
  end

  test "matches simple value condition" do
    q = create_step(Steps::Question, "Q1", 0, variable_name: "answer")
    yes_step = create_step(Steps::Action, "Yes path", 1)
    no_step = create_step(Steps::Action, "No path", 2)
    link(q, yes_step, condition: "yes", position: 0)
    link(q, no_step, condition: "no", position: 1)
    resolver = StepResolver.new(@workflow)
    assert_equal yes_step, resolver.resolve_next(q, { "answer" => "yes" })
    assert_equal no_step, resolver.resolve_next(q, { "answer" => "no" })
  end

  test "first matching condition wins (position order)" do
    q = create_step(Steps::Question, "Q1", 0, variable_name: "status")
    a = create_step(Steps::Action, "First", 1)
    b = create_step(Steps::Action, "Second", 2)
    link(q, a, condition: "active", position: 0)
    link(q, b, condition: "active", position: 1)
    resolver = StepResolver.new(@workflow)
    assert_equal a, resolver.resolve_next(q, { "status" => "active" })
  end

  # The shape a renamed variable produces: branches exist, the answer routes to
  # none of them. This returned nil, which is also what a Resolve returns, so
  # the run stopped and was recorded as a completion.
  test "no conditions match and no default returns NoMatch, not nil" do
    q = create_step(Steps::Question, "Q1", 0, variable_name: "answer")
    a = create_step(Steps::Action, "A1", 1)
    link(q, a, condition: "yes", position: 0)
    resolver = StepResolver.new(@workflow)

    result = resolver.resolve_next(q, { "answer" => "no" })

    assert_instance_of StepResolver::NoMatch, result
    assert_equal q.uuid, result.step_uuid
    assert_equal 1, result.transition_count
  end

  # The other reason a run has nowhere to go, and the one that is not a defect.
  test "a step with no outgoing transitions still returns nil" do
    r = create_step(Steps::Resolve, "Done", 0)
    a = create_step(Steps::Action, "Dead end", 1)
    resolver = StepResolver.new(@workflow)

    assert_nil resolver.resolve_next(r, {})
    assert_nil resolver.resolve_next(a, {}), "no edges at all is terminal by shape, not a gap"
  end

  test "expression condition evaluation" do
    q = create_step(Steps::Question, "Q1", 0, variable_name: "age")
    adult = create_step(Steps::Action, "Adult path", 1)
    child = create_step(Steps::Action, "Child path", 2)
    link(q, adult, condition: "age >= 18", position: 0)
    link(q, child, condition: "age < 18", position: 1)
    resolver = StepResolver.new(@workflow)
    assert_equal adult, resolver.resolve_next(q, { "age" => "25" })
    assert_equal child, resolver.resolve_next(q, { "age" => "10" })
  end

  test "resolves with empty results hash" do
    q = create_step(Steps::Question, "Q1", 0)
    a = create_step(Steps::Action, "A1", 1)
    link(q, a)
    resolver = StepResolver.new(@workflow)
    assert_equal a, resolver.resolve_next(q, {})
  end

  test "resolves with nil results" do
    q = create_step(Steps::Question, "Q1", 0)
    a = create_step(Steps::Action, "A1", 1)
    link(q, a)
    resolver = StepResolver.new(@workflow)
    assert_equal a, resolver.resolve_next(q, nil)
  end

  test "SubFlow step returns SubflowMarker" do
    target_wf = Workflow.create!(title: "Target", user: @user, status: "published")
    sf = create_step(Steps::SubFlow, "Run sub", 0, sub_flow_workflow_id: target_wf.id)
    next_step = create_step(Steps::Resolve, "Done", 1)
    link(sf, next_step)
    resolver = StepResolver.new(@workflow)
    result = resolver.resolve_next(sf, {})
    assert_instance_of StepResolver::SubflowMarker, result
    assert_equal target_wf.id, result.target_workflow_id
  end

  test "resolve_next_after_subflow continues from SubFlow step" do
    target_wf = Workflow.create!(title: "Target", user: @user, status: "published")
    sf = create_step(Steps::SubFlow, "Run sub", 0, sub_flow_workflow_id: target_wf.id)
    next_step = create_step(Steps::Resolve, "Done", 1)
    link(sf, next_step)
    resolver = StepResolver.new(@workflow)
    result = resolver.resolve_next_after_subflow(sf, {})
    assert_equal next_step, result
  end

  test "self-loop transition" do
    q = create_step(Steps::Question, "Retry", 0, variable_name: "retry")
    r = create_step(Steps::Resolve, "Done", 1)
    link(q, q, condition: "yes", position: 0)
    link(q, r, condition: "no", position: 1)
    resolver = StepResolver.new(@workflow)
    assert_equal q, resolver.resolve_next(q, { "retry" => "yes" })
    assert_equal r, resolver.resolve_next(q, { "retry" => "no" })
  end

  test "start_step returns workflow start_step" do
    q = create_step(Steps::Question, "Start", 0)
    @workflow.update!(start_step: q)
    resolver = StepResolver.new(@workflow)
    assert_equal q, resolver.start_step
  end

  test "terminal? returns true for Resolve step" do
    r = create_step(Steps::Resolve, "Done", 0)
    resolver = StepResolver.new(@workflow)
    assert resolver.terminal?(r)
  end

  test "terminal? returns true for step with no transitions" do
    q = create_step(Steps::Question, "Dead end", 0)
    resolver = StepResolver.new(@workflow)
    assert resolver.terminal?(q)
  end

  test "terminal? returns false for step with transitions" do
    q = create_step(Steps::Question, "Q", 0)
    a = create_step(Steps::Action, "A", 1)
    link(q, a)
    resolver = StepResolver.new(@workflow)
    assert_not resolver.terminal?(q)
  end

  test "jumps are checked before transitions" do
    q = create_step(Steps::Question, "Q1", 0, variable_name: "answer")
    jump_target = create_step(Steps::Action, "Jump Target", 1)
    transition_target = create_step(Steps::Action, "Transition Target", 2)
    link(q, transition_target)
    q.update_column(:jumps, [{ "condition" => "special", "next_step_id" => jump_target.uuid }])
    resolver = StepResolver.new(@workflow)
    result = resolver.resolve_next(q, { "answer" => "special" })
    assert_equal jump_target, result, "Jumps should be checked before transitions"
  end

  test "empty jumps array falls through to transitions" do
    q = create_step(Steps::Question, "Q1", 0)
    a = create_step(Steps::Action, "A1", 1)
    link(q, a)
    q.update_column(:jumps, [])
    resolver = StepResolver.new(@workflow)
    assert_equal a, resolver.resolve_next(q, {})
  end

  # transitions.position is nullable, and ORDER BY position alone puts a NULL
  # first on SQLite and last on PostgreSQL - so the same rows routed one way
  # here and another in production. The order is spelled out now, the way
  # production already read it: NULL last, id breaking a tie.
  test "a transition with no position is tried last, on every database" do
    q = create_step(Steps::Question, "Q", 0, answer_type: "yes_no", variable_name: "q")
    rest = create_step(Steps::Resolve, "Rest", 1)
    yes = create_step(Steps::Resolve, "Yes", 2)
    link(q, rest, position: nil)
    link(q, yes, condition: "q == 'yes'", position: 0)

    assert_equal yes, StepResolver.new(@workflow).resolve_next(q, { "q" => "yes" })
    assert_equal rest, StepResolver.new(@workflow).resolve_next(q, { "q" => "no" })
  end

  test "transitions sharing a position are tried in the order they were made" do
    q = create_step(Steps::Question, "Q", 0, answer_type: "yes_no", variable_name: "q")
    first = create_step(Steps::Resolve, "First", 1)
    second = create_step(Steps::Resolve, "Second", 2)
    link(q, first, condition: "q == 'yes'", position: 0)
    link(q, second, condition: "q != 'no'", position: 0)

    assert_equal first, StepResolver.new(@workflow).resolve_next(q, { "q" => "yes" })
  end
end
