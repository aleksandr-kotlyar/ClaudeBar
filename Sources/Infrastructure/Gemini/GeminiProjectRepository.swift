import Foundation
import Domain
import os.log

private let logger = Logger(subsystem: "com.claudebar", category: "GeminiProjectRepository")

internal struct GeminiProjectRepository {
    private let networkClient: any NetworkClient
    private let timeout: TimeInterval
    private let maxRetries: Int

    /// gemini-cli's bootstrap endpoint. Returns the user's `cloudaicompanionProject`
    /// (the project ID required for accurate per-user quota on the personal-OAuth
    /// "Gemini Code Assist" tier). The previous implementation called
    /// `cloudresourcemanager.googleapis.com/v1/projects` which fails for users
    /// without a GCP account, leaving the quota request projectless and the API
    /// returning dummy 100% buckets.
    private static let loadCodeAssistEndpoint = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"

    init(
        networkClient: any NetworkClient,
        timeout: TimeInterval,
        maxRetries: Int = 3
    ) {
        self.networkClient = networkClient
        self.timeout = timeout
        self.maxRetries = maxRetries
    }

    /// Fetches the best Gemini project to use for quota checking.
    /// Includes retry logic for cold-start network delays.
    func fetchBestProject(accessToken: String) async -> GeminiProject? {
        guard let projects = await fetchProjects(accessToken: accessToken) else { return nil }
        return projects.bestProjectForQuota
    }

    /// Resolves the user's Gemini Code Assist project via the loadCodeAssist
    /// bootstrap call and wraps it in a single-element `GeminiProjects` so the
    /// rest of the probe pipeline (which expects a collection) keeps working.
    /// Includes retry logic for cold-start network delays.
    func fetchProjects(accessToken: String) async -> GeminiProjects? {
        guard let url = URL(string: Self.loadCodeAssistEndpoint) else {
            logger.error("Invalid loadCodeAssist endpoint URL")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"metadata":{"pluginType":"GEMINI"}}"#.utf8)
        request.timeoutInterval = timeout

        // Retry with exponential backoff for cold-start network delays
        var lastError: Error?
        for attempt in 0..<maxRetries {
            if attempt > 0 {
                // Exponential backoff: 200ms, 500ms, 1000ms
                let delay = UInt64(200_000_000 * (attempt + 1))
                logger.debug("Gemini project discovery: retry \(attempt + 1)/\(self.maxRetries) after delay")
                try? await Task.sleep(nanoseconds: delay)
            }

            do {
                let (data, response) = try await networkClient.request(request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    logger.warning("Gemini project discovery: invalid response type")
                    continue
                }

                if httpResponse.statusCode == 200 {
                    if let decoded = try? JSONDecoder().decode(LoadCodeAssistResponse.self, from: data),
                       let projectId = decoded.cloudaicompanionProject, !projectId.isEmpty {
                        logger.debug("Gemini project discovery: resolved project '\(projectId, privacy: .public)'")
                        let project = GeminiProject(projectId: projectId, labels: nil)
                        return GeminiProjects(projects: [project])
                    }
                    logger.warning("Gemini project discovery: response missing cloudaicompanionProject")
                    return GeminiProjects(projects: [])
                } else if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    // Auth errors won't be fixed by retrying
                    logger.error("Gemini project discovery: auth error \(httpResponse.statusCode)")
                    return nil
                } else {
                    logger.warning("Gemini project discovery: HTTP \(httpResponse.statusCode)")
                }
            } catch let error as URLError where error.code == .timedOut {
                logger.warning("Gemini project discovery: timeout (attempt \(attempt + 1))")
                lastError = error
            } catch {
                logger.warning("Gemini project discovery: \(error.localizedDescription)")
                lastError = error
            }
        }

        if let lastError {
            logger.error("Gemini project discovery failed after \(self.maxRetries) attempts: \(lastError.localizedDescription)")
        }
        return nil
    }

    private struct LoadCodeAssistResponse: Decodable {
        let cloudaicompanionProject: String?
    }
}
