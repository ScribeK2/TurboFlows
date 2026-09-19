# Saves the step panel's connection editor.
#
# The editor holds a snapshot: the transitions it was rendered with, plus rows
# the author has added since. The save it replaces deleted every transition the
# step had and rebuilt them from that snapshot, so an edge written on the server
# after the panel opened - one a door grew, one a health fix added - was wiped by
# the panel's next autosave, including the flush it sends as it closes.
#
# The payload distinguishes two facts a single `known` list used to conflate:
# `rendered` is every uuid the server actually put in this editor; `minted` is
# every uuid this editor invented itself - a row the author added, whether or
# not it has since saved: nothing moves a uuid out of `minted` on success,
# only a fresh render of the whole fragment starts `minted` over. A rendered
# uuid missing from `rows` was removed by the author - OR
# by someone else's save landing while this panel sat open, and the two cannot
# be told apart from a missing row alone. So a MISSING row is only ever created
# when it was minted here; a rendered-but-missing row is left alone and
# reported in the result's `skipped`, so the caller can heal the stale panel
# instead of quietly re-creating a connection someone else deleted. A row in
# neither list was never the editor's to judge and is left alone, silently - it
# isn't a stale row, it's simply not this editor's business.
#
# A payload still sending the legacy `known` shape (a browser running
# pre-deploy JavaScript) is read exactly as it always was: a missing row was
# never actually gated on `known` at all - `known` only ever fed the delete
# set - so under this shape every missing row is still created outright, and
# nothing is ever reported skipped.
class TransitionSync
  class Malformed < StandardError; end

  Result = Data.define(:skipped)

  def self.call(step, json, renamed_variable: nil)
    new(step, json, renamed_variable).call
  end

  def initialize(step, json, renamed_variable = nil)
    @step = step
    @renamed_variable = renamed_variable
    @skipped = []
    @payload = parse(json)
    @legacy, @rendered, @minted = shape_of(@payload)
  end

  def call
    steps_by_uuid = @step.workflow.steps.index_by(&:uuid)

    Transition.transaction do
      @step.transitions.where(uuid: shown_uuids - rows.pluck("uuid")).destroy_all
      next_position = @step.transitions.maximum(:position).to_i + 1

      rows.each_with_index { |row, index| sync_row(row, index, next_position, steps_by_uuid) }

      Transition.settle_positions(@step)
    end

    Result.new(skipped: @skipped)
  end

  private

  # A missing row (no transition with this uuid, scoped to this step) is only
  # ever created when this editor minted it - or, under the legacy shape,
  # unconditionally, since `known` never gated creation to begin with. A
  # rendered-but-missing uuid with nowhere to point - the row's own target was
  # cleared, not removed elsewhere - is never something to heal a panel over,
  # so that check comes first and skips silently either way, same as an
  # existing row losing its target.
  def sync_row(row, index, next_position, steps_by_uuid)
    uuid = row["uuid"]
    target = steps_by_uuid[row["target_uuid"]]
    transition = @step.transitions.find_by(uuid: uuid)

    if transition.nil?
      return if target.nil?

      if @legacy || @minted.include?(uuid)
        transition = @step.transitions.new(uuid: uuid)
      elsif @rendered.include?(uuid)
        @skipped << uuid
        return
      else
        return
      end
    end

    if target.nil?
      transition.destroy if transition.persisted?
      return
    end

    transition.update!(
      target_step: target,
      condition: rewritten_condition(row["condition"]),
      label: row["label"].presence,
      position: transition.position || (next_position + index)
    )
  end

  def shown_uuids
    (@rendered + @minted).uniq
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

  # Only reads: what the payload's keys MEAN is #shape_of's to say, so nothing
  # here assigns state.
  def parse(json)
    parsed = JSON.parse(json.to_s)
    raise malformed unless parsed.is_a?(Hash) && parsed["rows"].is_a?(Array)

    parsed
  rescue JSON::ParserError => e
    raise Malformed, "Invalid transitions JSON: #{e.message}"
  end

  # [legacy, rendered, minted] for a parsed payload, in either the current
  # shape or the legacy one. A payload carrying both - unreachable from the
  # current JS, but not unparseable - resolves to the current shape:
  # `rendered`/`minted` win outright and `known` is ignored, for the delete set
  # as much as for the row loop. Under the current shape
  # either key may be absent, but one that is present has to be an Array:
  # wrapping a stray scalar would read a lone string as a uuid this editor
  # showed or minted, and a payload this page never sends is refused, not
  # guessed at.
  def shape_of(parsed)
    rendered, minted, known = parsed.values_at("rendered", "minted", "known")

    if rendered.is_a?(Array) || minted.is_a?(Array)
      raise malformed unless [rendered, minted].all? { |list| list.nil? || list.is_a?(Array) }

      [false, rendered.to_a.map(&:to_s), minted.to_a.map(&:to_s)]
    elsif known.is_a?(Array)
      known = known.map(&:to_s)
      [true, known, known]
    else
      raise malformed
    end
  end

  def malformed
    Malformed.new("Connections were not saved: the editor sent a shape this page does not read.")
  end
end
