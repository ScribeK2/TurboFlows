class Step < ApplicationRecord
  belongs_to :workflow
  has_many :transitions, dependent: :destroy
  has_many :incoming_transitions, class_name: "Transition", foreign_key: :target_step_id, dependent: :destroy

  validates :uuid, presence: true, uniqueness: { scope: :workflow_id }
  validates :position, presence: true

  before_validation :generate_uuid, if: -> { uuid.blank? }

  default_scope { order(:position) }

  # Check if this step is a terminal node (no outgoing transitions)
  def terminal?
    transitions.empty?
  end

  private

  def generate_uuid
    self.uuid = SecureRandom.uuid
  end
end
