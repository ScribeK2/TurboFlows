require "test_helper"

class TransitionSyncTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "sync-#{SecureRandom.hex(4)}@example.com", password: "password123456")
    @workflow = Workflow.create!(title: "Sync", user: @user)
    @question = Steps::Question.create!(workflow: @workflow, title: "Light green?", position: 0,
                                        answer_type: "yes_no", variable_name: "light")
    @a = Steps::Action.create!(workflow: @workflow, title: "A", position: 1)
    @b = Steps::Action.create!(workflow: @workflow, title: "B", position: 2)
  end

  def payload(known:, rows:)
    { known: known, rows: rows }.to_json
  end

  test "creates a row the editor added" do
    uuid = SecureRandom.uuid
    TransitionSync.call(@question, payload(known: [uuid], rows: [
                                             { uuid: uuid, target_uuid: @a.uuid, condition: "light > 3", label: "High" }
                                           ]))

    t = @question.transitions.reload.sole
    assert_equal [uuid, @a.id, "light > 3", "High"], [t.uuid, t.target_step_id, t.condition, t.label]
  end

  test "the same payload twice writes one transition" do
    uuid = SecureRandom.uuid
    json = payload(known: [uuid], rows: [{ uuid: uuid, target_uuid: @a.uuid, condition: "", label: "" }])
    TransitionSync.call(@question, json)

    assert_no_difference("Transition.count") { TransitionSync.call(@question, json) }
  end

  test "never deletes a transition the editor was not shown" do
    grown = Transition.create!(step: @question, target_step: @b, condition: "light == 'no'", label: "No")

    TransitionSync.call(@question, payload(known: [], rows: []))

    assert Transition.exists?(grown.id), "an edge outside `known` was deleted"
  end

  test "deletes a known row that is no longer listed" do
    old = Transition.create!(step: @question, target_step: @a, condition: "light > 3")

    TransitionSync.call(@question, payload(known: [old.uuid], rows: []))

    assert_not Transition.exists?(old.id)
  end

  test "retargets an existing row in place" do
    old = Transition.create!(step: @question, target_step: @a, condition: "light > 3")

    TransitionSync.call(@question, payload(known: [old.uuid], rows: [
                                             { uuid: old.uuid, target_uuid: @b.uuid, condition: "light > 3", label: "" }
                                           ]))

    assert_equal @b.id, old.reload.target_step_id
  end

  test "a row whose target was cleared is removed" do
    old = Transition.create!(step: @question, target_step: @a, condition: "light > 3")

    TransitionSync.call(@question, payload(known: [old.uuid], rows: [
                                             { uuid: old.uuid, target_uuid: "", condition: "light > 3", label: "" }
                                           ]))

    assert_not Transition.exists?(old.id)
  end

  test "a new row with no target yet writes nothing" do
    uuid = SecureRandom.uuid
    assert_no_difference("Transition.count") do
      TransitionSync.call(@question, payload(known: [uuid], rows: [{ uuid: uuid, target_uuid: "", condition: "", label: "" }]))
    end
  end

  test "cannot reach another step's transition by its uuid" do
    other = Transition.create!(step: @a, target_step: @b)

    assert_raises(ActiveRecord::RecordInvalid) do
      TransitionSync.call(@question, payload(known: [other.uuid], rows: [
                                               { uuid: other.uuid, target_uuid: @b.uuid, condition: "", label: "" }
                                             ]))
    end
    assert_equal @a.id, other.reload.step_id
  end

  test "a default edge settles after a conditional one" do
    default_uuid = SecureRandom.uuid
    cond_uuid = SecureRandom.uuid
    TransitionSync.call(@question, payload(known: [], rows: [
                                             { uuid: default_uuid, target_uuid: @a.uuid, condition: "", label: "" },
                                             { uuid: cond_uuid, target_uuid: @b.uuid, condition: "light > 3", label: "" }
                                           ]))

    assert_equal [cond_uuid, default_uuid], @question.transitions.reload.map(&:uuid)
  end

  test "an array payload is refused, not read as delete-everything" do
    Transition.create!(step: @question, target_step: @a)
    assert_raises(TransitionSync::Malformed) { TransitionSync.call(@question, "[]") }
    assert_equal 1, @question.transitions.count
  end

  test "unparseable JSON is refused" do
    assert_raises(TransitionSync::Malformed) { TransitionSync.call(@question, "not json{{") }
  end
end
