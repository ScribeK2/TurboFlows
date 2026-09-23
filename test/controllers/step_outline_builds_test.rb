require "test_helper"

# How many times one request builds the builder outline. StepOutline.for
# preloads every step with its transitions and targets (3 queries) and the walk
# is ~14ms on a 53-step workflow; the partials that need it used to each build
# their own, so a title autosave built it five times and a door pick eight.
# Each render entry point now builds ONE and passes it down as `outline:` to
# every partial and broadcast it renders (docs/agents/builder.md § The list is
# an outline, "Built once per request").
#
# Counts StepOutline.call, which .for goes through, across the whole request:
# the response AND its Action Cable broadcasts, which render synchronously in
# the request thread.
class StepOutlineBuildsTest < ActionDispatch::IntegrationTest
  # Prepended once for the process; counts only inside #outline_builds.
  module Counter
    class << self
      attr_accessor :count
    end

    def call(...)
      Counter.count += 1 if Counter.count
      super
    end
  end
  StepOutline.singleton_class.prepend(Counter)

  STREAM = { "Accept" => "text/vnd.turbo-stream.html" }.freeze

  setup do
    @editor = User.create!(email: "builds-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                           password_confirmation: "password123!", role: "editor")
    @workflow = Workflow.create!(title: "Builds", user: @editor, graph_mode: true)
    @question = Steps::Question.create!(workflow: @workflow, position: 0, title: "Light green?",
                                        question: "Light green?", answer_type: "yes_no", variable_name: "light")
    @working = Steps::Resolve.create!(workflow: @workflow, position: 1, title: "Working", resolution_type: "success")
    @spare = Steps::Resolve.create!(workflow: @workflow, position: 2, title: "Spare", resolution_type: "success")
    @yes = Transition.create!(step: @question, target_step: @working, condition: "light == 'yes'", label: "Yes",
                              position: 0)
    @workflow.update_columns(start_step_id: @question.id)
    sign_in @editor
  end

  test "a page load builds the outline once" do
    assert_equal(1, outline_builds { get workflow_path(@workflow, edit: true) })
    assert_response :ok
  end

  test "opening a step's panel builds the outline once" do
    assert_equal(1, outline_builds { get panel_edit_workflow_step_path(@workflow, @question) })
    assert_response :ok
  end

  # Both autosaves carry the panel's real, unchanged step[transitions_json],
  # as every panel autosave does, so the doors stream renders too.
  test "a copy-only autosave builds the outline once, row stream and row broadcast together" do
    transitions_json = rendered_transitions_json
    builds = outline_builds do
      patch workflow_step_path(@workflow, @question),
            params: { step: { help_text: "note", dirty_fields: ["help_text"], rendered: { help_text: "" },
                              transitions_json: transitions_json } },
            headers: STREAM
    end
    assert_response :ok
    assert_equal 1, builds
  end

  test "a title autosave builds the outline once, list broadcasts included" do
    transitions_json = rendered_transitions_json
    builds = outline_builds do
      patch workflow_step_path(@workflow, @question),
            params: { step: { title: "Renamed", dirty_fields: ["title"], rendered: { title: @question.title },
                              transitions_json: transitions_json } },
            headers: STREAM
    end
    assert_response :ok
    assert_equal 1, builds
  end

  test "a grow builds the outline once" do
    builds = outline_builds do
      post workflow_steps_path(@workflow),
           params: { step: { type: "action" }, from_step_id: @question.id, label: "No", condition: "light == 'no'" },
           headers: STREAM
    end
    assert_response :ok
    assert_equal 1, builds
  end

  test "a delete builds the outline once" do
    assert_equal(1, outline_builds { delete workflow_step_path(@workflow, @working), headers: STREAM })
    assert_response :ok
  end

  test "a door pick, a retarget and a disconnect each build the outline once" do
    create_builds = outline_builds do
      post workflow_step_transitions_path(@workflow, @question),
           params: { target_step_id: @spare.id, label: "No", condition: "light == 'no'" }, headers: STREAM
    end
    assert_response :ok

    update_builds = outline_builds do
      patch workflow_step_transition_path(@workflow, @question, @yes),
            params: { target_step_id: @spare.id }, headers: STREAM
    end
    assert_response :ok

    destroy_builds = outline_builds { delete workflow_step_transition_path(@workflow, @question, @yes), headers: STREAM }
    assert_response :ok

    assert_equal [1, 1, 1], [create_builds, update_builds, destroy_builds]
  end

  test "a health fix builds the outline once, for the list and the panel's numbers" do
    builds = outline_builds do
      post workflow_health_fix_path(@workflow),
           params: { fix_type: "settle_connections", step_uuid: @question.uuid }, headers: STREAM
    end
    assert_response :ok
    assert_equal 1, builds
  end

  private

  def rendered_transitions_json
    get panel_edit_workflow_step_path(@workflow, @question)
    css_select("input[name='step[transitions_json]']").first["value"]
  end

  def outline_builds
    Counter.count = 0
    yield
    Counter.count
  ensure
    Counter.count = nil
  end
end
