require "test_helper"

# The panel submits the WHOLE step on every change (see docs/agents/builder.md),
# so two editors on DIFFERENT fields of one step used to clobber each other with
# nothing in conflict. The payload now says which fields the author actually
# touched, and only those are written.
class StepsControllerFieldScopedTest < ActionDispatch::IntegrationTest
  setup do
    @editor = User.create!(
      email: "field-scoped-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )
    @workflow = Workflow.create!(title: "Field Scoped WF", user: @editor, graph_mode: true)
    @step = Steps::Question.create!(
      workflow: @workflow, position: 0, title: "Original title",
      question: "Original question?", variable_name: "q1", answer_type: "text"
    )
    sign_in @editor
  end

  test "a field the author did not touch is not written, even though it was submitted" do
    patch workflow_step_path(@workflow, @step),
          params: { step: { title: "Typed here", question: "Stale copy from the panel",
                            dirty_fields: ["title"] } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    @step.reload
    assert_equal "Typed here", @step.title
    assert_equal "Original question?", @step.question,
                 "an untouched field must keep what the OTHER editor wrote, not the stale copy this panel held"
  end

  test "a field the author touched is written" do
    patch workflow_step_path(@workflow, @step),
          params: { step: { title: "Typed here", dirty_fields: ["title"] } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_equal "Typed here", @step.reload.title
  end

  # The backward-compatible default, and it is load-bearing:
  # test/services/step_field_map_test.rb asserts a controller PATCH writes every
  # field of every type, and that test IS the publish/restore guarantee.
  test "a PATCH with no dirty_fields writes everything, exactly as before" do
    patch workflow_step_path(@workflow, @step),
          params: { step: { title: "Typed here", question: "Also this" } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    @step.reload
    assert_equal "Typed here", @step.title
    assert_equal "Also this", @step.question
  end

  test "an empty dirty_fields list writes nothing but still succeeds" do
    patch workflow_step_path(@workflow, @step),
          params: { step: { title: "Typed here", dirty_fields: [""] } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "Original title", @step.reload.title
  end

  # The genuine race: the panel was rendered showing "Original title", someone
  # else saved "Theirs" in between, and this author typed over what is now a
  # stale reading. Refuse, and keep their typing on their screen.
  test "a touched field whose rendered value no longer matches is refused" do
    @step.update!(title: "Theirs")

    patch workflow_step_path(@workflow, @step),
          params: { step: { title: "Mine", dirty_fields: ["title"],
                            rendered: { title: "Original title" } } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :conflict
    assert_equal "Theirs", @step.reload.title, "the refused save must write nothing"
    assert_includes response.body, "someone else changed"
  end

  test "a touched field whose rendered value still matches is written" do
    patch workflow_step_path(@workflow, @step),
          params: { step: { title: "Mine", dirty_fields: ["title"],
                            rendered: { title: "Original title" } } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "Mine", @step.reload.title
  end

  # A refused save writes NOTHING — not the step's own fields and not its
  # connections. This is the opposite of the connections refusal, where the
  # step's fields have already been written by the time TransitionSync runs, and
  # the message says so. Confusing the two tells the author the wrong thing
  # about their own data.
  test "a refused save does not write connections either" do
    target = Steps::Resolve.create!(workflow: @workflow, position: 1, title: "Done",
                                    resolution_type: "success")
    @step.update!(title: "Theirs")
    minted = SecureRandom.uuid

    assert_no_difference "Transition.count" do
      patch workflow_step_path(@workflow, @step),
            params: { step: { title: "Mine", dirty_fields: ["title"],
                              rendered: { title: "Original title" },
                              transitions_json: { rendered: [], minted: [minted],
                                                  rows: [{ uuid: minted,
                                                           target_step_id: target.id,
                                                           condition: "" }] }.to_json } },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :conflict
  end

  # The spec's explicit warning: a comparison that normalises away what it guards
  # is not a guard. step_field_map_test once compared rich text with
  # to_plain_text and so passed identically through an unbounded wrapper-nesting
  # corruption. This proves the comparison can still tell two bodies apart.
  test "the rich text comparison distinguishes two genuinely different bodies" do
    action = Steps::Action.create!(workflow: @workflow, position: 1, title: "Do it")
    action.update!(instructions: "<p>Theirs</p>")

    patch workflow_step_path(@workflow, action),
          params: { step: { instructions: "<p>Mine</p>", dirty_fields: ["instructions"],
                            rendered: { instructions: "<p>Originally rendered</p>" } } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :conflict
    assert_includes action.reload.instructions.body.to_html, "Theirs"
  end

  # An empty text input reads "" where its column holds nil. Without treating
  # those as the same value, EVERY optional field the author had never filled in
  # reported a conflict on its first save and could never be saved again — which
  # is what two existing panel tests caught: a guidance note that never saved,
  # and a validation refusal arriving as a conflict message.
  test "an empty input over a nil column is not a conflict" do
    assert_nil @step.help_text

    patch workflow_step_path(@workflow, @step),
          params: { step: { help_text: "Typed guidance", dirty_fields: ["help_text"],
                            rendered: { help_text: "" } } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "Typed guidance", @step.reload.help_text
  end

  # Without casting, a JSON column compares an Array against its own JSON string
  # and a boolean compares true against "1" — every such field would report a
  # conflict that never clears, and the panel would stop saving entirely.
  test "a boolean field saves repeatedly without a phantom conflict" do
    2.times do |i|
      patch workflow_step_path(@workflow, @step),
            params: { step: { can_resolve: i.even? ? "1" : "0", dirty_fields: ["can_resolve"],
                              rendered: { can_resolve: i.even? ? "0" : "1" } } },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }
      assert_response :success, "pass #{i} reported a conflict against its own cast value"
    end
  end

  test "a JSON field saves without a phantom conflict" do
    options = [{ "label" => "Yes", "value" => "yes" }]
    @step.update!(options: options)

    patch workflow_step_path(@workflow, @step),
          params: { step: { options: [{ label: "No", value: "no" }],
                            dirty_fields: ["options"],
                            rendered: { options: options.to_json } } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "No", @step.reload.options.first["label"]
  end
end
