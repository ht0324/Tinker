import Foundation

struct TaskEnablementStore {
    private let defaults: UserDefaults

    private let taskEnabledKeyPrefix = "automation.task.enabled."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func setEnabled(_ isEnabled: Bool, taskID: String) {
        defaults.set(isEnabled, forKey: taskEnabledKeyPrefix + taskID)
    }

    func isEnabled(_ taskID: String) -> Bool {
        defaults.bool(forKey: taskEnabledKeyPrefix + taskID)
    }
}
