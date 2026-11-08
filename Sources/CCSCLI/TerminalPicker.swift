import CCSCore
import CTerminal
import Foundation

final class TerminalPicker {
    let service: SessionService
    let newSessions: NewSessions
    let cliPath: String
    var provider: ProviderFilter, newProvider: Provider
    let enabledProviders: [Provider]
    let newProviderChoices: [Provider]
    var days: Int, recent: Bool, watch: Int
    var sessions = [Session](), query = "", selected = 0, top = 0, message = ""

    init(service: SessionService, settings: Settings, days: Int, recent: Bool, watch: Int, cliPath: String, provider: ProviderFilter, enabledProviders: [Provider]) {
        self.service = service; self.newSessions = NewSessions(service: service, settings: settings)
        self.enabledProviders = enabledProviders; self.newProviderChoices = settings.enabledProviders
        self.provider = provider; self.newProvider = settings.newProvider
        self.days = days; self.recent = recent; self.watch = watch; self.cliPath = cliPath
    }
    func put(_ y: Int, _ x: Int, _ text: String, _ limit: Int, _ style: Int = 0) {
        ccs_terminal_put(Int32(y), Int32(x), text, Int32(max(0, limit)), Int32(style))
    }
    func run() throws {
        sessions = try service.collect(days: days, provider: provider, enabledProviders: enabledProviders)
        guard ccs_terminal_start() == 0 else { throw CCSError.message("Could not initialize the terminal picker.") }
        defer { ccs_terminal_end() }
        var nextRefresh = Date().addingTimeInterval(Double(watch))
        while true {
            var h: Int32 = 0, w: Int32 = 0; ccs_terminal_size(&h, &w)
            let height = Int(h), width = Int(w)
            let rows = sessionRows(sessions, query: query, recent: recent)
            let choices = rows.indices.filter { rows[$0].session != nil }
            selected = min(selected, max(0, choices.count - 1))
            let current = choices.isEmpty ? -1 : choices[selected]
            if watch > 0 && Date() >= nextRefresh {
                let keep = current >= 0 ? rows[current].session?.key : nil
                do { sessions = try service.collect(days: days, provider: provider, enabledProviders: enabledProviders) } catch { message = error.localizedDescription }
                let refreshed = sessionRows(sessions, query: query, recent: recent).compactMap(\.session)
                if let keep, let i = refreshed.firstIndex(where: { $0.key == keep }) { selected = i }
                nextRefresh = Date().addingTimeInterval(Double(watch)); continue
            }
            ccs_terminal_clear()
            if height < 6 || width < 12 {
                put(0, 0, "Resize terminal", width - 1)
            } else {
                let panel = height >= 16, body = height - (panel ? 9 : 4)
                if current >= 0 { top = min(max(top, current - body + 1), current) }
                put(0, 1, "CCS sessions", width - 2, 1)
                let counts = "\(sessions.filter(\.isLive).count) open · \(sessions.count) total"
                put(0, 16, counts, width - 17, 2)
                put(1, 1, "\(provider.title) · New: \(newProvider.title) · \(recent ? "Recent" : "Folders") · \(days == 0 ? "all" : "\(days)d")\(watch > 0 ? " · refresh \(watch)s" : "")", width - 2, 2)
                for (offset, row) in rows.dropFirst(top).prefix(body).enumerated() {
                    let y = 2 + offset, active = top + offset == current
                    if let s = row.session {
                        ccs_terminal_row(Int32(y), active ? 1 : 0)
                        let indent = min(row.depth * 2, max(0, width - 28)), style = active ? 4 : 0
                        let mark = s.isSaved ? "○" : s.status == "unknown" ? "?" : "●"
                        let color = s.status == "idle" ? 8 : s.isSaved ? 2 : s.status == "unknown" ? 32 : 16
                        put(y, 1 + indent, mark, 2, style | color)
                        let stats = [s.statistics, ageString(s.mtime)].filter { !$0.isEmpty }.joined(separator: " ")
                        let tail = width >= 36 ? stats.count + 2 : 0
                        put(y, 3 + indent, "[\(s.provider.title)] " + s.displayTitle + (recent ? " · " + shortPath(s.cwd) : ""), width - indent - tail - 4, style)
                        if tail > 0 { put(y, width - tail, stats, tail - 1, style | (s.isLarge ? 32 : 2)) }
                    } else { put(y, 1 + min(row.depth * 2, max(0, width - 5)), row.label, width - 3 - min(row.depth * 2, max(0, width - 5)), 64) }
                }
                if choices.isEmpty { put(3, 3, "No sessions match. Esc clears search; ←→ changes date range.", width - 4, 2) }
                if panel && current >= 0, let s = rows[current].session {
                    put(height - 7, 1, String(repeating: "─", count: max(0, width - 2)), width - 2, 2)
                    put(height - 6, 2, s.recap.isEmpty ? "No recap saved for this session" : s.recap, width - 4)
                    put(height - 5, 2, "Last prompt: " + s.last, width - 4, 2)
                    put(height - 4, 2, shortPath(s.cwd), width - 4, 2)
                    put(height - 3, 2, "\(s.provider.title) · \(s.statistics.isEmpty ? "" : s.statistics + " · ")\(s.status) · id \(s.key)", width - 4, s.isLarge ? 32 : 2)
                }
                put(height - 2, 1, "Search: " + query, width - 2, 1)
                let issue = service.issues.filter { provider.includes($0.key) }.sorted { $0.key.rawValue < $1.key.rawValue }.first?.value
                put(height - 1, 1, message.isEmpty ? (issue ?? "↵ open · ^O new here · ^T new session · ^F filter · ^B new provider · Tab view · ^R refresh · ^C quit") : message, width - 2, message.isEmpty ? 2 : 32)
            }
            ccs_terminal_refresh()
            let delay = watch > 0 ? max(1, Int(nextRefresh.timeIntervalSinceNow * 1000)) : -1
            let key = Int(ccs_terminal_key(Int32(delay)))
            message = ""
            if key == 3 { return }
            if key == CCS_TIMEOUT || key == CCS_RESIZE { continue }
            if height < 6 || width < 12 { continue }
            switch key {
            case CCS_UP, 16: selected = max(0, selected - 1)
            case CCS_DOWN, 14: selected = min(max(0, choices.count - 1), selected + 1)
            case CCS_PAGE_UP: selected = max(0, selected - 10)
            case CCS_PAGE_DOWN: selected = min(max(0, choices.count - 1), selected + 10)
            case CCS_HOME: selected = 0
            case CCS_END: selected = max(0, choices.count - 1)
            case CCS_LEFT, CCS_RIGHT:
                days = cycleWindow(days, step: key == CCS_RIGHT ? 1 : -1)
                do { sessions = try service.collect(days: days, provider: provider, enabledProviders: enabledProviders) } catch { message = error.localizedDescription }
                selected = 0; top = 0
            case 9: recent.toggle(); selected = 0; top = 0
            case 27: query = ""; selected = 0
            case 127, 8: if !query.isEmpty { query.removeLast() }; selected = 0
            case 18:
                do { sessions = try service.collect(days: days, provider: provider, enabledProviders: enabledProviders) } catch { message = error.localizedDescription }
            case 6:
                let order = ProviderFilter.allCases.filter { filter in filter == .all || enabledProviders.contains { filter.includes($0) } }
                provider = order[((order.firstIndex(of: provider) ?? 0) + 1) % order.count]
                do {
                    var settings = Settings.load(); settings.providerFilter = provider; try settings.save()
                    sessions = try service.collect(days: days, provider: provider, enabledProviders: enabledProviders)
                } catch { message = error.localizedDescription }
                selected = 0; top = 0
            case 2:
                guard newProviderChoices.count > 1 else { continue }
                newProvider = newProvider == .claude ? .codex : .claude
                do { var settings = Settings.load(); settings.newProvider = newProvider; try settings.save() }
                catch { message = error.localizedDescription }
            case 20:
                do { try newSessions.start(cliPath: cliPath, provider: newProvider); if watch == 0 { return } } catch { message = error.localizedDescription }
            case 10, 13, 15:
                guard current >= 0, let s = rows[current].session else { continue }
                var fresh = key == 15
                if s.isLarge && !fresh {
                    guard let choice = confirm(s, height: height, width: width) else { continue }
                    fresh = choice
                }
                do { try service.activate(s, fresh: fresh); if watch == 0 { return } } catch { message = error.localizedDescription }
            default:
                if key >= 32, let scalar = UnicodeScalar(UInt32(key)), !CharacterSet.controlCharacters.contains(scalar) { query.unicodeScalars.append(scalar); selected = 0 }
            }
        }
    }
    func confirm(_ s: Session, height: Int, width: Int) -> Bool? {
        var fresh = true
        while true {
            ccs_terminal_clear()
            put(1, 1, "Large session: \(s.turns) prompts\(s.cost.map { " · $\(Int($0.rounded()))" } ?? "")", width - 2, 33)
            put(2, 1, "Resuming includes the saved conversation in future prompts.", width - 2)
            put(3, 1, "Start clean in " + shortPath(s.cwd) + "?", width - 2)
            put(height - 3, 1, " Start clean here ", width - 2, fresh ? 4 : 0)
            put(height - 2, 1, " Resume ", width - 2, fresh ? 0 : 4)
            put(height - 1, 1, "←→ choose · Enter confirm · n clean · r resume · Esc cancel", width - 2, 2)
            ccs_terminal_refresh()
            switch Int(ccs_terminal_key(-1)) {
            case 3, 27: return nil
            case 10, 13: return fresh
            case 110, 78: return true
            case 114, 82: return false
            case CCS_LEFT, CCS_RIGHT, CCS_UP, CCS_DOWN, 9: fresh.toggle()
            case CCS_RESIZE: return nil
            default: break
            }
        }
    }
}
