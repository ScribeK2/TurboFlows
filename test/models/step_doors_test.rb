require "test_helper"

class StepDoorsTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "doors-#{SecureRandom.hex(4)}@example.com", password: "password123456")
    @workflow = Workflow.create!(title: "Doors", user: @user)
    @a = Steps::Action.create!(workflow: @workflow, title: "A", position: 10)
    @b = Steps::Action.create!(workflow: @workflow, title: "B", position: 11)
  end

  def question(**attrs)
    Steps::Question.create!({ workflow: @workflow, title: "Light green?", position: 0, variable_name: "light" }.merge(attrs))
  end

  def doors(step) = Step::Doors.for(step.reload)

  test "a Resolve and a handoff have no doors and cannot grow" do
    resolve = Steps::Resolve.create!(workflow: @workflow, title: "Done", position: 1)
    other = Workflow.create!(title: "Elsewhere", user: @user)
    handoff = Steps::SubFlow.create!(workflow: @workflow, title: "Hand off", position: 2,
                                     sub_flow_workflow_id: other.id, sub_flow_returns: false)

    [resolve, handoff].each do |step|
      assert_empty doors(step).doors
      assert_not doors(step).growable?
    end
  end

  test "yes/no gives two answer doors with the panel's own condition strings" do
    d = doors(question(answer_type: "yes_no")).doors
    assert_equal([[:answer, "Yes", "light == 'yes'"], [:answer, "No", "light == 'no'"]],
                 d.map { |door| [door.kind, door.label, door.condition] })
    assert d.all?(&:stub?)
  end

  test "a Question with no variable name falls back to `answer`" do
    step = question(answer_type: "yes_no")
    step.variable_name = nil
    assert_equal "answer == 'yes'", Step::Doors.for(step).doors.first.condition
  end

  test "options give one door each, by value, with an apostrophe escaped as the panel escapes it" do
    step = question(answer_type: "multiple_choice",
                    options: [{ "label" => "Modem", "value" => "modem" }, { "label" => "Don't know", "value" => "Don't know" }])
    d = doors(step).doors
    assert_equal ["Modem", "Don't know"], d.map(&:label)
    assert_equal ["light == 'modem'", "light == 'Don\\'t know'"], d.map(&:condition)
  end

  test "text, no answer type, no options yet, and every non-Question get one Next door" do
    steps = [
      question(answer_type: "text"),
      question(answer_type: nil, title: "Untyped", variable_name: "untyped"),
      question(answer_type: "dropdown", options: [], title: "Empty", variable_name: "empty"),
      @a
    ]
    steps.each do |step|
      d = doors(step).doors
      assert_equal [[:next, "Next", nil]], d.map { |door| [door.kind, door.label, door.condition] }, step.title
    end
    assert_predicate doors(steps[2]), :needs_options?
    assert_not doors(steps[0]).needs_options?
  end

  test "a door is wired by any spelling the runner would take" do
    ["light == 'no'", "light=='No'", "LIGHT == \"no\"".downcase, "no", "No", "answer == 'no'"].each do |condition|
      step = question(answer_type: "yes_no", title: "Q #{condition}", variable_name: "light")
      Transition.create!(step: step, target_step: @a, condition: condition)

      no = doors(step).doors.find { |door| door.label == "No" }
      assert_equal @a, no.target_step, "#{condition.inspect} was not read as the No door"
      assert_empty doors(step).extras
    end
  end

  test "another variable's condition is an extra, not a door" do
    step = question(answer_type: "yes_no")
    other = Transition.create!(step: step, target_step: @a, condition: "tier == 'no'")

    assert doors(step).doors.all?(&:stub?)
    assert_equal [other], doors(step).extras
  end

  test "a hand-made duplicate of a wired door is an extra" do
    step = question(answer_type: "yes_no")
    first = Transition.create!(step: step, target_step: @a, condition: "light == 'yes'", position: 0)
    second = Transition.create!(step: step, target_step: @b, condition: "light == 'yes'", position: 1)

    assert_equal first, doors(step).doors.first.transition
    assert_equal [second], doors(step).extras
  end

  test "a default edge on a multi-door step is the last door, and catches the stubs" do
    step = question(answer_type: "yes_no")
    Transition.create!(step: step, target_step: @a, condition: "light == 'yes'", position: 0)
    Transition.create!(step: step, target_step: @b, position: 1)

    d = doors(step)
    assert_equal %i[answer answer anything_else], d.doors.map(&:kind)
    assert_equal "Anything else", d.doors.last.label
    assert_equal @b, d.fallback.target_step
    assert_equal ["No"], d.stubs.map(&:label)
    assert_empty d.missing
  end

  test "with no default edge an unwired answer is missing" do
    step = question(answer_type: "yes_no")
    Transition.create!(step: step, target_step: @a, condition: "light == 'yes'")

    assert_equal ["No"], doors(step).missing.map(&:label)
  end

  test "a step with nothing wired reports nothing missing: no_outgoing_transitions says it" do
    assert_empty doors(question(answer_type: "yes_no")).missing
  end

  test "a condition on this step's answer that matches no option is unmatched" do
    step = question(answer_type: "dropdown", options: [{ "label" => "Router", "value" => "router" }])
    stale = Transition.create!(step: step, target_step: @a, condition: "light == 'modem'")

    assert_equal [[stale, "modem"]], doors(step).unmatched_extras
  end

  # A hand-made duplicate of a wired door's own condition is an "extra" (only
  # the first transition claims the door - see #extras), but its value is
  # still a real answer. Reporting it as unmatched would say 'yes' is no
  # longer an option on a step where it plainly still is.
  test "a duplicate of a wired door's own condition is not unmatched" do
    step = question(answer_type: "yes_no")
    Transition.create!(step: step, target_step: @a, condition: "light == 'yes'", position: 0)
    duplicate = Transition.create!(step: step, target_step: @b, condition: "light == 'yes'", position: 1)

    d = doors(step)
    assert_equal [duplicate], d.extras
    assert_empty d.unmatched_extras
  end

  test "door_for finds a door by any spelling of its condition" do
    step = question(answer_type: "yes_no")
    assert_equal "No", doors(step).door_for("light=='NO'").label
    assert_nil doors(step).door_for("tier == 'gold'")
    assert_nil doors(step).door_for(nil)
    assert_equal :next, doors(@a).door_for(nil).kind
  end

  # ConditionEvaluator strips quotes from the expected side of an operator
  # condition but keeps a backslash literally, so no operator-form condition
  # can ever match a value containing an apostrophe (a known runtime
  # limitation tracked in TODOS.md). Doors must report what the runner does,
  # not what the author meant by writing the door's own escaped condition
  # back as a transition.
  test "an apostrophe option's own condition is not read as wired, because the runner would not take it" do
    step = question(answer_type: "dropdown",
                    options: [{ "label" => "Don't know", "value" => "Don't know" }, { "label" => "Router", "value" => "router" }])
    door = doors(step).doors.find { |d| d.label == "Don't know" }
    stale = Transition.create!(step: step, target_step: @a, condition: door.condition)

    d = doors(step)
    assert_predicate d.doors.find { |x| x.label == "Don't know" }, :stub?
    assert_equal [stale], d.extras
    assert_includes d.unmatched_extras.map(&:first), stale
  end

  # Proves the claim above against the runtime itself, not against Doors
  # agreeing with itself. The condition string below has exactly one
  # backslash before the apostrophe - the same string condition_for writes.
  test "the runner itself does not take an apostrophe operator-form condition" do
    condition = "light == 'Don\\'t know'"
    assert_not ConditionEvaluator.evaluate(condition, { "light" => "Don't know" })
    assert ConditionEvaluator.evaluate("light == 'router'", { "light" => "Router" })
  end

  test "a bare condition matches its literal text, quotes included, exactly as the runner's simple match does" do
    step = question(answer_type: "dropdown", options: [{ "label" => "Don't know", "value" => "Don't know" }])
    wired = Transition.create!(step: step, target_step: @a, condition: "Don't know")

    door = doors(step).doors.find { |d| d.label == "Don't know" }
    assert_equal wired, door.transition

    quoted = Transition.create!(step: question(answer_type: "yes_no", title: "Quoted", variable_name: "quoted"),
                                target_step: @a, condition: "'no'")
    no_door = doors(quoted.step).doors.find { |d| d.label == "No" }
    assert_nil no_door.transition
  end

  # The runner compares an ANSWER (the door's value) raw - no quote stripping.
  # ConditionEvaluator#evaluate_comparison only strips '" from the CONDITION
  # string's two halves; result_value.to_s.downcase is compared as-is. A door
  # whose value contains a literal quote character must not be read as wired
  # by its own displayed condition, because the runner never would take it.
  test "a value containing a quote character is not read as wired by its own condition" do
    step = question(answer_type: "dropdown",
                    options: [{ "label" => 'Say "OK"', "value" => 'Say "OK"' }, { "label" => "Router", "value" => "router" }])
    door = doors(step).doors.find { |d| d.label == 'Say "OK"' }
    stale = Transition.create!(step: step, target_step: @a, condition: door.condition)

    d = doors(step)
    assert_predicate d.doors.find { |x| x.label == 'Say "OK"' }, :stub?
    assert_equal [stale], d.extras
    assert_not ConditionEvaluator.evaluate(door.condition, { "light" => 'Say "OK"' })
  end

  # ConditionEvaluator#parse returns nil for a bare value like "modem" (no
  # [=!<>]), so the operator-form branch of unmatched_extras never saw it -
  # yet StepResolver's simple-value match honours exactly this condition at
  # runtime, so it is just as stale as an operator-form one that names a
  # value the step no longer offers.
  test "a bare stale value with no operator is unmatched too" do
    step = question(answer_type: "dropdown", options: [{ "label" => "Router", "value" => "router" }])
    stale = Transition.create!(step: step, target_step: @a, condition: "modem")

    assert_equal [[stale, "modem"]], doors(step).unmatched_extras
  end

  test "a bare value matching an answer is that door, not an unmatched extra" do
    step = question(answer_type: "dropdown", options: [{ "label" => "Router", "value" => "router" }])
    wired = Transition.create!(step: step, target_step: @a, condition: "router")

    d = doors(step)
    door = d.doors.find { |x| x.label == "Router" }
    assert_equal wired, door.transition
    assert_empty d.unmatched_extras
  end

  test "a step with no answers never reports a bare extra" do
    Transition.create!(step: @a, target_step: @b, condition: "modem")

    assert_empty doors(@a).unmatched_extras
  end
end
