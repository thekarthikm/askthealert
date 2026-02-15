/**
 * RAGService — Hybrid retrieval: offline (on-device) + online (backend).
 *
 * Offline corpus:
 *   Store the offline guidance corpus as a bundled JSON file in the iOS app
 *   (app bundle). Load into memory at startup and run keyword + synonym
 *   retrieval over the in-memory chunks using BM25-inspired scoring with
 *   a global synonyms map and per-chunk synonym boosting.
 *
 * Online retrieval:
 *   POST /retrieve to the backend for pgvector-based semantic search
 *   (Supabase Postgres). Hard timeout 400–800 ms. On timeout or error,
 *   fall back to offline immediately. Authority updates (stored online)
 *   override baseline when available.
 *
 * Backend storage is Supabase Postgres only; SQLite is not used on the server.
 */

import Foundation

// MARK: - Public RAG Chunk

/// A chunk of guidance content (from offline corpus or online retrieval).
struct RAGChunk: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let title: String
    let content: String
    let hazardTags: [String]
    let regionTags: [String]
    let citation: String
    let isAuthorityUpdate: Bool
    let similarity: Float

    /// Convenience initializer for offline chunks where similarity is from keyword scoring.
    init(
        id: String,
        title: String,
        content: String,
        hazardTags: [String] = [],
        regionTags: [String] = [],
        citation: String = "",
        isAuthorityUpdate: Bool = false,
        similarity: Float = 0
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.hazardTags = hazardTags
        self.regionTags = regionTags
        self.citation = citation
        self.isAuthorityUpdate = isAuthorityUpdate
        self.similarity = similarity
    }
}

// MARK: - Offline Corpus Types

/// Raw structure of each chunk in the bundled JSON corpus.
private struct OfflineCorpusChunk: Codable {
    let id: String
    let title: String
    let content: String
    let hazardTags: [String]?
    let regionTags: [String]?
    let citation: String?
    let keywords: [String]?
    let synonyms: [String: [String]]?
}

// MARK: - Online Response Types

private struct OnlineRetrieveResponse: Codable {
    let chunks: [RAGChunk]
    let authorityUpdates: [AuthorityUpdate]?
}

private struct AuthorityUpdate: Codable {
    let updateText: String
    let timestamp: String
}

// MARK: - RAG Service

actor RAGService {
    static let shared = RAGService()

    // MARK: Configuration

    /// Backend API base URL.
    private let baseURL: String = {
        if let configured = ProcessInfo.processInfo.environment["API_BASE_URL"], !configured.isEmpty {
            return configured
        }
        #if targetEnvironment(simulator)
        return "http://localhost:3001"
        #else
        return "http://HKs-MacBook-Air.local:3001"
        #endif
    }()

    /// Hard timeout for online retrieval (400–800 ms per spec).
    /// Uses 600ms as a balanced default.
    private let onlineTimeoutSeconds: TimeInterval = 0.6

    // MARK: State

    /// In-memory offline corpus loaded from bundled JSON.
    private var offlineChunks: [OfflineCorpusChunk] = []

    /// Inverse Document Frequency cache — computed once after corpus load.
    /// Maps normalised term → IDF value.
    private var idfCache: [String: Float] = [:]

    /// Global synonyms map — maps a word to its canonical forms.
    /// Built from per-chunk synonyms + hardcoded tornado-domain synonyms.
    private var globalSynonyms: [String: Set<String>] = [:]

    /// Average document length in tokens (for BM25 normalisation).
    private var avgDocLength: Float = 1

    /// Whether the corpus has been loaded.
    private var isLoaded = false

    // MARK: - BM25 Parameters

    /// Term-frequency saturation parameter. Higher values slow down TF saturation.
    /// Increased from 1.2 to 1.5 for better sensitivity to repeated terms in queries.
    private let bm25K1: Float = 1.5

    /// Document length normalisation. 0 = no normalisation, 1 = full normalisation.
    private let bm25B: Float = 0.75

    /// Boost factor for title matches (title is more important).
    /// Increased from 2.0 to 3.0 for more aggressive title matching.
    private let titleBoost: Float = 3.0

    /// Boost factor for keyword field matches.
    /// Increased from 1.5 to 2.0 for better keyword matching.
    private let keywordBoost: Float = 2.0

    /// Boost factor for synonym matches (slightly lower than direct).
    /// Increased from 0.7 to 0.9 to value synonyms more.
    private let synonymBoost: Float = 0.9

    /// Boost factor for hazard tag matches.
    /// Increased from 1.3 to 1.8 for better hazard filtering.
    private let hazardTagBoost: Float = 1.8

    // MARK: - Initialization

    /// Load the offline corpus from the app bundle into memory.
    /// Builds IDF cache and global synonyms map.
    func loadOfflineCorpus() {
        guard !isLoaded else { return }

        guard let url = Bundle.main.url(forResource: "tornado_guidance", withExtension: "json") else {
            print("⚠️ tornado_guidance.json not found in app bundle")
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            offlineChunks = try decoder.decode([OfflineCorpusChunk].self, from: data)
            isLoaded = true
            print("✅ Loaded \(offlineChunks.count) offline RAG chunks into memory")

            // Build indices
            buildIDFCache()
            buildGlobalSynonyms()
        } catch {
            print("❌ Failed to load offline corpus: \(error.localizedDescription)")
        }
    }

    /// Whether the corpus is loaded and ready for retrieval.
    var isReady: Bool { isLoaded }

    /// Number of chunks in the offline corpus.
    var chunkCount: Int { offlineChunks.count }

    // MARK: - Index Building

    /// Build the IDF (Inverse Document Frequency) cache for all terms in the corpus.
    /// IDF = log((N - n + 0.5) / (n + 0.5) + 1) where N = total docs, n = docs containing term.
    private func buildIDFCache() {
        let totalDocs = Float(offlineChunks.count)
        var docFrequency: [String: Int] = [:]

        for chunk in offlineChunks {
            // Gather unique terms from this document
            let allText = tokenise(chunk.title) + tokenise(chunk.content) + (chunk.keywords ?? []).map { normalise($0) }
            let uniqueTerms = Set(allText)
            for term in uniqueTerms {
                docFrequency[term, default: 0] += 1
            }
        }

        // Compute IDF for each term
        for (term, df) in docFrequency {
            let n = Float(df)
            idfCache[term] = log((totalDocs - n + 0.5) / (n + 0.5) + 1.0)
        }

        // Compute average document length
        let totalTokens = offlineChunks.reduce(0) { acc, chunk in
            acc + tokenise(chunk.content).count
        }
        avgDocLength = max(1, Float(totalTokens) / totalDocs)
    }

    /// Build a global synonyms map from per-chunk synonyms plus hardcoded domain synonyms.
    private func buildGlobalSynonyms() {
        // Start with hardcoded tornado-domain synonyms
        var synonymMap: [String: Set<String>] = [
            "tornado": Set(["twister", "cyclone", "funnel", "windstorm", "vortex"]),
            "twister": Set(["tornado", "cyclone", "funnel"]),
            "shelter": Set(["hide", "take cover", "safe place", "protection", "safe room"]),
            "basement": Set(["cellar", "lower level", "underground", "downstairs"]),
            "warning": Set(["emergency", "imminent", "take cover", "act now", "danger"]),
            "watch": Set(["advisory", "heads up", "get ready", "be prepared"]),
            "evacuate": Set(["leave", "get out", "flee", "run", "go away"]),
            "safe": Set(["secure", "protected", "ok", "okay", "alright", "fine"]),
            "danger": Set(["unsafe", "risk", "threat", "hazard", "peril"]),
            "injured": Set(["hurt", "wounded", "harmed", "cut", "broken"]),
            "kids": Set(["children", "child", "baby", "toddler", "family", "son", "daughter"]),
            "pet": Set(["dog", "cat", "animal", "companion animal"]),
            "car": Set(["vehicle", "truck", "van", "suv", "automobile"]),
            "house": Set(["home", "residence", "dwelling"]),
            "apartment": Set(["condo", "flat", "unit", "high-rise", "high rise", "highrise", "tower", "building"]),
            "high-rise": Set(["apartment", "condo", "high rise", "highrise", "tower", "building", "multi-story", "multi-storey"]),
            "condo": Set(["apartment", "flat", "unit", "high-rise", "high rise", "tower", "condominium"]),
            "phone": Set(["number", "call", "dial", "telephone", "contact"]),
            "power outage": Set(["blackout", "no power", "no electricity", "lights out"]),
            "help": Set(["assistance", "support", "aid"]),
            "road": Set(["highway", "street", "route"]),
            "scared": Set(["afraid", "frightened", "anxious", "terrified", "worried", "panicking"]),
            "what to do": Set(["instructions", "steps", "actions", "guidance", "advice"]),
        ]

        // Merge per-chunk synonyms from the corpus
        for chunk in offlineChunks {
            guard let chunkSyns = chunk.synonyms else { continue }
            for (key, values) in chunkSyns {
                let normKey = normalise(key)
                let normValues = Set(values.map { normalise($0) })
                synonymMap[normKey, default: Set()].formUnion(normValues)

                // Also create reverse mappings
                for value in normValues {
                    synonymMap[value, default: Set()].insert(normKey)
                }
            }
        }

        globalSynonyms = synonymMap
    }

    // MARK: - Retrieval

    /// Hybrid retrieve: try online first with strict timeout, always have offline as fallback.
    /// Offline is the primary source (always available). Online is supplementary.
    /// - Parameters:
    ///   - query: The user's question/query text.
    ///   - incidentCode: The current incident code for online context filtering.
    ///   - topK: Maximum number of chunks to return (default 5).
    ///   - hazardFilter: Optional hazard tag filter (e.g., "tornado").
    /// - Returns: Merged array of RAGChunks, authority updates first.
    func retrieve(
        query: String,
        incidentCode: String,
        topK: Int = 5,
        hazardFilter: String? = "tornado"
    ) async -> [RAGChunk] {
        // Always run offline retrieval (instant, works without network)
        let offlineResults = offlineRetrieve(query: query, topK: topK, hazardFilter: hazardFilter)

        // Attempt online retrieval with hard timeout (400-800ms)
        let onlineResults = await onlineRetrieve(
            query: query,
            incidentCode: incidentCode,
            topK: topK
        )

        // Merge: authority updates from online first, then ranked results
        return mergeResults(offline: offlineResults, online: onlineResults, topK: topK)
    }

    /// Offline-only retrieval (for use when network is explicitly unavailable).
    func retrieveOffline(query: String, topK: Int = 5, hazardFilter: String? = "tornado") -> [RAGChunk] {
        return offlineRetrieve(query: query, topK: topK, hazardFilter: hazardFilter)
    }

    // MARK: - Offline Retrieval (BM25 + Synonyms)

    /// Perform BM25-inspired scoring with synonym expansion and field boosting.
    private func offlineRetrieve(query: String, topK: Int, hazardFilter: String?) -> [RAGChunk] {
        guard isLoaded, !offlineChunks.isEmpty else { return [] }

        let queryTokens = tokenise(query)
        guard !queryTokens.isEmpty else { return [] }

        // Expand query with synonyms
        let expandedQueryTokens = expandWithSynonyms(queryTokens)

        var scored: [(chunk: OfflineCorpusChunk, score: Float)] = []

        for chunk in offlineChunks {
            // Apply hazard filter if specified
            if let filter = hazardFilter {
                let hazardTags = chunk.hazardTags ?? []
                if !hazardTags.isEmpty && !hazardTags.contains(filter) {
                    continue
                }
            }

            let score = computeBM25Score(
                chunk: chunk,
                queryTokens: queryTokens,
                expandedQueryTokens: expandedQueryTokens
            )

            // Accept any positive score (was already > 0, keeping same)
            // But also track all chunks with their scores for fallback
            scored.append((chunk, score))
        }

        // Sort by score descending
        let sortedScored = scored.sorted { $0.score > $1.score }
        
        // If no chunks scored above 0, take top chunks anyway (better than nothing)
        let hasPositiveScores = sortedScored.first?.score ?? 0 > 0
        let chunksToReturn = hasPositiveScores 
            ? sortedScored.filter { $0.score > 0 }
            : sortedScored // Return all chunks sorted by score even if all are 0
        
        return chunksToReturn
            .prefix(topK)
            .map { item in
                RAGChunk(
                    id: item.chunk.id,
                    title: item.chunk.title,
                    content: item.chunk.content,
                    hazardTags: item.chunk.hazardTags ?? [],
                    regionTags: item.chunk.regionTags ?? [],
                    citation: item.chunk.citation ?? "",
                    isAuthorityUpdate: false,
                    similarity: item.score
                )
            }
    }

    /// Compute BM25-inspired score for a chunk given query tokens.
    /// Incorporates: title boost, keyword boost, synonym matching, hazard tag relevance.
    private func computeBM25Score(
        chunk: OfflineCorpusChunk,
        queryTokens: [String],
        expandedQueryTokens: Set<String>
    ) -> Float {
        // Tokenise chunk fields
        let titleTokens = tokenise(chunk.title)
        let contentTokens = tokenise(chunk.content)
        let keywordTokens = (chunk.keywords ?? []).map { normalise($0) }

        // Build term frequency maps for each field
        let titleTF = termFrequency(titleTokens)
        let contentTF = termFrequency(contentTokens)
        let keywordSet = Set(keywordTokens)

        let docLength = Float(contentTokens.count)

        var totalScore: Float = 0

        // Score each original query term
        for term in queryTokens {
            let idf = idfCache[term] ?? 0.5 // Default IDF for unknown terms

            // Content BM25 score
            let tf = Float(contentTF[term] ?? 0)
            let bm25TF = (tf * (bm25K1 + 1)) / (tf + bm25K1 * (1 - bm25B + bm25B * docLength / avgDocLength))
            totalScore += idf * bm25TF

            // Title boost (exact match in title is very relevant)
            if titleTF[term] != nil {
                totalScore += idf * titleBoost
            }

            // Keyword field boost
            if keywordSet.contains(term) {
                totalScore += idf * keywordBoost
            }
        }

        // Score synonym-expanded terms (only the new ones, not original query terms)
        let originalSet = Set(queryTokens)
        let synonymOnlyTokens = expandedQueryTokens.subtracting(originalSet)

        for term in synonymOnlyTokens {
            let idf = idfCache[term] ?? 0.3

            // Content synonym match
            let tf = Float(contentTF[term] ?? 0)
            if tf > 0 {
                let bm25TF = (tf * (bm25K1 + 1)) / (tf + bm25K1 * (1 - bm25B + bm25B * docLength / avgDocLength))
                totalScore += idf * bm25TF * synonymBoost
            }

            // Title synonym match
            if titleTF[term] != nil {
                totalScore += idf * titleBoost * synonymBoost
            }

            // Keyword synonym match
            if keywordSet.contains(term) {
                totalScore += idf * keywordBoost * synonymBoost
            }
        }

        // Per-chunk synonym boost: if the chunk defines synonyms that match the query
        if let chunkSynonyms = chunk.synonyms {
            for (key, syns) in chunkSynonyms {
                let normKey = normalise(key)
                let normSyns = syns.map { normalise($0) }

                for qToken in queryTokens {
                    if normKey == qToken || normSyns.contains(qToken) {
                        totalScore += 0.5 // Small boost for per-chunk synonym relevance
                    }
                }
            }
        }

        // Hazard tag relevance boost
        let hazardTags = chunk.hazardTags ?? []
        for qToken in queryTokens {
            if hazardTags.contains(qToken) {
                totalScore += hazardTagBoost
            }
        }

        return totalScore
    }

    // MARK: - Online Retrieval (POST /retrieve)

    /// Attempt online retrieval from backend with strict timeout.
    /// Returns empty array on any failure (timeout, network error, server error).
    private func onlineRetrieve(query: String, incidentCode: String, topK: Int) async -> [RAGChunk] {
        guard let url = URL(string: "\(baseURL)/retrieve") else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Hard timeout 400–800 ms per spec (using configured value)
        request.timeoutInterval = onlineTimeoutSeconds

        let body: [String: Any] = [
            "query": query,
            "incidentCode": incidentCode,
            "topK": topK,
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            // Use URLSession with a custom ephemeral configuration for strict timeout
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = onlineTimeoutSeconds
            config.timeoutIntervalForResource = onlineTimeoutSeconds + 0.2 // small buffer
            config.waitsForConnectivity = false // Fail immediately if no connection
            let session = URLSession(configuration: config)

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200 ... 299).contains(httpResponse.statusCode)
            else {
                return []
            }

            let decoded = try JSONDecoder().decode(OnlineRetrieveResponse.self, from: data)
            return decoded.chunks
        } catch {
            // Expected to fail frequently (offline users, timeout, etc.)
            // Only log in debug builds
            #if DEBUG
            print("ℹ️ Online RAG retrieval unavailable (offline fallback active): \(error.localizedDescription)")
            #endif
            return []
        }
    }

    // MARK: - Result Merging

    /// Merge offline and online results with deduplication.
    /// Priority: authority updates > online results > offline results.
    private func mergeResults(offline: [RAGChunk], online: [RAGChunk], topK: Int) -> [RAGChunk] {
        var seen = Set<String>()
        var merged: [RAGChunk] = []

        // 1. Authority updates from online (highest priority — override baseline)
        for chunk in online where chunk.isAuthorityUpdate {
            if seen.insert(chunk.id).inserted {
                merged.append(chunk)
            }
        }

        // 2. Non-authority online results (semantic search may find things keyword misses)
        for chunk in online where !chunk.isAuthorityUpdate {
            if seen.insert(chunk.id).inserted {
                merged.append(chunk)
            }
        }

        // 3. Offline results (always available, BM25-scored)
        for chunk in offline {
            if seen.insert(chunk.id).inserted {
                merged.append(chunk)
            }
        }

        return Array(merged.prefix(topK))
    }

    // MARK: - Text Processing

    /// Normalise text: lowercase, remove punctuation, collapse whitespace.
    private func normalise(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "[^\\w\\s]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Tokenise text into an array of normalised words.
    /// Filters out common stopwords for better retrieval quality.
    private func tokenise(_ text: String) -> [String] {
        normalise(text)
            .split(separator: " ")
            .map(String.init)
            .filter { !stopwords.contains($0) && $0.count > 1 }
    }

    /// Build a term frequency map from tokens.
    private func termFrequency(_ tokens: [String]) -> [String: Int] {
        var tf: [String: Int] = [:]
        for token in tokens {
            tf[token, default: 0] += 1
        }
        return tf
    }

    /// Expand query tokens with synonyms from the global synonyms map.
    /// Returns the union of original tokens and their synonym expansions.
    private func expandWithSynonyms(_ queryTokens: [String]) -> Set<String> {
        var expanded = Set(queryTokens)

        for token in queryTokens {
            if let synonyms = globalSynonyms[token] {
                expanded.formUnion(synonyms)
            }
        }

        return expanded
    }

    // MARK: - Stopwords

    /// Common English stopwords to filter from queries and documents.
    private let stopwords: Set<String> = [
        "a", "an", "the", "is", "it", "in", "on", "at", "to", "of", "for",
        "and", "or", "but", "if", "by", "as", "be", "am", "are", "was",
        "were", "been", "being", "have", "has", "had", "do", "does", "did",
        "will", "would", "could", "should", "can", "may", "might", "shall",
        "not", "no", "so", "up", "out", "just", "than", "then", "too",
        "very", "what", "which", "who", "whom", "this", "that", "these",
        "those", "my", "your", "his", "her", "its", "our", "their", "me",
        "him", "us", "them", "i", "we", "you", "he", "she", "they",
        "with", "from", "about", "into", "through", "during", "before",
        "after", "above", "below", "between", "under", "again", "further",
        "once", "here", "there", "when", "where", "why", "how", "all",
        "each", "every", "both", "few", "more", "most", "other", "some",
        "such", "only", "own", "same", "also", "any",
    ]
}
