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

  test "door_for finds a door by any spelling of its condition" do
    step = question(answer_type: "yes_no")
    assert_equal "No", doors(step).door_for("light=='NO'").label
    assert_nil doors(step).door_for("tier == 'gold'")
    assert_nil doors(step).door_for(nil)
    assert_equal :next, doors(@a).door_for(nil).kind
  end
end
