ObjC.import("Foundation");

function run(arguments) {
    if (arguments.length !== 1) {
        throw new Error("usage: configure-claude-hooks.js <home>");
    }

    const home = arguments[0];
    const claudeDirectory = `${home}/.claude`;
    const settingsPath = `${claudeDirectory}/settings.json`;
    const manager = $.NSFileManager.defaultManager;
    manager.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(
        claudeDirectory, true, $(), null
    );

    let settings = {};
    if (manager.fileExistsAtPath(settingsPath)) {
        const text = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(
            settingsPath, $.NSUTF8StringEncoding, null
        ));
        if (text) {
            settings = JSON.parse(text);
        }
    }
    if (!settings || Array.isArray(settings) || typeof settings !== "object") {
        settings = {};
    }
    if (!settings.hooks || Array.isArray(settings.hooks) || typeof settings.hooks !== "object") {
        settings.hooks = {};
    }

    const command = '"/Applications/AccountDock.app/Contents/Resources/accountdock-claude-hook.sh" # accountdock-hook';
    ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"].forEach((event) => {
        if (!Array.isArray(settings.hooks[event])) {
            settings.hooks[event] = [];
        }
        settings.hooks[event] = settings.hooks[event].filter((group) => {
            if (!group || !Array.isArray(group.hooks)) return true;
            return !group.hooks.some((hook) =>
                hook && typeof hook.command === "string" && hook.command.includes("# accountdock-hook")
            );
        });
        settings.hooks[event].push({
            matcher: "",
            hooks: [{ type: "command", command }]
        });
    });

    const backupPath = `${settingsPath}.accountdock-backup`;
    if (manager.fileExistsAtPath(settingsPath) && !manager.fileExistsAtPath(backupPath)) {
        manager.copyItemAtPathToPathError(settingsPath, backupPath, null);
    }
    const output = $(JSON.stringify(settings, null, 2) + "\n")
        .dataUsingEncoding($.NSUTF8StringEncoding);
    if (!output.writeToFileAtomically(settingsPath, true)) {
        throw new Error(`could not write ${settingsPath}`);
    }
}
