class Transition < ApplicationRecord
  UUID_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  belongs_to :step
  belongs_to :target_step, class_name: "Step"

  validates :step_id, uniqueness: { scope: %i[target_step_id condition], message: "already has a transition to this target with the same condition" }
  # The browser makes this up for a row it has just added (TransitionSync), so
  # its shape is checked rather than trusted.
  validates :uuid, presence: true, uniqueness: true, format: { with: UUID_FORMAT }

  attr_readonly :uuid

  before_validation :generate_uuid, if: -> { uuid.blank? }

  scope :ordered, -> { order(:position) }

  # The order StepResolver tries a step's transitions in, spelled out. position
  # is nullable, and ORDER BY position alone puts a NULL first on SQLite and
  # last on PostgreSQL - the same rows routed differently here and in
  # production - while rows sharing a position came back in whatever order the
  # database liked. This is what production (PostgreSQL) already did: NULL
  # last, and id, the order they were made in, breaking a tie.
  # Step::Doors sorts loaded rows by .runner_sort_key, the same rule in Ruby.
  #
  # reorder, not order: Step's own `has_many :transitions` already says
  # order(:position), and a second order would only append after it.
  scope :in_runner_order, -> { reorder(Arel.sql("transitions.position IS NULL"), :position, :id) }

  def runner_sort_key
    [position.nil? ? 1 : 0, position || 0, id || 0]
  end

  validate :steps_belong_to_same_workflow

  # StepResolver takes the first transition that matches, and a blank condition
  # always matches - so a default edge sitting above a conditional one swallows
  # it. Conditionals first, in the order they already had; defaults last.
  #
  # Every row moves or none does. requires_new, because both callers already
  # hold a transaction open and a plain nested one would just join it: a
  # caller that rescued the failure would then keep the rows renumbered so far.
  def self.settle_positions(step)
    rows = step.transitions.includes(:target_step, :step).to_a
    ordered = rows.each_with_index.sort_by { |t, i| [t.condition.blank? ? 1 : 0, t.position || i, i] }.map(&:first)

    transaction(requires_new: true) do
      ordered.each_with_index { |t, i| t.update!(position: i) unless t.position == i }
    end
  end

  private

  def generate_uuid
    self.uuid = SecureRandom.uuid
  end

  def steps_belong_to_same_workflow
    return unless step && target_step

    if step.workflow_id != target_step.workflow_id
      errors.add(:target_step, "must belong to the same workflow")
    end
  end
end
