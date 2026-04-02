# StepParamsForm — form object that parses raw step params from controller submissions.
#
# The frontend sends transitions, output_fields, and attachments as JSON strings.
# This form object converts them to proper Ruby arrays so downstream services
# (StepSyncer, StepBuilder) receive clean data without mutating params in-place.
#
# Addresses audit finding C-02 (High).
class StepParamsForm
  attr_reader :title, :type, :transitions, :output_fields, :attachments

  def initialize(params)
    @title         = params[:title]
    @type          = params[:type]
    @transitions   = parse_json_array(params[:transitions_json])
    @output_fields = parse_json_array(params[:output_fields])
    @attachments   = parse_json_array(params[:attachments])
    @raw           = params.except(:transitions_json)
  end

  # Returns an ActionController::Parameters-like hash suitable for passing to
  # service objects that expect step data with parsed arrays.
  def to_step_params
    @raw.merge(
      transitions:   @transitions,
      output_fields: @output_fields,
      attachments:   @attachments
    )
  end

  private

  def parse_json_array(value)
    return value if value.is_a?(Array)
    return [] if value.blank?

    parsed = JSON.parse(value)
    parsed.is_a?(Array) ? parsed : []
  rescue JSON::ParserError
    []
  end
end
