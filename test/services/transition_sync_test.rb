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

  def new_payload(rendered:, minted:, rows:)
    { rendered: rendered, minted: minted, rows: rows }.to_json
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

  test "renamed_variable rewrites a row's condition to the new name" do
    uuid = SecureRandom.uuid
    TransitionSync.call(@question, payload(known: [uuid], rows: [
                                             { uuid: uuid, target_uuid: @a.uuid, condition: "untitled_question > 3", label: "" }
                                           ]), renamed_variable: %w[untitled_question light_green])

    assert_equal "light_green > 3", @question.transitions.reload.sole.condition
  end

  test "renamed_variable leaves a row on another variable alone" do
    uuid = SecureRandom.uuid
    TransitionSync.call(@question, payload(known: [uuid], rows: [
                                             { uuid: uuid, target_uuid: @a.uuid, condition: "tier == 'gold'", label: "" }
                                           ]), renamed_variable: %w[untitled_question light_green])

    assert_equal "tier == 'gold'", @question.transitions.reload.sole.condition
  end

  test "without renamed_variable nothing is rewritten" do
    uuid = SecureRandom.uuid
    TransitionSync.call(@question, payload(known: [uuid], rows: [
                                             { uuid: uuid, target_uuid: @a.uuid, condition: "untitled_question > 3", label: "" }
                                           ]))

    assert_equal "untitled_question > 3", @question.transitions.reload.sole.condition
  end

  # --- The rendered/minted shape (Task B1) ---

  test "a row whose uuid is in rendered but no longer exists is not created and is reported skipped" do
    uuid = SecureRandom.uuid
    result = TransitionSync.call(@question, new_payload(rendered: [uuid], minted: [], rows: [
                                                          { uuid: uuid, target_uuid: @a.uuid, condition: "", label: "" }
                                                        ]))

    assert_not Transition.exists?(uuid: uuid)
    assert_equal [uuid], result.skipped
  end

  test "a row whose uuid is in minted and does not exist is created" do
    uuid = SecureRandom.uuid
    result = TransitionSync.call(@question, new_payload(rendered: [], minted: [uuid], rows: [
                                                          { uuid: uuid, target_uuid: @a.uuid, condition: "", label: "" }
                                                        ]))

    assert Transition.exists?(uuid: uuid)
    assert_equal [], result.skipped
  end

  test "a row in neither rendered nor minted is not created and not reported" do
    uuid = SecureRandom.uuid
    result = TransitionSync.call(@question, new_payload(rendered: [], minted: [], rows: [
                                                          { uuid: uuid, target_uuid: @a.uuid, condition: "", label: "" }
                                                        ]))

    assert_not Transition.exists?(uuid: uuid)
    assert_equal [], result.skipped
  end

  test "a uuid only in rendered, missing from rows, is destroyed" do
    old = Transition.create!(step: @question, target_step: @a, condition: "light > 3")

    TransitionSync.call(@question, new_payload(rendered: [old.uuid], minted: [], rows: []))

    assert_not Transition.exists?(old.id)
  end

  test "a uuid only in minted, missing from rows, is destroyed" do
    old = Transition.create!(step: @question, target_step: @a, condition: "light > 3")

    TransitionSync.call(@question, new_payload(rendered: [], minted: [old.uuid], rows: []))

    assert_not Transition.exists?(old.id)
  end

  test "an existing row is updated when named only in rendered" do
    old = Transition.create!(step: @question, target_step: @a, condition: "light > 3")

    TransitionSync.call(@question, new_payload(rendered: [old.uuid], minted: [], rows: [
                                                 { uuid: old.uuid, target_uuid: @b.uuid, condition: "light > 3", label: "" }
                                               ]))

    assert_equal @b.id, old.reload.target_step_id
  end

  test "an existing row is updated when named only in minted" do
    old = Transition.create!(step: @question, target_step: @a, condition: "light > 3")

    TransitionSync.call(@question, new_payload(rendered: [], minted: [old.uuid], rows: [
                                                 { uuid: old.uuid, target_uuid: @b.uuid, condition: "light > 3", label: "" }
                                               ]))

    assert_equal @b.id, old.reload.target_step_id
  end

  test "the legacy known payload still creates a missing row and reports nothing skipped" do
    uuid = SecureRandom.uuid
    result = TransitionSync.call(@question, payload(known: [uuid], rows: [
                                                      { uuid: uuid, target_uuid: @a.uuid, condition: "", label: "" }
                                                    ]))

    assert Transition.exists?(uuid: uuid)
    assert_equal [], result.skipped
  end

  test "a payload with neither known nor rendered/minted is malformed" do
    assert_raises(TransitionSync::Malformed) do
      TransitionSync.call(@question, { rows: [] }.to_json)
    end
  end

  test "when both known and rendered/minted are present, the new shape wins and known is ignored" do
    known_uuid = SecureRandom.uuid
    result = TransitionSync.call(@question, {
      known: [known_uuid], rendered: [], minted: [],
      rows: [{ uuid: known_uuid, target_uuid: @a.uuid, condition: "", label: "" }]
    }.to_json)

    assert_not Transition.exists?(uuid: known_uuid), "known must not create a row once rendered/minted are present"
    assert_equal [], result.skipped
  end

  test "known is ignored for deletion once rendered/minted are present" do
    old = Transition.create!(step: @question, target_step: @a, condition: "light > 3")

    TransitionSync.call(@question, { known: [old.uuid], rendered: [], minted: [], rows: [] }.to_json)

    assert Transition.exists?(old.id), "known must be ignored for the delete set once rendered/minted are present"
  end

  test "renamed_variable rewrites a row's condition under the new shape too" do
    uuid = SecureRandom.uuid
    TransitionSync.call(@question, new_payload(rendered: [], minted: [uuid], rows: [
                                                 { uuid: uuid, target_uuid: @a.uuid, condition: "untitled_question > 3", label: "" }
                                               ]), renamed_variable: %w[untitled_question light_green])

    assert_equal "light_green > 3", @question.transitions.reload.sole.condition
  end

  test "a rendered row whose target was cleared is removed, not reported skipped" do
    old = Transition.create!(step: @question, target_step: @a, condition: "light > 3")

    result = TransitionSync.call(@question, new_payload(rendered: [old.uuid], minted: [], rows: [
                                                          { uuid: old.uuid, target_uuid: "", condition: "light > 3", label: "" }
                                                        ]))

    assert_not Transition.exists?(old.id)
    assert_equal [], result.skipped
  end

  test "a rendered row with no target and no existing transition writes nothing and is not reported skipped" do
    uuid = SecureRandom.uuid
    result = TransitionSync.call(@question, new_payload(rendered: [uuid], minted: [], rows: [
                                                          { uuid: uuid, target_uuid: "", condition: "", label: "" }
                                                        ]))

    assert_not Transition.exists?(uuid: uuid)
    assert_equal [], result.skipped
  end

  test "the same new-shape payload twice writes one transition" do
    uuid = SecureRandom.uuid
    json = new_payload(rendered: [], minted: [uuid], rows: [
                         { uuid: uuid, target_uuid: @a.uuid, condition: "", label: "" }
                       ])
    TransitionSync.call(@question, json)

    assert_no_difference("Transition.count") { TransitionSync.call(@question, json) }
  end

  test "a default edge settles after a conditional one under the new shape" do
    default_uuid = SecureRandom.uuid
    cond_uuid = SecureRandom.uuid
    TransitionSync.call(@question, new_payload(rendered: [], minted: [default_uuid, cond_uuid], rows: [
                                                 { uuid: default_uuid, target_uuid: @a.uuid, condition: "", label: "" },
                                                 { uuid: cond_uuid, target_uuid: @b.uuid, condition: "light > 3", label: "" }
                                               ]))

    assert_equal [cond_uuid, default_uuid], @question.transitions.reload.map(&:uuid)
  end

  test "cannot create another step's transition uuid via minted" do
    other = Transition.create!(step: @a, target_step: @b)

    assert_raises(ActiveRecord::RecordInvalid) do
      TransitionSync.call(@question, new_payload(rendered: [], minted: [other.uuid], rows: [
                                                   { uuid: other.uuid, target_uuid: @b.uuid, condition: "", label: "" }
                                                 ]))
    end
    assert_equal @a.id, other.reload.step_id
  end

  test "a foreign uuid claimed only as rendered is skipped, not touched" do
    other = Transition.create!(step: @a, target_step: @b)

    result = TransitionSync.call(@question, new_payload(rendered: [other.uuid], minted: [], rows: [
                                                          { uuid: other.uuid, target_uuid: @b.uuid, condition: "", label: "" }
                                                        ]))

    assert_equal @a.id, other.reload.step_id
    assert_equal [other.uuid], result.skipped
  end
end
