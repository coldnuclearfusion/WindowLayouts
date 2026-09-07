import Foundation
import Observation
import SwiftUI

struct LayoutGroup: Identifiable {
    let id: String
    let configName: String
    let isCurrent: Bool
    let layouts: [WindowLayout]
}

/// 배치 목록을 들고 있고 ~/Library/Application Support/WindowLayouts/layouts.json 에 저장한다.
/// 파일을 직접 편집하면 자동으로 다시 읽는다.
@Observable
final class LayoutStore {
    static let shared = LayoutStore()

    var layouts: [WindowLayout] = []
    var lastAppliedID: UUID?
    var loadError: String?

    let directoryURL: URL
    let fileURL: URL

    @ObservationIgnored private var lastWrittenData: Data?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var pendingSave: DispatchWorkItem?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directoryURL = base.appendingPathComponent("WindowLayouts", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("layouts.json")
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            load(force: true)
        } else {
            save()
        }
        startWatching()
    }

    // MARK: - 조회

    func layout(id: UUID) -> WindowLayout? {
        layouts.first { $0.id == id }
    }

    func index(of id: UUID) -> Int? {
        layouts.firstIndex { $0.id == id }
    }

    func binding(for id: UUID) -> Binding<WindowLayout> {
        Binding(
            get: { self.layout(id: id) ?? WindowLayout(name: "") },
            set: { newValue in
                guard let i = self.index(of: id) else { return }
                self.layouts[i] = newValue
                self.scheduleSave()
            }
        )
    }

    func entryBinding(layoutID: UUID, entryID: UUID) -> Binding<WindowEntry> {
        Binding(
            get: {
                self.layout(id: layoutID)?.windows.first { $0.id == entryID }
                    ?? WindowEntry(bundleID: "", appName: "", title: "", frame: .zero)
            },
            set: { newValue in
                guard let li = self.index(of: layoutID),
                      let wi = self.layouts[li].windows.firstIndex(where: { $0.id == entryID }) else { return }
                self.layouts[li].windows[wi] = newValue
                self.scheduleSave()
            }
        )
    }

    // MARK: - 변경

    func add(_ layout: WindowLayout) {
        layouts.append(layout)
        save()
    }

    func replace(_ layout: WindowLayout) {
        guard let i = index(of: layout.id) else { return }
        layouts[i] = layout
        save()
    }

    func remove(id: UUID) {
        layouts.removeAll { $0.id == id }
        if lastAppliedID == id { lastAppliedID = nil }
        save()
    }

    func duplicate(id: UUID) -> WindowLayout? {
        guard let i = index(of: id) else { return nil }
        var copy = layouts[i]
        copy.id = UUID()
        copy.name = layouts[i].name + " 복사본"
        copy.windows = copy.windows.map { entry in
            var e = entry
            e.id = UUID()
            return e
        }
        layouts.insert(copy, at: i + 1)
        save()
        return copy
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        layouts.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }

    func append(_ entries: [WindowEntry], to layoutID: UUID) {
        guard let i = index(of: layoutID) else { return }
        layouts[i].windows.append(contentsOf: entries)
        save()
    }

    func removeEntries(_ ids: Set<UUID>, from layoutID: UUID) {
        guard let i = index(of: layoutID) else { return }
        layouts[i].windows.removeAll { ids.contains($0.id) }
        save()
    }

    /// 창 항목 하나를 위(-1)/아래(+1)로 한 칸 옮긴다. 배열 순서 = 앞뒤 쌓임 순서
    func moveEntry(_ entryID: UUID, by delta: Int, in layoutID: UUID) {
        guard let li = index(of: layoutID),
              let wi = layouts[li].windows.firstIndex(where: { $0.id == entryID }) else { return }
        let target = wi + delta
        guard target >= 0, target < layouts[li].windows.count else { return }
        layouts[li].windows.swapAt(wi, target)
        save()
    }

    func moveEntries(in layoutID: UUID, fromOffsets: IndexSet, toOffset: Int) {
        guard let i = index(of: layoutID) else { return }
        layouts[i].windows.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }

    func setLaunchPolicy(_ policy: LaunchPolicy, for layoutID: UUID) {
        guard let i = index(of: layoutID) else { return }
        layouts[i].launchPolicy = policy
        save()
    }

    func setDisplayConfig(_ config: DisplayConfig?, for layoutID: UUID) {
        guard let i = index(of: layoutID) else { return }
        layouts[i].displayConfig = config
        save()
    }

    /// 목록 일부(ids)만 보이는 섹션 안에서 드래그로 순서를 바꿀 때, 전체 순서에 반영한다.
    func move(within ids: [UUID], fromOffsets: IndexSet, toOffset: Int) {
        var subset = ids
        subset.move(fromOffsets: fromOffsets, toOffset: toOffset)
        let positions = layouts.indices.filter { ids.contains(layouts[$0].id) }
        var updated = layouts
        for (pos, id) in zip(positions, subset) {
            if let l = layout(id: id) { updated[pos] = l }
        }
        layouts = updated
        save()
    }

    // MARK: - 모니터 구성별 묶기

    /// 현재 모니터 구성에 맞는 배치(구성 무관 배치 포함)가 첫 그룹, 나머지는 구성별로 뒤에 온다.
    func groups(current: DisplayConfig) -> [LayoutGroup] {
        var currentLayouts: [WindowLayout] = []
        var others: [(key: String, name: String, layouts: [WindowLayout])] = []
        for l in layouts {
            if let cfg = l.displayConfig, !cfg.hasSameDisplays(as: current) {
                if let i = others.firstIndex(where: { $0.key == cfg.key }) {
                    others[i].layouts.append(l)
                } else {
                    others.append((cfg.key, cfg.name, [l]))
                }
            } else {
                currentLayouts.append(l)
            }
        }
        var result = [LayoutGroup(id: "current", configName: current.name, isCurrent: true, layouts: currentLayouts)]
        result += others.map { LayoutGroup(id: $0.key, configName: $0.name, isCurrent: false, layouts: $0.layouts) }
        return result
    }

    // MARK: - 저장/읽기

    func reload() {
        load(force: true)
    }

    private func load(force: Bool) {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if !force, data == lastWrittenData { return }
        do {
            let file = try JSONDecoder().decode(LayoutFile.self, from: data)
            layouts = file.layouts
            lastWrittenData = data
            loadError = nil
        } catch {
            loadError = "layouts.json을 읽지 못했습니다: \(error.localizedDescription)"
        }
    }

    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(LayoutFile(layouts: layouts))
            lastWrittenData = data
            try data.write(to: fileURL, options: .atomic)
            loadError = nil
        } catch {
            loadError = "저장 실패: \(error.localizedDescription)"
        }
    }

    /// 텍스트 필드 편집처럼 잦은 변경은 0.5초 뒤에 한 번만 저장
    func scheduleSave() {
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    // MARK: - 파일 감시

    private func startWatching() {
        watcher?.cancel()
        watcher = nil
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            // 에디터의 원자적 저장(rename)에 대비해 잠시 뒤 다시 읽고 감시를 새로 건다
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let self else { return }
                self.load(force: false)
                self.startWatching()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }
}
