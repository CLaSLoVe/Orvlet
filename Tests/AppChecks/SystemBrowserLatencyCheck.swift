#if DEBUG
import AppKit
import Combine

@MainActor
enum SystemBrowserLatencyCheck {
    static func run(_ page: SystemBrowserPage) async throws -> [String] {
        var checks: [String] = []
        func require(_ value: Bool, _ label: String) throws {
            try StateMachineCheck.require(value, label, &checks)
        }
        func milliseconds(_ start: ContinuousClock.Instant) -> Double {
            let elapsed = start.duration(to: .now).components
            return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        }
        func textArrives(_ marker: String) async throws {
            for _ in 0..<200 {
                if try await page.evaluate("document.getElementById('latencyInput').value") as? String == marker { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw AppError.message("Input stayed queued behind pointer motion")
        }
        func flush() async throws {
            var finished = false
            page.enqueue { finished = true }
            for _ in 0..<200 {
                if finished { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw AppError.message("Browser input did not drain")
        }
        _ = try await page.evaluate("""
            document.body.innerHTML='<input id="latencyInput" style="position:fixed;top:8px;left:8px"><div style="height:20000px"></div>';
            document.getElementById('latencyInput').focus();
            window.wheels=[];document.addEventListener('wheel',e=>{e.preventDefault();wheels.push([e.deltaY,e.clientX,e.ctrlKey])},{passive:false});
            window.gestures=[];for(const t of ['pointerdown','pointerup'])document.addEventListener(t,e=>gestures.push([t,e.clientX,e.isTrusted]));true
            """)
        var samples: [Double] = []
        for sample in 0..<3 {
            let marker = "latency-\(sample)"
            _ = try await page.evaluate("document.getElementById('latencyInput').value='';true")
            let start = ContinuousClock.now
            for i in 0..<120 {
                page.input("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": 300 + i % 100, "y": 180,
                    "buttons": 0, "button": "none"])
            }
            page.input("Input.insertText", ["text": marker])
            try await textArrives(marker)
            samples.append(milliseconds(start))
        }
        try require(samples.allSatisfy { $0 < 500 }, "Typing stays below 500 ms after 120 queued pointer moves")
        let wheelStart = ContinuousClock.now
        for _ in 0..<120 {
            // Use CGFloat like Cocoa; numeric bridging must not lose scroll distance.
            page.input("Input.dispatchMouseEvent", ["type": "mouseWheel", "x": CGFloat(300), "y": CGFloat(180),
                "deltaX": CGFloat(0), "deltaY": CGFloat(3)])
        }
        // A change of target, direction or modifier must remain a separate event.
        for (x, delta, modifier) in [(400, 12, 0), (400, -6, 0), (400, -3, 2)] {
            page.input("Input.dispatchMouseEvent", ["type": "mouseWheel", "x": CGFloat(x), "y": CGFloat(180),
                "deltaX": CGFloat(0), "deltaY": CGFloat(delta), "modifiers": modifier])
        }
        page.input("Input.insertText", ["text": "-wheel"])
        try await textArrives("latency-2-wheel")
        let wheelLatency = milliseconds(wheelStart)
        try require(wheelLatency < 500, "Scrolling cannot build a seconds-long backlog ahead of typing")
        try require(try await page.evaluate("wheels.filter(e=>e[1]===300).reduce((s,e)=>s+e[0],0)===360 && wheels.some(e=>e[1]===400 && e[0]===12) && wheels.some(e=>e[1]===400 && e[0]===-6 && !e[2]) && wheels.some(e=>e[0]===-3 && e[2])") as? Bool == true,
            "Coalesced wheels preserve total distance, target, direction and modifiers")
        page.input("Input.dispatchMouseEvent", ["type": "mousePressed", "x": 350, "y": 220,
            "button": "left", "buttons": 1, "clickCount": 1])
        for i in 0..<120 {
            page.input("Input.dispatchMouseEvent", ["type": "mouseMoved", "x": 351 + i, "y": 220,
                "button": "left", "buttons": 1])
        }
        page.input("Input.dispatchMouseEvent", ["type": "mouseReleased", "x": 470, "y": 220,
            "button": "left", "buttons": 0, "clickCount": 1])
        try await flush()
        try require(try await page.evaluate("JSON.stringify(gestures)===JSON.stringify([['pointerdown',350,true],['pointerup',470,true]])") as? Bool == true,
            "Trusted press and release keep their order and positions around coalesced dragging")
        page.enqueue { _ = try await page.evaluate("document.getElementById('latencyInput').value='';document.getElementById('latencyInput').focus();true") }
        page.input("Input.insertText", ["text": "A"])
        page.input("Input.dispatchKeyEvent", ["type": "keyDown", "key": "Backspace", "windowsVirtualKeyCode": 8])
        page.input("Input.dispatchKeyEvent", ["type": "keyUp", "key": "Backspace", "windowsVirtualKeyCode": 8])
        page.input("Input.insertText", ["text": "B"])
        try await textArrives("B")
        try require(true, "Text and key transitions remain ordered across an asynchronous input action")

        var frameTimes: [Double] = []
        let animationStart = ContinuousClock.now
        let observation = page.$frame.dropFirst().sink { image in
            if image != nil { frameTimes.append(milliseconds(animationStart)) }
        }
        defer { observation.cancel() }
        _ = try await page.evaluate("window.animationStep=0;window.latencyAnimation=setInterval(()=>{document.body.style.backgroundColor='hsl('+((++animationStep*19)%360)+' 55% 85%)'},40);true")
        defer { Task { _ = try? await page.evaluate("clearInterval(window.latencyAnimation);true") } }
        try await Task.sleep(for: .seconds(1))
        try require(frameTimes.count >= 5, "The source delivers continuous changed frames, not only an opening screenshot")
        guard let model = page.owner?.model else { throw AppError.message("Missing browser owner") }
        let background = BrowserController(model: model)
        defer { background.dispose() }
        background.setUserPlaybackPaused(true, origin: "latency_check")
        _ = try await background.action(["action": "navigate", "url": "http://127.0.0.1:19244/fixture?background=latency"])
        let before = frameTimes.count
        try await Task.sleep(for: .milliseconds(300))
        try require(try await page.evaluate("document.visibilityState==='visible'") as? Bool == true && frameTimes.count > before,
            "A new background task does not occlude or freeze the displayed browser page")
        let data = try JSONSerialization.data(withJSONObject: ["pointerBurstToTextMilliseconds": samples,
            "wheelBurstToTextMilliseconds": wheelLatency, "animationFrameTimesMilliseconds": frameTimes], options: [.prettyPrinted])
        try data.write(to: URL(fileURLWithPath: "/tmp/orvlet-browser-latency.json"))
        print("Browser input latency (ms):", samples, "wheel:", wheelLatency)
        return checks
    }
}
#endif
