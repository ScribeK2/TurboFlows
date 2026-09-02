namespace :import_schema do
  desc "Regenerate public/schemas/turboflows-workflow-v1.json from the models"
  task generate: :environment do
    ImportSchemaGenerator::SCHEMA_PATH.dirname.mkpath
    ImportSchemaGenerator::SCHEMA_PATH.write("#{JSON.pretty_generate(ImportSchemaGenerator.call)}\n")
    puts "Wrote #{ImportSchemaGenerator::SCHEMA_PATH}"
  end
end
