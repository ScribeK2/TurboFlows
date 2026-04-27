RailsIcons.configure do |config|
  config.default_library = "heroicons"
  config.default_variant = "outline"

  # Clear Tailwind-flavored size defaults — TurboFlows uses .icon / .icon--xs/sm/lg/xl
  # CSS classes from icons.css instead. Callers pass `class:` explicitly.
  config.libraries.heroicons.outline.default.css = ""
  config.libraries.heroicons.outline.default.stroke_width = "2"

  config.libraries.heroicons.solid.default.css = ""
  config.libraries.heroicons.mini.default.css = ""
  config.libraries.heroicons.micro.default.css = ""
end
