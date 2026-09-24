require "test_helper"

# StepResolver takes a step's transitions in file order and the first match
# wins, and a transition with no condition always matches. So anything listed
# after one is a branch the runner never reaches. The builder keeps a default
# last on every write (Transition.settle_positions) and flags a stored one as
# :shadowed_connection, but that is a warning, so it publishes - and an import
# was the only thing that could write the shape at all. An AI-generated file
# that lists its default first used to pass strict import with no error and
# no warning, with every conditional branch below it dead.
class StrictImportTransitionOrderTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "strict-order-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
  end

  teardown do
    Workflow.where(title: "Transition Order").destroy_all
    User.where("email LIKE ?", "strict-order-%").destroy_all
  end

  test "a conditional transition listed after the default is refused" do
    report = validate(question_transitions([{ target_id: "done" },
                                            { target_id: "fix", condition: "ok == 'no'" }]))

    assert_not report.valid?
    error = report.errors.find { |e| e[:code] == "shadowed_transition" }
    assert_not_nil error, report.errors.inspect
    assert_equal "workflows[0].steps[0].transitions[1]", error[:path],
                 "the path names the dead transition, not the default above it"
    assert_match(/never/, error[:message])
    assert_match(/last/, error[:message])
  end

  test "a second transition with no condition is refused, since the first always wins" do
    report = validate(question_transitions([{ target_id: "fix", condition: "ok == 'no'" },
                                            { target_id: "done" },
                                            { target_id: "fix" }]))

    error = report.errors.find { |e| e[:code] == "shadowed_transition" }
    assert_not_nil error, report.errors.inspect
    assert_equal "workflows[0].steps[0].transitions[2]", error[:path]
  end

  test "every dead transition on a step is reported at once" do
    report = validate(question_transitions([{ target_id: "done" },
                                            { target_id: "fix", condition: "ok == 'no'" },
                                            { target_id: "fix", condition: "ok == 'maybe'" }]))

    paths = report.errors.select { |e| e[:code] == "shadowed_transition" }.pluck(:path)
    assert_equal %w[workflows[0].steps[0].transitions[1] workflows[0].steps[0].transitions[2]], paths
  end

  test "a default listed last is accepted" do
    report = validate(question_transitions([{ target_id: "fix", condition: "ok == 'no'" },
                                            { target_id: "done" }]))

    assert_predicate report, :valid?, report.errors.inspect
  end

  test "a condition of only whitespace counts as no condition" do
    report = validate(question_transitions([{ target_id: "done", condition: "  " },
                                            { target_id: "fix", condition: "ok == 'no'" }]))

    assert_includes report.errors.pluck(:code), "shadowed_transition"
  end

  # The message says to move the default last. Doing that has to produce a file
  # that imports AND routes each answer where it says, or the advice is a lie.
  test "moving the default last, as the error says, imports and routes the conditional branch" do
    refused = question_transitions([{ target_id: "done" },
                                    { target_id: "fix", condition: "ok == 'no'" }])
    assert_not validate(refused).valid?

    fixed = question_transitions([{ target_id: "fix", condition: "ok == 'no'" },
                                  { target_id: "done" }])
    content = fixed.to_json
    report = StrictImportValidator.new(user: @user, content:).validate
    assert_predicate report, :valid?, report.errors.inspect

    result = WorkflowImporter.new(@user, format: :json, content:, strict_report: report).call
    assert_predicate result, :success?

    workflow = result.workflow
    question = workflow.steps.find_by(uuid: "q")
    resolver = StepResolver.new(workflow)
    assert_equal "fix", resolver.resolve_next(question, { "ok" => "no" }).uuid
    assert_equal "done", resolver.resolve_next(question, { "ok" => "yes" }).uuid
  end

  private

  def validate(hash)
    StrictImportValidator.new(user: @user, content: hash.to_json).validate
  end

  def question_transitions(transitions)
    {
      schema_version: "1",
      workflows: [{
        title: "Transition Order",
        steps: [
          { id: "q", type: "question", title: "Working?", question: "Is it working?",
            answer_type: "multiple_choice", variable_name: "ok",
            options: [{ label: "Yes", value: "yes" }, { label: "No", value: "no" },
                      { label: "Maybe", value: "maybe" }],
            transitions: },
          { id: "fix", type: "resolve", title: "Fix", resolution_type: "success" },
          { id: "done", type: "resolve", title: "Done", resolution_type: "success" }
        ]
      }]
    }
  end
end
