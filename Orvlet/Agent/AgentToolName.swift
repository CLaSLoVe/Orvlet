import Foundation

/// Stable wire names. Domains select executors; they do not grant permissions.
enum AgentToolName: String, CaseIterable {
    enum Domain { case data, workspace, native, browser, completion }
    case inspectApi = "inspect_api"
    case queryApi = "query_api"
    case runCode = "run_code"
    case presentUi = "present_ui"
    case controlTask = "control_task"
    case reuseSavedUi = "reuse_saved_ui"
    case timerStart = "timer_start"
    case calendarClarify = "calendar_clarify"
    case calendarCreate = "calendar_create"
    case findMusic = "find_music"
    case observe
    case reuseUi = "reuse_ui"
    case navigate
    case act
    case composeUi = "compose_ui"
    case visibility
    case history
    case restore
    case screenshot
    case finish
    case controlMedia = "control_media"
    /// Inspection and final verification may always be repeated. Effects use request-scoped receipts.
    var changesState: Bool {
        switch self {
        case .observe, .screenshot, .history, .inspectApi, .calendarClarify, .finish: return false
        default: return true
        }
    }
    var domain: Domain {
        switch self {
        case .inspectApi, .queryApi: return .data
        case .runCode, .presentUi, .controlTask, .reuseSavedUi: return .workspace
        case .timerStart, .calendarClarify, .calendarCreate: return .native
        case .findMusic, .observe, .reuseUi, .navigate, .act, .composeUi, .visibility, .history, .restore, .screenshot,
            .controlMedia:
            return .browser
        case .finish: return .completion
        }
    }
}
