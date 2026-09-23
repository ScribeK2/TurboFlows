require "test_helper"

# The token values in _global.css, measured the way WCAG measures them.
#
# Two pairings shipped failing for a long time while the comments beside them
# said otherwise. Dark --color-primary was annotated "fill, white text" at L 0.70,
# where white measures 2.68:1; --color-ink-muted, used for every hint, subtitle,
# stat label and inactive tab, measured 3.1-3.4:1 in dark and 3.5-3.95:1 in
# light. Nothing rendered wrong, so nothing looked wrong — a colour that is too
# faint is still a colour. Found by the 2026-09-10 admin dark-mode audit.
#
# This reads the tokens rather than a page, so it guards the palette itself:
# retune a value and this says whether the pairs that depend on it still hold.
# The dark system-preference block is not read separately because
# GlobalThemeParityTest already requires it to match the [data-theme] block.
class TokenContrastTest < ActiveSupport::TestCase
  CSS = Rails.root.join("app/assets/stylesheets/_global.css").read.freeze

  LIGHT_BLOCK = "\n:root {".freeze
  DARK_BLOCK = "\n[data-theme=\"dark\"] {".freeze

  AA_TEXT = 4.5
  AA_NON_TEXT = 3.0

  # The avatar initial is literal white in .avatar-btn, in both themes.
  WHITE = "white (avatar initial)".freeze

  # [foreground, background, minimum]. Text pairs need 4.5:1; a filled button
  # read against the surface it sits on is a non-text boundary and needs 3:1.
  PAIRS = [
    ["--color-on-primary", "--color-primary", AA_TEXT],
    ["--color-on-primary", "--color-primary-hover", AA_TEXT],
    ["--color-primary-text", "--color-canvas", AA_TEXT],
    ["--color-primary-text", "--color-canvas-raised", AA_TEXT],
    # Link hovers. --color-primary-hover darkens a filled button in dark mode,
    # so a link cannot borrow it: five rules did, and would have dropped to 3:1.
    ["--color-primary-text-hover", "--color-canvas", AA_TEXT],
    ["--color-primary-text-hover", "--color-canvas-raised", AA_TEXT],
    ["--color-ink-muted", "--color-canvas", AA_TEXT],
    ["--color-ink-muted", "--color-canvas-alt", AA_TEXT],
    ["--color-ink-muted", "--color-canvas-raised", AA_TEXT],
    ["--color-ink-subtle", "--color-canvas-alt", AA_TEXT],
    ["--color-ink", "--color-canvas-alt", AA_TEXT],
    [WHITE, "--color-avatar-admin", AA_TEXT],
    [WHITE, "--color-primary", AA_TEXT], # the editor avatar
    [WHITE, "--color-avatar-regular", AA_TEXT],
    # The untyped .step-card__number chip: canvas-coloured text on subtle ink.
    ["--color-canvas-raised", "--color-ink-subtle", AA_TEXT],
    ["--color-primary", "--color-canvas-raised", AA_NON_TEXT]
  ].freeze

  %w[light dark].each do |theme|
    PAIRS.each do |foreground, background, minimum|
      test "#{theme}: #{foreground} on #{background} is at least #{minimum}:1" do
        tokens = theme_tokens(theme)
        ratio = contrast(color(tokens, foreground), color(tokens, background))

        assert_operator ratio.round(2), :>=, minimum,
                        "#{theme}: #{foreground} on #{background} measures #{format('%.2f', ratio)}:1, " \
                        "below #{minimum}:1. Retune the token, not this threshold."
      end
    end
  end

  private

  # Dark mode overrides :root rather than replacing it, so a token the dark
  # block does not declare (the avatar fills) keeps its light value there too.
  def theme_tokens(theme)
    light = custom_properties(block_body(LIGHT_BLOCK))
    theme == "light" ? light : light.merge(custom_properties(block_body(DARK_BLOCK)))
  end

  # Brace-matched body of the block opened by +selector+ (which includes the
  # opening brace). Same approach as GlobalThemeParityTest.
  def block_body(selector)
    start = CSS.index(selector)
    assert start, "selector not found in _global.css: #{selector.strip}"

    cursor = start + selector.length
    body_start = cursor
    depth = 1
    while depth.positive? && cursor < CSS.length
      case CSS[cursor]
      when "{" then depth += 1
      when "}" then depth -= 1
      end
      cursor += 1
    end

    CSS[body_start...(cursor - 1)]
  end

  def custom_properties(body)
    body.scan(/(--[\w-]+)\s*:\s*([^;]+);/).to_h { |name, value| [name, value.strip] }
  end

  # Follows var() aliases (light --color-primary-text is var(--color-primary))
  # down to a literal oklch(L C H).
  def color(tokens, name)
    return [1.0, 0.0, 0.0] if name == WHITE

    value = tokens.fetch(name) { flunk "#{name} is not declared in _global.css" }
    10.times do
      target = value[/\Avar\((--[\w-]+)\)\z/, 1] or break
      value = tokens.fetch(target) { flunk "#{name} aliases undeclared #{target}" }
    end

    match = value.match(/\Aoklch\(\s*([\d.]+)\s+([\d.]+)\s+([\d.]+)\s*\)\z/)
    assert match, "#{name} is '#{value}', which this test cannot measure"
    match.captures.map(&:to_f)
  end

  def contrast(first, second)
    darker, lighter = [luminance(first), luminance(second)].minmax
    (lighter + 0.05) / (darker + 0.05)
  end

  # OKLCH -> OKLab -> linear sRGB (Björn Ottosson's matrices), clamped to the
  # gamut, then WCAG relative luminance. Linear sRGB is already what the WCAG
  # formula wants after its gamma step, so no transfer function is applied.
  def luminance((lightness, chroma, hue))
    radians = hue * Math::PI / 180
    a = chroma * Math.cos(radians)
    b = chroma * Math.sin(radians)

    l = (lightness + (0.3963377774 * a) + (0.2158037573 * b))**3
    m = (lightness - (0.1055613458 * a) - (0.0638541728 * b))**3
    s = (lightness - (0.0894841775 * a) - (1.2914855480 * b))**3

    red   = ((4.0767416621 * l) - (3.3077115913 * m) + (0.2309699292 * s)).clamp(0.0, 1.0)
    green = ((-1.2684380046 * l) + (2.6097574011 * m) - (0.3413193965 * s)).clamp(0.0, 1.0)
    blue  = ((-0.0041960863 * l) - (0.7034186147 * m) + (1.7076147010 * s)).clamp(0.0, 1.0)

    (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
  end
end
