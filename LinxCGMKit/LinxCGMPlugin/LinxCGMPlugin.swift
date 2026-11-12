import LinxCGMKit
import LinxCGMKitUI
import LoopKit
import LoopKitUI
import os.log

class LinxCGMPlugin: NSObject, CGMManagerUIPlugin {
    private let log = OSLog(subsystem: "com.linxcgmkit", category: "LinxCGMPlugin")

    public var cgmManagerType: CGMManagerUI.Type? {
        LinxCGMManager.self
    }

    public var pumpManagerType: PumpManagerUI.Type? {
        nil
    }

    override init() {
        super.init()
        os_log("LinxCGMPlugin instantiated", log: log, type: .default)
    }
}
