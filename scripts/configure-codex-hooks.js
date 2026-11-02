ObjC.import("Foundation");

function mergeHooksFile(path) {
    const manager = $.NSFileManager.defaultManager;
    const directory = path.substring(0, path.lastIndexOf("/"));
    manager.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(
        directory, true, $(), null
    );

    let config = {};
    if (manager.fileExistsAtPath(path)) {
        const text = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(
            path, $.NSUTF8StringEncoding, null
        ));
        if (text) config = JSON.parse(text);
    }
    if (!config || Array.isArray(config) || typeof config !== "object") config = {};
    if (!config.hooks || Array.isArray(config.hooks) || typeof config.hooks !== "object") {
        config.hooks = {};
    }

    const command = '/bin/sh "/Applications/AccountDock.app/Contents/Resources/accountdock-codex-hook.sh" # accountdock-hook';
    ["SessionStart", "UserPromptSubmit", "Stop"].forEach((event) => {
        if (!Array.isArray(config.hooks[event])) config.hooks[event] = [];
        config.hooks[event] = config.hooks[event].filter((group) => {
            if (!group || !Array.isArray(group.hooks)) return true;
            return !group.hooks.some((hook) =>
                hook && typeof hook.command === "string" && hook.command.includes("# accountdock-hook")
            );
        });
        config.hooks[event].push({
            matcher: "",
            hooks: [{ type: "command", command, timeout: 5 }]
        });
    });
    if (!config.description) {
        config.description = "AccountDock lifecycle recovery metadata hooks.";
    }

    const backup = `${path}.accountdock-backup`;
    if (manager.fileExistsAtPath(path) && !manager.fileExistsAtPath(backup)) {
        manager.copyItemAtPathToPathError(path, backup, null);
    }
    const output = $(JSON.stringify(config, null, 2) + "\n")
        .dataUsingEncoding($.NSUTF8StringEncoding);
    if (!output.writeToFileAtomically(path, true)) {
        throw new Error(`could not write ${path}`);
    }
}

function run(arguments) {
    if (arguments.length !== 1) {
        throw new Error("usage: configure-codex-hooks.js <home>");
    }
    const home = arguments[0];
    mergeHooksFile(`${home}/.codex/hooks.json`);

    const managedRoot = `${home}/Library/Application Support/AccountDock/managed-codex-homes`;
    const manager = $.NSFileManager.defaultManager;
    if (!manager.fileExistsAtPath(managedRoot)) return;
    const children = ObjC.deepUnwrap(
        manager.contentsOfDirectoryAtPathError(managedRoot, null)
    ) || [];
    children.forEach((child) => mergeHooksFile(`${managedRoot}/${child}/hooks.json`));
}
