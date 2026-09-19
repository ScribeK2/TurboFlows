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

  # The same rule under BOTH readings of a value: the old writer's spelling
  # (backslash kept literally) and the new one's (backslash escaped) name one
  # answer, so whichever is the repeat is a repeat - not a value the step
  # stopped offering. #unmatched_extras has to read a condition exactly as
  # wiring a door reads it, or the health panel disagrees with the row.
  test "a duplicate spelled with the other backslash escaping is not unmatched either" do
    value = %q(C:\temp)
    spellings = ["path == 'C:\\temp'", "path == 'C:\\\\temp'"]
    assert_equal([1, 2], spellings.map { |c| c.count("\\") })

    [spellings, spellings.reverse].each do |first, second|
      step = question(answer_type: "dropdown", variable_name: "path",
                      options: [{ "label" => "Path", "value" => value }])
      Transition.create!(step: step, target_step: @a, condition: first, position: 0)
      duplicate = Transition.create!(step: step, target_step: @b, condition: second, position: 1)

      d = doors(step)
      assert_equal [duplicate], d.extras
      assert_empty d.unmatched_extras, "#{second.inspect} was reported as unmatched"
      step.destroy
    end
  end

  # StepResolver takes the first transition that matches, in position order,
  # and a blank condition always matches. Transition.settle_positions keeps a
  # default edge last for every builder write, but an import can write one
  # first - and then the runner never reaches the edges below it, whatever
  # they say. A door that read as wired there was the lie.
  test "an answer whose own edge sits below a default edge is a stub, because the runner never reaches it" do
    step = question(answer_type: "yes_no")
    default = Transition.create!(step: step, target_step: @a, position: 0)
    dead = Transition.create!(step: step, target_step: @b, condition: "light == 'no'", position: 1)

    d = doors(step)
    no_door = d.doors.find { |door| door.label == "No" }

    assert_predicate no_door, :stub?
    assert_equal default, d.fallback.transition
    assert_equal [dead], d.extras
    assert_equal [dead], d.shadowed
    assert_empty d.missing, "the default edge catches No, so it leads somewhere"
    assert_equal @a, StepResolver.new(@workflow).resolve_next(step, { "light" => "no" }),
                 "the runner itself takes the default edge for No"
  end

  test "an edge above the default edge still claims its door, and nothing is shadowed" do
    step = question(answer_type: "yes_no")
    live = Transition.create!(step: step, target_step: @b, condition: "light == 'no'", position: 0)
    Transition.create!(step: step, target_step: @a, position: 1)

    d = doors(step)
    assert_equal live, d.doors.find { |door| door.label == "No" }.transition
    assert_empty d.shadowed
  end

  # Doors has to read the order exactly as StepResolver does, or "the runner
  # never reaches it" is a guess: a default edge with no position is tried
  # LAST, so it shadows nothing.
  test "a default edge with no position shadows nothing, because the runner tries it last" do
    step = question(answer_type: "yes_no")
    Transition.create!(step: step, target_step: @a, position: nil)
    live = Transition.create!(step: step, target_step: @b, condition: "light == 'no'", position: 0)

    d = doors(step)
    assert_equal live, d.doors.find { |door| door.label == "No" }.transition
    assert_empty d.shadowed
    assert_equal @b, StepResolver.new(@workflow).resolve_next(step, { "light" => "no" })
  end

  test "a second default edge is not reported as shadowed: re-sorting cannot fix it" do
    Transition.create!(step: @a, target_step: @b, position: 0)
    other = Steps::Action.create!(workflow: @workflow, title: "C", position: 12)
    Transition.create!(step: @a, target_step: other, position: 1)

    assert_empty doors(@a).shadowed
  end

  test "door_for finds a door by any spelling of its condition" do
    step = question(answer_type: "yes_no")
    assert_equal "No", doors(step).door_for("light=='NO'").label
    assert_nil doors(step).door_for("tier == 'gold'")
    assert_nil doors(step).door_for(nil)
    assert_equal :next, doors(@a).door_for(nil).kind
  end

  # ConditionEvaluator now unescapes a well-formed string comparison's value
  # (either reading: unescaped, or literal with backslashes kept - see its
  # #value_matches? comment), so the door's own escaped condition - the same
  # string condition_for writes - IS what the runner takes. Doors reports
  # what the runner does, and the runner now takes this.
  test "an apostrophe option's own condition IS read as wired, because the runner takes it" do
    step = question(answer_type: "dropdown",
                    options: [{ "label" => "Don't know", "value" => "Don't know" }, { "label" => "Router", "value" => "router" }])
    door = doors(step).doors.find { |d| d.label == "Don't know" }
    wired = Transition.create!(step: step, target_step: @a, condition: door.condition)

    d = doors(step)
    found = d.doors.find { |x| x.label == "Don't know" }
    assert_not found.stub?
    assert_equal @a, found.target_step
    assert_not_includes d.extras, wired
    assert_empty d.unmatched_extras
  end

  # Proves the claim above against the runtime itself, not against Doors
  # agreeing with itself. The condition string below has exactly one
  # backslash before the apostrophe - the same string condition_for writes -
  # and its unescaped reading is exactly "Don't know".
  test "the runner itself takes an apostrophe operator-form condition" do
    condition = "light == 'Don\\'t know'"
    assert_equal 1, condition.count("\\")
    assert ConditionEvaluator.evaluate(condition, { "light" => "Don't know" })
    assert ConditionEvaluator.evaluate("light == 'router'", { "light" => "Router" })
  end

  # A value containing a backslash round-trips through condition_for however
  # it was written: the NEW writer escapes the backslash (two backslash
  # characters stored), so the runner's UNESCAPED reading matches the plain
  # option value.
  test "an option value containing a backslash round-trips through condition_for" do
    value = 'C:\temp'
    assert_equal 1, value.count("\\")
    step = question(answer_type: "dropdown",
                    options: [{ "label" => "C Drive", "value" => value }, { "label" => "Router", "value" => "router" }])
    door = doors(step).doors.find { |d| d.label == "C Drive" }
    assert_equal 2, door.condition.count("\\")
    assert_equal "light == 'C:\\\\temp'", door.condition

    wired = Transition.create!(step: step, target_step: @a, condition: door.condition)
    found = doors(step).doors.find { |x| x.label == "C Drive" }
    assert_not found.stub?
    assert_equal @a, found.target_step
    assert ConditionEvaluator.evaluate(wired.condition, { "light" => value })
  end

  # One row per shape a stored condition's backslash can already be in: the
  # OLD writer (never escaped a backslash), the NEW writer (escapes it), and
  # a value ending in a bare backslash (the legacy-split fallback, since it
  # has no valid close under the tokenizer's escape rule). Each condition is
  # built from `value` by simple interpolation (OLD writer's own shape) or by
  # the same escaping `condition_for` uses (NEW writer's shape), and the
  # backslash count is asserted so each case is provably the string its
  # description says, not a guess about Ruby's own string escaping.
  test "a door reads as wired under every backslash escaping the runner accepts" do
    old_style = ->(value) { "path == '#{value}'" }
    new_style = ->(value) { "path == '#{value.gsub(/[\\']/) { |char| "\\#{char}" }}'" }

    cases = [
      ["OLD writer, one backslash", %q(C:\temp), old_style.call(%q(C:\temp)), 1],
      ["OLD writer, another shape", %q(DOMAIN\user), old_style.call(%q(DOMAIN\user)), 1],
      ["OLD writer, two leading and one inner backslash", "\\\\server\\docs", old_style.call("\\\\server\\docs"), 3],
      ["NEW writer, backslash escaped", %q(C:\temp), new_style.call(%q(C:\temp)), 2],
      ["value ends in a bare backslash, the legacy path", "C:\\", old_style.call("C:\\"), 1]
    ]

    cases.each do |description, value, condition, backslash_count|
      assert_equal backslash_count, condition.count("\\"), "#{description}: #{condition.inspect}"

      step = question(answer_type: "dropdown", variable_name: "path",
                      options: [{ "label" => "Path", "value" => value }, { "label" => "Other", "value" => "other" }])
      Transition.create!(step: step, target_step: @a, condition: condition)

      door = doors(step).doors.find { |d| d.label == "Path" }
      assert_not door.stub?, "#{description}: #{condition.inspect} was not read as wired for #{value.inspect}"
      assert_equal @a, door.target_step, description
      assert ConditionEvaluator.evaluate(condition, { "path" => value }),
             "#{description}: the runner itself does not take #{condition.inspect} for #{value.inspect}"
    end
  end

  test "a door does not wire when the condition's two readings are something else entirely" do
    step = question(answer_type: "dropdown", variable_name: "path",
                    options: [{ "label" => "Router", "value" => "router" }])
    stale = Transition.create!(step: step, target_step: @a, condition: %q(path == 'C:\temp'))

    door = doors(step).doors.find { |d| d.label == "Router" }
    assert_predicate door, :stub?
    assert_equal [stale], doors(step).extras
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
  # The CONDITION side is now read through the tokenizer's escape rule, and a
  # double quote needs no escaping inside a single-quoted value, so this
  # door's own condition is already a well-formed string comparison and the
  # runner takes it.
  test "a value containing a quote character IS read as wired by its own condition" do
    step = question(answer_type: "dropdown",
                    options: [{ "label" => 'Say "OK"', "value" => 'Say "OK"' }, { "label" => "Router", "value" => "router" }])
    door = doors(step).doors.find { |d| d.label == 'Say "OK"' }
    wired = Transition.create!(step: step, target_step: @a, condition: door.condition)

    d = doors(step)
    found = d.doors.find { |x| x.label == 'Say "OK"' }
    assert_not found.stub?
    assert_equal @a, found.target_step
    assert_not_includes d.extras, wired
    assert ConditionEvaluator.evaluate(door.condition, { "light" => 'Say "OK"' })
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

  # unmatched_extras used to report the UNESCAPED reading (parsed[:value]),
  # which drops the backslash the author actually typed - "D:\gone" was
  # reported as "D:gone", a value that was never really the stale option.
  test "a stale connection with a backslash is reported as the author wrote it, not unescaped" do
    step = question(answer_type: "dropdown", options: [{ "label" => "Router", "value" => "router" }])
    stale = Transition.create!(step: step, target_step: @a, condition: "light == 'D:\\gone'")

    assert_equal [[stale, "D:\\gone"]], doors(step).unmatched_extras
  end
end
