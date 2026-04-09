namespace :templates do
  desc "Seed default workflow templates"
  task seed: :environment do
    puts "🌱 Seeding workflow templates..."
    puts ""

    # Load seeds file to execute template seeding
    # Note: This will run the template seeding portion of seeds.rb
    load Rails.root.join("db/seeds.rb")

    puts ""
    puts "✅ Template seeding complete!"
    puts ""
    puts "View templates at: /templates"
    puts ""

    # Display summary
    public_count = Template.public_templates.count
    total_count = Template.count

    puts "📊 Summary:"
    puts "   Public templates: #{public_count}"
    puts "   Total templates: #{total_count}"
    puts ""

    if public_count.positive?
      puts "Available templates:"
      Template.public_templates.order(:category, :name).each do |template|
        step_count = template.workflow_data&.length || 0
        puts "   - #{template.name} (#{template.category}) - #{step_count} steps"
      end
    end
  end

  desc "Reset and re-seed templates (removes existing templates)"
  task reset: :environment do
    puts "⚠️  WARNING: This will delete all existing templates!"
    puts "   (Admin templates will be preserved if they are not public)"
    puts ""
    print "Continue? (yes/no): "

    if $stdin.gets.chomp.downcase == 'yes'
      public_count = Template.public_templates.count
      Template.public_templates.destroy_all
      puts "✅ Deleted #{public_count} public templates"
      puts ""

      # Now seed fresh templates
      Rake::Task['templates:seed'].invoke
    else
      puts "❌ Cancelled. Templates not modified."
    end
  end
end
