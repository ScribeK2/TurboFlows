module Api
  module V1
    # The strict dialect's JSON Schema and the guide an AI reads before writing a
    # draft. The same text the import page offers as a prompt.
    class AuthoringGuidesController < BaseController
      before_action do
        next if current_api_token.allows?(:read) || current_api_token.allows?(:draft)

        require_scope!(:read)
      end

      def show
        render json: { schema_version: ImportSchemaGenerator::SCHEMA_VERSION,
                       schema: ImportSchemaGenerator.call,
                       guide: ImportPromptGenerator.call }
      end
    end
  end
end
