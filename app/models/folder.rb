class Folder < ApplicationRecord
  belongs_to :group
  belongs_to :parent, class_name: "Folder", optional: true
  has_many :children, class_name: "Folder", foreign_key: "parent_id", inverse_of: :parent, dependent: :nullify
  has_many :group_workflows, dependent: :nullify
  has_many :workflows, through: :group_workflows

  validates :name, presence: true,
                   length: { maximum: 255 },
                   uniqueness: { scope: :group_id }

  scope :ordered, -> { order(:position, :name) }

  def workflows_count
    group_workflows.count
  end
end
