class WorkflowTemplate
  TEMPLATES = begin
    raw = YAML.safe_load_file(Rails.root.join("config/templates.yml"), permitted_classes: [])
    deep_freeze = lambda do |obj|
      case obj
      when Hash
        obj.each_value { |v| deep_freeze.call(v) }
        obj.freeze
      when Array
        obj.each { |v| deep_freeze.call(v) }
        obj.freeze
      else
        obj.freeze
      end
    end
    deep_freeze.call(raw)
  end

  class << self
    def all
      TEMPLATES
    end

    def find(key)
      TEMPLATES.fetch(key)
    end

    def keys
      TEMPLATES.keys
    end
  end
end
