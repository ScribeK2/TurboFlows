class Tagging < ApplicationRecord
  belongs_to :tag
  belongs_to :workflow, touch: true

  validates :tag_id, uniqueness: { scope: :workflow_id }
end
