class Step < ApplicationRecord
  include Step::Positionable

  belongs_to :workflow, counter_cache: :steps_count
  has_many :transitions, dependent: :destroy
  has_many :incoming_transitions, class_name: "Transition", foreign_key: :target_step_id, dependent: :destroy

  validates :uuid, presence: true, uniqueness: { scope: :workflow_id }
  validates :position, presence: true

  attr_readonly :uuid

  before_validation :generate_uuid, if: -> { uuid.blank? }

  default_scope { order(:position) }

  # Short step type name (e.g., "question", "action", "sub_flow")
  # Used by Scenario and other code that dispatches on step type.
  def step_type
    type.demodulize.underscore
  end

  # Check if this step is a terminal node (no outgoing transitions)
  def terminal?
    transitions.empty?
  end

  # Summary of outgoing transitions for display in collapsed cards
  def condition_summary
    return "Terminal" if terminal? && is_a?(Steps::Resolve)

    trans = transitions.includes(:target_step)
    return nil if trans.empty?
    return "-> #{trans.first.target_step&.title || 'Next Step'}" if trans.size == 1 && trans.first.condition.blank?

    labels = trans.first(3).map do |t|
      label = t.label.presence || t.condition.presence || "Default"
      target = t.target_step&.title&.truncate(20) || "?"
      "#{label} -> #{target}"
    end
    summary = "#{trans.size} branch#{'es' if trans.size != 1}: #{labels.join(', ')}"
    summary += ", ..." if trans.size > 3
    summary
  end

  # Override in subclasses to provide type-specific summary
  def outcome_summary
    nil
  end

  private

  def generate_uuid
    self.uuid = SecureRandom.uuid
  end
end
