# Validates a strict-dialect import file without writing anything.
#
# Every check appends to one errors array, so a failing file comes back with all
# of its problems at once — an agent can fix ten errors in one pass but cannot
# see a silent drop. The codes are a published contract: once one ships, it does
# not get renamed.
#
# Resolution is deliberately separate from application: an unknown group or an
# unresolvable sub-flow target is a validation result, not an exception thrown
# partway through a write.
class StrictImportValidator
  Report = Data.define(:errors, :warnings, :workflow_data, :placement) do
    def valid? = errors.empty?
  end

  def self.strict?(content)
    parsed = JSON.parse(content.to_s)
    parsed.is_a?(Hash) && parsed.key?("schema_version")
  rescue JSON::ParserError
    false
  end

  def initialize(user:, content:)
    @user = user
    @content = content
    @errors = []
    @warnings = []
  end

  def validate
    document = parse_document
    return report if document.nil?

    check_schema_version(document)
    return report if @errors.any?

    workflow = extract_single_workflow(document)
    return report if workflow.nil?

    report(workflow_data: workflow)
  end

  private

  def parse_document
    document = JSON.parse(@content.to_s)

    unless document.is_a?(Hash)
      add_error("", "envelope_invalid", document.class.name,
                "The file must contain a JSON object at the top level.")
      return nil
    end

    document
  rescue JSON::ParserError => e
    add_error("", "malformed_json", nil, "The file is not valid JSON: #{e.message}")
    nil
  end

  def check_schema_version(document)
    version = document["schema_version"]
    return if version == ImportSchemaGenerator::SCHEMA_VERSION

    add_error("schema_version", "unsupported_schema_version", version,
              "schema_version #{version.inspect} is not supported.",
              expected: [ImportSchemaGenerator::SCHEMA_VERSION])
  end

  def extract_single_workflow(document)
    workflows = document["workflows"]

    unless workflows.is_a?(Array)
      return add_error("workflows", "envelope_invalid", workflows,
                       "The file must carry a 'workflows' array.")
    end

    if workflows.length != 1
      return add_error("workflows", "envelope_invalid", workflows.length,
                       "schema_version #{ImportSchemaGenerator::SCHEMA_VERSION} accepts " \
                       "exactly one workflow per file; this file has #{workflows.length}.")
    end

    workflow = workflows.first
    return workflow if workflow.is_a?(Hash)

    add_error("workflows[0]", "envelope_invalid", workflow.class.name,
              "Each entry in 'workflows' must be an object.")
  end

  # Always returns nil, so a caller can `return add_error(...)` to record and bail.
  def add_error(path, code, value, message, expected: nil)
    error = { path:, code:, message:, value: }
    error[:expected] = expected if expected
    @errors << error
    nil
  end

  def add_warning(path, code, value, message)
    @warnings << { path:, code:, message:, value: }
    nil
  end

  def report(workflow_data: nil, placement: nil)
    Report.new(errors: @errors, warnings: @warnings, workflow_data:, placement:)
  end
end
