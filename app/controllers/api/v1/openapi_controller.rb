module Api
  module V1
    # The OpenAPI 3.1 description of /api/v1, public: it describes endpoints,
    # not data, and the /api/docs page loads it from a browser that has no
    # token. The source of truth is config/openapi/v1.yaml; a test fails if it
    # and the routes disagree.
    class OpenapiController < ActionController::API
      DOCUMENT = YAML.safe_load_file(Rails.root.join("config/openapi/v1.yaml"), permitted_classes: [],
                                                                                aliases: false).freeze

      def show
        render json: DOCUMENT
      end
    end
  end
end
