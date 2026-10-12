import Foundation

/// Matches each spoken word to a voice and groups the words into turns.
enum TranscriptBuilder {
    struct Built {
        var lines: [TranscriptLine]
        var voices: [DetectedVoice]
    }

    /// Short timed pieces of speech (no voices), split at pauses, used to point notes back to the audio.
    static func chunks(words: [TimedWord]) -> [TranscriptLine] {
        var out: [TranscriptLine] = []
        var current: TranscriptLine?
        var count = 0
        for word in words {
            if var line = current, word.start - line.end < 1.2, count < 40 {
                line.text += " " + word.text
                line.end = word.end
                current = line
                count += 1
            } else {
                if let line = current { out.append(line) }
                current = TranscriptLine(speaker: nil, start: word.start, end: word.end, text: word.text)
                count = 1
            }
        }
        if let line = current { out.append(line) }
        return out
    }

    /// Voices that spoke less than this are treated as noise.
    private static let minimumTalkTime = 1.5

    static func build(words: [TimedWord], diarization: DiarizationOutput,
                      suggest: ([Float]) -> Person?) -> Built {
        // Number the voices 1, 2, 3 in the order they first speak.
        let ordered = diarization.segments.sorted { $0.start < $1.start }
        var idFor: [String: String] = [:]
        for seg in ordered where idFor[seg.speaker] == nil {
            idFor[seg.speaker] = String(idFor.count + 1)
        }
        let segments = ordered.map { seg -> DiarizedSegment in
            var s = seg
            s.speaker = idFor[seg.speaker] ?? seg.speaker
            return s
        }

        // Drop voices that barely spoke.
        var talk: [String: Double] = [:]
        for seg in segments { talk[seg.speaker, default: 0] += max(0, seg.end - seg.start) }
        let kept = Set(talk.filter { $0.value >= minimumTalkTime }.keys)
        let usable = segments.filter { kept.contains($0.speaker) }
        guard kept.count > 1, !usable.isEmpty else { return Built(lines: [], voices: []) }

        func speaker(at t: Double) -> String? {
            if let hit = usable.first(where: { $0.start <= t && t <= $0.end }) { return hit.speaker }
            var best: (String, Double)?
            for seg in usable {
                let d = t < seg.start ? seg.start - t : t - seg.end
                if best == nil || d < best!.1 { best = (seg.speaker, d) }
            }
            if let best, best.1 <= 1.5 { return best.0 }
            return nil
        }

        // Words -> turns. First decide who said each word, then pull words that sit just across a
        // speaker change back to the person whose sentence they finish.
        var assigned: [String?] = []
        var previous: String? = usable.first?.speaker
        for word in words {
            let who = speaker(at: (word.start + word.end) / 2) ?? previous
            assigned.append(who)
            previous = who
        }
        keepSentencesTogether(words, &assigned)

        var lines: [TranscriptLine] = []
        var current: TranscriptLine?
        var lastEnd = 0.0
        for (index, word) in words.enumerated() {
            let who = assigned[index]
            if var line = current, line.speaker == who, word.start - lastEnd < 4 {
                line.text += " " + word.text
                line.end = word.end
                current = line
            } else {
                if let line = current { lines.append(line) }
                current = TranscriptLine(speaker: who, start: word.start, end: word.end, text: word.text)
            }
            lastEnd = word.end
        }
        if let line = current { lines.append(line) }

        // One entry per voice, with a clean snippet and a voice print.
        let originalFor = Dictionary(uniqueKeysWithValues: idFor.map { ($0.value, $0.key) })
        var voices: [DetectedVoice] = []
        for id in kept.sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }) {
            let mine = usable.filter { $0.speaker == id }
            guard let best = mine.max(by: { score($0) < score($1) }) else { continue }
            let embedding = VoiceMath.normalized(diarization.embeddings[originalFor[id] ?? ""] ?? [])
            let match = suggest(embedding)
            voices.append(DetectedVoice(
                id: id, personID: nil, name: nil,
                talkTime: talk[id] ?? 0,
                snippetStart: best.start, snippetEnd: min(best.end, best.start + 10),
                embedding: embedding,
                suggestedPersonID: match?.id, suggestedName: match?.name))
        }
        return Built(lines: lines, voices: voices)
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let c = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return c == "." || c == "?" || c == "!" || c == "\u{2026}"
    }

    private static func startsLowercase(_ text: String) -> Bool {
        guard let c = text.first, c.isLetter else { return false }
        return c.isLowercase
    }

    /// Voice boundaries are a few tenths of a second off, so the last words of a sentence often land
    /// on the next speaker. When a turn starts in lowercase and the previous turn stopped without
    /// ending its sentence, the words up to the end of that sentence go back to the previous speaker.
    private static func keepSentencesTogether(_ words: [TimedWord], _ speakers: inout [String?]) {
        var i = 1
        while i < words.count {
            if speakers[i] != speakers[i - 1], !endsSentence(words[i - 1].text), startsLowercase(words[i].text) {
                let from = speakers[i]
                let to = speakers[i - 1]
                var j = i
                var moved = 0
                while j < words.count, speakers[j] == from, moved < 15 {
                    speakers[j] = to
                    moved += 1
                    let done = endsSentence(words[j].text)
                    j += 1
                    if done { break }
                }
                i = j
            } else {
                i += 1
            }
        }
    }

    /// Prefers a long, clear, uninterrupted stretch for the snippet.
    private static func score(_ seg: DiarizedSegment) -> Double {
        let length = min(seg.end - seg.start, 10)
        return length * Double(max(seg.quality, 0.1))
    }
}
