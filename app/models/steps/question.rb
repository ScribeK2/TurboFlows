class Steps::Question < Step
  validates :question, presence: true

  before_validation :generate_variable_name, if: -> { variable_name.blank? && title.present? }

  private

  def generate_variable_name
    self.variable_name = title
      .to_s.strip
      .gsub(/[?!.,;:'"(){}\[\]]/, "")
      .parameterize(separator: "_")
      .tr("-", "_").squeeze("_")
      .gsub(/^_|_$/, "")
      .first(30)
      .gsub(/_$/, "")
  end
end
