import SwiftUI

/// The shell and generated surfaces share a restrained, pearl-and-ink visual language.
enum CalmVisualStyle {
    static func windowFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.14, green: 0.135, blue: 0.18) : Color(red: 0.98, green: 0.975, blue: 1)
    }
    static let width: CGFloat = 136
    static let rowWidth: CGFloat = 120
    static let rowHeight: CGFloat = 34
    static func tint(_ accent: Color, scheme: ColorScheme) -> Color {
        guard scheme == .light, let rgb = NSColor(accent).usingColorSpace(.deviceRGB) else { return accent }
        return Color(red: rgb.redComponent * 0.62, green: rgb.greenComponent * 0.62, blue: rgb.blueComponent * 0.62)
    }
    static let generationGuidance = """
        ORVLET DESIGN CONTRACT — Pearl & Ink. Visual quality is a first-class acceptance criterion, alongside correctness and speed. A working but crude, generic or visually inconsistent interface is unfinished.

        INTENT: Design a small, desirable macOS companion: warm, precise, composed and quietly useful. Calm means low attention cost, not a bare prototype. Beauty comes from typography, proportion, optical alignment and subtle hierarchy, not more decoration. The task changes the composition; the product's visual language stays the same.

        LANGUAGE: Interface labels, buttons, hints and status text use English. Preserve user-supplied names and source content in their original language. Conversational replies may follow the human's language.

        INFORMATION RESTRAINT: Keep the default view quiet. Do not add permanent how-to copy, settings rows, search fields for a short list, or repeated chrome just because a feature exists. Secondary settings belong in an existing menu; preserve direct access to essential task actions. Do not duplicate an obvious gesture or nearby button in a menu. Keep contextual menus short and relevant, and centralize global preferences. Every new visible element must earn its attention cost.

        SHARED MATERIAL: The native shell already supplies the pearl/glass background, accent, rounded outline, task title, task glyph and window controls. Do not repeat that chrome, add a second outer card, fake album artwork/initials, emoji icons, decorative status dots, gradients, shadows, unrelated colors or web-style banners. Use the host system-rounded typeface. Text: --ink, --muted, --tint. Surfaces: --soft. Hairlines: --line. The host normalizes custom colors and fonts; express meaning with labels and hierarchy, not color alone. Support both light and dark appearance.

        EXPANDED COMPOSITION: The surface is about 300px wide including 14px host side insets; do not add another outer padding. Use a .calm-surface root, natural content height (100–320px including host padding), and a 4/8/12/16 spacing rhythm. One clear focal point, then useful context, then actions. Align related left edges and baselines; keep opposite margins balanced. Optical balance does not require centering everything. Use space between meaningful groups, never arbitrary spacer blocks, fixed-position overlays or full-height/100vh layouts. Preserve useful controls and input labels; a real form may need multiple fields. Long titles wrap to at most two lines, long prose wraps naturally; short primary values should remain readable. Do not solve overflow by making everything tiny or hiding essential controls.

        TYPOGRAPHY AND PRIMITIVES (compose freely; these are vocabulary, not task templates):
        .calm-title: 18px semibold, up to two lines for the main content title when it adds information beyond the native task header.
        .calm-value: 26px semibold, tabular numbers for the main result. .calm-label: 10px medium secondary label; .calm-description: 12px supporting text.
        .calm-stack: 8px vertical rhythm. .calm-row: aligned horizontal group. .calm-fields: two equal flexible columns; use one column for long inputs. A .calm-field label wraps its label text and input, textarea or select. Never rely on placeholder text as the only field label.
        .calm-actions: a wrapping control row. One .calm-primary button for the main action, .calm-secondary for supporting actions. At most three immediate actions; do not give every control equal visual weight. The host supplies comfortable 32px controls, consistent 10px corners, hover and keyboard-focus treatment.
        .calm-result: an unboxed result group with a label, live value and optional short explanation. .calm-list/.calm-item: compact separated rows for genuine multi-item content. Avoid nested gray panels and decorative badges.

        TASK FIT: Listening uses one live title and quiet source metadata. The host's expanded YouTube card provides transport, a thin seek bar for finite tracks, repeat, a volume popover and a folded queue; compact music remains title plus playback only. No duplicate song heading, fake cover, always-open volume panel or boxed duration. Generated music surfaces remain compact unless the human requests otherwise. A timer makes remaining time the focal point with direct controls. A calculation groups related inputs, one action and an unboxed result; text work gives the input and output adequate reading space. These are information priorities, not canned HTML: adapt composition to the actual task and verified data.

        COMPACT COMPOSITION: The host reserves a task glyph to the left; your content canvas is only 82×28px. Use a .calm-glance root with one useful .calm-value, optionally a short .calm-label above it. Host type is 12px/9px; do not add padding, icons, buttons, input fields, boxes, borders, headings or scrollbars. Keep the glance vertically centered, left aligned and limited to two lines. Select the most useful short reading (remaining time, next event time, result, count); omit secondary detail instead of squeezing the whole expanded card into this space. No filler such as 'Live status', 'Ready' or a repeated task name when a meaningful value exists. Native music and timer controls are already available beside the glance.

        FINISHING PASS (silently, before publishing; do not narrate it or delay starting the task): Is the purpose readable in one glance? Is there one focal point and a clear primary action? Are margins, baselines and spacing deliberate? Are all labels legible, values live-bound, long content handled and controls reachable at the actual size? Does compact mode show a useful glance rather than a miniature page? Would this sit naturally beside another Orvlet card in both themes? Fix visible problems in the first response. Never add model calls merely to decorate a running timer. Follow the host execution preference: task-first work starts immediately; interface-first prepares usable controls before starting playback. Time-sensitive deadlines are never delayed.
        """
    // Model-authored structure remains free. Brand properties are normalized at
    // the CSS declaration level, including inline styles, before the first paint.
    static let harmonizeScript = #"""
        function harmonize(style) {
          for (const name of Array.from(style)) {
            const value=style.getPropertyValue(name).trim();
            if (name.startsWith('--') || ['font','font-family','box-shadow','text-shadow','filter','backdrop-filter','-webkit-backdrop-filter','background-image','animation','transition','transform','zoom'].includes(name)) {
              style.removeProperty(name); continue;
            }
            if (name==='background') {
              style.removeProperty(name);
              if (/^(transparent|var\(--soft\))$/i.test(value)) style.setProperty('background-color',value);
              continue;
            }
            if (name==='color' || name.endsWith('-color')) {
              const allowed=name==='color' ? /^(inherit|currentcolor|var\(--(?:ink|muted|tint)\))$/i : /^(transparent|currentcolor|var\(--(?:soft|line|tint)\))$/i;
              if (!allowed.test(value)) { style.removeProperty(name); continue; }
            }
            // Author !important must not defeat host typography or compact sizing.
            style.setProperty(name,value,'');
          }
        }
        """#
    static let css = """
        :root{--ink:light-dark(#302e3f,#f0edf8);--muted:light-dark(#777386,#aaa5bb);--tint:light-dark(color-mix(in srgb,var(--accent) 62%,black),var(--accent));--soft:color-mix(in srgb,var(--accent) 12%,transparent);--line:light-dark(#34304a14,#f2eeff18);--space-1:4px;--space-2:8px;--space-3:12px;--space-4:16px}
        body{font-family:ui-rounded,-apple-system,BlinkMacSystemFont,sans-serif;color:var(--ink);padding:12px 14px;line-height:1.4;-webkit-font-smoothing:antialiased}
        #surface *{min-width:0;max-width:100%}input,textarea,select{width:100%}input[type=checkbox]{width:auto}textarea,select{font:inherit;color:inherit;background:var(--soft);border:1px solid var(--line);border-radius:10px;padding:7px 10px}textarea{resize:vertical}
        .calm-value{font-size:26px;font-weight:600;letter-spacing:-.6px;font-variant-numeric:tabular-nums;line-height:1.12}.calm-label{font-size:10px;color:var(--muted);font-weight:500;line-height:1.3}.calm-row{display:flex;align-items:center;gap:8px}.calm-stack{display:flex;flex-direction:column;gap:8px}
        .calm-surface{display:grid;gap:16px;align-content:start;padding:0;margin:0}
        .calm-title{font-size:18px;font-weight:600;letter-spacing:-.3px;line-height:1.25;overflow-wrap:anywhere;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
        .calm-description{font-size:12px;color:var(--muted);line-height:1.5;overflow-wrap:anywhere}
        .calm-fields{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}.calm-field{display:grid;gap:6px;align-content:start;font-size:10px;font-weight:500;color:var(--muted)}
        .calm-field input,.calm-field textarea,.calm-field select{font-size:12px;font-weight:400;color:var(--ink)}
        .calm-actions{display:flex;align-items:center;flex-wrap:wrap;gap:8px}.calm-result{display:grid;gap:4px}.calm-list{list-style:none;margin:0;padding:0;display:grid}.calm-item{padding:10px 0;border-bottom:1px solid var(--line)}.calm-item:last-child{border-bottom:0}
        #surface button,#surface input,#surface textarea,#surface select{font-family:inherit!important;border:1px solid var(--line);border-radius:10px!important;min-height:32px;color:var(--ink);background:var(--soft);line-height:1.3}
        #surface button{font-size:12px;font-weight:500;cursor:pointer}#surface button:disabled{opacity:.45;cursor:default}
        #surface .calm-primary{color:var(--tint)!important;background:color-mix(in srgb,var(--accent) 18%,transparent)!important;border-color:color-mix(in srgb,var(--accent) 24%,transparent)!important;font-weight:600}
        #surface .calm-secondary{background:transparent!important;border-color:var(--line)!important;color:var(--muted)!important}
        #surface button:hover:not(:disabled){background:color-mix(in srgb,var(--accent) 23%,transparent)!important}#surface :is(button,input,textarea,select):focus-visible{outline:2px solid var(--tint);outline-offset:2px}
        #surface input[type=checkbox]{min-height:0;accent-color:var(--tint)}
        button{border-radius:10px;border-color:var(--line);background:var(--soft);font-weight:500;padding:7px 11px}button:hover{background:color-mix(in srgb,var(--accent) 20%,transparent)}input{border-radius:10px;padding:7px 10px}
        #surface::-webkit-scrollbar{width:4px;height:4px}#surface::-webkit-scrollbar-thumb{background:var(--line);border-radius:4px}#surface::-webkit-scrollbar-track{background:transparent}
        #surface .calm-transport{display:inline-flex!important;align-items:center!important;justify-content:center!important;gap:8px!important;align-self:flex-start!important;justify-self:start!important;width:max-content!important;min-height:34px!important;padding:8px 14px!important;border-radius:10px!important;box-shadow:none!important;font-size:12px!important;font-weight:600!important}
        .calm-transport-icon{display:block!important;width:12px!important;height:12px!important;flex:none!important;background:currentColor!important;clip-path:polygon(15% 0,100% 50%,15% 100%)}
        [data-playing=true]>.calm-transport-icon{clip-path:polygon(0 0,35% 0,35% 100%,0 100%,0 0,65% 0,100% 0,100% 100%,65% 100%,65% 0)}
        html[data-compact=true] body{padding:0 0 0 26px!important;font:11px ui-rounded,-apple-system,BlinkMacSystemFont,sans-serif!important;background:transparent!important;color:var(--ink)!important}
        html[data-compact=true] #surface{display:flex!important;align-items:center!important;overflow:hidden!important;width:100%;height:100%;text-align:left!important}
        html[data-compact=true] #surface>*{max-width:100%;max-height:28px}
        html[data-compact=true] #surface *{font-family:inherit!important;box-shadow:none!important;background:transparent!important;border:0!important;border-radius:0!important;animation:none!important;color:var(--ink)!important;font-size:11px!important;line-height:1.2!important;min-width:0!important;max-width:100%!important;font-variant-numeric:tabular-nums}
        html[data-compact=true] .calm-glance{display:flex;flex-direction:column;justify-content:center;gap:1px;width:100%;padding:0!important;margin:0!important}
        html[data-compact=true] #surface .calm-value,html[data-compact=true] #surface strong,html[data-compact=true] #surface h1,html[data-compact=true] #surface h2{font-size:12px!important;font-weight:600!important;line-height:1.15!important;letter-spacing:-.2px!important;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        html[data-compact=true] #surface .calm-label,html[data-compact=true] #surface small{font-size:9px!important;line-height:1.15!important;color:var(--muted)!important;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        """
}

struct CalmGlyph: View {
    let symbol: String
    let accent: Color
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Image(systemName: symbol).font(.system(size: 10, weight: .medium))
            .foregroundStyle(CalmVisualStyle.tint(accent, scheme: scheme))
            .frame(width: 20, height: 20)
            .background(accent.opacity(scheme == .dark ? 0.16 : 0.12), in: RoundedRectangle(cornerRadius: 7))
    }
}
