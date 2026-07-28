ObjC.import("Foundation");

function readStandardInput() {
    const input = $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile;
    return ObjC.unwrap($.NSString.alloc.initWithDataEncoding(input, $.NSUTF8StringEncoding)) || "";
}

function safeString(value) {
    return typeof value === "string" ? value : "";
}

function environmentValue(key) {
    const value = $.NSProcessInfo.processInfo.environment.objectForKey($(key));
    return value ? ObjC.unwrap(value) : "";
}

function run() {
    let payload;
    try {
        payload = JSON.parse(readStandardInput());
    } catch (_) {
        return;
    }

    const sessionID = safeString(payload.session_id)
        || safeString(payload.sessionId)
        || environmentValue("CLAUDE_IDE_SESSION_ID")
        || environmentValue("CLAUDE_SESSION_ID");
    if (!/^[A-Za-z0-9._:-]{1,160}$/.test(sessionID)) {
        return;
    }

    const event = safeString(payload.hook_event_name)
        || safeString(payload.hookEventName)
        || "Unknown";
    const cwd = safeString(payload.cwd)
        || safeString(payload.working_directory)
        || environmentValue("PWD");
    const home = environmentValue("HOME");
    if (!home) {
        return;
    }

    const directory = `${home}/Library/Application Support/AccountDock/Sessions`;
    const manager = $.NSFileManager.defaultManager;
    manager.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(
        directory, true, $(), null
    );

    const record = {
        schemaVersion: 1,
        provider: environmentValue("ACCOUNTDOCK_PROVIDER") || "unknown",
        sessionID,
        event,
        workingDirectory: cwd,
        processID: Number(environmentValue("ACCOUNTDOCK_AGENT_PID")) || null,
        host: environmentValue("CLAUDE_CODE_ENTRYPOINT")
            || (environmentValue("TERM_PROGRAM") === "vscode" ? "vscode" : "cli"),
        observedAt: (new Date()).toISOString()
    };
    const data = $(JSON.stringify(record, null, 2)).dataUsingEncoding($.NSUTF8StringEncoding);
    const provider = record.provider.replace(/[^A-Za-z0-9_-]/g, "");
    const target = `${directory}/${provider}-${sessionID}.json`;
    data.writeToFileAtomically(target, true);
}
