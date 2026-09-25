require "test_helper"

class WorkflowStrictDocumentTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "api-#{SecureRandom.hex(4)}@example.com", password: "password123!",
                         password_confirmation: "password123!", role: "editor")
  end

  test "the document is a valid strict import for its owner, primary group first" do
    first = Group.create!(name: "Doc A #{SecureRandom.hex(2)}")
    primary = Group.create!(name: "Doc B #{SecureRandom.hex(2)}")
    [first, primary].each { UserGroup.create!(user: @user, group: it) }

    workflow = Workflow.create!(title: "Doc #{SecureRandom.hex(2)}", user: @user, status: "draft")
    resolve = Steps::Resolve.create!(workflow:, uuid: SecureRandom.uuid, position: 0, title: "Done",
                                     resolution_type: "success")
    workflow.update!(start_step: resolve)
    GroupWorkflow.create!(workflow:, group: first, is_primary: false)
    GroupWorkflow.create!(workflow:, group: primary, is_primary: true)

    document = workflow.to_strict_document
    entry = document[:workflows].sole

    assert_equal ImportSchemaGenerator::SCHEMA_VERSION, document[:schema_version]
    assert_equal [primary.name_path, first.name_path], entry[:groups]
    assert_equal resolve.uuid, entry[:start_step_id]
    report = StrictImportValidator.new(user: @user, content: document.to_json).validate
    assert_predicate report, :valid?, report.errors.inspect
  ensure
    Group.where("name LIKE ?", "Doc %").destroy_all
  end
end
