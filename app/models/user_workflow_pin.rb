class UserWorkflowPin < ApplicationRecord
  MAX_PINS = 8

  belongs_to :user
  belongs_to :workflow

  validates :user_id, uniqueness: { scope: :workflow_id }
  validate :pin_limit, on: :create

  private

  def pin_limit
    if user && user.user_workflow_pins.count >= MAX_PINS
      errors.add(:base, "You can pin up to #{MAX_PINS} workflows")
    end
  end
end
