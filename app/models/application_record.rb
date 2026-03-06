class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  # Cross-database case-insensitive LIKE query
  # PostgreSQL: uses ILIKE (case-insensitive)
  # SQLite: uses LIKE (already case-insensitive for ASCII)
  def self.case_insensitive_like(column, value)
    quoted_column = connection.quote_column_name(column)
    if connection.adapter_name.downcase.include?('postgresql')
      where("#{quoted_column} ILIKE ?", value)
    else
      where("#{quoted_column} LIKE ?", value)
    end
  end
end
