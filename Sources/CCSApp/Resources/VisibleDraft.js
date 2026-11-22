// Apple Terminal supplies rendered text. Return only the keys of tabs whose
// bottom composer resembles a draft. Never return or store its contents.
function possibleDraft(screen, provider) {
    const rows = screen.split(/\r\n|\r|\n/).map(row => row.trim());
    while (rows.length && !rows[rows.length - 1]) rows.pop();
    const tail = rows.slice(-14);
    const marker = provider === "claude" ? "❯" : "›";
    const index = tail.map(isPrompt).lastIndexOf(true);
    function isPrompt(row) {
        return row === marker || (row.startsWith(marker) && /\s/.test(row.charAt(1)));
    }
    if (index < 0) return false;
    const firstLine = tail[index].slice(1).trim();
    if (!firstLine || /^(?:try\b|ask (?:codex|claude)\b|type (?:a message|your)|what (?:should|would you)|implement \{feature\}|explain this codebase|run \/review|find and fix a bug in|summarize recent commits|improve documentation in|write tests for|use \/skills)/i.test(firstLine)) return false;
    const after = tail.slice(index + 1);
    if (provider === "claude") {
        const rule = row => /^[─━]{5,}$/.test(row);
        const end = after.findIndex(rule);
        return index > 0 && rule(tail[index - 1]) && end >= 0 && after.length - end <= 4;
    }
    // A submitted prompt in scrollback can use the same glyph. Require the
    // composer footer and exclude a second prompt, dialogs and assistant output.
    const footer = /(?:\? for shortcuts|context left|context remaining|gpt-[\w.-]+.*[·│|]|[·│|].*gpt-[\w.-]+)/i;
    const end = after.findIndex(row => footer.test(row));
    return end >= 0 && after.length - end <= 3 &&
        after.slice(0, end).every(row => !row || !/^[•◇◆›❯╭╰]/.test(row));
}

function run(argv) {
    const wanted = new Map(JSON.parse(argv[0]).map(tab => [tab.tty, tab]));
    const terminal = Application("com.apple.Terminal");
    const found = [];
    if (terminal.running()) {
        for (const window of terminal.windows()) {
            for (const tab of window.tabs()) {
                try {
                    const target = wanted.get(tab.tty());
                    if (target && tab.customTitle() === target.title &&
                        possibleDraft(tab.contents(), target.provider)) found.push(target.key);
                } catch (_) { /* A tab may have closed during the scan. */ }
            }
        }
    }
    return JSON.stringify(found);
}
