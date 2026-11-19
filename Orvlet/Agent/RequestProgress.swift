import Foundation

extension AgentController {
    static func progressLabel(_ tool: String) -> String {
        switch tool {
        case "load_tools": "Preparing task tools…"
        case "run_code": "Checking the calculation…"
        case "present_ui", "compose_ui", "manage_task": "Building and checking the card…"
        case "read_value", "query_api", "inspect_api": "Reading the data source…"
        case "observe", "navigate", "screenshot": "Checking the source page…"
        case "control_task", "act", "control_media": "Applying the task action…"
        case "finish": "Verifying the result…"
        case "reuse_ui", "reuse_saved_ui": "Binding the saved layout…"
        case "calendar_create", "calendar_clarify": "Checking the calendar…"
        case "find_music": "Finding playback…"
        case "timer_start": "Starting the countdown…"
        default: "Updating the task…"
        }
    }
}
