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
    second = GrowStep.create(workflow: @workflow, step_type: "question", from_step: first)
    third = GrowStep.create(workflow: @workflow, step_type: "question", from_step: second)

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
