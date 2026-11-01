import SwiftUI

/// The shell and generated surfaces share a restrained, pearl-and-ink visual language.
enum CalmVisualStyle {
    static let width: CGFloat = 136
    static let rowWidth: CGFloat = 120
    static let rowHeight: CGFloat = 34
    static func tint(_ accent: Color, scheme: ColorScheme) -> Color {
        guard scheme == .light, let rgb = NSColor(accent).usingColorSpace(.deviceRGB) else { return accent }
        return Color(red:rgb.redComponent * 0.62,green:rgb.greenComponent * 0.62,blue:rgb.blueComponent * 0.62)
    }
    static let generationGuidance = """
    ORVLET ART DIRECTION — Pearl & Ink (mandatory for both compact and expanded UI):
    This is one thoughtfully designed macOS object. The host supplies pearl/glass surfaces, a fine highlight, consistent corner radii and a single muted accent. Do not draw another outer card or imitate a full website.
    Use the system rounded/sans typeface, --ink for primary text, --muted for secondary text, --tint for accent text, --soft for accent fills and --line for fine separators. Never introduce unrelated colors, emoji, gradients, shadows, font families or decorative illustrations. Host styling owns the material; your job is to arrange meaningful task content.
    Expanded: use a 4/8/12/16 spacing rhythm, 12px body, 10px muted labels, 20–28px semibold primary values, 10px control corners. Align content to a shared left edge and baseline. One primary value and at most one supporting line; grouped actions below. Leave balanced breathing room, no arbitrary centering, nested gray panels or duplicate headings. Use supplied .calm-value, .calm-label, .calm-row and .calm-stack classes when useful; compose your own semantic arrangement, not a preset task template.
    Compact: content canvas is 82×28px beside the host's consistent 20px task glyph. The host reserves that glyph area and keeps close/play controls local. Make a tiny, carefully typeset glimpse: either one 12px semibold live value, or a 9px muted label above an 11px live value. Use .calm-glance as your root, .calm-value for the important reading, .calm-label for context. Vertically center the group, left-align text, use tabular numerals, no headings, buttons, boxes, scrollbars, decorative glyphs, filler like 'Live status', or repeated task names. Never shrink an expanded card into this space. Shorten or omit secondary text rather than clipping the main value. Keep contrast legible in light and dark themes. All factual values must be grounded and live-bound when changing.
    Before returning, check: balanced margins, one clear focal point, no clipped content, no control overlap, consistent type and accent, and readable at actual compact size. A new task should change the information design, not the product's art style.
    """
    static let css = """
    :root{--ink:light-dark(#302e3f,#f0edf8);--muted:light-dark(#777386,#aaa5bb);--tint:light-dark(color-mix(in srgb,var(--accent) 62%,black),var(--accent));--soft:color-mix(in srgb,var(--accent) 12%,transparent);--line:light-dark(#34304a14,#f2eeff18);--space-1:4px;--space-2:8px;--space-3:12px;--space-4:16px}
    body{font-family:ui-rounded,-apple-system,BlinkMacSystemFont,sans-serif;color:var(--ink);padding:12px 14px;line-height:1.4;-webkit-font-smoothing:antialiased}
    .calm-value{font-size:24px;font-weight:600;letter-spacing:-.6px;font-variant-numeric:tabular-nums;line-height:1.12}.calm-label{font-size:10px;color:var(--muted);font-weight:500;line-height:1.3}.calm-row{display:flex;align-items:center;gap:8px}.calm-stack{display:flex;flex-direction:column;gap:8px}
    button{border-radius:10px;border-color:var(--line);background:var(--soft);font-weight:500;padding:7px 11px}button:hover{background:color-mix(in srgb,var(--accent) 20%,transparent)}input{border-radius:10px;padding:7px 10px}
    html[data-compact=true] body{padding:0 0 0 26px!important;font:11px ui-rounded,-apple-system,BlinkMacSystemFont,sans-serif!important;background:transparent!important;color:var(--ink)!important}
    html[data-compact=true] #surface{display:flex!important;align-items:center!important;overflow:hidden!important;width:100%;height:100%;text-align:left!important}
    html[data-compact=true] #surface>*{max-width:100%;max-height:28px}
    html[data-compact=true] #surface *{font-family:inherit!important;box-shadow:none!important;background:transparent!important;border:0!important;border-radius:0!important;animation:none!important;color:var(--ink)!important;font-size:11px!important;line-height:1.2!important;min-width:0!important;max-width:100%!important;font-variant-numeric:tabular-nums}
    html[data-compact=true] .calm-glance{display:flex;flex-direction:column;justify-content:center;gap:1px;width:100%;padding:0!important;margin:0!important}
    html[data-compact=true] #surface .calm-value,html[data-compact=true] #surface strong,html[data-compact=true] #surface h1,html[data-compact=true] #surface h2{font-size:12px!important;font-weight:600!important;line-height:1.15!important;letter-spacing:-.2px!important;white-space:nowrap}
    html[data-compact=true] #surface .calm-label,html[data-compact=true] #surface small{font-size:9px!important;line-height:1.15!important;color:var(--muted)!important;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    """
}

struct CalmGlyph: View {
    let symbol: String
    let accent: Color
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Image(systemName:symbol).font(.system(size:10,weight:.medium))
            .foregroundStyle(CalmVisualStyle.tint(accent,scheme:scheme))
            .frame(width:20,height:20)
            .background(accent.opacity(scheme == .dark ? 0.16 : 0.12),in:RoundedRectangle(cornerRadius:7))
    }
}
