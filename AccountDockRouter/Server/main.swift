import Foundation
import Network

// AccountDockRouter: the local endpoint Claude Code reaches through
// `ANTHROPIC_BASE_URL`. `launchd` keeps it running independently of the
// AccountDock app, so Claude Code sessions keep working when the app quits.
// Everything it does is `RouterService`'s; this starts one on the standard
// environment and keeps the process alive.

/// Modification time of this executable, which the app compares with the
/// bundled copy to restart a router left running from an older build.
let buildStamp: String = {
    let path = CommandLine.arguments.first.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } ?? ""
    let date = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    return date.map { String(Int($0.timeIntervalSince1970)) } ?? "unknown"
}()

let service = RouterService(environment: .standard, buildStamp: buildStamp)
let listener: RouterListener
do {
    listener = try RouterListener(port: service.environment.port) { request, writer in
        await service.handle(request, writer)
    }
} catch {
    service.log.write("could not listen on \(service.environment.port): \(error.localizedDescription)")
    exit(1)
}
listener.start { state in
    switch state {
    case .ready: service.log.write("listening on \(RouterConfig.baseURL), version \(RouterConfig.version)")
    case .failed(let error):
        service.log.write("listener failed: \(error.localizedDescription)")
        exit(1)
    default: break
    }
}
dispatchMain()
