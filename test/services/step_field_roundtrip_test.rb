require "test_helper"

# Every field a step carries must survive a full round trip.
#
# There are two round trips, and one of them destroys data rather than merely
# losing it. Publishing snapshots the graph through StepSerializer; restoring a
# version feeds that snapshot to StepBuilder with `replace: true`, which deletes
# the live steps first. So a field the serializer omits is not "missing from the
# export" — it is gone from the workflow the moment someone restores a version.
#
# Note the shape of `jumps`: an Array of {condition, next_step_id}. StepResolver
# ignores anything else outright (`return nil unless ... is_a?(Array)`), and the
# import normalizer only preserves Arrays — so a fixture using a Hash would be
# asserting the preservation of a value the app cannot act on.
#
# The map of which fields belong to which step type is declared in four places
# that have disagreed before. These tests assert the round trip rather than the
# declarations, so they stay true however that map is eventually consolidated.
class StepFieldRoundtripTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(
      email: "roundtrip-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "admin"
    )
    @workflow = Workflow.create!(title: "Roundtrip WF", user: @user)

    @question = Steps::Question.create!(
      workflow: @workflow, position: 0, title: "Q", question: "Q?",
      variable_name: "qv", answer_type: "yes_no", can_resolve: true
    )
    @action = Steps::Action.create!(
      workflow: @workflow, position: 1, title: "A", action_type: "manual",
      can_resolve: true, jumps: [{ "condition" => "completed", "next_step_id" => "target-uuid" }],
      output_fields: [{ "name" => "ref", "value" => "x" }]
    )
    @message = Steps::Message.create!(
      workflow: @workflow, position: 2, title: "M",
      jumps: [{ "condition" => "skip", "next_step_id" => "other-uuid" }]
    )
    @escalate = Steps::Escalate.create!(
      workflow: @workflow, position: 3, title: "E", target_type: "supervisor",
      target_value: "team-a", priority: "urgent", reason_required: true
    )
    @resolve = Steps::Resolve.create!(
      workflow: @workflow, position: 4, title: "R", resolution_type: "success",
      resolution_code: "RES-42", notes_required: true, survey_trigger: true
    )
    @resolve.update!(description: "Custom resolve description")
    @action.update!(instructions: "Do the thing")
    @message.update!(content: "Say the thing")
    @escalate.update!(notes: "Escalation notes")

    [[@question, @action], [@action, @message], [@message, @escalate],
     [@escalate, @resolve]].each_with_index do |(from, to), i|
      Transition.create!(step: from, target_step: to, position: 0)
    end
    @workflow.update!(start_step: @question)
  end

  # Exactly what WorkflowVersionsController#restore does with a published
  # snapshot: serialize, then rebuild the graph over the top of the live one.
  def restore_through_snapshot
    snapshot = StepSerializer.call(@workflow)
    StepBuilder.call(@workflow, snapshot, start_node_uuid: @question.uuid, replace: true)
    @workflow.reload
  end

  def step_of(type)
    @workflow.steps.find { |s| s.type == type }
  end

  test "restoring a published version keeps an Action's jumps" do
    restore_through_snapshot

    assert_equal([{ "condition" => "completed", "next_step_id" => "target-uuid" }],
                 step_of("Steps::Action").jumps,
                 "jumps drive branching — losing them silently reroutes the workflow")
  end

  test "restoring a published version keeps a Message's jumps" do
    restore_through_snapshot

    assert_equal([{ "condition" => "skip", "next_step_id" => "other-uuid" }],
                 step_of("Steps::Message").jumps)
  end

  test "restoring a published version keeps a Resolve's resolution_code" do
    restore_through_snapshot

    assert_equal "RES-42", step_of("Steps::Resolve").resolution_code,
                 "the code lands in results['_resolution']['code'] at run time"
  end

  test "restoring a published version keeps a Question's can_resolve" do
    restore_through_snapshot

    assert step_of("Steps::Question").can_resolve,
           "the serializer and the permit list both carry it; the builder used to drop it"
  end

  test "restoring a published version keeps every rich text body" do
    restore_through_snapshot

    assert_equal "Do the thing", step_of("Steps::Action").instructions.to_plain_text.strip
    assert_equal "Say the thing", step_of("Steps::Message").content.to_plain_text.strip
    assert_equal "Escalation notes", step_of("Steps::Escalate").notes.to_plain_text.strip
    assert_equal "Custom resolve description",
                 step_of("Steps::Resolve").description.to_plain_text.strip
  end

  test "restoring a published version keeps the ordinary type-specific fields" do
    restore_through_snapshot

    q = step_of("Steps::Question")
    assert_equal "Q?", q.question
    assert_equal "qv", q.variable_name
    assert_equal "yes_no", q.answer_type

    e = step_of("Steps::Escalate")
    assert_equal "supervisor", e.target_type
    assert_equal "team-a", e.target_value
    assert_equal "urgent", e.priority
    assert e.reason_required

    r = step_of("Steps::Resolve")
    assert_equal "success", r.resolution_type
    assert r.notes_required
    assert r.survey_trigger
  end

  test "an exported workflow re-imports with its routing intact" do
    exported = { "title" => "Reimported", "steps" => StepSerializer.call(@workflow) }.to_json

    result = WorkflowImporter.new(@user, format: :json, content: exported).call

    assert_predicate result, :success?, result.errors.join(", ")
    steps = result.workflow.steps
    assert_equal([{ "condition" => "completed", "next_step_id" => "target-uuid" }],
                 steps.find { |s| s.type == "Steps::Action" }.jumps,
                 "export -> import must not silently reroute the workflow")
    assert_equal([{ "condition" => "skip", "next_step_id" => "other-uuid" }],
                 steps.find { |s| s.type == "Steps::Message" }.jumps)
    assert_equal "RES-42", steps.find { |s| s.type == "Steps::Resolve" }.resolution_code
  end
end
