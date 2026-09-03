require "test_helper"

# One fixture per error code, and a test that fails when a code has none. The
# codes are a published contract that an external agent parses; a code nobody has
# ever seen produced is a promise the app has not checked it can keep.
class StrictImportCorpusTest < ActiveSupport::TestCase
  CORPUS = Rails.root.join("test/fixtures/files/imports")

  # Every code StrictImportValidator and WorkflowPlacement can emit. Add the code
  # AND the fixture, or the last test in this file fails.
  EXPECTED_CODES = %w[
    malformed_json envelope_invalid unsupported_schema_version invalid_workflow_title
    unknown_step_type duplicate_step_id missing_step_id invalid_step_id
    unknown_field excluded_field missing_required_field
    missing_transitions unexpected_transitions dangling_transition_target
    invalid_enum_value graph_invalid invalid_condition_syntax
    unknown_sub_flow_target ambiguous_sub_flow_target sub_flow_target_not_published
    unknown_group group_not_permitted unknown_folder
  ].freeze

  setup do
    @user = User.create!(
      email: "corpus-#{SecureRandom.hex(4)}@example.com",
      password: "password123!", password_confirmation: "password123!", role: "editor"
    )

    # The fixtures are static files, so the records they name have fixed names.
    # Destroy before creating so a run killed halfway does not collide with the
    # next one — Group validates name uniqueness scoped to parent_id.
    Group.where(name: ["Corpus Group", "Corpus Forbidden"]).destroy_all
    Workflow.where(title: ["Corpus Sub Flow Target", "Corpus Ambiguous Target",
                           "Corpus Draft Target"]).destroy_all

    @group = Group.create!(name: "Corpus Group")
    UserGroup.create!(user: @user, group: @group)
    Group.create!(name: "Corpus Forbidden") # deliberately not a member

    published("Corpus Sub Flow Target")
    2.times { published("Corpus Ambiguous Target") }
    @user.workflows.create!(title: "Corpus Draft Target", status: "draft")
  end

  teardown do
    Workflow.where(title: ["Corpus Sub Flow Target", "Corpus Ambiguous Target",
                           "Corpus Draft Target"]).destroy_all
    User.where("email LIKE ?", "corpus-%").destroy_all
    Group.where(name: ["Corpus Group", "Corpus Forbidden"]).destroy_all
  end

  test "the valid fixture exercises all seven step types and validates cleanly" do
    report = validate_file("valid_all_step_types.json")

    assert_predicate report, :valid?, report.errors.inspect

    types = report.workflow_data["steps"].pluck("type").uniq.sort
    assert_equal Workflow::VALID_STEP_TYPES.sort, types
  end

  EXPECTED_CODES.each do |code|
    test "fixture invalid_#{code}.json produces the #{code} error" do
      report = validate_file("invalid_#{code}.json")

      assert_not report.valid?, "expected #{code}, got a valid report"
      assert_includes report.errors.pluck(:code), code,
                      "got #{report.errors.pluck(:code).inspect}"
    end
  end

  test "every fixture in the corpus is named after a code that exists" do
    named = Dir.children(CORPUS).grep(/\Ainvalid_(.+)\.json\z/) { Regexp.last_match(1) }

    assert_equal EXPECTED_CODES.sort, named.sort, "the corpus and EXPECTED_CODES disagree"
  end

  private

  def published(title)
    wf = @user.workflows.create!(title:, status: "published")
    Steps::Resolve.create!(workflow: wf, position: 0, title: "Done", resolution_type: "success")
    wf
  end

  def validate_file(name)
    StrictImportValidator.new(user: @user, content: CORPUS.join(name).read).validate
  end
end
