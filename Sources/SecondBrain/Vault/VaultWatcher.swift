// VaultWatcher.swift — наблюдение за изменениями vault через FSEvents.
//
// Зачем: пользователь может править vault параллельно в Obsidian/Finder/git —
// дерево в приложении обязано подхватывать внешние изменения само.
//
// Устройство: FSEventStream на корень vault (рекурсивно, latency 0.3 с на
// стороне системы) + свой Debouncer ещё на 0.3 с — пачка событий (git pull,
// массовое переименование) схлопывается в одно перестроение дерева.
// Свои собственные CRUD-операции отдельно не фильтруем: лишний rebuild дёшев,
// а гонки «своё/чужое» исчезают как класс.
//
// В MA аналога нет — модуль написан с нуля (задача 02).

import Foundation
import CoreServices

/// Схлопывает частые вызовы в один: исполняет block через `delay` после
/// ПОСЛЕДНЕГО schedule(). Потокобезопасен относительно очереди `queue`.
final class Debouncer {
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private var pending: DispatchWorkItem?

    init(delay: TimeInterval, queue: DispatchQueue = .main) {
        self.delay = delay
        self.queue = queue
    }

    /// Планирует исполнение, отменяя предыдущее незапущенное.
    func schedule(_ block: @escaping () -> Void) {
        pending?.cancel()
        let item = DispatchWorkItem(block: block)
        pending = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Отменяет запланированное (при закрытии vault).
    func cancel() {
        pending?.cancel()
        pending = nil
    }
}

/// FSEvents-наблюдатель за одной директорией (рекурсивно). Живёт, пока открыт
/// vault; VaultManager пересоздаёт его при смене vault и обязан отпустить при
/// закрытии (deinit останавливает поток событий).
final class VaultWatcher {
    private var stream: FSEventStreamRef?
    private let debouncer: Debouncer
    private let onChange: () -> Void

    /// - Parameters:
    ///   - url: корень vault;
    ///   - debounce: пауза схлопывания пачки событий перед onChange;
    ///   - onChange: вызывается на main queue после затишья.
    init(url: URL, debounce: TimeInterval = 0.3, onChange: @escaping () -> Void) {
        self.debouncer = Debouncer(delay: debounce, queue: .main)
        self.onChange = onChange

        // info-указатель — на self без retain: жизненный цикл стрима строго
        // вложен в жизненный цикл watcher'а (deinit гасит стрим до утечки self).
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        // latency 0.3 c: система сама коалесцирует события; kFSEventStreamCreateFlagNone —
        // нам не нужны пофайловые детали, любой сигнал = «перестрой дерево».
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<VaultWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.debouncer.schedule { watcher.onChange() }
            },
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
        )

        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
            FSEventStreamStart(stream)
        }
    }

    deinit {
        stop()
    }

    /// Останавливает и освобождает FSEventStream. Идемпотентен.
    func stop() {
        debouncer.cancel()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
