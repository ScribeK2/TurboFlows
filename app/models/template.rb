class Template < ApplicationRecord
  # Workflow_data stored as JSON - automatically serialized/deserialized
  validates :name, presence: true
  validates :category, presence: true

  scope :public_templates, -> { where(is_public: true) }
  scope :by_category, ->(category) { where(category: category) }

  def self.search(query)
    return all if query.blank?

    search_term = "%#{query.strip}%"
    case_insensitive_like("name", search_term)
      .or(case_insensitive_like("description", search_term))
      .or(case_insensitive_like("category", search_term))
  end
end
