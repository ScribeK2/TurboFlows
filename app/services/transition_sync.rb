# Saves the step panel's connection editor.
#
# The editor holds a snapshot: the transitions it was rendered with, plus rows
# the author has added since. The save it replaces deleted every transition the
# step had and rebuilt them from that snapshot, so an edge written on the server
# after the panel opened - one a door grew, one a health fix added - was wiped by
# the panel's next autosave, including the flush it sends as it closes.
#
# `known` is every uuid the editor has ever shown; `rows` is what it shows now.
# A known uuid missing from rows was removed by the author. A transition outside
# `known` was never the editor's to judge and is left alone.
class TransitionSync
  class Malformed < StandardError; end

  def self.call(step, json, renamed_variable: nil)
    new(step, json, renamed_variable).call
  end

  def initialize(step, json, renamed_variable = nil)
    @step = step
    @payload = parse(json)
    @renamed_variable = renamed_variable
  end

  def call
    steps_by_uuid = @step.workflow.steps.index_by(&:uuid)

    Transition.transaction do
      @step.transitions.where(uuid: known - rows.pluck("uuid")).destroy_all
      next_position = @step.transitions.maximum(:position).to_i + 1

      rows.each_with_index do |row, index|
        transition = @step.transitions.find_or_initialize_by(uuid: row["uuid"])
        target = steps_by_uuid[row["target_uuid"]]

        if target.nil?
          transition.destroy if transition.persisted?
          next
        end

        transition.update!(
          target_step: target,
          condition: rewritten_condition(row["condition"]),
          label: row["label"].presence,
          position: transition.position || (next_position + index)
        )
      end

      Transition.settle_positions(@step)
    end
  end

  private

  def known
    @payload["known"].map(&:to_s)
  end

  def rows
    @rows ||= @payload["rows"].select { |row| row.is_a?(Hash) && row["uuid"].present? }
  end

  # The panel's snapshot was rendered before whatever renamed the step's own
  # variable in this same save, so a row still naming the old identifier here
  # is stale in exactly the way Steps::Question#carry_conditions_to_new_variable
  # already fixed once on the DB rows. Apply the same rewrite here, or this
  # write undoes it.
  def rewritten_condition(condition)
    condition = condition.presence
    return condition unless @renamed_variable

    Steps::Question.rewrite_condition_variable(condition, *@renamed_variable)
  end

  def parse(json)
    parsed = JSON.parse(json.to_s)
    unless parsed.is_a?(Hash) && parsed["known"].is_a?(Array) && parsed["rows"].is_a?(Array)
      raise Malformed, "Connections were not saved: the editor sent a shape this page does not read."
    end

    parsed
  rescue JSON::ParserError => e
    raise Malformed, "Invalid transitions JSON: #{e.message}"
  end
end
