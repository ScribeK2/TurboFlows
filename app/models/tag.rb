class Tag < ApplicationRecord
  has_many :taggings, dependent: :destroy
  has_many :workflows, through: :taggings

  validates :name, presence: true, uniqueness: { case_sensitive: false }

  before_validation :strip_name

  scope :alphabetical, -> { order(:name) }

  private

  def strip_name
    self.name = name&.strip
  end
end
