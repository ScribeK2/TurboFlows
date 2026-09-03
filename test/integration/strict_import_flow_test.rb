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
