class AddHelpTextAndReferenceUrlToSteps < ActiveRecord::Migration[8.0]
  def change
    add_column :steps, :help_text, :string, limit: 500
    add_column :steps, :reference_url, :string
  end
end
