// Apple Terminal supplies rendered text. Return only the keys of tabs whose
// bottom composer resembles a draft. Never return or store its contents.
function possibleDraft(screen, provider) {
    const rows = screen.split(/\r\n|\r|\n/).map(row => row.trim());
    while (rows.length && !rows[rows.length - 1]) rows.pop();
    if (provider === "claude") return claudeDraft(rows);
    const tail = rows.slice(-14);
    const marker = "›";
    const index = tail.map(isPrompt).lastIndexOf(true);
    function isPrompt(row) {
        return row === marker || (row.startsWith(marker) && /\s/.test(row.charAt(1)));
    }
    if (index < 0) return false;
    const firstLine = tail[index].slice(1).trim();
    if (!firstLine || /^(?:try\b|ask (?:codex|claude)\b|type (?:a message|your)|what (?:should|would you)|implement \{feature\}|explain this codebase|run \/review|find and fix a bug in|summarize recent commits|improve documentation in|write tests for|use \/skills)/i.test(firstLine)) return false;
    const after = tail.slice(index + 1);
    // A submitted prompt in scrollback can use the same glyph. Require the
    // composer footer and exclude a second prompt, dialogs and assistant output.
    const footer = /(?:\? for shortcuts|context left|context remaining|gpt-[\w.-]+.*[·│|]|[·│|].*gpt-[\w.-]+)/i;
    const end = after.findIndex(row => footer.test(row));
    return end >= 0 && after.length - end <= 3 &&
        after.slice(0, end).every(row => !row || !/^[•◇◆›❯╭╰]/.test(row));
}

function claudeDraft(rows) {
    // Use the boundaries of the current input box. Wrapped lines may occupy
    // most of the viewport, and a pasted draft can start with a blank line.
    const rule = row => /^[─━]{5,}$/.test(row);
    // A terminal can draw separators without exposing them as text. The
    // auto-mode footer also anchors a single-line prompt at the current input.
    if (/^(?:[⏵▶►▸»]+\s*)?auto mode on\s*\(shift\+tab to cycle\)$/i.test(rows[rows.length - 1] || "")) {
        let last = rows.length - 2;
        while (last >= 0 && !rows[last]) last--;
        if (last >= 0 && rule(rows[last])) last--;
        while (last >= 0 && !rows[last]) last--;
        if (last >= 0 && rows[last].startsWith("❯")) return claudeInputHasText(rows[last].slice(1));
    }
    let bottom = rows.length - 1;
    while (bottom >= 0 && !rule(rows[bottom])) bottom--;
    if (bottom < 0) return false;
    const footer = rows.slice(bottom + 1).filter(Boolean);
    if (footer.some(row => /^[❯•✻✽]/.test(row))) return false;
    if (footer.length > 3) return false;

    let top = bottom - 1;
    while (top >= 0 && !rule(rows[top])) top--;
    if (top < 0) return false;
    const input = rows.slice(top + 1, bottom);
    const first = input.findIndex(Boolean);
    if (first < 0 || !input[first].startsWith("❯")) return false;
    return claudeInputHasText([input[first].slice(1), ...input.slice(first + 1)].join(" "));
}

function claudeInputHasText(input) {
    const text = input.trim();
    if (!text) return false;
    // Claude renders quoted Try suggestions as plain text in Terminal.
    return !/^try\s+["“].*["”]$/i.test(text) &&
        !/^(?:ask claude(?: anything)?|type (?:a message|your message)|explain this codebase|summarize recent commits|what (?:should we work on|would you like to do))[.?!…]*$/i.test(text);
}

function terminalTitle(raw) {
    // The Swift inventory uses cleanText before passing a title to this script.
    return (raw || "").replace(/\p{C}/gu, c => /\s/.test(c) ? " " : "").trim().replace(/\s+/g, " ");
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
                    if (target && terminalTitle(tab.customTitle()) === terminalTitle(target.title) &&
                        possibleDraft(tab.contents(), target.provider)) found.push(target.key);
                } catch (_) { /* A tab may have closed during the scan. */ }
            }
        }
    }
    return JSON.stringify(found);
}
