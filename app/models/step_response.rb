class StepResponse < ApplicationRecord
  belongs_to :scenario
  belongs_to :step

  validates :submitted_at, presence: true
end
