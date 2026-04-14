import CodexBarMacroSupport
import Foundation

@ProviderDescriptorRegistration
@ProviderDescriptorDefinition
public enum KimiProviderDescriptor {
    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .kimi,
            metadata: ProviderMetadata(
                id: .kimi,
                displayName: "Kimi",
                sessionLabel: "Weekly",
                weeklyLabel: "Rate Limit",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Kimi usage",
                cliName: "kimi",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: nil,
                dashboardURL: "https://www.kimi.com/code/console",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .kimi,
                iconResourceName: "ProviderIcon-kimi",
                color: ProviderColor(red: 254 / 255, green: 96 / 255, blue: 60 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Kimi cost summary is not supported." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [KimiWebFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "kimi",
                aliases: ["kimi-ai"],
                versionDetector: nil))
    }
}

struct KimiWebFetchStrategy: ProviderFetchStrategy {
    private enum AuthTokenSource {
        case override
        case browser
        case environment
    }

    private struct ResolvedAuthToken {
        let value: KimiCookieOverride
        let source: AuthTokenSource
    }

    let id: String = "kimi.web"
    let kind: ProviderFetchKind = .web
    private static let log = CodexBarLog.logger(LogCategories.kimiWeb)

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        if KimiCookieHeader.resolveCookieOverride(context: context) != nil {
            return true
        }

        if Self.resolveToken(environment: context.env) != nil {
            return true
        }

        #if os(macOS)
        if context.settings?.kimi?.cookieSource != .off {
            return KimiCookieImporter.hasSession(browserDetection: context.browserDetection)
        }
        #endif

        return false
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let tokens = self.resolveTokens(context: context)
        guard !tokens.isEmpty else {
            throw KimiAPIError.missingToken
        }

        var sawInvalidToken = false
        for resolvedToken in tokens {
            do {
                let snapshot = try await KimiUsageFetcher.fetchUsage(authToken: resolvedToken.value.token)
                return self.makeResult(
                    usage: snapshot.toUsageSnapshot(),
                    sourceLabel: "web")
            } catch KimiAPIError.invalidToken {
                sawInvalidToken = true
                continue
            }
        }

        if sawInvalidToken {
            throw KimiAPIError.invalidToken
        }
        throw KimiAPIError.missingToken
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        if case KimiAPIError.missingToken = error { return false }
        if case KimiAPIError.invalidToken = error { return false }
        return true
    }

    private func resolveTokens(context: ProviderFetchContext) -> [ResolvedAuthToken] {
        var tokens: [ResolvedAuthToken] = []

        // Check manual cookie first (highest priority when set)
        if let override = KimiCookieHeader.resolveCookieOverride(context: context) {
            tokens.append(ResolvedAuthToken(value: override, source: .override))
        }

        // Try browser cookie import when auto mode is enabled
        #if os(macOS)
        if context.settings?.kimi?.cookieSource != .off {
            do {
                let sessions = try KimiCookieImporter.importSessions(browserDetection: context.browserDetection)
                tokens.append(contentsOf: sessions.compactMap { session in
                    guard let token = session.authToken else { return nil }
                    return ResolvedAuthToken(value: KimiCookieOverride(token: token), source: .browser)
                })
            } catch {
                // No browser cookies found
            }
        }
        #endif

        // Fall back to environment
        if let override = Self.resolveToken(environment: context.env) {
            tokens.append(ResolvedAuthToken(value: KimiCookieOverride(token: override), source: .environment))
        }

        return self.deduplicatedTokens(tokens)
    }

    private func deduplicatedTokens(_ tokens: [ResolvedAuthToken]) -> [ResolvedAuthToken] {
        var deduplicated: [ResolvedAuthToken] = []
        for token in tokens {
            if deduplicated.contains(where: { $0.value.token == token.value.token }) {
                continue
            }
            deduplicated.append(token)
        }
        return deduplicated
    }

    private static func resolveToken(environment: [String: String]) -> String? {
        ProviderTokenResolver.kimiAuthToken(environment: environment)
    }
}
