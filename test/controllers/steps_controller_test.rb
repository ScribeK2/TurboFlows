require "test_helper"

class StepsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @editor = User.create!(
      email: "editor-steps-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    @workflow = Workflow.create!(title: "Steps Test WF", user: @editor, graph_mode: true)
    @step = Steps::Action.create!(workflow: @workflow, position: 0, title: "Existing Step")
    sign_in @editor
  end

  # 1. create step via JSON returns created step data
  test "create step via JSON returns created step data" do
    post workflow_steps_path(@workflow),
         params: { step: { type: "action", title: "New Action Step" } },
         as: :json

    assert_response :created
    json = response.parsed_body
    assert_equal "New Action Step", json["title"]
    assert_equal "action", json["type"]
    assert_predicate json["id"], :present?
    assert_predicate json["uuid"], :present?
  end

  # 2. create step defaults to action type when no type given
  test "create step defaults to action type" do
    post workflow_steps_path(@workflow),
         params: { step: { title: "Typeless Step" } },
         as: :json

    assert_response :created
    json = response.parsed_body
    assert_equal "action", json["type"]
  end

  # 3. create step for each valid type
  test "create step for each valid type" do
    @target_workflow = Workflow.create!(title: "Sub Flow Target", user: @editor)

    valid_types_and_params = {
      "question" => { type: "question", title: "Q Step", question: "What?" },
      "message" => { type: "message", title: "Msg Step" },
      "escalate" => { type: "escalate", title: "Esc Step", target_type: "supervisor", priority: "high" },
      "resolve" => { type: "resolve", title: "Res Step", resolution_type: "success" },
      "sub_flow" => { type: "sub_flow", title: "SF Step", sub_flow_workflow_id: @target_workflow.id }
    }

    valid_types_and_params.each do |step_type, step_attrs|
      post workflow_steps_path(@workflow),
           params: { step: step_attrs },
           as: :json

      assert_response :created, "Expected 201 for type #{step_type}, got #{response.status}: #{response.body}"
      json = response.parsed_body
      assert_equal step_type, json["type"], "Expected type #{step_type}, got #{json['type']}"
    end
  end

  # 4. update step via JSON returns updated title
  test "update step via JSON returns updated title" do
    patch workflow_step_path(@workflow, @step),
          params: { step: { title: "Updated Title" } },
          as: :json

    assert_response :ok
    json = response.parsed_body
    assert_equal "Updated Title", json["title"]
  end

  # 5. destroy step via JSON returns 204 no content
  test "destroy step via JSON returns 204 no content" do
    assert_difference("Step.count", -1) do
      delete workflow_step_path(@workflow, @step), as: :json
    end

    assert_response :no_content
  end

  # 6. reorder step updates position
  test "reorder step updates step position" do
    extra = Steps::Action.create!(workflow: @workflow, position: 1, title: "Second Step")

    patch reorder_workflow_step_path(@workflow, extra),
          params: { position: 0 },
          as: :json

    assert_response :ok
    assert_equal 0, extra.reload.position
  end

  # 7. create step via Turbo Stream appends to steps-list
  test "create step via turbo stream appends card" do
    assert_difference("Step.count", 1) do
      post workflow_steps_path(@workflow),
           params: { step_type: "action", step: { title: "Action via Turbo" } },
           headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :ok
    assert_includes response.body, "turbo-stream"
    assert_includes response.body, "append"
  end

  # 9. requires authentication — unauthenticated POST redirects
  test "requires authentication to create step" do
    sign_out @editor

    post workflow_steps_path(@workflow),
         params: { step: { title: "No Auth" } },
         as: :json

    assert_includes [302, 401], response.status
  end

  # 10. editor can view own workflow step
  test "editor can show step on own workflow" do
    get workflow_step_path(@workflow, @step), as: :json

    assert_response :ok
    json = response.parsed_body
    assert_equal @step.id, json["id"]
  end

  # 11. editor cannot CRUD steps on another editor's private workflow
  test "editor cannot update step on other editors private workflow" do
    other_editor = User.create!(
      email: "other-editor-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    other_workflow = Workflow.create!(title: "Other WF", user: other_editor)
    other_step = Steps::Action.create!(workflow: other_workflow, position: 0, title: "Other Step")

    patch workflow_step_path(other_workflow, other_step),
          params: { step: { title: "Hacked" } }

    assert_redirected_to workflows_path
    assert_match(/permission/, flash[:alert])
  end

  # 12. creating the first step auto-assigns it as start_step on the workflow
  test "creating first step auto-assigns it as start_step" do
    empty_workflow = Workflow.create!(title: "Empty WF", user: @editor, graph_mode: true)
    assert_nil empty_workflow.start_step_id

    post workflow_steps_path(empty_workflow),
         params: { step: { type: "question", title: "First Question", question: "What?" } },
         as: :json

    assert_response :created
    empty_workflow.reload
    assert_not_nil empty_workflow.start_step_id, "Expected start_step_id to be assigned after creating the first step"
    assert_equal empty_workflow.steps.first.id, empty_workflow.start_step_id
  end

  # 13. malformed transitions_json refuses the response, but the step's own
  # fields were already saved and no transition was written or removed.
  test "malformed transitions_json refuses the response without dropping the field save" do
    before_count = Transition.count

    patch workflow_step_path(@workflow, @step),
          params: { step: { title: "Renamed despite bad json", transitions_json: "not valid json{{{" } },
          as: :json

    assert_response :unprocessable_content
    json = response.parsed_body
    assert json["errors"].any? { |e| e.include?("connections") },
           "expected an error mentioning connections, got #{json['errors'].inspect}"
    assert_equal "Renamed despite bad json", @step.reload.title
    assert_equal before_count, Transition.count
  end

  # 14. regular user cannot create steps
  test "regular user cannot create steps" do
    regular = User.create!(
      email: "regular-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "user"
    )
    sign_in regular

    post workflow_steps_path(@workflow),
         params: { step: { title: "User Step" } }

    assert_redirected_to workflows_path
    assert_match(/permission/, flash[:alert])
  end

  # The rich text bodies, which reach the model through step_params like any
  # other attribute. `description` was rendered by the Resolve editor but never
  # permitted, so what the user typed was dropped on save with no error — the
  # kind of gap only an end-to-end assertion catches, since the form, the model
  # and the view were all individually correct.
  test "a Resolve step's custom description is saved, not silently dropped" do
    resolve = Steps::Resolve.create!(workflow: @workflow, position: 1, title: "R",
                                     resolution_type: "success")

    patch workflow_step_path(@workflow, resolve),
          params: { step: { description: "Confirm the customer is satisfied" } },
          as: :json

    assert_response :ok
    assert_equal "Confirm the customer is satisfied",
                 resolve.reload.description.to_plain_text.strip
  end

  test "the other rich text bodies save too" do
    { Steps::Action => :instructions, Steps::Message => :content,
      Steps::Escalate => :notes }.each_with_index do |(klass, field), i|
      step = klass.create!(workflow: @workflow, position: 10 + i, title: "S#{i}")

      patch workflow_step_path(@workflow, step),
            params: { step: { field => "body text #{i}" } }, as: :json

      assert_response :ok
      assert_equal "body text #{i}", step.reload.public_send(field).to_plain_text.strip,
                   "#{klass}##{field} must round-trip through step_params"
    end
  end

  test "the panel is a preview when the builder is in view mode" do
    escalate = Steps::Escalate.create!(workflow: @workflow, position: 1, title: "Escalate to network",
                                       target_type: "department", target_value: "Network Ops")

    get panel_edit_workflow_step_path(@workflow, escalate, readonly: 1)

    assert_response :success
    assert_select "form", count: 0
    assert_select "turbo-frame#builder-panel", text: /Network Ops/
    assert_select "turbo-frame#builder-panel", text: /Department/
  end

  test "the panel is editable in edit mode for someone who may edit" do
    get panel_edit_workflow_step_path(@workflow, @step)

    assert_response :success
    assert_select "form[data-controller='inline-autosave']", count: 1
  end

  test "a refused save reports through the flash rather than a frame nothing renders" do
    escalate = Steps::Escalate.create!(workflow: @workflow, position: 1, title: "Escalate")

    patch workflow_step_path(@workflow, escalate),
          params: { step: { priority: "bogus" } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :unprocessable_content
    assert_match(/<turbo-stream action="update" target="flash"/, response.body)
    assert_match "was not saved", response.body
    assert_match "Priority is not included in the list", response.body
    assert_equal "medium", escalate.reload.priority
  end

  # test.rb sets show_exceptions to :rescuable, so a missing route renders 404
  # rather than raising.
  test "the old edit route is gone" do
    get "/workflows/#{@workflow.id}/steps/#{@step.id}/edit"

    assert_response :not_found
  end

  test "the panel offers a guidance note and a reference link on every step type" do
    %w[question action message escalate resolve sub_flow form].each do |type|
      step = Step.class_for_type(type).create!(workflow: @workflow, position: 9, title: "A #{type}")

      get panel_edit_workflow_step_path(@workflow, step)

      assert_select "input[name='step[help_text]']", { count: 1 }, "no guidance note on #{type}"
      assert_select "input[name='step[reference_url]']", { count: 1 }, "no reference link on #{type}"
    end
  end

  test "the panel explains a step through its fields, not a banner" do
    # Published by column, not by WorkflowPublisher: the target only has to
    # resolve, and publishing would need a Resolve step and an audience.
    published = Workflow.create!(title: "Target", user: @editor).tap { |w| w.update_columns(status: "published") }
    {
      Steps::Escalate => "Escalate Step:",
      Steps::Resolve => "Resolve Step:",
      Steps::Message => "Message Step:",
      Steps::SubFlow => "Variable Mapping"
    }.each do |klass, banner|
      attrs = { workflow: @workflow, position: 9, title: "A step" }
      attrs[:sub_flow_workflow_id] = published.id if klass == Steps::SubFlow
      step = klass.create!(**attrs)

      get panel_edit_workflow_step_path(@workflow, step)

      assert_no_match banner, response.body
      assert_no_match ">Graph<", response.body
    end
  end

  test "form field rows have column headers and a plain remove" do
    form = Steps::Form.create!(workflow: @workflow, position: 9, title: "Details",
                               options: [{ "name" => "account_no", "label" => "Account number", "field_type" => "text",
                                           "required" => true, "position" => 0 }])

    get panel_edit_workflow_step_path(@workflow, form)

    assert_select ".form-field-list__head", text: /Name.*Label.*Type.*Required/m
    assert_select ".form-field-row button.btn--negative", count: 0
    assert_select ".form-field-row button[title='Remove field'].btn--plain", count: 1
  end

  test "an editor who may only view the workflow gets the panel as a preview" do
    viewer = User.create!(email: "viewer-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                          password_confirmation: "password123!", role: "editor")
    # can_be_edited_by? lets any editor edit a Global workflow owned by another
    # editor, so Global would grant view AND edit. A non-Global group the
    # viewer reaches, owned by someone else, is the only shape that is
    # view-only: WorkflowAuthorization#can_be_edited_by? still requires
    # `user == self.user` off of Global.
    group = Group.create!(name: "Viewer Group #{SecureRandom.hex(4)}")
    UserGroup.create!(user: viewer, group: group)
    GroupWorkflow.create!(group: group, workflow: @workflow, is_primary: true)
    sign_in viewer

    get panel_edit_workflow_step_path(@workflow, @step)

    assert_response :success
    assert_select "form", count: 0
    assert_select "turbo-frame#builder-panel", text: /Existing Step/

    patch workflow_step_path(@workflow, @step), params: { step: { title: "Changed" } }
    assert_redirected_to workflows_path
    assert_equal "Existing Step", @step.reload.title
  end

  test "a panel save with a stale snapshot leaves a server-made edge alone" do
    target = Steps::Resolve.create!(workflow: @workflow, position: 1, title: "Done")
    grown = Transition.create!(step: @step, target_step: target)

    patch workflow_step_path(@workflow, @step),
          params: { step: { title: "Renamed", transitions_json: { known: [], rows: [] }.to_json } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :ok
    assert Transition.exists?(grown.id)
    assert_equal "Renamed", @step.reload.title
  end

  test "a save that reaches another step's transition by uuid is refused as a turbo stream" do
    target = Steps::Resolve.create!(workflow: @workflow, position: 1, title: "Done")
    other_step = Steps::Action.create!(workflow: @workflow, position: 2, title: "Other")
    other_transition = Transition.create!(step: other_step, target_step: target)

    patch workflow_step_path(@workflow, @step),
          params: { step: { transitions_json: { known: [other_transition.uuid], rows: [
            { uuid: other_transition.uuid, target_uuid: target.uuid, condition: "", label: "" }
          ] }.to_json } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :unprocessable_content
    assert_select "turbo-stream[target='flash']"
    assert_equal other_step.id, other_transition.reload.step_id
  end
end
