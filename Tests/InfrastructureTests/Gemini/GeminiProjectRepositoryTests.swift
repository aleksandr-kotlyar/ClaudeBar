import Testing
import Foundation
import Mockable
@testable import Infrastructure

@Suite
struct GeminiProjectRepositoryTests {

    @Test
    func `fetchProjects returns nil when network fails`() async throws {
        let mockService = MockNetworkClient()
        given(mockService)
            .request(.any)
            .willProduce { _ in throw URLError(.notConnectedToInternet) }

        let repository = GeminiProjectRepository(
            networkClient: mockService,
            timeout: 1.0
        )

        let projects = await repository.fetchProjects(accessToken: "token")
        #expect(projects == nil)
    }

    @Test
    func `fetchProjects resolves project from loadCodeAssist response`() async throws {
        let mockService = MockNetworkClient()
        let json = """
        {
            "currentTier": { "id": "standard-tier" },
            "cloudaicompanionProject": "alien-superstate-rq4hk"
        }
        """.data(using: .utf8)!

        given(mockService)
            .request(.any)
            .willReturn((json, HTTPURLResponse(url: URL(string: "http://x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!))

        let repository = GeminiProjectRepository(
            networkClient: mockService,
            timeout: 1.0
        )

        let projects = await repository.fetchProjects(accessToken: "token")

        #expect(projects != nil)
        #expect(projects?.projects.count == 1)
        #expect(projects?.projects.first?.projectId == "alien-superstate-rq4hk")
    }

    @Test
    func `fetchProjects calls loadCodeAssist endpoint with bearer token`() async throws {
        let mockService = MockNetworkClient()
        let json = """
        { "cloudaicompanionProject": "alien-superstate-rq4hk" }
        """.data(using: .utf8)!

        given(mockService)
            .request(.any)
            .willReturn((json, HTTPURLResponse(url: URL(string: "http://x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!))

        let repository = GeminiProjectRepository(
            networkClient: mockService,
            timeout: 1.0
        )

        _ = await repository.fetchProjects(accessToken: "test-token")

        verify(mockService)
            .request(.matching { request in
                let url = request.url?.absoluteString ?? ""
                guard url.contains("loadCodeAssist") else { return false }
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" else { return false }
                guard let body = request.httpBody, let bodyStr = String(data: body, encoding: .utf8) else { return false }
                return bodyStr.contains("\"pluginType\":\"GEMINI\"")
            })
            .called(1)
    }

    @Test
    func `fetchProjects returns empty when cloudaicompanionProject is missing`() async throws {
        let mockService = MockNetworkClient()
        let json = """
        { "currentTier": { "id": "standard-tier" } }
        """.data(using: .utf8)!

        given(mockService)
            .request(.any)
            .willReturn((json, HTTPURLResponse(url: URL(string: "http://x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!))

        let repository = GeminiProjectRepository(
            networkClient: mockService,
            timeout: 1.0
        )

        let projects = await repository.fetchProjects(accessToken: "token")

        #expect(projects?.projects.isEmpty == true)
    }

    @Test
    func `fetchBestProject returns the resolved project`() async throws {
        let mockService = MockNetworkClient()
        let json = """
        { "cloudaicompanionProject": "alien-superstate-rq4hk" }
        """.data(using: .utf8)!

        given(mockService)
            .request(.any)
            .willReturn((json, HTTPURLResponse(url: URL(string: "http://x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!))

        let repository = GeminiProjectRepository(
            networkClient: mockService,
            timeout: 1.0
        )

        let project = await repository.fetchBestProject(accessToken: "token")

        #expect(project?.projectId == "alien-superstate-rq4hk")
    }
}
