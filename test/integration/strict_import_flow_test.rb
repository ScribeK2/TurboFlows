require "test_helper"

class StrictImportFlowTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(
      email: "strict-flow-#{SecureRandom.hex(4)}@example.com",
      password: "password123!",
      password_confirmation: "password123!",
      role: "editor"
    )
    sign_in @user
  end

  teardown { User.where("email LIKE ?", "strict-flow-%").destroy_all }

  test "a valid strict file renders a preview and writes nothing yet" do
    assert_no_difference -> { Workflow.count } do
      post workflow_import_path, params: { file: upload(valid_file) }
    end

    assert_response :success
    assert_select "[data-testid='import-report']"
    assert_match(/2 steps/, response.body)
  end

  test "confirming the preview creates the workflow" do
    assert_difference -> { Workflow.count }, 1 do
      post commit_workflow_import_path, params: { content: valid_file }
    end

    assert_redirected_to workflow_path(Workflow.order(:created_at).last)
  end

  test "an invalid strict file renders errors with codes and writes nothing" do
    assert_no_difference -> { Workflow.count } do
      post workflow_import_path, params: { file: upload(invalid_file) }
    end

    assert_response :unprocessable_content
    assert_match(/dangling_transition_target/, response.body)
    assert_select "[data-controller='clipboard']"
  end

  test "a legacy file with no schema_version still imports in one shot" do
    legacy = {
      title: "Legacy One Shot",
      steps: [{ id: "done", type: "resolve", title: "Done", resolution_type: "success" }]
    }.to_json

    assert_difference -> { Workflow.count }, 1 do
      post workflow_import_path, params: { file: upload(legacy) }
    end

    assert_response :redirect
  end

  # --- a set of linked workflows in one file -----------------------------------

  test "a bundle previews every workflow it carries and writes nothing yet" do
    assert_no_difference -> { Workflow.count } do
      post workflow_import_path, params: { file: upload(bundle_file) }
    end

    assert_response :success
    assert_match(/carries 2 workflows/, response.body)
    assert_match(/Bundle Flow Router/, response.body)
    assert_match(/Bundle Flow Child/, response.body,
                 "the second workflow must be previewed too, not hidden behind the first")
  end

  test "committing a bundle creates every workflow and lands on the list" do
    assert_difference -> { Workflow.count }, 2 do
      post commit_workflow_import_path, params: { content: bundle_file }
    end

    assert_redirected_to workflows_path
    assert_match(/Imported 2 workflows/, flash[:notice])
    assert_match(/Bundle Flow Router/, flash[:notice],
                 "after importing a set, which ones is the immediate question")
  end

  # --- a refusal that only exists at commit ----------------------------------
  #
  # StrictImportValidator binds in-bundle sub-flow targets by title but never
  # walks the graph they make, so a cycle is reachable only after insert. Preview
  # passes, commit refuses — and the refusal used to go out as a flash: bottom
  # right, gone in five seconds, the first three messages cut at 150 characters.
  # Observed on a real 24-workflow bundle: twelve findings, three shown, the
  # first cut mid-cycle-path. The same file fails the same way every time, so
  # the toast was the only report an operator or their AI agent ever got.

  test "precondition: a cyclic bundle previews as ready to import" do
    post workflow_import_path, params: { file: upload(cyclic_bundle_file) }

    assert_response :success
    assert_match(/Ready to import/, response.body)
  end

  test "a bundle refused at commit gets the persistent report page, not a flash" do
    assert_no_difference -> { Workflow.count } do
      post commit_workflow_import_path, params: { content: cyclic_bundle_file }
    end

    assert_response :unprocessable_content
    assert_nil flash[:alert], "a five-second toast is not a report"
    assert_select "[data-testid=import-report]"
    assert_match(/cannot be imported yet/, response.body)
    assert_match(/Nothing was created/, response.body)
  end

  test "every commit-time finding is shown whole" do
    post commit_workflow_import_path, params: { content: cyclic_bundle_file }

    assert_select ".badge--alert", text: /refused_at_commit/
    assert_match(/Cyclic Flow A/, response.body)
    assert_match(/Cyclic Flow B/, response.body)
    assert_no_match(/and \d+ more/, response.body, "nothing is summarised away")
    assert_no_match(/Failed to import workflow/, response.body)
  end

  test "a committed bundle wires its sub_flow to the workflow that arrived with it" do
    post commit_workflow_import_path, params: { content: bundle_file }

    router = Workflow.find_by(title: "Bundle Flow Router")
    child  = Workflow.find_by(title: "Bundle Flow Child")
    sub_flow = router.steps.find { |step| step.step_type == "sub_flow" }

    assert_equal child.id, sub_flow.sub_flow_workflow_id
  end

  test "committing a file with a select field stores its choices" do
    post commit_workflow_import_path, params: { content: select_field_file }

    workflow = Workflow.find_by(title: "Select Field Flow")
    field = workflow.steps.find { |s| s.step_type == "form" }.fields.first

    assert_equal [{ "label" => "IVR", "value" => "ivr" },
                  { "label" => "Secure link", "value" => "link" }],
                 field["select_options"],
                 "the accepting path through the real commit endpoint, not just the validator"
  end

  test "a single workflow still lands on that workflow, not the list" do
    post commit_workflow_import_path, params: { content: valid_file }

    assert_redirected_to workflow_path(Workflow.order(:created_at).last)
  end

  test "a nested group named by itself is accepted and assigned on commit" do
    root = Group.create!(name: "Flow Root #{SecureRandom.hex(2)}")
    child = Group.create!(name: "Flow Nested #{SecureRandom.hex(2)}", parent: root)
    UserGroup.create!(user: @user, group: root)
    content = {
      schema_version: "1",
      workflows: [{
        title: "Nested Group Flow",
        groups: [child.name],
        steps: [
          { id: "done", type: "resolve", title: "Done", resolution_type: "success" }
        ]
      }]
    }.to_json

    post workflow_import_path, params: { file: upload(content) }

    assert_response :success
    assert_match(/Ready to import/, response.body)
    assert_match(child.name, response.body)

    post commit_workflow_import_path, params: { content: content }

    workflow = Workflow.find_by(title: "Nested Group Flow")
    assert_equal [child.id], workflow.groups.map(&:id)
  ensure
    Workflow.where(title: "Nested Group Flow").destroy_all
    child&.destroy
    root&.destroy
  end

  private

  def upload(content)
    file = Tempfile.new(["import", ".json"])
    file.write(content)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "application/json")
  end

  def valid_file
    {
      schema_version: "1",
      workflows: [{
        title: "Flow Test",
        steps: [
          { id: "hello", type: "message", title: "Greet", content: "<p>Hello</p>",
            transitions: [{ target_id: "done" }] },
          { id: "done", type: "resolve", title: "Done", resolution_type: "success" }
        ]
      }]
    }.to_json
  end

  def select_field_file
    {
      schema_version: "1",
      workflows: [{
        title: "Select Field Flow",
        steps: [
          { id: "collect", type: "form", title: "Take payment",
            options: [{ name: "method", label: "How paid", field_type: "select",
                        required: true, position: 0,
                        select_options: [{ label: "IVR", value: "ivr" },
                                         { label: "Secure link", value: "link" }] }],
            transitions: [{ target_id: "done" }] },
          { id: "done", type: "resolve", title: "Done", resolution_type: "success" }
        ]
      }]
    }.to_json
  end

  # A calls B and B calls A, both returning: legal to write, illegal to run.
  def cyclic_bundle_file
    flow = lambda do |title, target|
      { title: title,
        steps: [
          { id: "run", type: "sub_flow", title: "Run #{target}", target_workflow_title: target,
            transitions: [{ target_id: "done" }] },
          { id: "done", type: "resolve", title: "Done", resolution_type: "success" }
        ] }
    end

    { schema_version: "1",
      workflows: [flow.call("Cyclic Flow A", "Cyclic Flow B"), flow.call("Cyclic Flow B", "Cyclic Flow A")] }.to_json
  end

  def bundle_file
    {
      schema_version: "1",
      workflows: [
        {
          title: "Bundle Flow Router",
          steps: [
            { id: "run-child", type: "sub_flow", title: "Run the child",
              target_workflow_title: "Bundle Flow Child",
              transitions: [{ target_id: "done" }] },
            { id: "done", type: "resolve", title: "Done", resolution_type: "success" }
          ]
        },
        {
          title: "Bundle Flow Child",
          steps: [
            { id: "child-done", type: "resolve", title: "Done", resolution_type: "success" }
          ]
        }
      ]
    }.to_json
  end

  def invalid_file
    {
      schema_version: "1",
      workflows: [{
        title: "Broken",
        steps: [
          { id: "hello", type: "message", title: "Greet", content: "<p>Hello</p>",
            transitions: [{ target_id: "nowhere" }] },
          { id: "done", type: "resolve", title: "Done", resolution_type: "success" }
        ]
      }]
    }.to_json
  end
end
