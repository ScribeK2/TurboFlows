require "test_helper"

# The builder's step list is an outline of the graph. These pin the rules the
# spec fixed (revision 2): the LAST door continues, a merged step belongs to
# the door the walk reaches first with the trunk walked first, numbering is
# render order, and "ways in" counts every transition into a step.
class StepOutlineTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "outline-#{SecureRandom.hex(4)}@example.com", password: "password123456")
    @workflow = Workflow.create!(title: "Outline", user: @user)
  end

  def question(title, position, answers: %w[yes no], variable: "q#{position}")
    if answers == %w[yes no]
      Steps::Question.create!(workflow: @workflow, title: title, position: position, answer_type: "yes_no", variable_name: variable)
    else
      Steps::Question.create!(workflow: @workflow, title: title, position: position, answer_type: "multiple_choice",
                              variable_name: variable, options: answers.map { |a| { "label" => a, "value" => a.parameterize(separator: "_") } })
    end
  end

  def action(title, position) = Steps::Action.create!(workflow: @workflow, title: title, position: position)
  def resolve(title, position) = Steps::Resolve.create!(workflow: @workflow, title: title, position: position)

  def wire(from, to, answer: nil, position: 0)
    condition = answer ? "#{from.variable_name} == '#{answer}'" : nil
    Transition.create!(step: from, target_step: to, condition: condition, position: position)
  end

  def outline = StepOutline.for(@workflow.reload)
  def titles(steps) = steps.map(&:title)

  # Yes → Working, No → Power cycle → Did it come back? (Yes → Working, No → Escalate).
  def toy_graph
    @q1 = question("Power light green?", 0, variable: "light")
    @working = resolve("Working", 1)
    @cycle = action("Power cycle", 2)
    @q2 = question("Did it come back?", 3, variable: "back")
    @escalate = Steps::Escalate.create!(workflow: @workflow, title: "Escalate to tier 2", position: 4)
    wire(@q1, @working, answer: "yes", position: 0)
    wire(@q1, @cycle, answer: "no", position: 1)
    wire(@cycle, @q2)
    wire(@q2, @working, answer: "yes", position: 0)
    wire(@q2, @escalate, answer: "no", position: 1)
    @workflow.update_columns(start_step_id: @q1.id)
  end

  test "a single door continues, so a linear chain stays flat" do
    a = action("A", 0)
    b = action("B", 1)
    c = resolve("C", 2)
    wire(a, b)
    wire(b, c)
    @workflow.update_columns(start_step_id: a.id)

    root = outline.root
    assert_empty root.exits
    assert_equal "B", root.continuation.child.step.title
    assert_equal "C", root.continuation.child.continuation.child.step.title
  end

  # Mutation check: in StepOutline#node_for use `doors.first` for the
  # continuation - this goes red.
  test "on a Yes/No step No continues, even when Yes leads further" do
    q = question("Fixed?", 0, variable: "fixed")
    long1 = action("Long 1", 1)
    long2 = action("Long 2", 2)
    long_done = resolve("Long done", 3)
    short = resolve("Short", 4)
    wire(q, long1, answer: "yes", position: 0)
    wire(long1, long2)
    wire(long2, long_done)
    wire(q, short, answer: "no", position: 1)
    @workflow.update_columns(start_step_id: q.id)

    root = outline.root
    assert_equal "No", root.continuation.door.label
    assert_equal(["Yes"], root.exits.map { |e| e.door.label })
  end

  test "a wired Anything else continues over every answer" do
    q = question("Services status", 0, answers: %w[Outage Normal], variable: "status")
    o1 = action("Tell caller", 1)
    o2 = resolve("Outage done", 2)
    carry = resolve("Carry on", 3)
    wire(q, o1, answer: "outage", position: 0)
    wire(o1, o2)
    wire(q, carry, position: 1) # blank condition: the fallback door
    @workflow.update_columns(start_step_id: q.id)

    root = outline.root
    assert_equal "Anything else", root.continuation.door.label
    assert_equal(%w[Outage Normal], root.exits.map { |e| e.door.label })
    assert_equal :step, root.exits.first.kind
    assert_equal :stub, root.exits.last.kind
  end

  test "a fresh Yes/No question continues on its No stub" do
    q = question("Fresh?", 0)
    @workflow.update_columns(start_step_id: q.id)

    root = outline.root
    assert_equal "No", root.continuation.door.label
    assert_equal :stub, root.continuation.kind
  end

  test "a Resolve has no continuation and no exits" do
    r = resolve("Done", 0)
    @workflow.update_columns(start_step_id: r.id)
    root = outline.root
    assert_nil root.continuation
    assert_empty root.exits
  end

  test "a handoff has no continuation and no exits" do
    target = Workflow.create!(title: "Handoff target", user: @user)
    Steps::Resolve.create!(workflow: target, position: 0, title: "Done", resolution_type: "success")
    handoff = Steps::SubFlow.create!(workflow: @workflow, position: 0, title: "Continue elsewhere",
                                     sub_flow_workflow_id: target.id, sub_flow_returns: false)
    @workflow.update_columns(start_step_id: handoff.id)

    root = outline.root
    assert_nil root.continuation
    assert_empty root.exits
  end

  # Mutation check: in StepOutline#node_for build `exits` BEFORE
  # `continuation` - the rejoin captures the trunk and this goes red.
  test "a side branch that rejoins the trunk reads as a jump, not a capture" do
    q = question("Open ticket?", 0, variable: "ticket")
    note = Steps::Message.create!(workflow: @workflow, title: "Do not open a second", position: 1)
    status = question("Services status", 2, variable: "status")
    done = resolve("Done", 3)
    wire(q, note, answer: "yes", position: 0)
    wire(q, status, position: 1) # "Anything else": the trunk
    wire(note, status)           # rejoins the trunk
    wire(status, done, answer: "yes", position: 0)
    @workflow.update_columns(start_step_id: q.id)

    root = outline.root
    assert_equal "Services status", root.continuation.child.step.title, "the trunk owns the rejoined step"
    rejoin = root.exits.first.child.continuation
    assert_equal :jump, rejoin.kind
    assert_equal "Services status", rejoin.target.title
  end

  test "an early merge is owned by the deeper step and the first mention is a jump" do
    toy_graph
    root = outline.root
    assert_equal :jump, root.exits.first.kind
    later_yes = root.continuation.child.continuation.child.exits.first
    assert_equal :step, later_yes.kind
    assert_equal "Working", later_yes.child.step.title
  end

  test "a self-loop is a jump" do
    q = question("Again?", 0, variable: "again")
    done = resolve("Done", 1)
    wire(q, q, answer: "yes", position: 0)
    wire(q, done, answer: "no", position: 1)
    @workflow.update_columns(start_step_id: q.id)

    assert_equal :jump, outline.root.exits.first.kind
  end

  test "extras and the fallback are carried on the node" do
    q = question("Which?", 0, answers: %w[A B], variable: "which")
    a = resolve("A done", 1)
    other = resolve("Other", 2)
    wire(q, a, answer: "a", position: 0)
    wire(q, other, position: 1)
    extra = Transition.create!(step: q, target_step: a, condition: "ticket == 'x'", position: 2)
    @workflow.update_columns(start_step_id: q.id)

    root = outline.root
    assert_equal [extra], root.extras
    assert_equal other, root.fallback.target_step
  end

  test "steps nothing leads to are orphans, listed last in reading order" do
    a = action("A", 0)
    done = resolve("Done", 1)
    lone = resolve("Lone", 2)
    wire(a, done)
    @workflow.update_columns(start_step_id: a.id)

    result = outline
    assert_equal [lone], result.orphans
    assert_equal %w[A Done Lone], titles(result.reading_order)
  end

  # Mutation check: in #walk_orphans always start at `remaining.first` (ignore
  # what leads in) - Y becomes its own root and this goes red.
  test "an unconnected chain keeps its shape, starting where nothing leads in" do
    s = action("Start", 0)
    done = resolve("Done", 1)
    y = resolve("Y", 2)
    x = question("X", 3, variable: "x")
    wire(s, done)
    wire(x, y, answer: "no", position: 0)
    @workflow.update_columns(start_step_id: s.id)

    result = outline
    assert_equal [x], result.orphan_roots.map(&:step)
    assert_equal "Y", result.orphan_roots.first.continuation.child.step.title
    assert_equal :stub, result.orphan_roots.first.exits.first.kind, "an unconnected question keeps its Yes stub"
    assert_equal %w[Start Done X Y], titles(result.reading_order)
  end

  test "an unconnected cycle starts at its first step by position" do
    s = action("Start", 0)
    done = resolve("Done", 1)
    p = action("P", 2)
    q = action("Q", 3)
    wire(s, done)
    wire(p, q)
    wire(q, p)
    @workflow.update_columns(start_step_id: s.id)

    result = outline
    assert_equal [p], result.orphan_roots.map(&:step)
    assert_equal :jump, result.orphan_roots.first.continuation.child.continuation.kind
  end

  # Mutation check: in .render_order visit the continuation before the exits - red.
  test "reading order is exits first, then the continuation; ordinals count in it" do
    toy_graph
    result = outline
    assert_equal ["Power light green?", "Power cycle", "Did it come back?", "Working", "Escalate to tier 2"],
                 titles(result.reading_order)
    assert_equal 4, result.ordinals[@working.uuid]
    assert_equal (1..5).to_a, result.ordinals.values
  end

  test "a linear workflow numbers like the flat list did" do
    a = action("A", 0)
    b = action("B", 1)
    c = resolve("C", 2)
    wire(a, b)
    wire(b, c)
    @workflow.update_columns(start_step_id: a.id)
    assert_equal({ a.uuid => 1, b.uuid => 2, c.uuid => 3 }, outline.ordinals)
  end

  test "rows and chain_rows count real rows, not jumps or stubs" do
    toy_graph
    root = outline.root
    assert_equal 1, root.rows, "step 1's only exit is a jump"
    assert_equal 5, root.chain_rows
    cycle = root.continuation.child
    assert_equal 4, cycle.chain_rows, "Power cycle → Did it come back? (+ Working) → Escalate"
    q2 = cycle.continuation.child
    assert_equal 2, q2.rows, "Did it come back? + Working"
  end

  # Mutation check: in #collect_ways_in skip extras - the extra-source
  # assertion goes red.
  test "ways in counts every transition into a step, in reading order, only from two" do
    toy_graph
    lone = resolve("Lone", 9)
    Transition.create!(step: lone, target_step: @working, condition: "x == 'y'", position: 0) # an orphan's extra
    result = outline

    ways = result.ways_in_for(@working)
    assert_equal [@q1, @q2, lone], ways.map(&:source)
    assert_equal ["Yes", "Yes", "x == 'y'"], ways.map(&:label)
    assert_empty result.ways_in_for(@cycle), "one way in is not shown"
  end

  test "a self-loop counts as a way in" do
    q = question("Again?", 0, variable: "again")
    start = action("Start", 1)
    wire(start, q)
    wire(q, q, answer: "yes", position: 0)
    @workflow.update_columns(start_step_id: start.id)

    assert_equal [start, q], outline.ways_in_for(q).map(&:source)
  end

  test "with no start step the first step by position starts the walk" do
    b = action("B", 1)
    a = action("A", 0)
    wire(a, b)
    assert_equal "A", outline.root.step.title
  end

  test "an empty workflow has no root, no orphans, no ordinals" do
    result = outline
    assert_nil result.root
    assert_empty result.reading_order
    assert_empty result.ordinals
  end
end
