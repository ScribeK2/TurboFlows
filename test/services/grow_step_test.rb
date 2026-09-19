require "test_helper"

class GrowStepTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "grow-#{SecureRandom.hex(4)}@example.com", password: "password123456")
    @workflow = Workflow.create!(title: "Grow", user: @user)
  end

  def step(klass, title, position, **attrs)
    klass.create!(workflow: @workflow, title: title, position: position, **attrs)
  end

  test "with no from_step it appends and makes no transition" do
    first = step(Steps::Action, "First", 1)

    grown = nil
    assert_no_difference("Transition.count") do
      grown = GrowStep.create(workflow: @workflow, step_type: "message")
    end

    assert_instance_of Steps::Message, grown
    assert_equal "Untitled Message", grown.title
    assert_operator grown.position, :>, first.position
  end

  test "the first step of a workflow becomes its start step" do
    grown = GrowStep.create(workflow: @workflow, step_type: "question")
    assert_equal grown.id, @workflow.reload.start_step_id
  end

  test "with a from_step it lands directly after it, shifts the rest, and wires the edge" do
    parent = step(Steps::Action, "Parent", 1)
    later = step(Steps::Action, "Later", 2)

    grown = GrowStep.create(workflow: @workflow, step_type: "action", from_step: parent)

    assert_equal [parent.id, grown.id, later.id], @workflow.steps.reload.order(:position).map(&:id)
    edge = parent.transitions.reload.sole
    assert_equal grown.id, edge.target_step_id
    assert_nil edge.condition
  end

  test "it works whatever numbering the workflow uses" do
    parent = step(Steps::Action, "Parent", 0)
    later = step(Steps::Action, "Later", 1)

    grown = GrowStep.create(workflow: @workflow, step_type: "action", from_step: parent)

    assert_equal [parent.id, grown.id, later.id], @workflow.steps.reload.order(:position).map(&:id)
  end

  test "a named door carries its label and condition" do
    question = step(Steps::Question, "Light green?", 1, answer_type: "yes_no", variable_name: "light")

    grown = GrowStep.create(workflow: @workflow, step_type: "action", from_step: question,
                            label: "No", condition: "light == 'no'")

    edge = question.transitions.reload.sole
    assert_equal ["No", "light == 'no'", grown.id], [edge.label, edge.condition, edge.target_step_id]
  end

  test "a conditional edge is placed ahead of an existing default" do
    question = step(Steps::Question, "Q", 1, answer_type: "yes_no", variable_name: "q")
    fallback = step(Steps::Action, "Fallback", 2)
    Transition.create!(step: question, target_step: fallback, position: 0)

    GrowStep.create(workflow: @workflow, step_type: "action", from_step: question,
                    label: "Yes", condition: "q == 'yes'")

    assert_equal ["q == 'yes'", nil], question.transitions.reload.map(&:condition)
  end

  test "refuses to grow from a Resolve" do
    resolve = step(Steps::Resolve, "Done", 1)
    assert_no_difference("Step.count") do
      assert_raises(GrowStep::Refused) { GrowStep.create(workflow: @workflow, step_type: "action", from_step: resolve) }
    end
  end

  test "refuses to grow from a handoff" do
    target = Workflow.create!(title: "Elsewhere", user: @user)
    handoff = step(Steps::SubFlow, "Hand off", 1, sub_flow_workflow_id: target.id, sub_flow_returns: false)
    assert_raises(GrowStep::Refused) { GrowStep.create(workflow: @workflow, step_type: "action", from_step: handoff) }
  end

  test "refuses a from_step in another workflow" do
    other = Workflow.create!(title: "Other", user: @user)
    foreign = Steps::Action.create!(workflow: other, title: "Foreign", position: 1)
    assert_raises(GrowStep::Refused) { GrowStep.create(workflow: @workflow, step_type: "action", from_step: foreign) }
  end

  # A stub's data-grow-* attributes go stale when the door is wired between
  # the row rendering and "New step" being pressed - another editor, a second
  # click racing the first. A second edge on that door could never fire (first
  # match wins), so the step it reached would be one nothing points at.
  test "refuses to grow from a door that is already wired, and adds nothing" do
    question = step(Steps::Question, "Light green?", 1, answer_type: "yes_no", variable_name: "light")
    wired = step(Steps::Action, "Already there", 2)
    Transition.create!(step: question, target_step: wired, condition: "light == 'no'", label: "No")

    error = assert_raises(GrowStep::Refused) do
      GrowStep.create(workflow: @workflow, step_type: "action", from_step: question,
                      label: "No", condition: "light=='NO'")
    end

    assert_match(/already leads to/, error.message)
    assert_equal [wired.id], question.transitions.reload.map(&:target_step_id)
    assert_equal 2, @workflow.steps.count
    assert_equal 2, wired.reload.position
  end

  test "refuses to grow from a Next door that is already wired" do
    parent = step(Steps::Action, "Parent", 1)
    child = step(Steps::Action, "Child", 2)
    Transition.create!(step: parent, target_step: child)

    assert_raises(GrowStep::Refused) do
      GrowStep.create(workflow: @workflow, step_type: "action", from_step: parent)
    end
    assert_equal 2, @workflow.steps.count
  end

  test "a wired door does not stop a grow from another door on the same step" do
    question = step(Steps::Question, "Light green?", 1, answer_type: "yes_no", variable_name: "light")
    Transition.create!(step: question, target_step: step(Steps::Action, "No side", 2), condition: "light == 'no'")

    grown = GrowStep.create(workflow: @workflow, step_type: "action", from_step: question,
                            label: "Yes", condition: "light == 'yes'")

    assert_includes question.transitions.reload.map(&:target_step_id), grown.id
  end

  # The stub the author pressed says "No" leads nowhere, because a default edge
  # an import sorted first shadows No's own edge. Adding a second No edge would
  # be the wrong repair: once anything settles the order, the OLD edge claims
  # the door and the new step is the one nothing reaches. So the order is put
  # right before the doors are read, and the door turns out to be taken.
  test "a grow from a door shadowed by a default edge settles the order instead of adding a second edge" do
    question = step(Steps::Question, "Light green?", 1, answer_type: "yes_no", variable_name: "light")
    rest = step(Steps::Action, "Everything else", 2)
    no_side = step(Steps::Action, "No side", 3)
    Transition.create!(step: question, target_step: rest, position: 0)
    Transition.create!(step: question, target_step: no_side, condition: "light == 'no'", position: 1)

    assert_raises(GrowStep::Refused) do
      GrowStep.create(workflow: @workflow, step_type: "action", from_step: question,
                      label: "No", condition: "light == 'no'")
    end

    assert_equal ["light == 'no'", nil], question.transitions.reload.order(:position).map(&:condition)
    assert_equal 3, @workflow.steps.count
  end

  test "connect to a door shadowed by a default edge retargets its own edge" do
    question = step(Steps::Question, "Light green?", 1, answer_type: "yes_no", variable_name: "light")
    rest = step(Steps::Action, "Everything else", 2)
    no_side = step(Steps::Action, "No side", 3)
    elsewhere = step(Steps::Action, "Elsewhere", 4)
    Transition.create!(step: question, target_step: rest, position: 0)
    shadowed = Transition.create!(step: question, target_step: no_side, condition: "light == 'no'", position: 1)

    GrowStep.connect(workflow: @workflow, from_step: question, target_step: elsewhere,
                     label: "No", condition: "light == 'no'")

    assert_equal elsewhere.id, shadowed.reload.target_step_id
    assert_equal 2, question.transitions.count
    assert_equal ["light == 'no'", nil], question.transitions.reload.order(:position).map(&:condition)
  end

  # The door a stub names can stop existing before the press lands: the step's
  # answer type or options changed (the panel's own autosave, another editor).
  # The "Next" door of a Question that has since become Yes/No is the costly
  # one - its blank condition would catch BOTH answers, and the health check
  # goes quiet the moment anything catches them.
  test "refuses a blank-condition grow from a step that now has answer doors" do
    question = step(Steps::Question, "Light green?", 1, answer_type: "yes_no", variable_name: "light")

    error = assert_raises(GrowStep::Refused) do
      GrowStep.create(workflow: @workflow, step_type: "action", from_step: question)
    end

    assert_match(/answers have changed/, error.message)
    assert_empty question.transitions.reload
    assert_equal 1, @workflow.steps.count
  end

  test "refuses a grow for an answer the step no longer offers" do
    question = step(Steps::Question, "Which?", 1, answer_type: "multiple_choice", variable_name: "which",
                                                  options: [{ "label" => "Router", "value" => "router" }])

    assert_raises(GrowStep::Refused) do
      GrowStep.create(workflow: @workflow, step_type: "action", from_step: question,
                      label: "Modem", condition: "which == 'modem'")
    end
    assert_empty question.transitions.reload
  end

  test "a refused or invalid grow shifts nothing" do
    parent = step(Steps::Action, "Parent", 1)
    later = step(Steps::Action, "Later", 2)

    assert_raises(ActiveRecord::RecordInvalid) do
      GrowStep.create(workflow: @workflow, step_type: "action", from_step: parent,
                      attrs: { reference_url: "javascript:alert(1)" })
    end
    assert_equal 2, later.reload.position
  end

  test "each builder-made Question gets its own variable name" do
    first = GrowStep.create(workflow: @workflow, step_type: "question")
    second = GrowStep.create(workflow: @workflow, step_type: "question", from_step: first,
                             label: "Yes", condition: "#{first.variable_name} == 'yes'")
    third = GrowStep.create(workflow: @workflow, step_type: "question", from_step: second,
                            label: "Yes", condition: "#{second.variable_name} == 'yes'")

    assert_equal %w[untitled_question untitled_question_2 untitled_question_3],
                 [first, second, third].map(&:variable_name)
  end

  test "a variable name the caller supplies is kept" do
    grown = GrowStep.create(workflow: @workflow, step_type: "question",
                            attrs: { title: "Is it on?", variable_name: "power" })
    assert_equal "power", grown.variable_name
  end

  test "a builder-made Question starts as Yes/No" do
    assert_equal "yes_no", GrowStep.create(workflow: @workflow, step_type: "question").answer_type
  end

  test "an answer type the caller supplies is kept" do
    grown = GrowStep.create(workflow: @workflow, step_type: "question", attrs: { answer_type: "number" })
    assert_equal "number", grown.answer_type
  end

  test "connect wires a door to a step that already exists" do
    question = step(Steps::Question, "Q", 1, answer_type: "yes_no", variable_name: "q")
    done = step(Steps::Resolve, "Done", 2)

    assert_no_difference("Step.count") do
      GrowStep.connect(workflow: @workflow, from_step: question, target_step: done, label: "Yes", condition: "q == 'yes'")
    end

    edge = question.transitions.reload.sole
    assert_equal [done.id, "Yes", "q == 'yes'"], [edge.target_step_id, edge.label, edge.condition]
  end

  test "connect retargets a door that is already wired, however its condition is spelled" do
    question = step(Steps::Question, "Q", 1, answer_type: "yes_no", variable_name: "q")
    first = step(Steps::Action, "First", 2)
    second = step(Steps::Action, "Second", 3)
    existing = Transition.create!(step: question, target_step: first, condition: "Q=='YES'".sub("Q", "q"))

    assert_no_difference("Transition.count") do
      GrowStep.connect(workflow: @workflow, from_step: question, target_step: second, label: "Yes", condition: "q == 'yes'")
    end
    assert_equal second.id, existing.reload.target_step_id
  end

  # An option value containing a backslash: the stored edge here is what the
  # OLD writer produced (the backslash never escaped, one backslash), and the
  # condition the browser now posts is what door.condition renders - the NEW
  # writer's escaping (two backslashes). Step::Doors#door_for still finds the
  # OLD-style transition as the "C Drive" door's own edge (see
  # test/models/step_doors_test.rb), so connect retargets it rather than
  # adding a second edge the runner could never tell apart from the first.
  test "connect retargets an old-style backslash edge instead of adding a second one" do
    options = [{ "label" => "C Drive", "value" => 'C:\temp' }, { "label" => "Router", "value" => "router" }]
    question = step(Steps::Question, "Q", 1, answer_type: "dropdown", variable_name: "path", options: options)
    first = step(Steps::Action, "First", 2)
    second = step(Steps::Action, "Second", 3)
    old_style_condition = "path == 'C:\\temp'"
    assert_equal 1, old_style_condition.count("\\")
    existing = Transition.create!(step: question, target_step: first, condition: old_style_condition)

    new_style_condition = Step::Doors.for(question).doors.find { |d| d.label == "C Drive" }.condition
    assert_equal 2, new_style_condition.count("\\")

    assert_no_difference("Transition.count") do
      GrowStep.connect(workflow: @workflow, from_step: question, target_step: second,
                       label: "C Drive", condition: new_style_condition)
    end
    assert_equal second.id, existing.reload.target_step_id
    assert_equal old_style_condition, existing.condition
  end

  test "connect on a Next door retargets the default edge" do
    action = step(Steps::Action, "A", 1)
    first = step(Steps::Action, "First", 2)
    second = step(Steps::Resolve, "Second", 3)
    existing = Transition.create!(step: action, target_step: first)

    GrowStep.connect(workflow: @workflow, from_step: action, target_step: second)

    assert_equal [second.id], action.transitions.reload.map(&:target_step_id)
    assert_equal existing.id, action.transitions.first.id
  end

  test "connect refuses a Resolve source and a target in another workflow" do
    resolve = step(Steps::Resolve, "Done", 1)
    action = step(Steps::Action, "A", 2)
    other = Workflow.create!(title: "Other", user: @user)
    foreign = Steps::Action.create!(workflow: other, title: "Foreign", position: 1)

    assert_raises(GrowStep::Refused) { GrowStep.connect(workflow: @workflow, from_step: resolve, target_step: action) }
    assert_raises(ActiveRecord::RecordInvalid) { GrowStep.connect(workflow: @workflow, from_step: action, target_step: foreign) }
  end

  test "connect retargeting a wired door onto a collision raises and changes nothing" do
    question = step(Steps::Question, "Q", 1, answer_type: "yes_no", variable_name: "q")
    original_target = step(Steps::Action, "Original", 2)
    colliding_target = step(Steps::Action, "Colliding", 3)
    yes_edge = Transition.create!(step: question, target_step: original_target, condition: "q == 'yes'")
    # An extra: same condition as the "Yes" door, a different target - legal
    # to exist (a hand-made duplicate), but retargeting the door onto it would
    # collide on [step_id, target_step_id, condition]. Doors#build claims the
    # lower-id transition first when neither has a position, so yes_edge (the
    # one created first) is the door and this one stays an extra.
    Transition.create!(step: question, target_step: colliding_target, condition: "q == 'yes'")

    assert_raises(ActiveRecord::RecordInvalid) do
      GrowStep.connect(workflow: @workflow, from_step: question, target_step: colliding_target, label: "Yes", condition: "q == 'yes'")
    end
    assert_equal original_target.id, yes_edge.reload.target_step_id
  end
end
