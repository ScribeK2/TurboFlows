require "test_helper"

# UIGUIDE's two-tier semantics: --color-negative/positive/warning are sized for
# TEXT, icons and borders. When one is used as a fill, whatever text sits on it
# must be --color-on-X, which is white in light mode and ink in dark. Hardcoded
# white fails: in dark mode those tokens are light fills (L 0.80), so white on
# them measures ~3:1 and misses AA.
#
# Note what this does NOT assert. A semantic token used as a fill is perfectly
# legal — 22 rules do it today for status dots, progress bars and flash accents,
# where there is no text and therefore no contrast pair to get wrong. Flagging
# those would make this test noise, and a noisy test gets deleted. The defect is
# specifically text-on-fill with the wrong text token.
class SemanticFillContrastTest < ActiveSupport::TestCase
  STYLESHEET_DIR = Rails.root.join("app/assets/stylesheets")

  SEMANTIC_FILL = /background(?:-color)?\s*:[^;]*var\(--color-(?:negative|positive|warning)\)/
  ON_SEMANTIC   = /var\(--color-on-(?:negative|positive|warning)\)/
  COLOR_DECL    = /(?:\A|[;{\s])color\s*:([^;]*);/

  test "no rule puts non---color-on-* text on a semantic fill" do
    offenders = []

    Dir[STYLESHEET_DIR.join("*.css")].each do |path|
      css = File.read(path)

      # Innermost rule blocks only: a leaf `selector { declarations }`. Nested
      # at-rules (@layer, @media) contain braces and so never match, which is
      # what we want — declarations only ever live in leaves.
      #
      # Offsets are captured up front: matching COLOR_DECL below would otherwise
      # clobber Regexp.last_match and report the wrong line.
      rules = css.to_enum(:scan, /([^{}]+)\{([^{}]*)\}/)
                 .map { [Regexp.last_match.begin(0), Regexp.last_match(1), Regexp.last_match(2)] }

      rules.each do |offset, selector, body|
        next unless body.match?(SEMANTIC_FILL)

        color = body.match(COLOR_DECL)
        next if color.nil?                      # fill with no text — fine
        next if color[1].match?(ON_SEMANTIC)    # correctly paired — fine

        # Skip the selector's leading whitespace so the line points at the
        # selector itself, not the newline that ended the previous rule.
        line = css[0...(offset + selector[/\A\s*/].length)].count("\n") + 1
        offenders << "#{File.basename(path)}:#{line} " \
                     "#{selector.strip.lines.last.to_s.strip} sets text " \
                     "'#{color[1].strip}' on a semantic fill"
      end
    end

    assert_empty offenders,
                 "Text on a --color-negative/positive/warning fill must use the matching " \
                 "--color-on-* token (white in light, ink in dark). Hardcoded white fails " \
                 "AA in dark mode.\n  " + offenders.join("\n  ")
  end
end
