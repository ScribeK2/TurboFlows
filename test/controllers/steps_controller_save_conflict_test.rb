require "test_helper"

# Two saves of one step in the same instant — two tabs, or two editors — and the
# second loses the optimistic-locking race. It used to escape as an unhandled
# ActiveRecord::StaleObjectError, which Rails answers with an empty 409 that the
# builder ignored: the edit vanished with nothing on screen. Found by the
# department load test (test/load/department.js, editor race), 2026-09-14.
class StepsControllerSaveConflictTest < ActionDispatch::IntegrationTest
  setup do
    @editor = User.create!(
      email: "editor-conflict-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(title: "Save Conflict WF", user: @editor, graph_mode: true)
    @step = Steps::Action.create!(workflow: @workflow, position: 0, title: "Original title")
    sign_in @editor
  end

  # Another save of this step lands after this request loaded the step and
  # before it writes — the window the race needs. The test's transaction rolls
  # that save back along with the failed one, so assertions check that the
  # losing edit was not written, not what the other tab wrote.
  def with_another_save_landing_first
    other_save = lambda do |step|
      Step.where(id: step.id).update_all(["title = ?, lock_version = lock_version + 1", "Saved in the other tab"])
    end
    Steps::Action.set_callback(:update, :before, other_save)
    yield
  ensure
    Steps::Action.skip_callback(:update, :before, other_save)
  end

  test "a save that loses the race says so through the flash" do
    with_another_save_landing_first do
      patch workflow_step_path(@workflow, @step),
            params: { step: { title: "Typed here" } },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :conflict
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_includes response.body, '<turbo-stream action="update" target="flash">'
    assert_includes response.body, "wasn&#39;t saved"
    assert_not_equal "Typed here", @step.reload.title
  end

  test "a JSON save that loses the race answers with the reason" do
    with_another_save_landing_first do
      patch workflow_step_path(@workflow, @step), params: { step: { title: "Typed here" } }, as: :json
    end

    assert_response :conflict
    assert_match(/wasn't saved/, response.parsed_body["errors"].join)
    assert_not_equal "Typed here", @step.reload.title
  end

  test "an HTML save that loses the race goes back to the builder and says why" do
    with_another_save_landing_first do
      patch workflow_step_path(@workflow, @step), params: { step: { title: "Typed here" } }
    end

    assert_redirected_to workflow_path(@workflow, edit: true)
    assert_match(/wasn't saved/, flash[:alert])
    assert_not_equal "Typed here", @step.reload.title
  end

  test "a save that doesn't race still saves" do
    patch workflow_step_path(@workflow, @step),
          params: { step: { title: "Typed here" } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "Typed here", @step.reload.title
  end
end
