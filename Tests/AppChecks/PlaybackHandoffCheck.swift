#if DEBUG
import AppKit
import SwiftUI
import WebKit

@MainActor
enum PlaybackHandoffCheck {
    static func run(_ model: AppModel) async throws {
        model.settings.autoAdapt = false
        model.settings.allowAgents = false
        model.isLiveTest = true
        model.persistHistory = false
        let other = BrowserController(model:model)
        let player = model.browser
        let otherWindow = NSWindow(contentRect:NSRect(x:-17000,y:-17000,width:500,height:300),styleMask:.borderless,backing:.buffered,defer:false)
        otherWindow.contentView = other.webView
        otherWindow.orderBack(nil)
        model.parkedBrowsers[other.id] = other
        defer { otherWindow.orderOut(nil); other.dispose(); player.dispose() }
        func check(_ value: Bool, _ text: String) throws {
            guard value else { throw AppError.message(text) }
            print("PASS " + text)
        }
        _ = try await other.action(["action":"navigate","url":"http://127.0.0.1:19244/"])
        do { _ = try await other.action(["action":"media","operation":"play"]) }
        catch {
            print("PRIME " + JSONText.encode((try? await other.observe()) ?? [:]))
            throw error
        }
        _ = try await PlaybackRestartCheck.advancing(other)
        let window = NSWindow(contentRect:NSRect(x:-16000,y:-16000,width:600,height:350),styleMask:.borderless,backing:.buffered,defer:false)
        window.contentView = player.webView
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        if CommandLine.arguments.contains("--restart-only") {
            print(JSONText.encode(["checks":try await PlaybackRestartCheck.local(model),"ok":true]))
            return
        }
        player.webView.loadHTMLString("""
        <html><head><title>Field recording</title></head><body>
        <audio id="media" preload="auto" src="http://127.0.0.1:19244/tone.wav" loop></audio>
        <button id="play" style="position:absolute;left:40px;top:40px;width:160px;height:50px" onclick="media.play().catch(e=>window.playError=e.message)">Play recording</button>
        <button id="other" style="position:absolute;left:240px;top:40px;width:160px;height:50px">Unrelated action</button>
        <script>window.trustedClicks=0;document.addEventListener('click',e=>{if(e.isTrusted)trustedClicks++},true)</script>
        </body></html>
        """,baseURL:URL(string:"http://127.0.0.1:19244/handoff"))
        for _ in 0..<80 {
            if (try? await player.webView.evaluateJavaScript("document.querySelector('audio')?.readyState>=2")) as? Bool == true { break }
            try await Task.sleep(for:.milliseconds(100))
        }
        model.webExpanded = true
        model.collapsed = false
        model.selectedTaskID = player.id
        func click(_ selector: String) async throws {
            let box = try await player.webView.evaluateJavaScript("(()=>{let r=document.querySelector(" + JSONText.encode(selector) + ").getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})()") as! [Double]
            let local = NSPoint(x:box[0],y:player.webView.isFlipped ? box[1] : player.webView.bounds.height-box[1])
            let point = player.webView.convert(local,to:nil)
            for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
                let e = NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                    windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
                window.sendEvent(e)
            }
            try await Task.sleep(for:.milliseconds(350))
        }
        try await click("#other")
        try check(model.playbackCoordinator.owner == other.id && player.playbackSuspended,
            "An unrelated real page click cannot steal playback")
        // A script-triggered click has no fresh trusted gesture at the isolated bridge.
        try await Task.sleep(for:.milliseconds(1300))
        _ = try await player.webView.evaluateJavaScript("document.querySelector('#play').click();true")
        try await Task.sleep(for:.milliseconds(300))
        try check(model.playbackCoordinator.owner == other.id, "Synthetic page clicks cannot acquire playback")
        try await click("#play")
        print("GESTURE " + JSONText.encode((try? await player.webView.evaluateJavaScript("({trustedClicks,playError:window.playError||'',paused:media.paused})")) ?? [:]))
        let playing = try await PlaybackRestartCheck.advancing(player)
        let otherState = try await other.observe()
        try check(model.playbackCoordinator.owner == player.id && !player.playbackSuspended
            && otherState["playing"] as? Bool == false,
            "A real play click hands off focus, pauses the earlier source and advances the new source")
        guard let card = model.sideTasks.first(where:{ $0.id == player.id }) else { throw AppError.message("Missing player card") }
        try check(card.isMediaTask && card.usesMusicCard && !card.opensSourceByDefault
            && card.allowedActions.contains("toggle") && model.musicPlayback[card.id]?.ready == true,
            "A non-YouTube source receives a player card without model-generated markup")
        try await model.performMusicControl(card.id,operation:"pause")
        try check((try await player.observe())["playing"] as? Bool == false, "The player card pauses the same source")
        try await model.performMusicControl(card.id,operation:"play")
        _ = try await PlaybackRestartCheck.advancing(player)
        let render = ImageRenderer(content:MusicCard(model:model,task:model.sideTasks.first { $0.id == card.id }!)
            .frame(width:328,height:184).background(CalmVisualStyle.windowFill(.light)).environment(\.colorScheme,.light))
        render.scale = 2
        if let image = render.nsImage, let data = image.tiffRepresentation,
            let png = NSBitmapImageRep(data:data)?.representation(using:.png,properties:[:]) {
            print("PLAYER_IMAGE " + png.base64EncodedString())
        }
        print(JSONText.encode(["ok":true,"cardID":card.id.uuidString,"title":card.title,"position":playing["currentTime"] ?? 0]))
        _ = try await player.action(["action":"navigate","url":"http://127.0.0.1:19244/blocked-source"])
        let blocked = model.sideTasks.first { $0.id == card.id }!
        try check(blocked.usesMusicCard && blocked.title == card.title && blocked.status == "Access needed"
            && model.musicErrors[card.id] != nil, "A rejected source retains the named player card and reports unavailable playback")
    }
}
#endif
