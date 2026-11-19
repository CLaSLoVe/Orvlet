import Foundation

/// Host-rendered graphics. Generated markup supplies labels and state keys.
enum CardVisuals {
    static let script = #"""
        const figures = [...document.querySelectorAll('figure[data-series]')];
        const tables = [...document.querySelectorAll('table')].filter(table => table.querySelector('thead th[data-column]'));
        const lastVisual = new WeakMap();

        function readColumn(raw) {
          try {
            const values = JSON.parse(raw);
            return Array.isArray(values) && values.length <= 512 ? values : [];
          } catch { return []; }
        }
        function changed(element, values) {
          const before = lastVisual.get(element);
          if (before && before.length === values.length && values.every((v,i) => before[i] === v)) return false;
          lastVisual.set(element, values);
          return true;
        }
        function drawRows(table, state) {
          const headers = [...table.querySelectorAll('thead th')];
          const raw = headers.map(h => state[h.dataset.column]);
          if (!changed(table, raw)) return;
          const columns = raw.map(readColumn);
          let count = columns[0].length;
          if (!columns.every(column => column.length === count)) count = 0;
          const body = table.tBodies[0] || table.createTBody();
          body.replaceChildren();
          for (let i=0; i<count; i++) {
            const row = body.insertRow();
            for (const column of columns) {
              const cell = column[i];
              row.insertCell().textContent = ['string','number','boolean'].includes(typeof cell) ? String(cell) : '—';
            }
          }
          if (!count) {
            const cell = body.insertRow().insertCell();
            cell.colSpan = headers.length;
            cell.textContent = '—';
          }
        }
        function numeric(value) {
          if (typeof value !== 'number' && (typeof value !== 'string' || !value.trim())) return NaN;
          const n = Number(value);
          return Number.isFinite(n) ? n : NaN;
        }
        function svgElement(tag, attributes) {
          const element = document.createElementNS('http://www.w3.org/2000/svg', tag);
          for (const [name,value] of Object.entries(attributes)) element.setAttribute(name, String(value));
          return element;
        }
        function drawSeries(figure, state) {
          const raw = [state[figure.dataset.x], state[figure.dataset.series]];
          if (!changed(figure, raw)) return;
          const xs = readColumn(raw[0]), ys = readColumn(raw[1]).map(numeric);
          const time = figure.dataset.xFormat;
          function coordinate(value) {
            const n = numeric(value);
            if (Number.isFinite(n)) return time === 'unixSeconds' ? n*1000 : n;
            return typeof value === 'string' && /^\d{4}-\d{2}-\d{2}/.test(value) ? Date.parse(value) : NaN;
          }
          const x = xs.map(coordinate), valid = ys.filter(Number.isFinite);
          const caption = figure.querySelector('figcaption') || document.createElement('figcaption');
          if (!caption.textContent) caption.textContent = figure.getAttribute('aria-label') || '';
          caption.classList.add('visual-heading');
          figure.replaceChildren(caption);
          if (!x.length || x.length !== ys.length || !valid.length ||
              x.some((v,i) => !Number.isFinite(v) || (i && v <= x[i-1]))) {
            figure.append(document.createTextNode('—'));
            return;
          }
          const low = Math.min(...valid), high = Math.max(...valid), last = x.length-1;
          const X = i => last ? 52 + (x[i]-x[0])/(x[last]-x[0])*221 : 162;
          const Y = v => high === low ? 41 : 72-(v-low)/(high-low)*60;
          const svg = svgElement('svg', {viewBox:'0 0 280 84', role:'img'});
          const format = v => v.toLocaleString(document.documentElement.lang,{maximumSignificantDigits:6});
          svg.setAttribute('aria-label', [caption.textContent, String(xs[0]), String(xs[last]), format(low), format(high)].join(' · '));
          for (const value of new Set([low,high])) {
            const y = Y(value);
            svg.append(svgElement('line',{x1:50,x2:275,y1:y,y2:y,stroke:'var(--line)'}));
            const label = svgElement('text',{x:46,y:y+3,'text-anchor':'end','font-size':9,fill:'var(--muted)'});
            label.textContent = format(value);
            svg.append(label);
          }
          let path = '', connected = false;
          for (let i=0; i<ys.length; i++) {
            if (!Number.isFinite(ys[i])) { connected = false; continue; }
            path += (connected ? 'L' : 'M') + X(i) + ',' + Y(ys[i]) + ' ';
            if (!connected && !Number.isFinite(ys[i+1])) svg.append(svgElement('circle',{cx:X(i),cy:Y(ys[i]),r:2.4,fill:'currentColor'}));
            connected = true;
          }
          svg.append(svgElement('path',{d:path,stroke:'currentColor',fill:'none','stroke-width':2,'stroke-linejoin':'round','stroke-linecap':'round'}));
          const range = document.createElement('div');
          range.className = 'visual-range';
          for (const i of new Set([0,last])) {
            const label = document.createElement('span');
            label.textContent = String(xs[i]);
            if (time === 'unixSeconds' || time === 'unixMilliseconds') {
              const date = new Date(x[i]);
              if (Number.isFinite(date.getTime())) label.textContent = date.toLocaleString(document.documentElement.lang,{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'});
            }
            range.append(label);
          }
          figure.append(svg,range);
        }
        function updateVisuals(state) {
          for (const table of tables) drawRows(table,state);
          for (const figure of figures) drawSeries(figure,state);
        }
        """#
}

/// Declarative blocks for local forms and remote readings. The host owns their DOM and styles.
struct CardVisual: Codable {
    enum Kind: String, Codable { case table, line }
    struct Column: Codable {
        var key: String
        var label: String
    }
    var kind: Kind
    var label: String
    var columns: [Column]
    var xFormat: String? = nil

    static let schema: [String: Any] = [
        "type": "array", "maxItems": 3,
        "description": "Optional host components. Choose a table for comparing values or a line for an observed trend. Use exact keys of declared aligned array fields or array outputs. Omit visuals for scalar-only readings. For a line supply x then y, and include units in the label.",
        "items": ["type": "object", "properties": [
            "kind": ["type": "string", "enum": ["table", "line"]], "label": ["type": "string"],
            "columns": ["type": "array", "items": ["type": "object", "properties": [
                "key": ["type": "string"], "label": ["type": "string"]], "required": ["key", "label"]]],
            "xFormat": ["type": "string", "description": "Use number for durations, distances, counts and other measured x values. Use a Unix format only for absolute timestamps.", "enum": ["number", "unixSeconds", "unixMilliseconds"]],
        ], "required": ["kind", "label", "columns"]],
    ]

    @MainActor
    static func decodeProposals(_ raw: Any?) -> (blocks: [CardVisual], count: Int) {
        guard let raw, !(raw is NSNull) else { return ([], 0) }
        let blocks = raw as? [Any] ?? [raw]
        let schema = ToolSchema.closed(CardVisual.schema)["items"] as! [String: Any]
        let decoded: [CardVisual] = blocks.compactMap { value in
            guard var block = value as? [String: Any] else { return nil }
            if block["label"] == nil { block["label"] = "" }
            if let columns = block["columns"] as? [Any], columns.count <= 6 {
                block["columns"] = columns.map { value -> Any in
                    if let key = value as? String { return ["key": key, "label": ""] }
                    guard var column = value as? [String: Any], column["label"] == nil else { return value }
                    column["label"] = ""
                    return column
                }
            }
            guard (try? ToolContract.validate(block, schema: schema)) != nil,
                let data = try? JSONSerialization.data(withJSONObject: block) else { return nil }
            return try? JSONDecoder().decode(CardVisual.self, from: data)
        }
        return (decoded, blocks.count)
    }

    func bound(to available: [Column]) -> CardVisual? {
        guard (1...6).contains(columns.count) else { return nil }
        var block = self
        var boundColumns: [Column] = []
        for column in columns {
            let key = column.key.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = available.filter { $0.key.caseInsensitiveCompare(key) == .orderedSame }
            let byLabel = available.filter { $0.label.caseInsensitiveCompare(key) == .orderedSame }
            guard !key.isEmpty, let field = available.first(where: { $0.key == key })
                ?? (matches.count == 1 ? matches.first : nil)
                ?? (matches.isEmpty && byLabel.count == 1 ? byLabel.first : nil)
            else { return nil }
            let label = column.label.trimmingCharacters(in: .whitespacesAndNewlines)
            boundColumns.append(Column(key: field.key, label: label.isEmpty ? field.label : label))
        }
        block.columns = boundColumns
        block.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if block.label.isEmpty {
            block.label = block.kind == .line ? boundColumns.last!.label : boundColumns.map(\.label).joined(separator: " · ")
        }
        guard (try? Self.markup([block])) != nil else { return nil }
        return block
    }

    static func markup(_ blocks: [CardVisual], path: String = "$.form.visuals") throws -> String {
        guard blocks.count <= 3 else { throw ToolArgumentError(path: path, issue: "keep at most three visual blocks") }
        return try blocks.enumerated().map { index, block in
            let base = path + "[\(index)]"
            guard !block.label.isEmpty, block.label.count <= 80 else {
                throw ToolArgumentError(path: base + ".label", issue: "use a label of 1–80 characters")
            }
            guard (1...6).contains(block.columns.count), block.kind != .line || block.columns.count == 2 else {
                throw ToolArgumentError(path: base + ".columns", issue: block.kind == .line
                    ? "bind exactly two distinct series in x, y order" : "bind one to six columns")
            }
            var seen: Set<String> = []
            for (position, column) in block.columns.enumerated() {
                let field = base + ".columns[\(position)]"
                guard column.key.range(of: #"^[a-zA-Z][a-zA-Z0-9_-]{0,31}$"#, options: .regularExpression) != nil,
                    seen.insert(column.key).inserted else {
                    throw ToolArgumentError(path: field + ".key", issue: "use a distinct, valid series key")
                }
                guard !column.label.isEmpty, column.label.count <= 80 else {
                    throw ToolArgumentError(path: field + ".label", issue: "use a label of 1–80 characters")
                }
            }
            if let format = block.xFormat, !["number", "unixSeconds", "unixMilliseconds"].contains(format) {
                throw ToolArgumentError(path: base + ".xFormat", issue: "choose number, unixSeconds or unixMilliseconds")
            }
            let label = BuiltinCards.escape(block.label)
            if block.kind == .line {
                let format = block.xFormat.map { " data-x-format='" + $0 + "'" } ?? ""
                return "<figure data-x='" + block.columns[0].key + "' data-series='" + block.columns[1].key
                    + "' aria-label='" + label + "'" + format + "></figure>"
            }
            let headers = block.columns.map { "<th scope='col' data-column='" + $0.key + "'>" + BuiltinCards.escape($0.label) + "</th>" }.joined()
            return "<table><caption>" + label + "</caption><thead><tr>" + headers + "</tr></thead></table>"
        }.joined()
    }
}
