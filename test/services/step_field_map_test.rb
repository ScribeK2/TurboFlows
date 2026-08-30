require "test_helper"

# The guarantee behind StepFieldMap: every field it declares survives every
# round trip the app puts a step through.
#
# Driven by the map rather than by a hand-written list, so adding a field to
# StepFieldMap immediately tests it against all five readers. That is the point
# — the bug class here was never a wrong value, it was a field silently absent
# from one reader, which no per-reader unit test can see.
#
# Three round trips, because they fail differently:
#
#   publish -> restore   StepSerializer -> StepBuilder(replace: true). Destroys
#                        data: restore deletes the live steps first.
#   export -> import     StepSerializer -> WorkflowImporter, through the
#                        parser's normalizer, which is a reader in its own right
#                        and drops fields before the importer ever sees them.
#   controller PATCH     StepsController#step_params. Discards silently: the
#                        request succeeds and the value is simply not there.
class StepFieldMapTest < ActionDispatch::IntegrationTest
  # A representative non-blank value for every field in the map. Booleans are
  # true and strings are distinctive so a field that silently resets to its
  # default is a failure rather than a coincidence.
  VALUES = {
    help_text: "Help for the agent",
    reference_url: "https://example.com/kb/1",
    question: "Is the account verified?",
    answer_type: "yes_no",
    variable_name: "verified",
    options: [{ "label" => "Yes", "value" => "yes" }, { "label" => "No", "value" => "no" }],
    can_resolve: true,
    action_type: "manual",
    output_fields: [{ "name" => "ref", "value" => "R-1" }],
    jumps: [{ "condition" => "completed", "next_step_id" => "some-uuid" }],
    target_type: "supervisor",
    target_value: "team-a",
    priority: "urgent",
    reason_required: true,
    resolution_type: "success",
    resolution_code: "RES-42",
    notes_required: true,
    survey_trigger: true,
    variable_mapping: { "outer" => "inner" },
    instructions: "Follow these steps",
    content: "Read this to the customer",
    notes: "Escalation notes",
    description: "Custom resolve description"
  }.freeze

  # title and position are structural: set by the builder from the graph, not
  # from a value table. sub_flow_workflow_id needs a real workflow id.
  STRUCTURAL = %i[title position sub_flow_workflow_id].freeze

  setup do
    @user = User.create!(
      email: "fieldmap-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "admin"
    )
    @target_wf = Workflow.create!(title: "Sub-flow target", user: @user)
    Steps::Resolve.create!(workflow: @target_wf, position: 0, title: "Sub done",
                           resolution_type: "success")
    @target_wf.update!(start_step: @target_wf.steps.first)
  end

  # A workflow with one step of every type, fully populated, wired into a chain
  # that ends at the Resolve step (StepBuilder refuses a graph without one).
  def fully_populated_workflow
    wf = Workflow.create!(title: "Field map WF", user: @user)

    steps = StepFieldMap.types.each_with_index.map do |type, i|
      klass = StepBuilder::STI_MAP.fetch(type)
      attrs = { workflow: wf, position: i, title: "#{type} step" }

      StepFieldMap.plain_fields(type).each do |field|
        next if STRUCTURAL.include?(field)

        attrs[field] = VALUES.fetch(field)
      end
      attrs[:sub_flow_workflow_id] = @target_wf.id if type == "sub_flow"

      step = klass.create!(**attrs)
      StepFieldMap.rich_text_fields(type).each do |field|
        step.update!(field => VALUES.fetch(field))
      end
      step
    end

    # Chain them, ending on the Resolve step so the graph is restorable.
    ordered = steps.reject { |s| s.type == "Steps::Resolve" } + steps.select { |s| s.type == "Steps::Resolve" }
    ordered.each_cons(2) { |from, to| Transition.create!(step: from, target_step: to, position: 0) }
    wf.update!(start_step: ordered.first)
    wf.reload
  end

  def assert_fields_intact(workflow, context)
    StepFieldMap.types.each do |type|
      klass = StepBuilder::STI_MAP.fetch(type)
      step = workflow.steps.find { |s| s.is_a?(klass) }
      assert step, "#{context}: the #{type} step vanished entirely"

      StepFieldMap.plain_fields(type).each do |field|
        next if STRUCTURAL.include?(field)

        assert_equal VALUES.fetch(field), step.public_send(field),
                     "#{context}: #{type}##{field} did not survive"
      end

      if StepFieldMap.plain_fields(type).include?(:sub_flow_workflow_id)
        assert_equal @target_wf.id, step.sub_flow_workflow_id,
                     "#{context}: #{type}#sub_flow_workflow_id did not survive"
      end

      StepFieldMap.rich_text_fields(type).each do |field|
        assert_equal VALUES.fetch(field), step.public_send(field).to_plain_text.strip,
                     "#{context}: #{type}##{field} (rich text) did not survive"
      end
    end
  end

  test "every mapped field survives publish and restore" do
    wf = fully_populated_workflow
    snapshot = StepSerializer.call(wf)

    # Exactly what WorkflowVersionsController#restore does.
    StepBuilder.call(wf, snapshot, start_node_uuid: wf.start_step.uuid, replace: true)

    assert_fields_intact(wf.reload, "publish -> restore")
  end

  test "every mapped field survives export and re-import" do
    wf = fully_populated_workflow
    exported = { "title" => "Reimported", "steps" => StepSerializer.call(wf) }.to_json

    result = WorkflowImporter.new(@user, format: :json, content: exported).call
    assert_predicate result, :success?, result.errors.join(", ")

    assert_fields_intact(result.workflow.reload, "export -> import")
  end

  # Behavioural rather than introspective: PATCH the value and read it back.
  # A permit list can be inspected, but only a real request proves the value
  # reaches the column — which is the failure `description` had, where the form,
  # the model and the view were each individually correct.
  test "every mapped field survives a controller PATCH" do
    sign_in @user
    wf = Workflow.create!(title: "Patch WF", user: @user)
    Steps::Resolve.create!(workflow: wf, position: 99, title: "terminal",
                           resolution_type: "success")

    StepFieldMap.types.each_with_index do |type, i|
      klass = StepBuilder::STI_MAP.fetch(type)
      step = klass.create!(workflow: wf, position: i, title: "#{type} step")

      payload = {}
      StepFieldMap.all_fields(type).each do |field|
        next if STRUCTURAL.include?(field)

        payload[field] = VALUES.fetch(field)
      end
      payload[:sub_flow_workflow_id] = @target_wf.id if type == "sub_flow"

      patch workflow_step_path(wf, step), params: { step: payload }, as: :json
      assert_response :ok, "#{type}: PATCH itself failed"

      step.reload
      payload.each_key do |field|
        expected = field == :sub_flow_workflow_id ? @target_wf.id : VALUES.fetch(field)
        actual = if StepFieldMap.rich_text_fields(type).include?(field)
                   step.public_send(field).to_plain_text.strip
                 else
                   step.public_send(field)
                 end

        assert_equal expected, actual,
                     "#{type}##{field} is in the map but did not survive a PATCH — " \
                     "it is being discarded on save with no error"
      end
    end
  end
end
