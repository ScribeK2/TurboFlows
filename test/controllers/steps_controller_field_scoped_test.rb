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
end
