require "test_helper"

class StepsControllerTest < ActionDispatch::IntegrationTest
  include ActionView::RecordIdentifier

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

  # 7. create step via Turbo Stream replaces the list and opens the new step
  test "create via turbo stream replaces the list and opens the new step" do
    assert_difference("Step.count", 1) do
      post workflow_steps_path(@workflow),
           params: { step_type: "action", step: { title: "Action via Turbo" } },
           headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :ok
    assert_select "turbo-stream[action='replace'][target='step-list']"
    assert_select "turbo-stream[action='replace'][target='builder-panel']"
    assert_select "turbo-stream[action='update'][target='step-count-text']"
  end

  # The panel is opened client-side (builder_controller#syncSelectedRow), not
  # by the server — a selected_step local here used to race the same
  # #steps-list subtree's Action Cable rebroadcast in a solo editor's own
  # browser. Every row in this response renders unselected.
  test "create via turbo stream renders every row unselected" do
    post workflow_steps_path(@workflow),
         params: { step_type: "action", step: { title: "Action via Turbo" } },
         headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :ok
    assert_no_match "builder__step--selected", response.body
  end

  # From a door the parent really has: GrowStep refuses one it does not.
  test "create with from_step_id lands after the parent and connects it" do
    parent = Steps::Question.create!(workflow: @workflow, position: 1, title: "Light?", question: "Light?",
                                     answer_type: "yes_no", variable_name: "light")
    later = Steps::Resolve.create!(workflow: @workflow, position: 2, title: "Done")

    assert_difference("Transition.count", 1) do
      post workflow_steps_path(@workflow),
           params: { step_type: "message", from_step_id: parent.id, label: "No", condition: "light == 'no'" },
           headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    grown = @workflow.steps.find_by!(type: "Steps::Message")
    assert_equal [@step.id, parent.id, grown.id, later.id], @workflow.steps.order(:position).map(&:id)
    edge = parent.transitions.sole
    assert_equal [grown.id, "No", "light == 'no'"], [edge.target_step_id, edge.label, edge.condition]
  end

  test "create from a Resolve is refused with a message" do
    resolve = Steps::Resolve.create!(workflow: @workflow, position: 1, title: "Done")

    assert_no_difference("Step.count") do
      post workflow_steps_path(@workflow),
           params: { step_type: "action", from_step_id: resolve.id },
           headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :unprocessable_content
    assert_select "turbo-stream[target='flash']"
  end

  test "create with another workflow's step id is not found" do
    other = Workflow.create!(title: "Other", user: @editor)
    foreign = Steps::Action.create!(workflow: other, position: 0, title: "Foreign")

    post workflow_steps_path(@workflow), params: { step_type: "action", from_step_id: foreign.id }, as: :json
    assert_response :not_found
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

  # TransitionSync drops a row that is not an object and carries on, so the
  # controller's own reader of the same payload sees it too - and plucking a
  # key out of an Integer raises TypeError, which it did not rescue.
  test "a row that is not an object is ignored by both readers of the payload" do
    patch workflow_step_path(@workflow, @step),
          params: { step: { title: "Saved beside an odd row",
                            transitions_json: { rendered: [], minted: [], rows: [1] }.to_json } },
          as: :turbo_stream

    assert_response :success
    assert_equal "Saved beside an odd row", @step.reload.title
  end

  # An HTML form posts no key at all for an empty list, so removing a
  # Question's ONLY option used to leave it stored: step_params permitted
  # nothing for options and the save carried none. The panel sends a blank
  # marker entry instead, which has to read as "no options", not as one
  # blank option.
  test "a blank options marker clears a Question's last option" do
    question = Steps::Question.create!(workflow: @workflow, position: 1, title: "Q", question: "Q?",
                                       answer_type: "multiple_choice", variable_name: "q",
                                       options: [{ "label" => "Only", "value" => "only" }])

    patch workflow_step_path(@workflow, question),
          params: { step: { options: [""] } },
          as: :turbo_stream

    assert_response :success
    assert_empty question.reload.options
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

  # This test and several below it send the LEGACY `{known, rows}` transitions_json
  # shape on purpose, not merely because they predate the rendered/minted
  # split - a browser running pre-deploy JavaScript still sends exactly this
  # shape today, and
  # TransitionSync must keep honouring it (see its class comment). The shape
  # today's editor actually sends is covered in
  # test/controllers/steps_controller_stale_panel_sync_test.rb and
  # test/services/transition_sync_test.rb. Of these `known`-shaped tests, only
  # one has an outcome that genuinely depends on the shape: "a save that
  # reaches another step's transition by uuid is refused as a turbo stream" -
  # under `known`/legacy a missing row is always attempted as a create, which
  # collides with the foreign transition's uuid and raises RecordInvalid
  # (422); under `rendered` alone the same row would be skipped and the panel
  # healed (200) instead. The rest here are shape-agnostic: empty lists, a
  # row that already exists, a stubbed TransitionSync.call, or - "a save that
  # turns an editor row into a door" and its contrast below - a brand-new
  # uuid sent as `known`, which under `rendered`/`minted` would arrive as
  # `minted` instead and behave the same way: both shapes create the row
  # outright, so the door-shape outcome does not depend on which one sent it.
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

  # The panel's transitions_json hidden field is rendered inside the same
  # autosave form as every other step field, and holds a snapshot of each
  # transition's condition as of when the panel opened. Renaming a Question's
  # own variable_name in the same PATCH must not have that stale snapshot
  # write the old name straight back over what
  # Steps::Question#carry_conditions_to_new_variable just fixed.
  test "a variable_name save rewrites its own stale transitions_json payload, and streams the connections editor" do
    question = Steps::Question.create!(workflow: @workflow, title: "Light green?", position: 1,
                                       answer_type: "yes_no", variable_name: "untitled_question")
    target = Steps::Action.create!(workflow: @workflow, position: 2, title: "Target")
    edge = Transition.create!(step: question, target_step: target, condition: "untitled_question == 'yes'")

    stale_transitions_json = {
      known: [edge.uuid],
      rows: [{ uuid: edge.uuid, target_uuid: target.uuid, condition: edge.condition, label: nil }]
    }.to_json

    patch workflow_step_path(@workflow, question),
          params: { step: { variable_name: "light_green", transitions_json: stale_transitions_json } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "light_green == 'yes'", edge.reload.condition
    assert_select "turbo-stream[action='update'][target='#{dom_id(question, :connections)}']"

    # The second save: just the title, carrying the payload the freshly
    # streamed editor would now hold (built the way the view does, from the
    # step's current transitions - all `rendered`, nothing `minted`).
    fresh_transitions_json = {
      rendered: question.transitions.reload.map(&:uuid),
      minted: [],
      rows: question.transitions.map do |t|
        { uuid: t.uuid, target_uuid: t.target_step&.uuid,
          condition: t.condition, label: t.label }
      end
    }.to_json

    patch workflow_step_path(@workflow, question),
          params: { step: { title: "Renamed title", transitions_json: fresh_transitions_json } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "light_green == 'yes'", edge.reload.condition
  end

  test "the panel shows a Yes/No Question's doors, stubs with a New step button" do
    question = Steps::Question.create!(workflow: @workflow, position: 1, title: "Light green?",
                                       answer_type: "yes_no", variable_name: "light")
    Transition.create!(step: question, target_step: @step, condition: "light == 'yes'", label: "Yes")

    get panel_edit_workflow_step_path(@workflow, question)

    assert_select "##{dom_id(question, :doors)} .step-doors__row", 2
    assert_select ".step-doors__row", text: /Yes.*Existing Step/m
    assert_select ".step-doors__row button[data-grow-from='#{question.id}'][data-grow-condition=\"light == 'no'\"]", text: "New step"
    assert_select "form form", false, "a form was nested inside the panel's autosave form"
  end

  # Finding 2a/2b: "New step", "Use existing…", "Change" and "Remove" repeat
  # once per door with only a sibling span telling them apart - a name a
  # screen reader can't hear. Each button's accessible name has to say WHICH
  # door, without changing the visible text a sighted, mouse-driven test
  # still clicks by.
  test "each door action names which door it acts on" do
    question = Steps::Question.create!(workflow: @workflow, position: 1, title: "Light green?",
                                       answer_type: "yes_no", variable_name: "light")
    edge = Transition.create!(step: question, target_step: @step, condition: "light == 'yes'", label: "Yes")

    get panel_edit_workflow_step_path(@workflow, question)

    assert_select "##{dom_id(question, :doors)}" do
      assert_select "button[aria-label='New step for “No”']", text: "New step"
      assert_select "button[aria-label='Use an existing step for “No”']", text: "Use existing…"
      assert_select "button[aria-label='Change where “Yes” leads']", text: "Change"
      assert_select "a[aria-label='Remove the “Yes” connection']", text: "Remove"
    end
    assert_select "dialog##{dom_id(question, :target_picker)}[aria-labelledby='#{dom_id(question, :target_picker_heading)}']"
    assert_select "##{dom_id(question, :target_picker_heading)}", text: "Use an existing step"

    edge.destroy!
  end

  # A step with only the single, unlabelled "Next" door reads naturally
  # ("after this one"), not by quoting the literal word "Next".
  test "the unlabelled Next door reads naturally, not by quoting “Next”" do
    action = Steps::Action.create!(workflow: @workflow, position: 1, title: "Untitled Action")

    get panel_edit_workflow_step_path(@workflow, action)

    assert_select "##{dom_id(action, :doors)}" do
      assert_select "button[aria-label='New step after this one']", text: "New step"
      assert_select "button[aria-label='Use an existing step after this one']", text: "Use existing…"
    end
  end

  test "the readonly panel shows doors with nothing to press" do
    question = Steps::Question.create!(workflow: @workflow, position: 1, title: "Light green?",
                                       answer_type: "yes_no", variable_name: "light")

    get panel_edit_workflow_step_path(@workflow, question, readonly: 1)

    assert_select "##{dom_id(question, :doors)} .step-doors__row", 2
    assert_select "##{dom_id(question, :doors)} button", false
    assert_select "##{dom_id(question, :doors)} a", false
    assert_select ".step-doors__row", text: /No.*nothing yet/m
  end

  test "the editor lists only connections that are not doors" do
    question = Steps::Question.create!(workflow: @workflow, position: 1, title: "Light green?",
                                       answer_type: "yes_no", variable_name: "light")
    Transition.create!(step: question, target_step: @step, condition: "light == 'yes'")
    extra = Transition.create!(step: question, target_step: @step, condition: "tier == 'gold'")

    get panel_edit_workflow_step_path(@workflow, question)

    payload = JSON.parse(css_select("input[name='step[transitions_json]']").first["value"])
    assert_equal [extra.uuid], payload["rendered"]
    assert_equal [], payload["minted"]
    assert_equal [extra.uuid], payload["rows"].pluck("uuid")
    # `known` is the TRANSITIONAL duplicate of `rendered` (see
    # _transitions_editor.html.erb's comment): a tab still running the
    # pre-2026-09-19 controller reads only this key, so it has to carry a
    # real, usable delete set - not be absent, and not merely present-but-empty.
    assert_equal payload["rendered"], payload["known"]
  end

  test "changing the answer type streams the doors" do
    question = Steps::Question.create!(workflow: @workflow, position: 1, title: "Q", answer_type: "yes_no")

    patch workflow_step_path(@workflow, question),
          params: { step: { answer_type: "text" } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_select "turbo-stream[action='replace'][target='#{dom_id(question, :doors)}']"
  end

  # A handoff has no doors (Step::Doors#growable? is false for one), so its own
  # connection, if it has one, must still show up in the "Other connections"
  # editor - and _transitions_editor.html.erb reads it via step.transitions
  # directly rather than Step::Doors.for(step).extras. This is the claim that
  # makes the two interchangeable there.
  test "a handoff's extras are exactly its own transitions" do
    target_workflow = Workflow.create!(title: "Handoff Target", user: @editor)
    Steps::Resolve.create!(workflow: target_workflow, position: 0, title: "Done", resolution_type: "success")
    handoff = Steps::SubFlow.create!(workflow: @workflow, position: 1, title: "Continue elsewhere",
                                     sub_flow_workflow_id: target_workflow.id, sub_flow_returns: false)
    edge = Transition.create!(step: handoff, target_step: @step)

    assert_equal [edge], Step::Doors.for(handoff).extras
  end

  # Two connections from one Question to the same target, one condition
  # naming each variable. Renaming the old variable to the new one rewrites
  # the first condition onto the second's, which Transition's own uniqueness
  # validation refuses from inside Question#carry_conditions_to_new_variable's
  # after_update callback - the whole save, rename included, rolls back.
  test "a rename that collides two conditions onto one target is refused, not a 500" do
    question = Steps::Question.create!(workflow: @workflow, position: 1, title: "Q",
                                       answer_type: "yes_no", variable_name: "old")
    first = Transition.create!(step: question, target_step: @step, condition: "old == 'yes'")
    Transition.create!(step: question, target_step: @step, condition: "new == 'yes'")

    patch workflow_step_path(@workflow, question),
          params: { step: { variable_name: "new" } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :unprocessable_content
    assert_select "turbo-stream[target='flash']"
    assert_equal "old", question.reload.variable_name
    assert_equal "old == 'yes'", first.reload.condition,
                 "the whole transaction must roll back, not just the variable_name"
  end

  # connections_or_doors_stream has three outcomes; the two above (rename,
  # doors_changed? false) are covered elsewhere. This is the third: a save
  # whose transitions_json turns one of the editor's own rows into a door -
  # the row's condition now reads as the No door - so the whole Connections
  # fragment has to come back, not just the doors list, or the row would show
  # twice: once as a door, once still sitting in the editor below it.
  test "a save that turns an editor row into a door streams the whole connections fragment" do
    question = Steps::Question.create!(workflow: @workflow, position: 1, title: "Light green?",
                                       answer_type: "yes_no", variable_name: "light")
    new_uuid = SecureRandom.uuid
    transitions_json = {
      known: [new_uuid],
      rows: [{ uuid: new_uuid, target_uuid: @step.uuid, condition: "light == 'no'", label: "No" }]
    }.to_json

    patch workflow_step_path(@workflow, question),
          params: { step: { transitions_json: transitions_json } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    transition = question.transitions.reload.sole
    assert_equal transition, Step::Doors.for(question.reload).door_for("light == 'no'").transition

    assert_select "turbo-stream[action='update'][target='#{dom_id(question, :connections)}']"
    assert_select "turbo-stream[action='replace'][target='#{dom_id(question, :doors)}']", false
  end

  # The contrast case: the same shape of save, but the sent row's condition
  # names a variable no door of this step reads at all, so it stays an
  # "extra" - editor_row_became_door? is false, and only the doors list (not
  # the whole fragment) needs replacing.
  test "a save whose new row is not a door streams only the doors list" do
    question = Steps::Question.create!(workflow: @workflow, position: 1, title: "Light green?",
                                       answer_type: "yes_no", variable_name: "light")
    new_uuid = SecureRandom.uuid
    transitions_json = {
      known: [new_uuid],
      rows: [{ uuid: new_uuid, target_uuid: @step.uuid, condition: "tier == 'gold'", label: nil }]
    }.to_json

    patch workflow_step_path(@workflow, question),
          params: { step: { transitions_json: transitions_json } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    transition = question.transitions.reload.sole
    assert_includes Step::Doors.for(question.reload).extras, transition

    assert_select "turbo-stream[action='replace'][target='#{dom_id(question, :doors)}']"
    assert_select "turbo-stream[action='update'][target='#{dom_id(question, :connections)}']", false
  end

  # Finding 1: a door that becomes an extra is never shown to the editor.
  # A Yes/No Question has its No door wired. Switching to Text means
  # Step::Doors no longer claims that transition - it becomes an extra - but
  # the editor's own snapshot (sent as empty known/rows, exactly what it held
  # before this save) never contained that uuid. The whole fragment must come
  # back, or the panel would show "No other connections" while the edge is
  # still live in the database.
  test "a door that becomes an extra streams the whole connections fragment" do
    question = Steps::Question.create!(workflow: @workflow, position: 1, title: "Light green?",
                                       answer_type: "yes_no", variable_name: "light")
    no_edge = Transition.create!(step: question, target_step: @step, condition: "light == 'no'", label: "No")
    transitions_json = { known: [], rows: [] }.to_json

    patch workflow_step_path(@workflow, question),
          params: { step: { answer_type: "text", transitions_json: transitions_json } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_select "turbo-stream[action='update'][target='#{dom_id(question, :connections)}']"
    assert_select "turbo-stream[action='replace'][target='#{dom_id(question, :doors)}']", false
    assert_equal "light == 'no'", no_edge.reload.condition
  end

  # Contrast: the same shape of save, but the extra was already sitting in the
  # editor's own known/rows before this PATCH - so the editor already shows
  # it, and only the doors list needs replacing.
  test "an extra the editor already knew about streams only the doors list" do
    question = Steps::Question.create!(workflow: @workflow, position: 1, title: "Light green?",
                                       answer_type: "yes_no", variable_name: "light")
    extra = Transition.create!(step: question, target_step: @step, condition: "tier == 'gold'")
    transitions_json = {
      known: [extra.uuid],
      rows: [{ uuid: extra.uuid, target_uuid: @step.uuid, condition: "tier == 'gold'", label: nil }]
    }.to_json

    patch workflow_step_path(@workflow, question),
          params: { step: { answer_type: "text", transitions_json: transitions_json } },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_select "turbo-stream[action='replace'][target='#{dom_id(question, :doors)}']"
    assert_select "turbo-stream[action='update'][target='#{dom_id(question, :connections)}']", false
  end

  # Finding 2: sync_transitions did not rescue ActiveRecord::RecordNotUnique.
  # Two overlapping saves of the same newly minted row (Turbo aborts the
  # earlier fetch, not the server work) can hit the unique index on
  # transitions.uuid; the loser must answer through the refusal path, not a
  # 500. RecordNotUnique carries no #record, unlike RecordInvalid.
  test "a duplicate transition uuid race answers with the refusal path, not a 500" do
    question = Steps::Question.create!(workflow: @workflow, position: 1, title: "Q", answer_type: "text")
    transitions_json = {
      known: [SecureRandom.uuid],
      rows: [{ uuid: SecureRandom.uuid, target_uuid: @step.uuid, condition: nil, label: nil }]
    }.to_json

    original_call = TransitionSync.method(:call)
    TransitionSync.define_singleton_method(:call) { |*, **| raise ActiveRecord::RecordNotUnique, "dup" }
    begin
      patch workflow_step_path(@workflow, question),
            params: { step: { transitions_json: transitions_json } },
            headers: { "Accept" => "text/vnd.turbo-stream.html" }
    ensure
      TransitionSync.define_singleton_method(:call, original_call)
    end

    assert_response :unprocessable_content
    assert_select "turbo-stream[target='flash']"
  end

  test "the panel offers every other step as an existing target, outside the autosave form" do
    question = Steps::Question.create!(workflow: @workflow, position: 1, title: "Light green?",
                                       answer_type: "yes_no", variable_name: "light")

    get panel_edit_workflow_step_path(@workflow, question)

    assert_select "dialog##{dom_id(question, :target_picker)} button[name='target_step_id'][value='#{@step.id}']"
    assert_select "dialog button[name='target_step_id'][value='#{question.id}']", false
    assert_select "form[data-controller~='inline-autosave'] dialog", false
    assert_select ".step-doors__row button", text: "Use existing…"
    # form_with method: :post renders no _method field of its own - the
    # dialog's hidden field (flipped to "patch" by JS for a retarget) must be
    # the only one, or Rails would read whichever one comes first. (No
    # authenticity_token field to check alongside it: config/environments/test.rb
    # sets allow_forgery_protection false, so no form embeds one in this
    # environment - not something specific to this dialog's form.)
    assert_select "dialog form input[name='_method']", count: 1
  end

  test "the readonly panel offers no way to point a door at an existing step" do
    question = Steps::Question.create!(workflow: @workflow, position: 1, title: "Light green?",
                                       answer_type: "yes_no", variable_name: "light")

    get panel_edit_workflow_step_path(@workflow, question, readonly: 1)

    assert_select "dialog", false
    assert_select "button", text: "Use existing…", count: 0
    assert_select "button", text: "Change", count: 0
  end

  test "a Resolve step's panel renders no target picker dialog" do
    resolve = Steps::Resolve.create!(workflow: @workflow, position: 1, title: "Done")

    get panel_edit_workflow_step_path(@workflow, resolve)

    assert_select "dialog##{dom_id(resolve, :target_picker)}", false
  end

  test "a handoff Sub-Flow's panel renders no target picker dialog" do
    published = Workflow.create!(title: "Handoff target", user: @editor).tap { |w| w.update_columns(status: "published") }
    handoff = Steps::SubFlow.create!(workflow: @workflow, position: 1, title: "Hand off",
                                     sub_flow_workflow_id: published.id, sub_flow_returns: false)

    get panel_edit_workflow_step_path(@workflow, handoff)

    assert_select "dialog##{dom_id(handoff, :target_picker)}", false
  end
end
